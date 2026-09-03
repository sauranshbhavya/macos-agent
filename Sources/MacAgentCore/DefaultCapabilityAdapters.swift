import AppKit
import Foundation

public enum DefaultCapabilityAdapters {
    /// **The one place in this package that opens a Finder window** (SONNY-395).
    ///
    /// It is a named constant rather than a literal at the call site so that the sweep in
    /// `RevealInFinderSeamTests` can assert there is exactly one of it, and so that the two
    /// registries below read as a choice between named things rather than as one of them quietly
    /// carrying an `NSWorkspace` call.
    public static let liveFinderReveal: RevealInFinderCapabilityAdapter.Reveal = {
        NSWorkspace.shared.activateFileViewerSelecting($0)
    }

    /// **`finderRevealer` is undefaulted for the reason the adapter's own initializer gives.**
    ///
    /// A default here would be a default one level out — every caller of `all()` that predates the
    /// parameter would keep whatever this line chose, which is the exact shape SONNY-350 removed
    /// from the store vendors.
    public static func all(
        finderRevealer: @escaping RevealInFinderCapabilityAdapter.Reveal
    ) -> [any CapabilityAdapter] {
        [
            LargestFilesZipCapabilityAdapter(),
            DocxConversionCapabilityAdapter(),
            WebResearchMarkdownCapabilityAdapter(),
            OpenAppCapabilityAdapter(),
            OpenAppSearchURLCapabilityAdapter(),
            OpenSafeURLCapabilityAdapter(),
            OpenGeneratedArtifactCapabilityAdapter(),
            CreateLocalDraftCapabilityAdapter(),
            CalculatorCapabilityAdapter(),
            ClipboardHistoryCapabilityAdapter(),
            SnippetSaveCapabilityAdapter(),
            SnippetExpansionCapabilityAdapter(),
            RunningAppSwitchCapabilityAdapter(),
            RecentArtifactsCapabilityAdapter(),
            OpenMediaResultCapabilityAdapter(),
            FinderSelectionCapabilityAdapter(),
            RevealInFinderCapabilityAdapter(reveal: finderRevealer),
            PermissionReadinessCapabilityAdapter(),
            SaveRoutineCapabilityAdapter(),
            RunRoutineCapabilityAdapter(),
            CreateWorkspaceCapabilityAdapter(),
            EditWorkspaceCapabilityAdapter(),
            OpenWorkspaceCapabilityAdapter(),
            InvokeShortcutCapabilityAdapter(),
            VisionSessionCapabilityAdapter(),
            StandingWatcherCapabilityAdapter(),
            MetadataOnlyCapabilityAdapter(metadata: clarify)
        ]
    }

    private static let clarify = CapabilityMetadata(
        id: "local.planner.clarify",
        displayName: "Ask clarification",
        description: "Ask a short clarifying question with no side effects.",
        operations: [.clarify],
        plannerTools: [
            AgentTool(
                operation: .clarify,
                name: "Ask clarification",
                description: "Ask a short question when a required folder, app, count, or output destination is missing or ambiguous.",
                requiredFields: ["question"],
                sideEffects: [],
                dryRunBehavior: "Show the question and wait for the user answer.",
                examples: ["Which folder should I scan?"]
            )
        ],
        requiredPermissions: [],
        defaultRiskTier: .tier0
    )
}
