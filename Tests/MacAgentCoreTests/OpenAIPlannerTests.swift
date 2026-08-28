import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The planner, **against Sonny's own backend** (SONNY-130).
///
/// **Every test in the environment-key version of this file has a successor here**, and the four
/// that changed shape changed it because the thing they asserted no longer exists rather than
/// because it stopped being worth asserting:
///
/// | before | after |
/// |---|---|
/// | `plannerRecordsReportedResponsesUsage` | `plannerRecordsTheUsageTheBackendReported` |
/// | `plannerEstimatesResponsesUsageWhenUsageIsNull` | `plannerRecordsAnEstimateTheBackendMadeRatherThanMakingItsOwn` |
/// | `priorTaskContextIsSentAsSeparatePlannerMessage` | same name |
/// | `prepareFailurePriorTaskContextIsSentAsSeparatePlannerMessage` | same name |
/// | `plannerSurfacesBadHTTPStatusWithResponseBody` | `plannerSurfacesABackendFailureWithTheAppsOwnWordsAndNeverTheServers` |
/// | `plannerSurfacesMalformedOutputTextAsItsOwnDecodingError` | same name |
/// | `plannerSurfacesUnreadableResponseBodyAsMissingOutputText` | `plannerSurfacesAnUnreadableResponseBodyAsABackendFailure` |
///
/// The two renamed failure tests are the ones worth reading. There is no HTTP status or response
/// body in a planner error any more — the shared client turns both into a typed `code`, and §7.1
/// forbids showing the server's own sentence — so "surfaces the status and the body" became
/// "surfaces the app's own sentence and none of the server's", which is the property that replaced
/// it. And `missingOutputText` is unreachable from this path: `output_text` is a required field of
/// the contract's response, so a body without it fails to decode rather than decoding into nothing.
@MainActor
struct OpenAIPlannerTests {
    // MARK: - What goes on the wire

    @Test
    func plannerSendsTheContractsBodyToThePlanRouteUnderTheUsersOwnSession() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(
                ModelRouteFixtures.textRouteJSON(outputText: openAppPlanJSON)
            )
        }
        defer { fixture.unregister() }

        _ = try await Self.planner(fixture).plan(command: "Open Safari")

        let sent = try recorded.only
        #expect(sent.method == "POST")
        #expect(sent.path == "/v1/plan")
        #expect(sent.contentType == "application/json")
        // The user's own Sonny session, not a provider credential — the whole point of the move.
        #expect(sent.authorization == "Bearer test-access-token")
        // §9.1: every POST carries a key, and it is what makes a retry unable to double-bill.
        #expect(sent.idempotencyKey?.isEmpty == false)

        let body = sent.json
        // §2.4: required on every content-bearing request, and never defaulted.
        #expect(body["task_id"] as? String == "task-fixture-1")
        #expect(body["retention"] as? String == "standard")
        #expect(body["response_schema_name"] as? String == "agent_plan")
        #expect(body["response_schema"] as? [String: Any] != nil)
        #expect(body["reasoning_effort"] as? String == "medium")
        #expect(body["verbosity"] as? String == "low")
    }

    @Test
    func aRunStartedWithDontSaveThisTaskSendsRetentionNone() async throws {
        // §10.1: `"none"` is what the app sends for a run started with "Don't save this task" on,
        // and it is the one thing that produces it. Asserted on the wire because the field is the
        // whole of the user's privacy answer once the request leaves the Mac.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(
                ModelRouteFixtures.textRouteJSON(outputText: openAppPlanJSON)
            )
        }
        defer { fixture.unregister() }

        let planner = OpenAIPlanner(
            client: fixture.client,
            taskContext: BackendTaskContext(taskID: "task-private", retention: .notStored)
        )
        _ = try await planner.plan(command: "Open Safari")

        #expect(try recorded.only.json["retention"] as? String == "none")
        #expect(try recorded.only.json["task_id"] as? String == "task-private")
    }

    @Test
    func theRequestNamesNoProviderNoModelAndNoVendorEndpoint() async throws {
        // SONNY-130's sixth requirement, asserted on the bytes rather than argued. This is the
        // property that turns SONNY-110's move to a paid zero-retention route into a redeploy: if
        // the client named the model or the vendor, changing either would need an app release.
        //
        // **The system prompt is excluded here and asserted separately below**, because it is a
        // payload the capability registry builds rather than anything this client decides — and one
        // capability's description still names a provider, for a reason the other test states. The
        // exclusion is one named message, not a softened pattern.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(
                ModelRouteFixtures.textRouteJSON(outputText: openAppPlanJSON)
            )
        }
        defer { fixture.unregister() }

        _ = try await Self.planner(fixture).plan(command: "Open Safari")

        let sent = try recorded.only
        let body = try #require(
            JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        )
        var withoutSystemPrompt = body
        var messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        messages.removeFirst()
        withoutSystemPrompt["messages"] = messages
        let wire = String(
            data: try JSONSerialization.data(withJSONObject: withoutSystemPrompt),
            encoding: .utf8
        )!.lowercased()

        for forbidden in ["openai", "api.openai.com", "gpt-", "anthropic", "claude", "cerebras", "tavily"] {
            #expect(!wire.contains(forbidden), "request body names \(forbidden)")
        }
        #expect(!sent.path.contains("responses"))
        // And the model identifier is not hiding in a header either.
        #expect(sent.authorization == "Bearer test-access-token")
    }

    /// **No provider name reaches the system prompt at all, which is the count this test was
    /// written to watch move.**
    ///
    /// It was `theOnlyProviderNameLeftInTheSystemPromptIsTheOneTheDegradationBranchRemoves`, and it
    /// asserted exactly one occurrence of "openai": `PermissionReadinessCapabilityAdapter`'s tool
    /// description said *"Show readiness for OpenAI key, …"*, describing a readiness row that
    /// genuinely still read `OPENAI_API_KEY`. SONNY-130 left it deliberately, on the reasoning that
    /// the sentence was accurate about something that had not moved yet; SONNY-136 moved it, so the
    /// count is zero and the name says so.
    ///
    /// **The system prompt is where this matters most**, and it is worth stating rather than
    /// leaving as an inherited habit: the prompt folds in every capability's description and side
    /// effects (`ToolRegistry.plannerDescription`), so a provider name written into any adapter's
    /// metadata is a provider name sent to whichever provider `MODEL_ROUTE_PLAN` happens to pick —
    /// which is the thing §4.2 says the client must not know about.
    @Test
    func noProviderNameReachesTheSystemPrompt() throws {
        let prompt = OpenAIPlanner.systemPrompt(toolRegistry: .default).lowercased()
        #expect(prompt.components(separatedBy: "openai").count - 1 == 0)
        // The readiness tool is still described, and now by its real subject. Asserted so that
        // "zero occurrences of openai" cannot be satisfied by the description disappearing.
        #expect(prompt.contains("show readiness for the sonny account"))
        #expect(!prompt.contains("content to openai"))
        for forbidden in ["api.openai.com", "gpt-", "anthropic", "cerebras", "tavily", "opencode"] {
            #expect(!prompt.contains(forbidden), "the system prompt names \(forbidden)")
        }
    }

    @Test
    func priorTaskContextIsSentAsSeparatePlannerMessage() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(
                ModelRouteFixtures.textRouteJSON(outputText: openAppPlanJSON)
            )
        }
        defer { fixture.unregister() }

        let context = PriorTaskContext(
            command: "Find the 3 largest files in ~/Desktop/MacAgentDemo and zip them.",
            plan: Self.largestPlan(),
            outcome: PriorTaskOutcome(status: .completed, summary: "Created largest.zip."),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        _ = try await Self.planner(fixture).plan(
            command: "use ~/Documents/MacAgentDocs instead",
            priorTaskContext: context
        )

        let messages = try #require(try recorded.only.json["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "user"])
        #expect(messages[1]["text"] as? String == context.plannerContextText)
        #expect((messages[1]["text"] as? String)?.contains("TRUSTED_PRIOR_TASK_CONTEXT_BEGIN") == true)
        #expect((messages[1]["text"] as? String)?.contains("MacAgentDemo") == true)
        #expect(messages[2]["text"] as? String == "use ~/Documents/MacAgentDocs instead")
    }

    @Test
    func prepareFailurePriorTaskContextIsSentAsSeparatePlannerMessage() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(
                ModelRouteFixtures.textRouteJSON(outputText: openAppPlanJSON)
            )
        }
        defer { fixture.unregister() }

        let context = PriorTaskContext(
            command: "find the 3 largest files in ~/Desktop/SomeFolder",
            outcome: PriorTaskOutcome(
                status: .failed,
                summary: "The folder ~/Desktop/SomeFolder could not be scanned."
            ),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        _ = try await Self.planner(fixture).plan(
            command: "use ~/Documents instead",
            priorTaskContext: context
        )

        let messages = try #require(try recorded.only.json["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let contextText = try #require(messages[1]["text"] as? String)
        #expect(contextText.contains("Previous command: find the 3 largest files in ~/Desktop/SomeFolder"))
        // Reworded by SONNY-150 to state the fact without a cause — see `PriorTaskContext`.
        #expect(contextText.contains("Previous plan summary: - not recorded"))
        #expect(contextText.contains(
            "Previous outcome: failed - The folder ~/Desktop/SomeFolder could not be scanned."
        ))
        #expect(messages[2]["text"] as? String == "use ~/Documents instead")
    }

    @Test
    func theSystemPromptIsSentUnchangedAndIsStillTheOneTheRegistryDescribes() async throws {
        // The prompt stayed on the Mac, which is half of what §1.3's boundary says. §4.2 obliges the
        // server to forward it without editing, re-wrapping or re-ordering it — so what leaves here
        // has to be the whole prompt, byte for byte, or the server is being asked to fix it.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(
                ModelRouteFixtures.textRouteJSON(outputText: openAppPlanJSON)
            )
        }
        defer { fixture.unregister() }

        _ = try await Self.planner(fixture).plan(command: "Open Safari")

        let messages = try #require(try recorded.only.json["messages"] as? [[String: Any]])
        #expect(messages.first?["text"] as? String == OpenAIPlanner.systemPrompt(toolRegistry: .default))
    }

    // MARK: - Usage

    @Test
    func plannerRecordsTheUsageTheBackendReported() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.textRouteJSON(
                outputText: openAppPlanJSON,
                usage: ModelRouteFixtures.reportedTokenUsage(input: 42, output: 18, total: 60)
            ))
        }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        _ = try await Self.planner(fixture, usageRecorder: recorder).plan(command: "Open Safari")

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedInputTokens == 42)
        #expect(summary.reportedOutputTokens == 18)
        #expect(summary.reportedTotalTokens == 60)
        #expect(summary.estimatedTotalTokens == 0)
        #expect(summary.records.first?.kind == .planner)
        #expect(summary.records.first?.tokenSource == .reported)
        // §4.2: `AIUsageRecord.model` holds the route's name rather than a model identifier the
        // client is no longer allowed to know. It is non-optional and it eventually gets rendered.
        #expect(summary.records.first?.model == "plan")
    }

    @Test
    func plannerRecordsAnEstimateTheBackendMadeRatherThanMakingItsOwn() async throws {
        // **The estimation moved, and this is the test that says so.** It used to happen here, from
        // the request and response text, whenever the provider reported nothing. §4.2 puts it on the
        // server — "the server estimates only when the provider reported nothing, and says which it
        // did" — because the server is the only side that can see whether the provider answered.
        // What the client keeps is the distinction, which the local summary renders.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.textRouteJSON(
                outputText: openAppPlanJSON,
                usage: ModelRouteFixtures.estimatedTokenUsage(input: 900, output: 30, total: 930)
            ))
        }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        _ = try await Self.planner(fixture, usageRecorder: recorder).plan(command: "Open Safari")

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedTotalTokens == 0)
        #expect(summary.estimatedInputTokens == 900)
        #expect(summary.estimatedOutputTokens == 30)
        #expect(summary.estimatedTotalTokens == 930)
        #expect(summary.hasEstimatedTokens)
        #expect(summary.records.first?.tokenSource == .estimated)
    }

    @Test
    func theSummaryStillPopulatesWhenTheBackendSendsNoUsageBlockAtAll() async throws {
        // A response with no `usage` is not a shape the gateway sends today, and it is exactly the
        // shape an older or a partly-deployed server would. The requirement is that the local
        // per-task summary must not silently go blank, so a request with no numbers is still a
        // request the summary counts.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.textRouteJSON(outputText: openAppPlanJSON))
        }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        _ = try await Self.planner(fixture, usageRecorder: recorder).plan(command: "Open Safari")

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.records.first?.kind == .planner)
        #expect(summary.records.first?.model == "plan")
        #expect(summary.records.first?.tokenSource == nil)
    }

    @Test
    func usageIsRecordedEvenWhenTheModelsPlanCannotBeDecoded() async throws {
        // The order the environment-key version used, kept: a plan the model returned malformed
        // still cost what it cost, and a summary that omitted exactly the failed runs would
        // understate the ones a user is most likely to ask about.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.textRouteJSON(
                outputText: "{not valid json",
                usage: ModelRouteFixtures.reportedTokenUsage(input: 7, output: 1, total: 8)
            ))
        }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        await #expect(throws: AgentPlanDecodingError.invalidJSON) {
            _ = try await Self.planner(fixture, usageRecorder: recorder).plan(command: "Open Safari")
        }

        #expect(recorder.snapshot().requestCount == 1)
        #expect(recorder.snapshot().reportedTotalTokens == 8)
    }

    // MARK: - Failure

    @Test
    func plannerSurfacesABackendFailureWithTheAppsOwnWordsAndNeverTheServers() async throws {
        // §7.1: "the client never displays `message`". The server's sentence is for logs and the
        // support lookup, and a sentence authored on the server and rendered in the app is a hole
        // straight through Sonny's rule that the product does not explain itself.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.failure(
                status: 502,
                code: "provider.rejected",
                message: "Upstream exploded: prompt contained 'my tax returns folder'"
            )
        }
        defer { fixture.unregister() }

        do {
            _ = try await Self.planner(fixture).plan(command: "Open Safari")
            Issue.record("Expected the backend failure to surface as PlannerError.backend.")
        } catch let error as PlannerError {
            guard case .backend(let backendError) = error else {
                Issue.record("Expected .backend, got \(error).")
                return
            }
            guard case .api(let api) = backendError else {
                Issue.record("Expected an API error, got \(backendError).")
                return
            }
            #expect(api.code == .providerRejected)
            #expect(api.statusCode == 502)
            // The typed error carries the server's sentence for logs...
            #expect(api.message.contains("tax returns"))
            // ...and what the user is shown carries none of it — and does not invite a retry, which
            // §9.3 says would fail identically (PR #139, F7).
            let shown = try #require(error.errorDescription)
            #expect(shown == "Sonny couldn't do this one.")
            #expect(!shown.lowercased().contains("try again"))
            #expect(!shown.contains("tax returns"))
            #expect(!shown.contains("502"))
            #expect(!shown.lowercased().contains("provider"))
        }
    }

    @Test
    func plannerTellsAnUnsignedInUserToSignInRatherThanFailingOpaquely() async throws {
        // §7.2 case 1. Reachable in a way the environment-key version's `missingAPIKey` was not: it
        // threw at *construction*, before a run existed, so a user with no key never got here at
        // all. Now the planner constructs fine and the request is what refuses.
        let client = makeHermeticBackendClient(
            environment: SonnyBackendEnvironment(
                baseURL: URL(string: "https://sonny-unreached.invalid")!,
                source: .debugOverride
            )
        )
        let planner = OpenAIPlanner(client: client, taskContext: ModelRouteFixtures.standardContext)

        do {
            _ = try await planner.plan(command: "Open Safari")
            Issue.record("Expected a request with no session to be refused before it was sent.")
        } catch let error as PlannerError {
            #expect(error == .backend(.notSignedIn))
            #expect(error.errorDescription == "Sign in to Sonny to run this.")
        }
    }

    @Test
    func plannerSurfacesMalformedOutputTextAsItsOwnDecodingError() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(
                ModelRouteFixtures.textRouteJSON(outputText: "{not valid json")
            )
        }
        defer { fixture.unregister() }

        await #expect(throws: AgentPlanDecodingError.invalidJSON) {
            _ = try await Self.planner(fixture).plan(command: "Open Safari")
        }
    }

    @Test
    func plannerSurfacesAnUnreadableResponseBodyAsABackendFailure() async throws {
        // **The successor to `plannerSurfacesUnreadableResponseBodyAsMissingOutputText`, and the
        // outcome changed on purpose.** `output_text` is a required field of §4.2's response, so a
        // 200 carrying something else is a body this client cannot read at all — which is
        // `undecodableResponse`, not "the model said nothing". `PlannerError.missingOutputText`
        // still exists and is still thrown, by `OpenAIResponseParser`, which `VisionModelClient`
        // uses and this ticket does not touch. (It named `CerebrasPlanner` as a second user until
        // SONNY-132 deleted that class.)
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(Data("<html>not json at all</html>".utf8))
        }
        defer { fixture.unregister() }

        do {
            _ = try await Self.planner(fixture).plan(command: "Open Safari")
            Issue.record("Expected an unreadable body to surface as a backend failure.")
        } catch let error as PlannerError {
            guard case .backend(.undecodableResponse) = error else {
                Issue.record("Expected .backend(.undecodableResponse), got \(error).")
                return
            }
            #expect(error.errorDescription == "Sonny couldn't finish this one. Try again.")
        }
    }

    /// **A stop is not a failure, on the route a stop most often lands on** (SONNY-320).
    ///
    /// The shape asserted here is the one a real stop produces, not a convenient stand-in.
    /// `cancelCurrentRun` cancels `currentTask`, the enclosing task's cancellation reaches the
    /// in-flight `URLSession` call, and `URLSession` raises `URLError(.cancelled)` — which
    /// `SonnyBackendClient.transportError` maps to `SonnyBackendError.cancelled` and this client
    /// then wraps. So the stub fails the transport rather than injecting the wrapped error directly:
    /// the mapping from a Foundation error to the typed one is part of what must keep working.
    ///
    /// **The last three expectations are the ones a mutant dies on.** A `backendError` that returned
    /// `.cancelled` unconditionally, or ignored the associated value, satisfies everything above
    /// them.
    @Test
    func aStopWhileAPlanIsInFlightIsACancellationRatherThanAFailure() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return .failure(URLError(.cancelled))
        }
        defer { fixture.unregister() }

        do {
            _ = try await Self.planner(fixture).plan(command: "Open Safari")
            Issue.record("Expected the stopped request to surface as PlannerError.backend(.cancelled).")
        } catch let error as PlannerError {
            #expect(error == .backend(.cancelled))
            #expect(
                SonnyBackendError.isCancellation(error),
                "a stop is not a failure to report - see performStart's catch"
            )
            // §9.3 gives `.cancelled` no attempt budget, so a stop costs exactly one request and
            // never sits in a retry sleep the user is waiting through.
            #expect(recorded.all.count == 1)
        }

        // The wrapper is transparent in one direction only: every other backend failure through the
        // same case is still a failure, and a case carrying no backend error is not a cancellation.
        #expect(!SonnyBackendError.isCancellation(PlannerError.backend(.offline)))
        #expect(!SonnyBackendError.isCancellation(PlannerError.backend(.notSignedIn)))
        #expect(!SonnyBackendError.isCancellation(PlannerError.missingOutputText))
    }

    // MARK: - Fixtures

    private static func planner(
        _ fixture: SignedInBackendFixture,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared
    ) -> OpenAIPlanner {
        OpenAIPlanner(
            client: fixture.client,
            taskContext: ModelRouteFixtures.standardContext,
            usageRecorder: usageRecorder
        )
    }

    private static func largestPlan() -> AgentPlan {
        AgentPlan(
            summary: "Zip largest files.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files.",
                    inputPath: "~/Desktop/MacAgentDemo",
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Create zip.",
                    inputPath: "~/Desktop/MacAgentDemo",
                    outputPath: "~/Desktop/largest.zip",
                    count: 3
                )
            ]
        )
    }
}

/// The plan the stub answers with. File-level rather than a member, because the suite is
/// `@MainActor` and the stub handlers are `@Sendable` closures that run on URLSession's threads.
private let openAppPlanJSON = #"{"summary":"Open Safari.","requiresConfirmation":false,"steps":[{"id":"open","operation":"open_app","description":"Open Safari.","inputPath":null,"outputPath":null,"count":null,"targetURL":null,"appName":"Safari","question":null,"mediaProvider":null,"mediaTitle":null,"mediaArtist":null,"contextSource":null,"routineName":null,"routineSteps":null,"workspaceName":null,"workspaceApps":null,"workspaceURLs":null,"sourceURLs":null,"searchQuery":null,"draftTitle":null,"draftContent":null,"shortcutName":null,"shortcutInput":null}]}"#

/// The shipping app's planner factory (SONNY-132), migrated from
/// `PlannerProviderRegistryTests.shippedRegistryOffersOpenAIAsDefaultWithCerebrasAsTheAlternate`.
///
/// What that test pinned was a *set* of providers and which one was the default. Neither exists on
/// this side any more: there is one factory, and which provider serves a request is
/// `MODEL_ROUTE_PLAN` on the gateway. What survives the move is the half that still means something
/// — the shipped factory builds a planner that talks to Sonny's backend, and it is a function of
/// the one client in the process rather than of a shared instance it could reach for itself.
@Suite
@MainActor
struct ShippedPlannerFactoryTests {
    @Test
    func theShippedFactoryBuildsAPlannerThatTalksToSonnysBackend() {
        let factory = OpenAIPlanner.throughSonnysBackend(client: makeHermeticBackendClient())
        let planner = factory(
            BackendTaskContext(taskID: "task-factory-1", retention: .standard),
            NoopTaskUsageRecorder.shared
        )
        #expect(planner is OpenAIPlanner)
    }

    /// Two calls build two planners rather than handing back one shared object.
    ///
    /// A run's planner carries that run's `BackendTaskContext`, so a factory that cached one would
    /// silently plan the second task under the first task's id and retention answer — §5.1's join
    /// key and §2.4.2's privacy field, both wrong, both invisible.
    @Test
    func eachCallBuildsAPlannerForItsOwnRun() {
        let factory = OpenAIPlanner.throughSonnysBackend(client: makeHermeticBackendClient())
        let first = factory(
            BackendTaskContext(taskID: "task-factory-1", retention: .standard),
            NoopTaskUsageRecorder.shared
        )
        let second = factory(
            BackendTaskContext(taskID: "task-factory-2", retention: .notStored),
            NoopTaskUsageRecorder.shared
        )
        // **`ObjectIdentifier`, not `!==`, and that is a compiler workaround rather than style.**
        // `#expect((first as AnyObject) !== (second as AnyObject))` crashes SILGen on this
        // toolchain — `fatal error encountered during compilation`, "While emitting reabstraction
        // thunk", killing the whole `swift test` run with no failing test to point at. The
        // existential erasure of `any Planning` to `AnyObject` inside the macro's autoclosure is
        // what does it. Comparing identifiers erases nothing and says the same thing.
        #expect(ObjectIdentifier(first as AnyObject) != ObjectIdentifier(second as AnyObject))
    }
}
