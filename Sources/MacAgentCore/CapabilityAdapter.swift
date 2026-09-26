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
    case calendarsAccess = "calendars_access"
    case remindersAccess = "reminders_access"

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
        case .calendarsAccess:
            return "Calendars"
        case .remindersAccess:
            return "Reminders"
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
        case .calendarsAccess:
            return "Sonny may read the events on your calendars."
        case .remindersAccess:
            return "Sonny may add reminders to your Reminders."
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
    public var requiredPermissions: [CapabilityPermissionMetadata]
    public var defaultRiskTier: CapabilityRiskTier
    public var executorLocation: CapabilityExecutorLocation

    public init(
        id: String,
        displayName: String,
        description: String,
        version: String = "1.0",
        operations: [AgentOperation],
        requiredPermissions: [CapabilityPermissionMetadata] = [],
        defaultRiskTier: CapabilityRiskTier,
        executorLocation: CapabilityExecutorLocation = .localMac
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.version = version
        self.operations = operations
        self.requiredPermissions = requiredPermissions
        self.defaultRiskTier = defaultRiskTier
        self.executorLocation = executorLocation
    }
}

public struct CapabilityExecutionContext {

    public var whitelist: PathWhitelist
    public var inventory: FileInventory
    public var zipArchiver: any ZipArchiving
    public var documentConverter: any DocumentConverting
    public var browserOpener: any BrowserOpening
    /// Puts the app the user was in back in front after an open (SONNY-451); see `FocusRestoring`.
    public var focusRestorer: any FocusRestoring
    /// What the run's next unit does with the front (PR #238's F5). `nil` in V2, where nothing chains
    /// units; the V1 executor set it for each unit of a chain. See `restoringFocus(afterOpening:log:_:)`.
    public var focusHandoff: FocusHandoff?
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
    public var webPageLoader: PublicWebPageLoader
    public var clipboardHistoryStore: ClipboardHistoryStore
    public var snippetStore: SnippetStore
    public var runningAppSwitcher: any RunningAppSwitching
    public var recentArtifactStore: RecentArtifactStore
    public var shortcutCatalog: any ShortcutCatalogProviding
    public var shortcutInvoker: any ShortcutInvoking
    public var shortcutRunHistoryStore: ShortcutRunHistoryStore
    /// Unfinished runs and standing watchers, in one file (SONNY-210, SONNY-236).
    ///
    /// Here for `start_watching` and for nothing else today: `StandingWatcherCapabilityAdapter` is
    /// the only door a *user* creates a watcher through, and it needs to read the cap and write the
    /// record. The resumable half of the store is the view model's own and does not come through
    /// here.
    public var resumableTaskStore: ResumableTaskStore
    /// The user's calendars and reminders (SONNY-453). Read by `read_calendar_events` and
    /// `create_reminder` and nothing else.
    public var eventKit: any EventKitAccessing
    public var fileManager: FileManager
    public var now: () -> Date
    /// The calendar a named day and a clock time are read in — this Mac's own, in the product, and a
    /// fixed one in every test that asks what "tomorrow" is (SONNY-453). Beside `now` because the two
    /// together are what a day means.
    public var calendar: Calendar
    /// Live push-to-talk hotkey registration state. Read through a closure for the same reason
    /// as `now` — the real value lives in the UI layer and changes after launch, so a snapshot
    /// or a hardcoded `true` would misreport an actual Control-Option-Space conflict.
    public var hotKeyReady: () -> Bool
    /// Whether a Sonny session is held on this Mac, for the readiness row that replaced the
    /// `OPENAI_API_KEY` one (SONNY-136).
    ///
    /// **A closure, and defaulted to `.undetermined` rather than to `.signedIn`.** It is a closure
    /// for exactly `hotKeyReady`'s reason: the real answer lives in the UI layer and changes after
    /// launch, so a snapshot taken at construction misreports a sign-in or a sign-out that happened
    /// since. It defaults to `.undetermined` because a context built by something that has no
    /// account wiring — `MacAgentCore` on its own, and every test that is not about readiness —
    /// genuinely does not know, and `.signedIn` would be a default that reports readiness nobody
    /// checked.
    public var modelAccessReadiness: () -> ModelAccessReadiness
    /// The other half of the account row (SONNY-336): whether this Mac holds an entitlement claim it
    /// can verify offline right now.
    ///
    /// **A closure defaulted to `.undetermined`, for exactly the reasons one line up.** The answer
    /// lives behind `EntitlementService`, an actor the UI layer owns, and it changes after launch —
    /// a sign-in, a refresh, a claim lapsing — so a snapshot taken at construction misreports it.
    /// The default is the never-asked value because a context built with no entitlement wiring
    /// genuinely has not asked; `.confirmed` would be a default that reports an entitlement nobody
    /// checked, which is the direction SONNY-136 refused to build in.
    public var planReadiness: () -> PlanReadiness
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
    /// specific and more recent instruction wins.
    ///
    /// **Workspace binding used to be outside this parameter entirely, and as of SONNY-186 it is
    /// not.** This said *"Workspace binding is unaffected and does not come through this parameter
    /// at all — `OpenWorkspaceCapabilityAdapter` resolves its own browser from the workspace's app
    /// list and passes it directly"*, which was true while a routine could not carry
    /// `open_workspace`: the two rules could not meet, because nothing set `preferredBrowser` on a
    /// path that reached that adapter. A routine may carry one now, so they meet, and the adapter
    /// reads `preferredBrowser` first and falls back to the workspace's own app list — the founders'
    /// 2026-08-04 one-routine-one-browser rule winning inside a routine, and nothing changing
    /// outside one. The decision and its cost are recorded at
    /// `OpenWorkspaceCapabilityAdapter.execute`; it does **not** read a browser named on the
    /// `open_workspace` step, so the precedence stated above still describes every path that exists.
    ///
    /// **This comment is why PR #177's F1 is filed against the record and not only the code.** The
    /// changelog bullet that branch wrote named `git grep -n "forbiddenStepOperations" -- Sources`
    /// as the enumeration that finds what a relaxation of that set makes reachable. It cannot reach
    /// this file: `grep -c "forbiddenStepOperations" Sources/MacAgentCore/CapabilityAdapter.swift`
    /// → **0**, against **13** files that do contain it
    /// (`git grep -l "forbiddenStepOperations" -- Sources | wc -l`), both at `740876c`. A file that
    /// reasons about the *consequence* of a rule without naming the rule is invisible to a grep
    /// keyed on the rule's name, and this file was the one that documented the split.
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



    public init(
        whitelist: PathWhitelist,
        inventory: FileInventory,
        zipArchiver: any ZipArchiving,
        documentConverter: any DocumentConverting,
        browserOpener: any BrowserOpening,
        appCatalog: MacAppCatalog,
        installedAppResolver: any InstalledAppResolving,
        appSearchURLCatalog: AppSearchURLCatalog,
        appOpener: any AppOpening,
        // Defaulted to the inert restorer, and that is the safe direction here unlike a store's
        // default (SONNY-240): an inert restorer reads no frontmost app and moves none, so a
        // fixture that says nothing cannot bring a real app forward on the developer's Mac. The
        // shipping executor passes `FocusRestorer.forThisMac()` and a scan test pins that it does.
        focusRestorer: any FocusRestoring = FocusRestorer.inert(),
        focusHandoff: FocusHandoff? = nil,
        fileOpener: any FileOpening,
        mediaOpener: any MediaOpening,
        spotifyPlaybackProvider: any SpotifyPlaybackProviding,
        appleMusicPlaybackProvider: any AppleMusicPlaybackProviding,
        finderContextReader: any FinderContextReading,
        permissionReadinessService: PermissionReadinessService,
        webPageLoader: PublicWebPageLoader,
        clipboardHistoryStore: ClipboardHistoryStore,
        snippetStore: SnippetStore,
        runningAppSwitcher: any RunningAppSwitching,
        recentArtifactStore: RecentArtifactStore,
        shortcutCatalog: any ShortcutCatalogProviding,
        shortcutInvoker: any ShortcutInvoking,
        shortcutRunHistoryStore: ShortcutRunHistoryStore,
        // Non-defaulted, exactly as the twelve stores beside it are and for SONNY-240's reason: a
        // defaulted store resolves to the real `~/Library` location, so a fixture that omitted it
        // would create watchers in the developer's own data — and then check them on a real timer.
        resumableTaskStore: ResumableTaskStore,
        // Defaulted to the seam that refuses, which is the safe direction for the focus restorer's
        // reason (SONNY-451): a construction site that says nothing cannot reach a real calendar.
        eventKit: any EventKitAccessing = UnavailableEventKitStore(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        hotKeyReady: @escaping () -> Bool = { true },
        modelAccessReadiness: @escaping () -> ModelAccessReadiness = { .undetermined },
        planReadiness: @escaping () -> PlanReadiness = { .undetermined },
        preferredBrowser: MacApp? = nil,
        claimedEarlierInThisRun: RunClaims = .none
    ) {
        self.whitelist = whitelist
        self.inventory = inventory
        self.zipArchiver = zipArchiver
        self.documentConverter = documentConverter
        self.browserOpener = browserOpener
        self.focusRestorer = focusRestorer
        self.focusHandoff = focusHandoff
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
        self.webPageLoader = webPageLoader
        self.clipboardHistoryStore = clipboardHistoryStore
        self.snippetStore = snippetStore
        self.runningAppSwitcher = runningAppSwitcher
        self.recentArtifactStore = recentArtifactStore
        self.shortcutCatalog = shortcutCatalog
        self.shortcutInvoker = shortcutInvoker
        self.shortcutRunHistoryStore = shortcutRunHistoryStore
        self.resumableTaskStore = resumableTaskStore
        self.eventKit = eventKit
        self.fileManager = fileManager
        self.now = now
        self.calendar = calendar
        self.hotKeyReady = hotKeyReady
        self.modelAccessReadiness = modelAccessReadiness
        self.planReadiness = planReadiness
        self.preferredBrowser = preferredBrowser
        self.claimedEarlierInThisRun = claimedEarlierInThisRun
    }
}

public extension CapabilityExecutionContext {
    /// Runs an open of `bundleIdentifiers` and gives the user's app back once it has completed — or,
    /// when the run's next unit is a screen-control session on one of those apps, hands the user's
    /// app to that session to give back when it ends (SONNY-451; the hand-over is PR #238's F5).
    ///
    /// **Why the hand-over.** A planned `open Notes and make a note` is an `open_app` step and then a
    /// session on Notes; restoring between them put the user's app in front for a moment before the
    /// session brought Notes forward again. The trace line is the one every open step writes.
    @MainActor
    func restoringFocus<T>(
        afterOpening bundleIdentifiers: [String],
        log: @escaping (AgentPhase, String) -> Void,
        _ work: () async throws -> T
    ) async rethrows -> T {
        try await focusRestorer.restoringFocus(
            onRestore: { log(.act, "Brought \($0.displayName) back in front") },
            handingOnTo: focusHandoff?.carry(forOpening: bundleIdentifiers),
            work
        )
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

/// An adapter asked for a step it has no body for.
public enum CapabilityRegistryError: Error, Equatable, LocalizedError {
    case notExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .notExecutable(let id):
            return "\(id) has metadata but no executor yet."
        }
    }
}
