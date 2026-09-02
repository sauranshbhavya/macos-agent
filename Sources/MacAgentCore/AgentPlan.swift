import Foundation

public struct AgentPlan: Codable, Equatable, Sendable {
    public var summary: String
    public var requiresConfirmation: Bool
    public var steps: [AgentStep]
    /// Set when this plan is one piece of work repeated over many items — "summarise each of these
    /// forty PDFs" (SONNY-235). `nil` on every plan that is not, which is nearly all of them.
    ///
    /// **Plan-level rather than a step operation or a step property**, and `PlanItemJob`'s doc
    /// comment is where that decision and the two rejected alternatives are recorded. `steps` holds
    /// the *template* — the work done to one item — until `AgentActionExecutor.prepare` resolves the
    /// items and replaces it with one copy per item; after that this field is the declaration the
    /// expansion came from, and the record of which items the run is walking.
    public var itemJob: PlanItemJob?

    public init(
        summary: String,
        requiresConfirmation: Bool,
        steps: [AgentStep],
        itemJob: PlanItemJob? = nil
    ) {
        self.summary = summary
        self.requiresConfirmation = requiresConfirmation
        self.steps = steps
        self.itemJob = itemJob
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case requiresConfirmation
        case steps
        case itemJob
    }

    /// Written out rather than synthesized for one reason: an `itemJob` object whose `source` is
    /// null is how the wire says "this is not a job", and it has to become `nil` here rather than a
    /// half-filled value (SONNY-235).
    ///
    /// The encode side stays synthesized, so a stored plan writes the nested object exactly as this
    /// type holds it and a plan that is not a job writes no key at all.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.requiresConfirmation = try container.decode(Bool.self, forKey: .requiresConfirmation)
        self.steps = try container.decode([AgentStep].self, forKey: .steps)
        do {
            self.itemJob = try container.decodeIfPresent(PlanItemJob.self, forKey: .itemJob)
        } catch PlanItemJobDecodingSignal.notAJob {
            self.itemJob = nil
        }
    }
}

public struct AgentStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var operation: AgentOperation
    public var description: String
    public var inputPath: String?
    public var outputPath: String?
    public var count: Int?
    public var targetURL: String?
    public var appName: String?
    public var question: String?
    public var mediaProvider: MediaProvider?
    public var mediaTitle: String?
    public var mediaArtist: String?
    public var contextSource: FinderContextSource?
    /// **Whether this step's folder really came from the Finder selection** — a resolve-phase fact,
    /// written only by `FinderSelectionResolver.pinningSelectedDirectoryInput` and only on a pass
    /// that actually drove Finder to read one. `nil` everywhere else, including on every plan the
    /// planner emits.
    ///
    /// It exists because `contextSource` cannot answer that question and never could. That field is
    /// the *planner's declaration* that the user said "the selected folder"; whether the resolution
    /// then reached Finder depends on the whole plan, because `pinningSelectedDirectoryInput` pools
    /// the matching steps and `selectedDirectoryPath` returns `primary ?? secondary` before it looks
    /// at `contextSource` at all. So a step carrying the declaration *and* its own non-empty
    /// `inputPath` is satisfied from that path, Finder is never contacted, and the step still
    /// declares itself selection-driven — which is exactly what `PlanScopedResources` reported
    /// Finder off until SONNY-185. SONNY-73 fixed the pooled half of that by clearing the
    /// declaration on the steps the pin back-fills; the per-step half needed a second fact, because
    /// after the first pass a declaring step the pin filled in and a declaring step that arrived
    /// with a path are byte-for-byte the same thing.
    ///
    /// **Resolver-only in the same sense as `resolvedAppName`**: absent from
    /// `AgentPlanDecoder.stepKeys` and from the planner schema, so a model cannot assert it, at any
    /// nesting depth. `resolvedAppName`'s own comment warns against adding a second decode-excluded
    /// *identity* field, and that warning is respected rather than sidestepped — this is not an
    /// identity, it names no app and resolves no query, it is one boolean about where a path came
    /// from. What it does cost is one more key in the per-key exclusion audit, which is why
    /// `theGoalDecodesWhileThePinsStayResolverOnly` covers it alongside the other two rather than by
    /// inspection.
    ///
    /// **Not persisted into a routine**, for the same reason the two pins are not: a saved routine's
    /// steps come from the planner's own nested `routineSteps`, which the top-level resolve phase
    /// never touches, so a stored routine cannot carry a stale answer about a Finder read that
    /// happened once, long ago.
    public var resolvedFromFinderSelection: Bool?
    /// Which of `AgentPlan.itemJob`'s items this step belongs to, zero-based, or `nil` on every step
    /// of a plan that is not a job (SONNY-235).
    ///
    /// **Written only by `PlanItemJobResolver.expanding`**, and resolver-only in exactly the sense
    /// `resolvedFromFinderSelection` is: absent from `AgentPlanDecoder.stepKeys` and from the planner
    /// schema, so a model cannot assert it at any nesting depth. It is what lets the chain walk say
    /// "this failure belongs to item 17" — and what lets SONNY-210's `completedStepIDs`, which knows
    /// nothing about items, be read back as item progress without storing that progress twice.
    public var itemIndex: Int?
    public var routineName: String?
    public var routineSteps: [AgentStep]?
    public var workspaceName: String?
    /// Apps a workspace should contain. `create_workspace` reads it as the workspace's whole app
    /// list; `edit_workspace` reads it as the apps to *add*. Reused rather than paired with a
    /// `workspaceAppsToAdd` twin for the same reason the operation already decides what `appName`
    /// and `searchQuery` mean elsewhere: the field carries a value, the operation carries the verb.
    public var workspaceApps: [String]?
    /// URLs a workspace should contain — the whole list for `create_workspace`, the URLs to add for
    /// `edit_workspace`. Same reuse as `workspaceApps`.
    public var workspaceURLs: [String]?
    /// Folders to add to a workspace's restriction scope (`edit_workspace`). There is no
    /// `create_workspace` half on purpose: creation names apps and URLs, and file locations are
    /// configured afterwards by the edit path.
    public var workspaceFileLocations: [String]?
    public var workspaceAppsToRemove: [String]?
    public var workspaceURLsToRemove: [String]?
    public var workspaceFileLocationsToRemove: [String]?
    public var sourceURLs: [String]?
    public var searchQuery: String?
    public var draftTitle: String?
    public var draftContent: String?
    public var shortcutName: String?
    public var shortcutInput: String?
    /// The app a `switch_running_app` step will actually activate, or a `vision_session` step will
    /// actually control — pinned exactly once, by that operation's adapter's
    /// `resolveDefaultOutputs`, in the resolve phase every executor gate (`prepare`, `assessRisk`,
    /// `execute`) runs before doing anything else (SONNY-58). Nil until that phase runs; never
    /// emitted by the planner and never by the instant resolver, because the key is absent from
    /// `AgentPlanDecoder.stepKeys` and that check recurses into nested `routineSteps`. Once set, the
    /// pin is the identity: scope classifies it, the preview names it, and execution activates it or
    /// fails — nothing re-resolves the query.
    ///
    /// **Two writers now, and they are still the only two** (`RunningAppSwitchCapabilityAdapter`,
    /// `VisionSessionCapabilityAdapter`). Reused rather than paired with a parallel
    /// `visionTargetBundleIdentifier`, because a second decode-excluded app-identity field would be
    /// a second thing every hostile-payload test, every scope classifier and every future reader has
    /// to know about — and the exclusion guarantee is per-key, so a new key is a new place to get it
    /// wrong. What the two writers share is exactly what this field means: the one app this step is
    /// pinned to.
    public var resolvedAppName: String?
    /// The pinned app's bundle identifier — the half of the pin execution acts by and scope matching
    /// compares first. Written together with `resolvedAppName`, never separately. For a vision
    /// session it is also what `ScreenControlPolicy` judges: the terminal ban compares this, never a
    /// display name.
    public var resolvedBundleIdentifier: String?
    /// What the user asked Sonny to accomplish inside the target app — the vision session's goal,
    /// verbatim.
    ///
    /// **Decodable, and deliberately unlike the two pin fields above it.** SONNY-92 landed this
    /// field decode-*excluded* — absent from `AgentPlanDecoder.stepKeys` and from the planner schema
    /// — because that ticket's never-touch list assigned the goldens to SONNY-93. SONNY-93 then made
    /// `visionSession` planner-visible and moved the goal into both, three commits later on the same
    /// branch. This comment still described the SONNY-92 state at `6c3e4ad`, telling a reader
    /// auditing the single-sourcing guarantee the opposite of the truth about a security-relevant key
    /// set (PR #50 review, F10).
    ///
    /// The asymmetry that *is* true, and is the thing worth auditing: **the goal is the planner's to
    /// write, the identity is the resolver's alone.** `visionGoal` is in `stepKeys`;
    /// `resolvedAppName` and `resolvedBundleIdentifier` are not, at any nesting depth. Pinned by
    /// `theGoalDecodesWhileThePinsStayResolverOnly`.
    ///
    /// Carried as trusted content: it originates from the user's own command, and the vision prompt
    /// wraps it in `TRUSTED_USER_INSTRUCTION_BEGIN/END` precisely so that everything read off the
    /// screen can be wrapped as untrusted and told apart from it.
    public var visionGoal: String?

    /// The browser the user named for a URL-opening step, verbatim, or `nil` when they named none.
    ///
    /// **Planner-visible, like `visionGoal` and unlike the two resolver pins above it.** The model is
    /// the only thing that sees the command text, so it is the only thing that can tell "open
    /// example.com in Chrome" from "open example.com". So this key is in `AgentPlanDecoder.stepKeys`
    /// and in the schema; it is not a second decode-excluded app-identity field, which
    /// `resolvedAppName`'s own comment warns against adding.
    ///
    /// **A name, not an identity, and deliberately not resolved here.** It holds what the user said.
    /// `CapabilityExecutionContext.browser(named:)` turns it into a `MacApp` at execution time
    /// through the same `installedAppResolver` every other app-name path uses; if it resolves to
    /// nothing installed, the step falls back to the system default rather than failing, which is the
    /// behaviour `WorkspaceBrowserOpener` already documents for a workspace naming a browser that is
    /// not there.
    ///
    /// **Not gated on `WorkspaceBrowserCatalog`.** That catalog answers "which of these apps is the
    /// browser", which is the question a workspace's app list poses and this field does not — the
    /// user already said which one. Gating on it would refuse a browser outside its five bundle
    /// identifiers for no reason the user could see, and reusing a definition for a question it was
    /// not built to answer is its own kind of drift.
    public var browserName: String?

    /// What the user asked Sonny to watch for, in their own words — "the price on that page", "the
    /// status going to shipped" (SONNY-382).
    ///
    /// **Planner-visible, for `visionGoal`'s reason and not `resolvedAppName`'s.** The model is the
    /// only thing that reads the command text, so it is the only thing that can turn "tell me when
    /// this page changes" into a phrase worth reading back days later. So this key is in
    /// `AgentPlanDecoder.stepKeys` and in the schema, and it is not a second decode-excluded
    /// identity field.
    ///
    /// **A label and nothing more.** Nothing compares it, nothing re-plans from it, and no part of
    /// deciding whether the page changed reads it — that is `StandingWatcherEvaluator.digest(of:)`
    /// over the page's own text. It exists because the notification has to name the thing the user
    /// asked about rather than a URL, and because the Routines row has to be recognisable as theirs.
    /// `StandingWatcher.subject` is where it lands, capped there at
    /// `StandingWatcher.maxSubjectCharacters`.
    public var watchSubject: String?


    public init(
        id: String,
        operation: AgentOperation,
        description: String,
        inputPath: String? = nil,
        outputPath: String? = nil,
        count: Int? = nil,
        targetURL: String? = nil,
        appName: String? = nil,
        question: String? = nil,
        mediaProvider: MediaProvider? = nil,
        mediaTitle: String? = nil,
        mediaArtist: String? = nil,
        contextSource: FinderContextSource? = nil,
        routineName: String? = nil,
        routineSteps: [AgentStep]? = nil,
        workspaceName: String? = nil,
        workspaceApps: [String]? = nil,
        workspaceURLs: [String]? = nil,
        workspaceFileLocations: [String]? = nil,
        workspaceAppsToRemove: [String]? = nil,
        workspaceURLsToRemove: [String]? = nil,
        workspaceFileLocationsToRemove: [String]? = nil,
        sourceURLs: [String]? = nil,
        searchQuery: String? = nil,
        draftTitle: String? = nil,
        draftContent: String? = nil,
        shortcutName: String? = nil,
        shortcutInput: String? = nil,
        browserName: String? = nil,
        resolvedAppName: String? = nil,
        resolvedBundleIdentifier: String? = nil,
        resolvedFromFinderSelection: Bool? = nil,
        itemIndex: Int? = nil,
        visionGoal: String? = nil,
        watchSubject: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.description = description
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.count = count
        self.targetURL = targetURL
        self.appName = appName
        self.question = question
        self.mediaProvider = mediaProvider
        self.mediaTitle = mediaTitle
        self.mediaArtist = mediaArtist
        self.contextSource = contextSource
        self.routineName = routineName
        self.routineSteps = routineSteps
        self.workspaceName = workspaceName
        self.workspaceApps = workspaceApps
        self.workspaceURLs = workspaceURLs
        self.workspaceFileLocations = workspaceFileLocations
        self.workspaceAppsToRemove = workspaceAppsToRemove
        self.workspaceURLsToRemove = workspaceURLsToRemove
        self.workspaceFileLocationsToRemove = workspaceFileLocationsToRemove
        self.sourceURLs = sourceURLs
        self.searchQuery = searchQuery
        self.draftTitle = draftTitle
        self.draftContent = draftContent
        self.shortcutName = shortcutName
        self.shortcutInput = shortcutInput
        self.browserName = browserName
        self.resolvedAppName = resolvedAppName
        self.resolvedBundleIdentifier = resolvedBundleIdentifier
        self.resolvedFromFinderSelection = resolvedFromFinderSelection
        self.itemIndex = itemIndex
        self.visionGoal = visionGoal
        self.watchSubject = watchSubject
    }
}

public enum AgentOperation: String, Codable, CaseIterable, Sendable {
    case scanSelectLargestFiles = "scan_select_largest_files"
    case createZip = "create_zip"
    case scanDocx = "scan_docx"
    case convertDocxToPDF = "convert_docx_to_pdf"
    case openHackerNews = "open_hacker_news"
    case fetchHNHeadlines = "fetch_hn_headlines"
    case writeMarkdown = "write_markdown"
    case webToMarkdown = "web_to_markdown"
    case openApp = "open_app"
    case openAppSearchURL = "open_app_search_url"
    case openURL = "open_url"
    case playMedia = "play_media"
    case getFinderSelection = "get_finder_selection"
    case revealInFinder = "reveal_in_finder"
    case showPermissionReadiness = "show_permission_readiness"
    case saveRoutine = "save_routine"
    case runRoutine = "run_routine"
    case createWorkspace = "create_workspace"
    case editWorkspace = "edit_workspace"
    case openWorkspace = "open_workspace"
    case openGeneratedArtifact = "open_generated_artifact"
    case createLocalDraft = "create_local_draft"
    case calculateUtility = "calculate_utility"
    case lookupClipboardHistory = "lookup_clipboard_history"
    case expandSnippet = "expand_snippet"
    case saveSnippet = "save_snippet"
    case switchRunningApp = "switch_running_app"
    case lookupRecentArtifacts = "lookup_recent_artifacts"
    case invokeShortcut = "invoke_shortcut"
    /// Sonny acts inside an app it has no adapter for, by looking at the app's window and
    /// synthesizing real clicks and keystrokes (row I, SONNY-92).
    ///
    /// **One operation, not one per action.** A whole session — capture, decide, act, repeat — is a
    /// single step of a single plan, so the engine assesses it once before anything moves and the
    /// per-action gating happens inside `VisionSessionCapabilityAdapter`'s containment layer, which
    /// is engine code calling the same `RiskApprovalPolicy.requirement(for:context:)` every other
    /// path calls. Modelling each click as its own plan step was the alternative and is wrong: the
    /// steps are not knowable before the run starts, which is the entire reason this capability
    /// exists.
    case visionSession = "vision_session"
    /// Sonny waits for a public page to change and tells the user when it does (SONNY-382).
    ///
    /// **The step starts a watcher; it is not the watching.** Executing it reads the page once,
    /// stores that reading as the baseline, and returns — the checking happens afterwards on
    /// `AgentViewModel.checkStandingWatchers`'s own pulse, days later, with no plan and no run
    /// behind it. So this operation's whole consequence is one public GET and one local record,
    /// which is what `StandingWatcherCapabilityAdapter.assessRisk` judges.
    ///
    /// **There is no matching stop operation, and that is a decision rather than an omission.**
    /// Stopping is the Routines page's Stop control (`AgentViewModel.stopWatching`), because the
    /// thing a user needs to stop is one of a list they are looking at — a planner step would have
    /// to name a watcher in words and guess which one they meant. The founders' rule for this
    /// ticket is that starting and stopping ship together; they do, through two different doors.
    case startWatching = "start_watching"
    case clarify
    case unsupported

    /// The operations the planner's JSON schema may name.
    ///
    /// An operation is excluded here **only** when the instant resolver is the whole of its front
    /// door — the four below are recognised locally from fixed command shapes, never modelled, so
    /// putting them in the schema would buy nothing but prompt surface. That agreement (excluded ⇔
    /// declared by an adapter with no planner tools ⇔ reachable through the instant resolver) is
    /// asserted by `PlannerBoundaryTests`; before SONNY-68 it was only incidentally true.
    ///
    /// `saveSnippet` left the list in SONNY-48, and for a reason narrower than "snippets should be
    /// plannable": `StoredRoutine.forbiddenStepOperations` permits a snippet step inside a routine,
    /// and `SnippetSaveCapabilityAdapter.assessRisk` was written specifically so a *scheduled*
    /// routine carrying one does not escalate itself into never running again (SONNY-31) — a
    /// behaviour that no product path could reach, because `save_routine` is authored through the
    /// planner and the planner had no snippet word. Excluding it made the core's permission a
    /// promise nothing could collect on. `expandSnippet` stays excluded on purpose: its execution
    /// returns the expansion as the run summary and types nothing anywhere, so inside a routine it
    /// would produce text with no consumer.
    ///
    /// `switchRunningApp` used to sit in this list and no longer does. Exclusion was not a decision
    /// about the operation's safety, it was an assumption that the resolver claimed every switch
    /// phrasing — and it did not: anything the resolver declined fell to a planner with no word for
    /// the intent, which spent it on whichever operation the sentence vaguely fit, `edit_workspace`
    /// included (SONNY-68). Giving the planner the truthful word is what stops a focus command from
    /// being absorbed by a destructive one; the resolver still answers the common phrasings without
    /// a round trip. It stays out of routines all the same — see
    /// `StoredRoutine.forbiddenStepOperations`.
    ///
    /// `visionSession` sat in this list for exactly one ticket. SONNY-92 built the capability with
    /// the operation excluded, because the schema enum this property feeds is a golden-covered
    /// surface and that ticket's never-touch list assigned the goldens to SONNY-93; SONNY-93 gives
    /// the planner the word, and owns the golden drift that follows. The exclusion set is back to
    /// its one meaning: the instant resolver is the whole of the operation's front door.
    public static var plannerVisibleCases: [AgentOperation] {
        allCases.filter { operation in
            switch operation {
            case .calculateUtility,
                 .lookupClipboardHistory,
                 .expandSnippet,
                 .lookupRecentArtifacts:
                return false
            default:
                return true
            }
        }
    }
}

public enum MediaProvider: String, Codable, CaseIterable, Sendable {
    case appleMusic = "apple_music"
    case spotify

    public var displayName: String {
        switch self {
        case .appleMusic:
            return "Apple Music"
        case .spotify:
            return "Spotify"
        }
    }
}

public enum AgentPlanDecodingError: Error, Equatable, LocalizedError {
    case invalidJSON
    case unexpectedTopLevelKey(String)
    case unexpectedStepKey(String)
    case unexpectedItemJobKey(String)
    case missingOutputText
    case malformedPlan(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Planner returned invalid JSON."
        case .unexpectedTopLevelKey(let key):
            return "Planner returned an unexpected top-level key: \(key)."
        case .unexpectedStepKey(let key):
            return "Planner returned an unexpected step key: \(key)."
        case .unexpectedItemJobKey(let key):
            return "Planner returned an unexpected job key: \(key)."
        case .missingOutputText:
            return "Planner response did not include output text."
        case .malformedPlan(let detail):
            return "Planner returned a plan Sonny could not read: \(detail)"
        }
    }
}

public enum AgentPlanDecoder {
    private static let topLevelKeys: Set<String> = [
        "summary",
        "requiresConfirmation",
        "steps",
        "itemJob"
    ]

    /// The keys a planner may name **inside** an `itemJob` (SONNY-235).
    ///
    /// `items` is deliberately absent, and that is the same rule `stepKeys` applies to
    /// `resolvedFromFinderSelection` and the two app pins: the list of forty paths a job will act on
    /// is *resolved* from the machine by `PlanItemJobResolver`, never asserted by a model. Without
    /// this check a planner could name any forty paths it liked and have them written into forty
    /// steps' `inputPath` — which the whitelist would still refuse, but only after the plan had
    /// already been previewed and assessed as something the user might approve.
    private static let itemJobKeys: Set<String> = [
        "source",
        "folderPath",
        "itemKind",
        "fileExtensions",
        "itemField"
    ]

    private static let stepKeys: Set<String> = [
        "browserName",
        "id",
        "operation",
        "description",
        "inputPath",
        "outputPath",
        "count",
        "targetURL",
        "appName",
        "question",
        "mediaProvider",
        "mediaTitle",
        "mediaArtist",
        "contextSource",
        "routineName",
        "routineSteps",
        "workspaceName",
        "workspaceApps",
        "workspaceURLs",
        "workspaceFileLocations",
        "workspaceAppsToRemove",
        "workspaceURLsToRemove",
        "workspaceFileLocationsToRemove",
        "sourceURLs",
        "searchQuery",
        "draftTitle",
        "draftContent",
        "shortcutName",
        "shortcutInput",
        // Row I, SONNY-93. The pins beside it stay absent — the goal is the planner's to write,
        // and the identity (`resolvedAppName`, `resolvedBundleIdentifier`) and the Finder-read fact
        // (`resolvedFromFinderSelection`, SONNY-185) are the resolver's alone.
        "visionGoal",
        // SONNY-382. Planner-visible for the same reason as `visionGoal`: it is a phrase from the
        // user's own sentence, and nothing but the model reads that sentence.
        "watchSubject"
    ]

    public static func decodeStrict(from data: Data) throws -> AgentPlan {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw AgentPlanDecodingError.invalidJSON
        }

        for key in dictionary.keys where !topLevelKeys.contains(key) {
            throw AgentPlanDecodingError.unexpectedTopLevelKey(key)
        }

        guard let steps = dictionary["steps"] as? [[String: Any]] else {
            throw AgentPlanDecodingError.invalidJSON
        }

        for step in steps {
            try validateStepKeys(step)
        }

        if let itemJob = dictionary["itemJob"] {
            // `null` is how a strict-schema provider says "not a job", so it is not an object and is
            // not an error either.
            if !(itemJob is NSNull) {
                guard let itemJobDictionary = itemJob as? [String: Any] else {
                    throw AgentPlanDecodingError.invalidJSON
                }
                for key in itemJobDictionary.keys where !itemJobKeys.contains(key) {
                    throw AgentPlanDecodingError.unexpectedItemJobKey(key)
                }
            }
        }

        // The key allowlist above only inspects key *names*. An unknown operation value or a
        // wrong field type still reaches the decoder, and a raw DecodingError would surface to
        // the user as unreadable Foundation text.
        do {
            return try JSONDecoder().decode(AgentPlan.self, from: data)
        } catch let error as DecodingError {
            throw AgentPlanDecodingError.malformedPlan(Self.describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        case .keyNotFound(let key, _):
            return "missing field \(key.stringValue)"
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path.isEmpty ? "value" : path) is not a \(type)"
        case .valueNotFound(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(path.isEmpty ? "value" : path) is missing a \(type)"
        @unknown default:
            return error.localizedDescription
        }
    }

    public static func decodeStrict(from text: String) throws -> AgentPlan {
        guard let data = text.data(using: .utf8) else {
            throw AgentPlanDecodingError.invalidJSON
        }
        return try decodeStrict(from: data)
    }

    private static func validateStepKeys(_ step: [String: Any]) throws {
        for key in step.keys where !stepKeys.contains(key) {
            throw AgentPlanDecodingError.unexpectedStepKey(key)
        }

        guard let routineSteps = step["routineSteps"] as? [[String: Any]] else {
            return
        }

        for nestedStep in routineSteps {
            try validateStepKeys(nestedStep)
        }
    }
}

public enum AgentPlanSchema {
    private static let stepRequiredKeys = [
        "id",
        "operation",
        "description",
        "inputPath",
        "outputPath",
        "count",
        "targetURL",
        "appName",
        "question",
        "mediaProvider",
        "mediaTitle",
        "mediaArtist",
        "contextSource",
        "routineName",
        "routineSteps",
        "workspaceName",
        "workspaceApps",
        "workspaceURLs",
        "workspaceFileLocations",
        "workspaceAppsToRemove",
        "workspaceURLsToRemove",
        "workspaceFileLocationsToRemove",
        "sourceURLs",
        "searchQuery",
        "draftTitle",
        "draftContent",
        "shortcutName",
        "shortcutInput",
        "visionGoal",
        "browserName",
        "watchSubject"
    ]

    /// The schema's own name, as `docs/sonny-backend-api-contract.md` §4.2's
    /// `response_schema_name` carries it. Short, stable, and never rendered anywhere.
    public static let name = "agent_plan"

    /// **The bare JSON Schema, separated from the provider wrapper around it** (SONNY-130).
    ///
    /// §4.2 puts `response_schema` — this value — on the wire and leaves the mapping onto a
    /// provider's structured-output mechanism to the server, because "the client does not know
    /// which mechanism was used and must not need to".
    ///
    /// **There is no `responseFormat()` beside this any more, and there should not be one**
    /// (SONNY-321). It wrapped this schema in OpenAI's `json_schema` envelope — `type`, `name`,
    /// `strict`, `schema` — for `CerebrasPlanner`, which built its own provider request while it
    /// held its own credential. SONNY-132 deleted that class and SONNY-130 had already left
    /// `WebResearchNoteSchema`'s identical wrapper caller-less; both were removed together, because
    /// removing one of a matched pair is the half-swept state a later reader has to re-derive.
    /// **A client-side provider envelope is not a shape this client should be able to build:**
    /// §4.2 puts the bare schema on the wire and makes the mapping the server's, so a wrapper here
    /// would be the client deciding a mechanism it "must not need to" know. If a future reader
    /// wants one, that is a contract change first.
    public static func schema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["summary", "requiresConfirmation", "steps", "itemJob"],
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "Short human-readable summary of the proposed action."
                ],
                "requiresConfirmation": [
                    "type": "boolean",
                    "description": "True when the action writes files, opens apps, or converts documents."
                ],
                "steps": [
                    "type": "array",
                    "minItems": 1,
                    "items": stepSchema(allowsRoutineSteps: true)
                ],
                "itemJob": itemJobSchema()
            ]
        ]
    }

    /// The declaration that turns one group of steps into the same work repeated over many items
    /// (SONNY-235).
    ///
    /// **`items` is not here and must never be**, for the reason `AgentPlanDecoder.itemJobKeys`
    /// states: the paths a job acts on are read from the machine at prepare time, and a model that
    /// could name them would be choosing forty files to act on. The schema and the decode allowlist
    /// have to agree about that, and `aPlannerMayDeclareAJobAndMayNotNameItsItems` holds the decode
    /// half.
    ///
    /// **Always an object, never a nullable one, and "not a job" is a null `source` inside it.** The
    /// obvious spelling is `"type": ["object", "null"]`, and it is one the gateway cannot send: the
    /// Anthropic prune rewrites a type union into an `anyOf` and leaves every sibling keyword on the
    /// parent, so a nullable object comes out as a bare `{"type": "object"}` branch with no
    /// `additionalProperties` — which `server/test/anthropic.test.ts` refuses, correctly, because the
    /// structured-output subset requires it on object nodes. Teaching the prune to carry
    /// `properties`, `required` and `additionalProperties` into that branch is a redesign of
    /// `withoutTypeUnions` for a shape nothing else sends, which its own comment warns against; and
    /// putting `additionalProperties: false` on a branch that carries no `properties` would forbid
    /// the very object it is describing. So the nesting stays and the nullability moves inside it,
    /// which is a shape the prune already handles everywhere else in this schema.
    ///
    /// Named in the top-level `required` list beside the other three, because the structured-output
    /// subset requires every property to be required. `AgentPlan.init(from:)` is what turns an object
    /// with a null `source` back into "no job" — see `PlanItemJobDecodingSignal`.
    private static func itemJobSchema() -> [String: Any] {
        [
            "type": "object",
            "description": "Set ONLY when the user asked for the same work to be done to every item in one folder or in the Finder selection — \"summarise each of these\", \"convert all of these folders\". Null for every other command, including one that names two or three things explicitly, which is an ordinary multi-step plan. When set, steps describes the work done to ONE item and Sonny repeats it for each item it finds.",
            "additionalProperties": false,
            "required": ["source", "folderPath", "itemKind", "fileExtensions", "itemField"],
            "properties": [
                "source": [
                    "type": ["string", "null"],
                    "enum": PlanItemSource.allCases.map(\.rawValue) + [NSNull()],
                    "description": "Where the items come from: folder for a folder the user named, finder_selection for whatever they have selected in Finder. NULL when this is not a job over many items, which is almost every command."
                ],
                "folderPath": [
                    "type": ["string", "null"],
                    "description": "The folder to read when source is folder, otherwise null."
                ],
                "itemKind": [
                    "type": ["string", "null"],
                    "enum": PlanItemKind.allCases.map(\.rawValue) + [NSNull()],
                    "description": "Whether each item is a file or a folder. Required when source is set; null otherwise."
                ],
                "fileExtensions": [
                    "type": ["array", "null"],
                    "items": ["type": "string"],
                    "description": "File extensions without dots, such as pdf or docx, when the user named a kind of file. Null for every file, and null whenever itemKind is folders."
                ],
                "itemField": [
                    "type": ["string", "null"],
                    "enum": PlanItemField.allCases.map(\.rawValue) + [NSNull()],
                    "description": "Which field of each repeated step the item is written into: inputPath for a capability that reads a file or folder, shortcutInput for running a Shortcut on each item. Required when source is set; null otherwise."
                ]
            ]
        ]
    }

    private static func stepSchema(allowsRoutineSteps: Bool) -> [String: Any] {
        var properties = baseStepProperties()
        properties["routineSteps"] = allowsRoutineSteps
            ? [
                "type": ["array", "null"],
                "description": "Nested executable steps for save_routine, or null.",
                "items": stepSchema(allowsRoutineSteps: false)
            ]
            : [
                "type": "null",
                "description": "Nested routines are not allowed."
            ]

        return [
            "type": "object",
            "additionalProperties": false,
            "required": stepRequiredKeys,
            "properties": properties
        ]
    }

    private static func baseStepProperties() -> [String: Any] {
        [
            "id": ["type": "string"],
            "operation": [
                "type": "string",
                "enum": AgentOperation.plannerVisibleCases.map(\.rawValue)
            ],
            "description": ["type": "string"],
            "inputPath": [
                "type": ["string", "null"],
                "description": "Folder or file path supplied by the user, or null."
            ],
            "outputPath": [
                "type": ["string", "null"],
                "description": "Destination folder or file path, reveal target path, or null."
            ],
            "count": [
                "type": ["integer", "null"],
                "description": "Requested count, such as top 3 files or top 5 headlines."
            ],
            "targetURL": [
                "type": ["string", "null"],
                "description": "URL for browser/fetch actions or exact provider result URI for media actions, or null."
            ],
            "appName": [
                "type": ["string", "null"],
                "description": "Human app name for open_app or switch_running_app actions, or null."
            ],
            "question": [
                "type": ["string", "null"],
                "description": "Clarifying question for clarify actions, or null."
            ],
            "mediaProvider": [
                "type": ["string", "null"],
                "enum": (MediaProvider.allCases.map(\.rawValue) as [Any]) + [NSNull()],
                "description": "Music provider for media-opening actions, or null."
            ],
            "mediaTitle": [
                "type": ["string", "null"],
                "description": "Song or album title for media-opening actions, or null."
            ],
            "mediaArtist": [
                "type": ["string", "null"],
                "description": "Artist name for media-opening actions when provided by the user, or null."
            ],
            "contextSource": [
                "type": ["string", "null"],
                "enum": ([FinderContextSource.finderSelection.rawValue] as [Any]) + [NSNull()],
                "description": "Use finder_selection when the user refers to selected Finder items, or null."
            ],
            "routineName": [
                "type": ["string", "null"],
                "description": "Routine name for save_routine or run_routine, or null."
            ],
            "workspaceName": [
                "type": ["string", "null"],
                "description": "Workspace name for create_workspace, edit_workspace or open_workspace, or null."
            ],
            "workspaceApps": [
                "type": ["array", "null"],
                "description": "App names for create_workspace, or app names to add for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceURLs": [
                "type": ["array", "null"],
                "description": "HTTP/HTTPS URLs for create_workspace, or URLs to add for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceFileLocations": [
                "type": ["array", "null"],
                "description": "Folder paths inside Desktop or Documents to add to a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceAppsToRemove": [
                "type": ["array", "null"],
                "description": "App names to remove from a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceURLsToRemove": [
                "type": ["array", "null"],
                "description": "URLs or site domains to remove from a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "workspaceFileLocationsToRemove": [
                "type": ["array", "null"],
                "description": "Folder paths to remove from a workspace for edit_workspace, or null.",
                "items": ["type": "string"]
            ],
            "sourceURLs": [
                "type": ["array", "null"],
                "description": "HTTP/HTTPS source URLs for web_to_markdown comparison notes, or null.",
                "items": ["type": "string"]
            ],
            "searchQuery": [
                "type": ["string", "null"],
                "description": "Topic or web search query for web_to_markdown research notes, the snippet trigger for save_snippet, or null."
            ],
            "draftTitle": [
                "type": ["string", "null"],
                "description": "Title for create_local_draft Markdown drafts, or null."
            ],
            "draftContent": [
                "type": ["string", "null"],
                "description": "User-provided body content for create_local_draft Markdown drafts, the expansion text for save_snippet, or null."
            ],
            "shortcutName": [
                "type": ["string", "null"],
                "description": "Existing Apple Shortcut name for invoke_shortcut, or null."
            ],
            "shortcutInput": [
                "type": ["string", "null"],
                "description": "Simple text input to pass to invoke_shortcut through a temporary input file, or null."
            ],
            "browserName": [
                "type": ["string", "null"],
                "description": "The browser the user named for a URL-opening step, exactly as they said it (for example \"Chrome\", \"Safari\"), or null when they named none."
            ],
            "visionGoal": [
                "type": ["string", "null"],
                "description": "What vision_session should accomplish inside the named app, in one sentence, or null. Sonny reads the app's window and decides each click and keystroke from what it sees."
            ],
            "watchSubject": [
                "type": ["string", "null"],
                "description": "For start_watching: what the user asked to be told about, in their own words and as a short noun phrase — \"the price on that page\", \"the status of my order\". Null for every other operation."
            ]
        ]
    }
}
