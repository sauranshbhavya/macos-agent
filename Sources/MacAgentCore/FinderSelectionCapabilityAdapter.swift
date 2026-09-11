import Foundation

public struct FinderSelectionCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.finder.read-selection",
        displayName: "Read Finder selection",
        description: "Read selected Finder items and validate them against the path whitelist.",
        operations: [.getFinderSelection],
        plannerTools: [
            AgentTool(
                operation: .getFinderSelection,
                name: "Read Finder selection",
                description: "Read selected Finder files and folders, validate that every path is inside the Desktop/Documents whitelist, and show them as context.",
                requiredFields: [],
                sideEffects: ["ask Finder for selection"],
                dryRunBehavior: "Show selected Finder items without modifying them.",
                examples: ["What is selected in Finder?", "Show my Finder selection"]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .finderAutomation),
            CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess)
        ],
        defaultRiskTier: .tier0
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let selection = try whitelistedSelection(context: context)
        return [
            ActionPreview(
                title: "Finder selection",
                details: selection.map(\.path)
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        log(.act, "Reading Finder selection")
        let selection = try whitelistedSelection(context: context)
        log(.observe, "Found \(selection.count) selected item(s)")
        return AgentRunResult(plan: plan, previews: previews, summary: FinderSelectionSummary.sentence(for: selection))
    }

    private func whitelistedSelection(context: CapabilityExecutionContext) throws -> [URL] {
        try FinderSelectionResolver.whitelistedSelection(
            whitelist: context.whitelist,
            finderContextReader: context.finderContextReader
        )
    }
}

/// The sentence a Finder-selection result reads (SONNY-441).
///
/// It used to be a count — "Finder selection contains 1 whitelisted item(s)." — and the founders'
/// pass read exactly that back: something is selected, and nothing says what. The paths were in
/// the preview's details, which the result panel does not show. So the summary names the items by
/// file name, in the shape the executor already uses for a list it cannot show whole
/// (`AgentActionExecutor`'s clarification lists: five named, then "and N more"). "Whitelisted" was
/// an internal word and is gone from the sentence; the whitelist check itself is untouched.
public enum FinderSelectionSummary {
    /// How many names a sentence carries before it counts the rest.
    public static let namedItemLimit = 5

    public static func sentence(for items: [URL]) -> String {
        let names = items.map(\.lastPathComponent)
        let shown = names.prefix(namedItemLimit)
        let remainder = names.count > namedItemLimit ? ", and \(names.count - namedItemLimit) more" : ""
        return "Selected in Finder: \(shown.joined(separator: ", "))\(remainder)."
    }
}
