import Foundation
import MacAgentTestSupport
@testable import MacAgentCore

/// A `CapabilityExecutionContext` for the handful of vision tests that must call an adapter method
/// *directly*.
///
/// **Almost no test should use this.** Every vision test that can go through `AgentActionExecutor`
/// does, because the executor is what runs `resolveDefaultOutputs` before every gate and a test that
/// skipped it would be exercising a path production never takes. The exceptions are the defense-in-
/// depth tests for the assess and execute doors, whose entire point is that those doors answer
/// correctly *with resolve never having run* — which is unreachable through the executor by
/// construction.
@MainActor
enum CapabilityTestContext {
    static func make(
        installed: [InstalledApp],
        whitelist: PathWhitelist = PathWhitelist(),
        appOpener: any AppOpening = WorkspaceAppOpener(),
        browserOpener: any BrowserOpening = WorkspaceBrowserOpener(),
        focusRestorer: any FocusRestoring = FocusRestorer.inert(),
        stores: CapabilityTestStores = CapabilityTestStores(),
        eventKit: any EventKitAccessing = UnavailableEventKitStore(),
        runningAppSwitcher: (any RunningAppSwitching)? = nil,
        shortcutCatalog: any ShortcutCatalogProviding = ProcessShortcutCatalog(),
        shortcutInvoker: any ShortcutInvoking = ProcessShortcutInvoker(),
        webPageLoader: PublicWebPageLoader = .live(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) -> CapabilityExecutionContext {
        CapabilityExecutionContext(
            whitelist: whitelist,
            inventory: FileInventory(),
            zipArchiver: ProcessZipArchiver(),
            documentConverter: AutoDocumentConverter(),
            browserOpener: browserOpener,
            appCatalog: .default,
            installedAppResolver: InstalledAppResolver(source: FixedAppSource(installed)),
            appSearchURLCatalog: .default,
            appOpener: appOpener,
            // Inert unless a test passes its own (SONNY-451): the real one reads this Mac's frontmost
            // app and would bring it forward from inside a test.
            focusRestorer: focusRestorer,
            fileOpener: WorkspaceFileOpener(),
            mediaOpener: NativeMediaOpener(),
            spotifyPlaybackProvider: UnavailableSpotifyPlaybackProvider(),
            appleMusicPlaybackProvider: UnavailableAppleMusicPlaybackProvider(),
            finderContextReader: AppleScriptFinderContextReader(),
            permissionReadinessService: .deterministic(),
            webPageLoader: webPageLoader,
            clipboardHistoryStore: stores.clipboard,
            snippetStore: stores.snippets,
            // Inert rather than `forThisMac()` (SONNY-440): the real one reads this Mac's process
            // list and, for a switch step, would bring a real app forward from inside a test.
            // Nothing here switches apps, so the empty list and a refusing activation are the
            // honest fixture.
            runningAppSwitcher: runningAppSwitcher ?? WorkspaceRunningAppSwitcher(
                runningApplications: { [] },
                activation: { _ in .refused }
            ),
            recentArtifactStore: stores.recentFiles,
            shortcutCatalog: shortcutCatalog,
            shortcutInvoker: shortcutInvoker,
            shortcutRunHistoryStore: stores.shortcutRuns,
            resumableTaskStore: stores.watchers,
            eventKit: eventKit,
            fileManager: fileManager,
            now: now,
            calendar: calendar
        )
    }

    /// Every store gets a per-call temporary file. None of these tests touch a store, but a store
    /// pointed at its real location would be a test writing to the developer's own data.
    private static func scratchURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CapabilityTestContext-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}

/// The stores an adapter under test writes to, each under its own scratch folder.
struct CapabilityTestStores {
    var clipboard = ClipboardHistoryStore(fileURL: CapabilityTestStores.scratch("clipboard.json"))
    var snippets = SnippetStore(fileURL: CapabilityTestStores.scratch("snippets.json"))
    var recentFiles = RecentArtifactStore(fileURL: CapabilityTestStores.scratch("recent-files.json"))
    var shortcutRuns = ShortcutRunHistoryStore(fileURL: CapabilityTestStores.scratch("shortcut-runs.json"))
    var watchers = ResumableTaskStore(fileURL: CapabilityTestStores.scratch("watchers.json"))

    static func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CapabilityTestStores-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}

/// Runs a one-operation plan through its adapter the way `AdapterCapability` does: resolve the
/// outputs, preview, assess, then execute. The kernel's own path adds the gate and the ledger,
/// which the kernel tests cover.
@MainActor
struct PlanHarness {
    struct Prepared {
        let plan: AgentPlan
        let previews: [ActionPreview]
        let assessment: CapabilityRiskAssessment

        /// The question the adapter turned the step into, when it needs a detail it wasn't given.
        var clarificationQuestion: String? {
            plan.steps.first { $0.operation == .clarify }?.question
        }
    }

    let context: CapabilityExecutionContext
    let adapters: [any CapabilityAdapter]

    init(context: CapabilityExecutionContext, reveal: @escaping RevealInFinderCapabilityAdapter.Reveal = { _ in }) {
        self.context = context
        adapters = [
            CalculatorCapabilityAdapter(), ClipboardHistoryCapabilityAdapter(), CreateLocalDraftCapabilityAdapter(),
            CreateReminderCapabilityAdapter(), DocxConversionCapabilityAdapter(), FinderSelectionCapabilityAdapter(),
            InvokeShortcutCapabilityAdapter(), LargestFilesZipCapabilityAdapter(), OpenAppSearchURLCapabilityAdapter(),
            OpenGeneratedArtifactCapabilityAdapter(), OpenMediaResultCapabilityAdapter(), OpenSafeURLCapabilityAdapter(),
            PermissionReadinessCapabilityAdapter(), ReadCalendarEventsCapabilityAdapter(), RecentArtifactsCapabilityAdapter(),
            RenameCapabilityAdapter(), RevealInFinderCapabilityAdapter(reveal: reveal), RunningAppSwitchCapabilityAdapter(),
            SnippetExpansionCapabilityAdapter(), SnippetSaveCapabilityAdapter(), StandingWatcherCapabilityAdapter(),
        ]
    }

    func adapter(for plan: AgentPlan) throws -> any CapabilityAdapter {
        guard let operation = plan.steps.first?.operation,
              let adapter = adapters.first(where: { $0.metadata.operations.contains(operation) }) else {
            throw AgentExecutionError.unsupported("no adapter for this plan")
        }
        return adapter
    }

    func prepare(plan: AgentPlan) throws -> Prepared {
        let adapter = try adapter(for: plan)
        let resolved = try adapter.resolveDefaultOutputs(in: plan, context: context)
        if resolved.steps.contains(where: { $0.operation == .clarify }) {
            return Prepared(plan: resolved, previews: [], assessment: CapabilityRiskAssessment(defaultTier: .tier0))
        }
        return Prepared(
            plan: resolved,
            previews: try adapter.preview(plan: resolved, context: context),
            assessment: try adapter.assessRisk(plan: resolved, context: context)
        )
    }

    func preview(plan: AgentPlan) throws -> [ActionPreview] {
        try prepare(plan: plan).previews
    }

    func execute(_ prepared: Prepared) async throws -> AgentRunResult {
        try await adapter(for: prepared.plan).execute(plan: prepared.plan, context: context, log: { _, _ in })
    }

    func execute(plan: AgentPlan, log: @escaping (AgentPhase, String) -> Void = { _, _ in }) async throws -> AgentRunResult {
        let prepared = try prepare(plan: plan)
        return try await adapter(for: prepared.plan).execute(plan: prepared.plan, context: context, log: log)
    }

    func assessRisk(plan: AgentPlan) throws -> CapabilityRiskAssessment {
        try prepare(plan: plan).assessment
    }
}
