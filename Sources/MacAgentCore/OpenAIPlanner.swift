import Foundation

@MainActor
public protocol Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan
}

public extension Planning {
    func plan(command: String) async throws -> AgentPlan {
        try await plan(command: command, priorTaskContext: nil)
    }
}

public enum PlannerError: Error, LocalizedError, Equatable, CarriesBackendError {
    /// A run reached a planner that should never have been asked for a plan (SONNY-136).
    ///
    /// **This is `missingAPIKey` renamed to the condition it actually reports, not a new case.** The
    /// old name and its sentence — "OPENAI_API_KEY is not set. Add it to the environment before
    /// launching the app." — described a state that stopped existing when SONNY-130 moved planning
    /// behind the gateway, and the case did not go with it because `InstantOnlyFallbackPlanner`
    /// still throws it: a run built from a pre-built plan or from the instant resolver is given a
    /// planner that refuses, so that "this plan is already made" is a property of the runner rather
    /// than a convention. So the one *reachable* thing this case reported was being reported in the
    /// words of an unreachable one — a live path wearing a dead message, which is the shape this
    /// ticket exists to remove.
    ///
    /// Reaching it means a plan-less run got as far as planning, which no retry and no user action
    /// fixes, so the sentence says what happened and stops rather than inviting one.
    case noPlannerRan
    /// Still live. `OpenAIResponseParser` throws it and `VisionModelClient` uses that parser.
    /// **This named `CerebrasPlanner` as a second user until SONNY-132 deleted that class** — the
    /// open-weights planner is a server-side provider now, so its parsing happens in
    /// `server/src/model/cerebras.ts` and nothing on this side reads its wire shape.
    case missingOutputText
    /// A call to Sonny's backend failed. The user sees `SonnyBackendCopy`'s sentence for it, never
    /// the server's own `message` (§7.1).
    case backend(SonnyBackendError)

    /// ``CarriesBackendError``: so a cancellation raised inside the shared client is still
    /// recognisable after this type wraps it (SONNY-320). Without it a user who pressed stop while
    /// a plan was in flight is told *"Sonny couldn't finish this one. Try again."*, because
    /// ``SonnyBackendError/isCancellation(_:)`` cannot see through the wrapper and every caller
    /// that asks it takes the failure branch.
    ///
    /// **One property answers for two routes.** `WebResearchSynthesizer` throws this same case
    /// rather than declaring a `backend` of its own, so `/v1/plan` and `/v1/research/synthesize`
    /// are both covered here — the population is the error type, not the route.
    public var backendError: SonnyBackendError? {
        guard case .backend(let error) = self else { return nil }
        return error
    }

    public var errorDescription: String? {
        switch self {
        case .noPlannerRan:
            return "Sonny couldn't plan this one."
        case .missingOutputText:
            // **Provider-neutral since SONNY-136.** It read "OpenAI response did not include text
            // output." — a vendor's name in a sentence a user can be shown, which the founder's
            // decision of 2026-08-19 forbids and which stopped being true besides: which provider
            // answers a plan is `MODEL_ROUTE_PLAN` on the gateway and may be any of three.
            return "Sonny couldn't read the plan that came back."
        case .backend(let error):
            return SonnyBackendCopy.sentence(for: error)
        }
    }
}

/// The shipped planner, **talking to Sonny's own backend rather than to a provider** (SONNY-130).
///
/// The type name is unchanged, and that is deliberate rather than an oversight. What SONNY-130's
/// sixth requirement is actually about is the model identifier, the vendor endpoint and the
/// provider choice, and all three are gone from here: they now live in `server/src/model/`, which
/// is what turns SONNY-110's move to a paid zero-retention route into a redeploy.
///
/// **One of the two reasons for the name went with SONNY-132 and the other did not.** The first was
/// that `CerebrasPlanner` called `OpenAIPlanner.systemPrompt(toolRegistry:)`, so renaming the type
/// meant editing a file that ticket's never-touch list forbade; that class is deleted now, so the
/// argument is gone. The second stands on its own: `docs/sonny-backend-api-contract.md` §4.2 cites
/// this exact symbol as the post-move prompt builder, so the name is part of a document the server
/// and both clients are written against. **This class is not OpenAI-specific and has not been since
/// SONNY-130** — which provider serves a plan is `MODEL_ROUTE_PLAN`, and on any given request it
/// may be any of three.
@MainActor
public final class OpenAIPlanner: Planning {
    private let client: SonnyBackendClient
    private let taskContext: BackendTaskContext
    private let toolRegistry: ToolRegistry
    private let usageRecorder: any TaskUsageRecording

    /// **`client` and `taskContext` have no defaults**, for the two reasons this repository already
    /// records for parameters of this kind. A defaulted client would be a second construction of
    /// the shared one, which would defeat the single-flight refresh guard the whole of PR #133's F1
    /// depends on — ten concurrent 401s must cause one rotation, and two clients means two. A
    /// defaulted `taskContext` would be a defaulted `retention`, which §2.4.2 forbids on the wire
    /// for exactly the reason it should be forbidden here: a privacy field nobody chose.
    public init(
        client: SonnyBackendClient,
        taskContext: BackendTaskContext,
        toolRegistry: ToolRegistry = .default,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared
    ) {
        self.client = client
        self.taskContext = taskContext
        self.toolRegistry = toolRegistry
        self.usageRecorder = usageRecorder
    }

    public func plan(command: String, priorTaskContext: PriorTaskContext? = nil) async throws -> AgentPlan {
        let body = try SonnyTextRouteBody(
            context: taskContext,
            messages: messages(command: command, priorTaskContext: priorTaskContext),
            schemaName: AgentPlanSchema.name,
            schema: AgentPlanSchema.schema()
        ).encoded()

        let decoded: SonnyTextRouteResponse
        do {
            decoded = try await client.modelRouteResponse(
                SonnyTextRouteResponse.self,
                route: .plan,
                body: body
            )
        } catch let error as SonnyBackendError {
            throw PlannerError.backend(error)
        }

        // **Recorded before the plan is decoded, which is the order the environment-key version
        // used and the order that is right.** A plan the model returned malformed still cost what
        // it cost, and a summary that silently omitted exactly the failed runs would understate the
        // ones a user is most likely to ask about.
        usageRecorder.record(
            decoded.usage?.record(kind: .planner, route: .plan)
                ?? AIUsageRecord(kind: .planner, model: SonnyModelRoute.plan.usageModelName)
        )
        return try AgentPlanDecoder.decodeStrict(from: decoded.output_text)
    }

    /// §4.2's ordered, role-tagged messages — the same three the request body has always carried,
    /// in the same order, with the same text.
    private func messages(
        command: String,
        priorTaskContext: PriorTaskContext?
    ) -> [(role: String, text: String)] {
        var messages: [(role: String, text: String)] = [
            (role: "system", text: Self.systemPrompt(toolRegistry: toolRegistry))
        ]
        if let priorTaskContext {
            messages.append((role: "user", text: priorTaskContext.plannerContextText))
        }
        messages.append((role: "user", text: command))
        return messages
    }

    /// The routine-exclusion sentence's operation list, derived from
    /// `StoredRoutine.forbiddenStepOperations` rather than written out beside it (SONNY-74).
    ///
    /// The sentence named five operations while the store refused nine, and nothing on either side
    /// said so. A user asking for "a routine that opens my research workspace" got a plan the
    /// planner had no reason to avoid, then `AutomationStoreError.unsafeRoutineStep` — an
    /// internal-sounding refusal naming an operation they never typed — where a working routine or
    /// an explanation belonged. The nested schema is no help: `AgentPlanSchema.stepSchema` gives
    /// nested steps the same `plannerVisibleCases` enum as top-level ones, so every planner-visible
    /// operation is structurally emittable inside `routineSteps` and this prose is the only thing
    /// steering the model away from the ones the store will refuse.
    ///
    /// **Derived, because the gap was not static.** The set grew twice after the sentence was
    /// written, and the second addition was `.visionSession` — the third of three independent
    /// layers of "unattended vision: never", listed there so the scheduled path can never see a
    /// vision step through the routine door. Nothing broke, because the validator still refuses;
    /// what changed is that the belt-and-braces layer became the one doing the catching while the
    /// model was being invited toward a shape the product refuses on safety grounds. Deriving is
    /// the only shape that survives the set changing a third time.
    ///
    /// Declaration order via `allCases`, because a `Set` has none and a sentence that reordered
    /// itself between processes would make the golden untestable and defeat prompt caching.
    ///
    /// One sentence covers every provider, and it still does after SONNY-132 moved the second one
    /// server-side. This prompt is `messages[0]` on the wire (§4.2), so whichever provider the
    /// router picks receives this text — the Cerebras adapter appends a schema suffix to its *copy*
    /// and edits nothing here. A fix here cannot land on one provider and not the others.
    nonisolated private static var forbiddenRoutineStepPhrase: String {
        let names = AgentOperation.allCases
            .filter { StoredRoutine.forbiddenStepOperations.contains($0) }
            .map(\.rawValue)
        guard let last = names.last, names.count > 1 else {
            return names.first ?? ""
        }
        return names.dropLast().joined(separator: ", ") + (names.count == 2 ? " or " : ", or ") + last
    }

    nonisolated public static func systemPrompt(toolRegistry: ToolRegistry = .default) -> String {
        """
    You plan a tiny macOS agent. Return only a JSON object that matches the provided schema.

    Registered local tools:
    \(toolRegistry.plannerDescription)

    Important rules:
    - Use only the fixed operation enum values.
    - Use registered tools only. Do not invent tools, commands, scripts, or APIs.
    - Include user-supplied paths exactly as written. Do not invent local file paths.
    - A TRUSTED_PRIOR_TASK_CONTEXT_BEGIN/END message may appear before the current command. It is Sonny's short-lived record of only the immediately preceding task.
    - The user may provide a short correction such as "use ~/Documents instead", "try /tmp instead", "no, scan ~/Documents instead", or "use 5 instead".
    - When prior task context is present and the current command is a correction/refinement phrase that does not name a complete new action, reuse the prior task's exact action(s), operation(s), count(s), output intent, and safety/risk-relevant behavior. Replace only the field(s) the user explicitly changed, such as folder/path, URL, app, count, query, provider, or output path.
    - If prior plan summary or steps are unavailable because the prior task failed before preparation completed, infer the prior action from Previous command and Previous outcome, then apply the user's correction to that same action.
    - Do not invent a different task category or unrelated candidate operation from a short correction phrase. For example, after a largest-files task, "use ~/Documents instead" means run the same largest-files task against ~/Documents; it does not mean search for documents, convert DOCX files, or ask which operation to perform.
    - If the new command is a complete standalone task, or it clearly conflicts with the prior task rather than refining it, ignore prior task context and plan the new command normally.
    - Ask a clarification question only when both the prior task and the correction text still leave the replacement field or required action unresolved. Do not ask for clarification merely because the correction phrase is short.
    - Use null for unavailable fields.
    - If a folder, app name, URL, count, or output destination is required but missing or ambiguous, return exactly one clarify step with a short question.
    - A count, an output destination, or a title the user did not state is not missing information: every step that takes one already has a working default. Omit the field and let the default apply, and never ask which to use. A folder, an app name, or a URL is different and stays askable under the rule above.
    - For largest files, produce scan_select_largest_files then create_zip.
    - For DOCX conversion, produce scan_docx then convert_docx_to_pdf.
    - For Hacker News headline saving, produce open_hacker_news, fetch_hn_headlines, then write_markdown.
    - For summarizing one public web page to Markdown, produce one web_to_markdown step with targetURL and optional outputPath.
    - For comparing multiple public web sources to Markdown, produce one web_to_markdown step with sourceURLs and optional outputPath.
    - For researching a topic/search query to Markdown, produce one web_to_markdown step with searchQuery and optional outputPath.
    - For opening an app, produce one open_app step with appName.
    - For opening an allowlisted app or website search page, produce one open_app_search_url step with appName and searchQuery. Use only supported search targets; do not invent URL templates.
    - For opening a general website, produce one open_url step with targetURL using http or https.
    - Opening a URL never needs a browser named: URLs open in the system default browser. Never ask which browser to use. If the user does name one, set browserName on that step to the name they used and produce the URL step as normal.
    - For creating a local draft, produce one create_local_draft step with draftContent, optional draftTitle, and optional outputPath. Do not automate Notes, Mail, Calendar, or any app UI.
    - For opening a generated local artifact after a writing step, add open_generated_artifact with outputPath null so the executor can open the previous produced artifact.
    - For saving a text snippet, produce one save_snippet step with searchQuery holding the trigger and draftContent holding the text it expands to. Use only a trigger and text the user supplied; if either is missing, ask a clarification question. This step may also be nested inside save_routine.
    - For bringing an app that is already running to the front, produce one switch_running_app step with appName holding only the app the user named. A phrase such as "in my research workspace" says where the task belongs, not what to change: never turn a request to switch or focus on an app into edit_workspace or create_workspace. When the thing the user asks to switch or focus on is itself a saved workspace rather than an app, that is an open_workspace request instead. Use open_app when the user asked to open or launch an app that may not be running.
    - For song or album requests, produce one play_media step with mediaProvider, mediaTitle, optional mediaArtist, and targetURL only if the user supplied an exact Apple Music or Spotify result URI. The local executor tries provider-aware playback first, then falls back to opening the provider result or search.
    - If a song or album request is missing the provider or title, ask a clarification question.
    - For Finder context phrases such as "selected folder", "selected files", "this Finder selection", or "the folder selected in Finder", set contextSource to finder_selection and leave inputPath null.
    - For "reveal the result/zip/markdown/PDFs in Finder" after a writing step, add reveal_in_finder with outputPath null so the executor can reveal the previous produced artifact.
    - For permission/readiness requests, produce one show_permission_readiness step.
    - For teaching a routine, produce one save_routine step with routineName and routineSteps containing only registered non-routine steps. Do not put \(forbiddenRoutineStepPhrase) inside routineSteps.
    - For running a saved routine, produce one run_routine step with routineName.
    - For creating a workspace, produce one create_workspace step with workspaceName, workspaceApps, and workspaceURLs. Use only explicitly named apps/URLs. If none are provided, ask a clarification question.
    - For changing a workspace the user already saved, produce one edit_workspace step with workspaceName and only the fields the user asked to change: workspaceApps, workspaceURLs, workspaceFileLocations to add, and workspaceAppsToRemove, workspaceURLsToRemove, workspaceFileLocationsToRemove to remove. Never use create_workspace to change an existing workspace, and never put an item in both an add and a remove field.
    - For opening a saved workspace, produce one open_workspace step with workspaceName.
    - For running an existing Apple Shortcut, produce one invoke_shortcut step with shortcutName and optional shortcutInput when simple text input was explicitly supplied.
    - When the user asks for the same work to be done to every item in one folder or in the Finder selection — "summarise each of these", "convert all of these folders" — set itemJob and write steps as the work done to ONE item, which Sonny then repeats for each item it finds. Leave itemJob null for every other command, including one that names two or three things explicitly: that is an ordinary multi-step plan. Never write the items themselves; Sonny reads them from the folder or the selection.
    - You may produce multi-step chained plans when the user asks for multiple supported actions. Keep steps in execution order.
    - For any unsupported request, return one unsupported step and explain why.
    - Never include shell commands, AppleScript, or code.
    """
    }
}

/// How a run's planner is built, as the one seam a call site needs (SONNY-132).
///
/// **This replaces `PlannerProviderRegistry`, which is deleted.** That type mapped a client-side
/// *selection* — `SONNY_PLANNER`, an id, a display name, a fallback notice — onto one of several
/// registered providers. Every part of that is now the server's: `MODEL_ROUTE_PLAN` names the
/// chain, the gateway walks it, and §4.2 forbids the response from naming which provider answered.
/// A client-side registry of providers would be a client that knows about providers, which is the
/// one thing row 12 exists to prevent.
///
/// What the registry genuinely bought at the construction site was narrower than the type: a way to
/// hand `performStart` something that makes a planner for *this run*, without `performStart` naming
/// a concrete class. That is a closure, and this is it. The two facts it takes are the two that
/// cannot be defaulted — the run's `BackendTaskContext`, which carries a retention answer nobody
/// may guess, and the run's usage recorder.
///
/// **It does not throw, and the absence is the point.** The registry's whole fallback machinery
/// existed because a provider's construction could fail — a missing `CEREBRAS_API_KEY` was the
/// canonical case. There is one planner now and it holds no credential: a call made with no session
/// signed in fails at the *request* with `notSignedIn`, which is a sentence the user can act on.
/// Nothing between choosing a planner and making the call can fail any more, so nothing has to be
/// reported there.
public typealias PlannerFactory = @MainActor @Sendable (
    BackendTaskContext, any TaskUsageRecording
) -> any Planning

extension OpenAIPlanner {
    /// The shipping app's planner factory: one that talks to Sonny's backend.
    ///
    /// **A function of the backend client rather than a stored value** (SONNY-130's reasoning,
    /// carried over from `PlannerProviderRegistry.default`): there is exactly one
    /// `SonnyBackendClient` in the process, it holds the single-flight refresh guard that makes ten
    /// concurrent 401s cause one rotation, and a second one would defeat it. Taking it here rather
    /// than reaching for a shared instance is why no call site can acquire it by saying nothing.
    nonisolated public static func throughSonnysBackend(
        client: SonnyBackendClient
    ) -> PlannerFactory {
        { taskContext, usageRecorder in
            OpenAIPlanner(client: client, taskContext: taskContext, usageRecorder: usageRecorder)
        }
    }
}

public enum OpenAIResponseParser {
    public static func outputText(from data: Data) throws -> String {
        // A truncated or non-JSON response body would otherwise escape as a raw Foundation
        // error the user sees verbatim; every failure here is the same user-facing problem.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw PlannerError.missingOutputText
        }

        if let direct = dictionary["output_text"] as? String, !direct.isEmpty {
            return direct
        }

        guard let output = dictionary["output"] as? [[String: Any]] else {
            throw PlannerError.missingOutputText
        }

        for item in output {
            guard let content = item["content"] as? [[String: Any]] else {
                continue
            }
            for part in content {
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }

        throw PlannerError.missingOutputText
    }
}
