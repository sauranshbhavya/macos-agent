import Foundation

public enum DefaultCapabilityAdapters {
    public static func all() -> [any CapabilityAdapter] {
        [
            LargestFilesZipCapabilityAdapter(),
            DocxConversionCapabilityAdapter(),
            WebResearchMarkdownCapabilityAdapter(),
            OpenAllowlistedAppCapabilityAdapter(),
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
            RevealInFinderCapabilityAdapter(),
            PermissionReadinessCapabilityAdapter(),
            SaveRoutineCapabilityAdapter(),
            RunRoutineCapabilityAdapter(),
            CreateWorkspaceCapabilityAdapter(),
            EditWorkspaceCapabilityAdapter(),
            OpenWorkspaceCapabilityAdapter(),
            InvokeShortcutCapabilityAdapter(),
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
