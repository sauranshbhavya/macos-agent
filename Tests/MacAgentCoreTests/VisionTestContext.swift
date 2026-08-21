import Foundation
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
enum VisionTestContext {
    static func make(
        installed: [InstalledApp],
        vision: VisionSessionEnvironment? = nil
    ) -> CapabilityExecutionContext {
        CapabilityExecutionContext(
            whitelist: PathWhitelist(),
            inventory: FileInventory(),
            zipArchiver: ProcessZipArchiver(),
            documentConverter: AutoDocumentConverter(),
            browserOpener: WorkspaceBrowserOpener(),
            hackerNewsFetcher: HackerNewsAPIClient(),
            appCatalog: .default,
            installedAppResolver: InstalledAppResolver(source: FixedAppSource(installed)),
            appSearchURLCatalog: .default,
            appOpener: WorkspaceAppOpener(),
            fileOpener: WorkspaceFileOpener(),
            mediaOpener: NativeMediaOpener(),
            spotifyPlaybackProvider: UnavailableSpotifyPlaybackProvider(),
            appleMusicPlaybackProvider: UnavailableAppleMusicPlaybackProvider(),
            finderContextReader: AppleScriptFinderContextReader(),
            permissionReadinessService: .deterministic(),
            routineStore: RoutineStore(fileURL: scratchURL("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: scratchURL("workspaces.json")),
            webPageLoader: .live(),
            webSearchProvider: UnavailableWebSearchProvider(),
            webResearchSynthesizer: EnvironmentWebResearchSynthesizer(),
            clipboardHistoryStore: ClipboardHistoryStore(fileURL: scratchURL("clipboard.json")),
            snippetStore: SnippetStore(fileURL: scratchURL("snippets.json")),
            runningAppSwitcher: WorkspaceRunningAppSwitcher(),
            recentArtifactStore: RecentArtifactStore(fileURL: scratchURL("artifacts.json")),
            shortcutCatalog: ProcessShortcutCatalog(),
            shortcutInvoker: ProcessShortcutInvoker(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(fileURL: scratchURL("shortcuts.json")),
            taskScope: .unscoped,
            assessNestedPlan: { _, _ in CapabilityRiskAssessment(defaultTier: .tier0) },
            previewNestedPlan: { _ in [] },
            executeNestedPlan: { plan, _, _ in AgentRunResult(plan: plan, previews: [], summary: "") },
            visionSession: vision
        )
    }

    /// Every store gets a per-call temporary file. None of these tests touch a store, but a store
    /// pointed at its real location would be a test writing to the developer's own data.
    private static func scratchURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionTestContext-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }
}
