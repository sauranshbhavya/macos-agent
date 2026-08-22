import Foundation

public enum CapabilityRiskTier: Int, Codable, CaseIterable, Equatable, Sendable {
    case tier0 = 0
    case tier1 = 1
    case tier2 = 2
    case tier3 = 3
    case tier4 = 4

    public var displayName: String {
        "Tier \(rawValue)"
    }
}

public enum CapabilityExecutorLocation: String, Codable, Equatable, Sendable {
    case localMac = "local_mac"
}

public enum CapabilityPermissionEnforcement: String, Codable, Equatable, Sendable {
    case descriptiveOnly = "descriptive_only"
}

public enum CapabilityPermissionRequirement: String, Codable, CaseIterable, Equatable, Sendable {
    case desktopDocumentsAccess = "desktop_documents_access"
    case browserOpening = "browser_opening"
    case appOpening = "app_opening"
    case networkAccess = "network_access"
    case finderAutomation = "finder_automation"
    case wordAutomation = "word_automation"
    case shortcutsAutomation = "shortcuts_automation"
    case screenRecording = "screen_recording"
    case accessibilityControl = "accessibility_control"

    public var displayName: String {
        switch self {
        case .desktopDocumentsAccess:
            return "Desktop/Documents access"
        case .browserOpening:
            return "Browser opening"
        case .appOpening:
            return "App opening"
        case .networkAccess:
            return "Network access"
        case .finderAutomation:
            return "Finder automation"
        case .wordAutomation:
            return "Microsoft Word automation"
        case .shortcutsAutomation:
            return "Shortcuts automation"
        case .screenRecording:
            return "Screen Recording"
        case .accessibilityControl:
            return "Accessibility control"
        }
    }

    public var description: String {
        switch self {
        case .desktopDocumentsAccess:
            return "macOS may require access to user-selected Desktop or Documents paths."
        case .browserOpening:
            return "Sonny may ask macOS to open a URL in the default browser."
        case .appOpening:
            return "Sonny may ask macOS to open an app installed on this Mac."
        case .networkAccess:
            return "Sonny may make a fixed network request for this capability."
        case .finderAutomation:
            return "Sonny may use a fixed Finder AppleScript template."
        case .wordAutomation:
            return "Sonny may use a fixed Microsoft Word AppleScript template."
        case .shortcutsAutomation:
            return "Sonny may invoke a named Apple Shortcut through the fixed Shortcuts CLI template."
        case .screenRecording:
            return "Sonny may capture the frontmost window of an app you target so screen-aware tools can see it."
        case .accessibilityControl:
            return "Sonny may use macOS Accessibility to act inside apps you have specifically allowed."
        }
    }
}

public struct CapabilityPermissionMetadata: Codable, Equatable, Sendable {
    public var requirement: CapabilityPermissionRequirement
    public var enforcement: CapabilityPermissionEnforcement

    public init(
        requirement: CapabilityPermissionRequirement,
        enforcement: CapabilityPermissionEnforcement = .descriptiveOnly
    ) {
        self.requirement = requirement
        self.enforcement = enforcement
    }
}

public struct CapabilityMetadata: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String
    public var version: String
    public var operations: [AgentOperation]
    public var plannerTools: [AgentTool]
    public var requiredPermissions: [CapabilityPermissionMetadata]
    public var defaultRiskTier: CapabilityRiskTier
    public var executorLocation: CapabilityExecutorLocation

    public init(
        id: String,
        displayName: String,
        description: String,
        version: String = "1.0",
        operations: [AgentOperation],
        plannerTools: [AgentTool],
        requiredPermissions: [CapabilityPermissionMetadata] = [],
        defaultRiskTier: CapabilityRiskTier,
        executorLocation: CapabilityExecutorLocation = .localMac
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.version = version
        self.operations = operations
        self.plannerTools = plannerTools
        self.requiredPermissions = requiredPermissions
        self.defaultRiskTier = defaultRiskTier
        self.executorLocation = executorLocation
    }
}

public struct CapabilityExecutionContext {
    /// Assesses a nested plan under an **explicitly named** workspace scope.
    ///
    /// The scope is a parameter rather than something the closure captures because the two callers
    /// need opposite answers, and the difference is a recorded product decision rather than an
    /// implementation detail: `run_routine` forwards the caller's scope (a routine's steps must not
    /// escape the boundary its caller is bound by), while `save_routine` passes `.unscoped` because
    /// saving touches one file inside Sonny's own store and the routine's steps are scoped when it
    /// actually runs — `PlanScopedResources`' `.saveRoutine` case states exactly that.
    ///
    /// Captured scope is what made that go wrong once already: a single captured value silently
    /// applied `run_routine`'s rule to `save_routine` too, which produced a scope prompt naming a
    /// URL nothing in the plan would open. With the scope in the signature a new nested-assess
    /// caller cannot inherit either rule by accident — it has to write one down.
    public typealias AssessNestedPlan = @MainActor (AgentPlan, TaskWorkspaceScope) throws -> CapabilityRiskAssessment
    public typealias PreviewNestedPlan = @MainActor (AgentPlan) throws -> [ActionPreview]
    /// Runs a nested plan, optionally binding a browser for every URL it opens on the injected
    /// browser-opener seam. `nil` means the
    /// nested plan keeps the system default, which is what every caller except a routine passes.
    public typealias ExecuteNestedPlan = @MainActor (AgentPlan, MacApp?, @escaping (AgentPhase, String) -> Void) async throws -> AgentRunResult

    public var whitelist: PathWhitelist
    public var inventory: FileInventory
    public var zipArchiver: any ZipArchiving
    public var documentConverter: any DocumentConverting
    public var browserOpener: any BrowserOpening
    public var hackerNewsFetcher: any HackerNewsFetching
    /// The alias table — which names mean the same app. Not a roster of what may be opened; that
    /// question moved to `installedAppResolver` when C12 dissolved the launch allowlist (SONNY-82).
    public var appCatalog: MacAppCatalog
    /// Which app a human name means on *this* Mac, answered from the Launch Services database.
    /// The launch, workspace-open and browser-binding paths all resolve through this one seam.
    public var installedAppResolver: any InstalledAppResolving
    public var appSearchURLCatalog: AppSearchURLCatalog
    public var appOpener: any AppOpening
    public var fileOpener: any FileOpening
    public var mediaOpener: any MediaOpening
    public var spotifyPlaybackProvider: any SpotifyPlaybackProviding
    public var appleMusicPlaybackProvider: any AppleMusicPlaybackProviding
    public var finderContextReader: any FinderContextReading
    public var permissionReadinessService: PermissionReadinessService
    public var routineStore: RoutineStore
    public var workspaceStore: WorkspaceStore
    public var webPageLoader: PublicWebPageLoader
    public var webSearchProvider: any WebSearchProviding
    public var webResearchSynthesizer: any WebResearchSynthesizing
    public var clipboardHistoryStore: ClipboardHistoryStore
    public var snippetStore: SnippetStore
    public var runningAppSwitcher: any RunningAppSwitching
    public var recentArtifactStore: RecentArtifactStore
    public var shortcutCatalog: any ShortcutCatalogProviding
    public var shortcutInvoker: any ShortcutInvoking
    public var shortcutRunHistoryStore: ShortcutRunHistoryStore
    public var fileManager: FileManager
    public var now: () -> Date
    /// Live push-to-talk hotkey registration state. Read through a closure for the same reason
    /// as `now` — the real value lives in the UI layer and changes after launch, so a snapshot
    /// or a hardcoded `true` would misreport an actual Control-Option-Space conflict.
    public var hotKeyReady: () -> Bool
    /// The browser this execution should prefer for every URL it opens *on the injected
    /// browser-opener seam*, or `nil` for the system default. `.playMedia` is on a different seam
    /// and does not consult this — **decided, not pending** (SONNY-51, founder 2026-08-20): a media
    /// step's fallback link is playback, which the OS routes, and forcing an https provider link
    /// through a named browser could override the handler that would otherwise open the Spotify or
    /// Music app. The reasoning and the cost are in `docs/sonny-founder-design-decisions.md`.
    ///
    /// Set only for the nested execution of a routine that names a browser-capable app among its
    /// own steps (SONNY-24), mirroring what a workspace already does with its apps list. It is
    /// `nil` for every top-level run, so a plain "open github.com" keeps going to the system
    /// default browser — the ordinary path must not inherit a routine's preference.
    public var preferredBrowser: MacApp?

    /// Destination paths, `DestinationKey.folded`, that earlier units of this same chain have already
    /// claimed or written (SONNY-76).
    ///
    /// **Empty for a single-unit plan, which is every plan that is not a chain.** It exists because a
    /// two-folder DOCX conversion into one output folder is two `[scan_docx, convert]` units after
    /// SONNY-34, so the second unit re-scans after the first has written. Without this it saw the
    /// first unit's PDF as a file that predated the run, reported the second document "skipped
    /// because a PDF already exists", and left the user a document short with an explanation pointing
    /// at a file they never had.
    ///
    /// Accumulated from what each unit's previews say they write, so it needs no second return
    /// channel and covers writes from any capability rather than only the docx one — a PDF this run
    /// produced is this run's whether a conversion or something else made it.
    ///
    /// **`let`, not `var`, since SONNY-163 made the nested-plan closures inherit it.** Those closures
    /// capture the value this context was built with, and a `var` here would let an adapter mutate
    /// its own copy of the context and reasonably expect the nested call to see the change — which it
    /// would not, silently. A mutation battery found exactly that: a mutant seeding a claim on this
    /// property before calling `executeNestedPlan` changed nothing, because the property and the
    /// captured value are two homes for one fact. `let` deletes the second home, so the divergence is
    /// a compile error rather than a behaviour nothing can observe.
    public let claimedEarlierInThisRun: RunClaims

    /// The browser a URL-opening step should use: the one the user named on that step if it resolves
    /// to something installed, otherwise whatever was already in force (SONNY-157).
    ///
    /// **Precedence, stated rather than left to whichever the code happens to apply.** A browser named
    /// on the step wins over `preferredBrowser`, which today is only ever set by the routine path. The
    /// reasoning is specificity: a routine's binding is a saved default inferred from the apps that
    /// routine opens, while a name on the step is what the user said in this command. The more
    /// specific and more recent instruction wins. Workspace binding is unaffected and does not come
    /// through this parameter at all — `OpenWorkspaceCapabilityAdapter` resolves its own browser from
    /// the workspace's app list and passes it directly.
    ///
    /// **Reads the step for this operation rather than the first browser named anywhere in the plan.**
    /// A chained plan can open two URLs, and "open A in Chrome then B in Safari" must not put both in
    /// Chrome. Each adapter asks with its own operation, so each reads the step it is already acting
    /// on.
    ///
    /// **An unresolvable name falls back rather than failing.** If the user names a browser that is
    /// not installed, the step keeps whatever it would have used anyway. That matches the reasoning
    /// `WorkspaceBrowserOpener` already records for the same situation: a link opening in the wrong
    /// browser beats one that fails mid-open. The opener applies the same rule again if the app is
    /// installed but refuses to launch, and logs it.
    public func browser(for operation: AgentOperation, in plan: AgentPlan) -> MacApp? {
        let named = plan.steps.first { $0.operation == operation }?.browserName
        guard let named, !named.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return preferredBrowser
        }
        return installedAppResolver.resolve(named)?.macApp ?? preferredBrowser
    }
    /// The workspace scope the *current* assessment is running under, for a nested-assess caller
    /// that needs to forward it. `.unscoped` for every preview and execute context — neither
    /// assesses — and for every task not bound to a workspace.
    public var taskScope: TaskWorkspaceScope
    public var assessNestedPlan: AssessNestedPlan
    public var previewNestedPlan: PreviewNestedPlan
    public var executeNestedPlan: ExecuteNestedPlan
    /// Everything a vision session needs from outside this module, or `nil` when this build has no
    /// screen-control wiring.
    ///
    /// One aggregate rather than six fields, and defaulted to `nil` rather than non-defaulted,
    /// because the failure mode here is the opposite of `taskScope`'s: a construction site that
    /// forgets this gets a vision session that *refuses to run* with
    /// `VisionSessionError.visionUnavailable`, which is loud. A site that forgot a `taskScope` got a
    /// silently unchecked routine, which is why that one is non-defaulted and this one is not.
    public var visionSession: VisionSessionEnvironment?
    /// Whether this run leaves traces — "Don't save this task" (SONNY-120).
    ///
    /// Defaulted to `.record`, so every existing construction site and every test keeps its current
    /// behaviour, and an adapter that never asks behaves exactly as before. Adapters that write a
    /// `.trace` store ask before writing; the classification-enumerating test is what catches one
    /// that forgets.
    public var recordingPolicy: TaskRecordingPolicy = .record

    /// The standing memory switches — Command Center's Memory section (SONNY-208).
    ///
    /// Defaulted on the same reasoning as `recordingPolicy` directly above. The two are asked
    /// together through `allowsRecording(to:)` and never separately: a run may write a store only if
    /// *this* task is recording traces **and** the user has not switched that kind of memory off.
    public var memoryRecording: MemoryRecordingSettings = .recordEverything

    /// Whether this run may write new memory into `store` — both switches, one question.
    ///
    /// The single place the conjunction is written for capabilities, so an adapter cannot ask half
    /// of it. `AgentViewModel.allowsRecording(to:)` is the same conjunction on the view model's own
    /// writing sites, which live outside any capability.
    public func allowsRecording(to store: LocalStore) -> Bool {
        recordingPolicy.allowsWriting(to: store) && memoryRecording.allowsRecording(to: store)
    }

    public init(
        whitelist: PathWhitelist,
        inventory: FileInventory,
        zipArchiver: any ZipArchiving,
        documentConverter: any DocumentConverting,
        browserOpener: any BrowserOpening,
        hackerNewsFetcher: any HackerNewsFetching,
        appCatalog: MacAppCatalog,
        installedAppResolver: any InstalledAppResolving,
        appSearchURLCatalog: AppSearchURLCatalog,
        appOpener: any AppOpening,
        fileOpener: any FileOpening,
        mediaOpener: any MediaOpening,
        spotifyPlaybackProvider: any SpotifyPlaybackProviding,
        appleMusicPlaybackProvider: any AppleMusicPlaybackProviding,
        finderContextReader: any FinderContextReading,
        permissionReadinessService: PermissionReadinessService,
        routineStore: RoutineStore,
        workspaceStore: WorkspaceStore,
        webPageLoader: PublicWebPageLoader,
        webSearchProvider: any WebSearchProviding,
        webResearchSynthesizer: any WebResearchSynthesizing,
        clipboardHistoryStore: ClipboardHistoryStore,
        snippetStore: SnippetStore,
        runningAppSwitcher: any RunningAppSwitching,
        recentArtifactStore: RecentArtifactStore,
        shortcutCatalog: any ShortcutCatalogProviding,
        shortcutInvoker: any ShortcutInvoking,
        shortcutRunHistoryStore: ShortcutRunHistoryStore,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        hotKeyReady: @escaping () -> Bool = { true },
        preferredBrowser: MacApp? = nil,
        claimedEarlierInThisRun: RunClaims = .none,
        // Non-defaulted, on the same reasoning as `assessRisk(plan:scope:)` and both `AgentRunner`
        // entry points, and for a failure that is one layer quieter than either: a second
        // construction site omitting this would leave `taskScope` at `.unscoped`, which turns
        // `run_routine`'s nested forward into a no-op — a routine's steps would stop being checked
        // against the boundary its caller is bound by, with every test still green because the
        // executor's own call site would be the only one passing a real scope.
        taskScope: TaskWorkspaceScope,
        assessNestedPlan: @escaping AssessNestedPlan,
        previewNestedPlan: @escaping PreviewNestedPlan,
        executeNestedPlan: @escaping ExecuteNestedPlan,
        visionSession: VisionSessionEnvironment? = nil,
        recordingPolicy: TaskRecordingPolicy = .record,
        memoryRecording: MemoryRecordingSettings = .recordEverything
    ) {
        self.recordingPolicy = recordingPolicy
        self.memoryRecording = memoryRecording
        self.whitelist = whitelist
        self.inventory = inventory
        self.zipArchiver = zipArchiver
        self.documentConverter = documentConverter
        self.browserOpener = browserOpener
        self.hackerNewsFetcher = hackerNewsFetcher
        self.appCatalog = appCatalog
        self.installedAppResolver = installedAppResolver
        self.appSearchURLCatalog = appSearchURLCatalog
        self.appOpener = appOpener
        self.fileOpener = fileOpener
        self.mediaOpener = mediaOpener
        self.spotifyPlaybackProvider = spotifyPlaybackProvider
        self.appleMusicPlaybackProvider = appleMusicPlaybackProvider
        self.finderContextReader = finderContextReader
        self.permissionReadinessService = permissionReadinessService
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.webPageLoader = webPageLoader
        self.webSearchProvider = webSearchProvider
        self.webResearchSynthesizer = webResearchSynthesizer
        self.clipboardHistoryStore = clipboardHistoryStore
        self.snippetStore = snippetStore
        self.runningAppSwitcher = runningAppSwitcher
        self.recentArtifactStore = recentArtifactStore
        self.shortcutCatalog = shortcutCatalog
        self.shortcutInvoker = shortcutInvoker
        self.shortcutRunHistoryStore = shortcutRunHistoryStore
        self.fileManager = fileManager
        self.now = now
        self.hotKeyReady = hotKeyReady
        self.preferredBrowser = preferredBrowser
        self.claimedEarlierInThisRun = claimedEarlierInThisRun
        self.taskScope = taskScope
        self.assessNestedPlan = assessNestedPlan
        self.previewNestedPlan = previewNestedPlan
        self.executeNestedPlan = executeNestedPlan
        self.visionSession = visionSession
    }
}

public protocol CapabilityAdapter: Sendable {
    var metadata: CapabilityMetadata { get }

    @MainActor
    func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan

    @MainActor
    func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview]

    @MainActor
    func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment

    @MainActor
    func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult
}

public extension CapabilityAdapter {
    @MainActor
    func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        plan
    }

    @MainActor
    func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        throw CapabilityRegistryError.notExecutable(metadata.id)
    }

    @MainActor
    func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier)
    }

    @MainActor
    func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        throw CapabilityRegistryError.notExecutable(metadata.id)
    }
}

public struct MetadataOnlyCapabilityAdapter: CapabilityAdapter {
    public var metadata: CapabilityMetadata

    public init(metadata: CapabilityMetadata) {
        self.metadata = metadata
    }
}

public enum CapabilityRegistryError: Error, Equatable, LocalizedError {
    case duplicateCapabilityID(String)
    case duplicateOperation(AgentOperation, String, String)
    case unsupportedOperation(AgentOperation)
    case notExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateCapabilityID(let id):
            return "Capability ID \(id) is registered more than once."
        case .duplicateOperation(let operation, let firstID, let secondID):
            return "\(operation.rawValue) is registered by both \(firstID) and \(secondID)."
        case .unsupportedOperation(let operation):
            return "\(operation.rawValue) is not registered as an executable capability."
        case .notExecutable(let id):
            return "\(id) has metadata but no executor yet."
        }
    }
}

public struct CapabilityRegistry: Sendable {
    public var adapters: [any CapabilityAdapter]
    private var operationIndex: [AgentOperation: any CapabilityAdapter]

    public init(adapters: [any CapabilityAdapter]) throws {
        var seenIDs: Set<String> = []
        var operationIndex: [AgentOperation: any CapabilityAdapter] = [:]

        for adapter in adapters {
            let metadata = adapter.metadata
            if !seenIDs.insert(metadata.id).inserted {
                throw CapabilityRegistryError.duplicateCapabilityID(metadata.id)
            }

            for operation in metadata.operations {
                if let existing = operationIndex[operation] {
                    throw CapabilityRegistryError.duplicateOperation(
                        operation,
                        existing.metadata.id,
                        metadata.id
                    )
                }
                operationIndex[operation] = adapter
            }
        }

        self.adapters = adapters
        self.operationIndex = operationIndex
    }

    public static let `default`: CapabilityRegistry = {
        do {
            return try CapabilityRegistry(adapters: DefaultCapabilityAdapters.all())
        } catch {
            preconditionFailure("Default capability registry is invalid: \(error)")
        }
    }()

    public var metadata: [CapabilityMetadata] {
        adapters.map(\.metadata)
    }

    public var tools: [AgentTool] {
        adapters.flatMap(\.metadata.plannerTools)
    }

    public func adapter(for operation: AgentOperation) throws -> any CapabilityAdapter {
        guard let adapter = operationIndex[operation] else {
            throw CapabilityRegistryError.unsupportedOperation(operation)
        }
        return adapter
    }
}
