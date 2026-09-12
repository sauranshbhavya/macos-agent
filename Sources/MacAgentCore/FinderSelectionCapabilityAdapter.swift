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
        let selection = try whitelistedItems(context: context)
        return [
            ActionPreview(
                title: "Finder selection",
                details: selection.map(\.whitelisted.path)
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
        let selection = try whitelistedItems(context: context)
        log(.observe, "Found \(selection.count) selected item(s)")
        // **Named as Finder names them, checked as the whitelist resolves them** (PR #228's F2):
        // a selected symbolic link reads by the link's own name, not its target's, and a name
        // with a trailing space keeps it. The whitelisted path is what the preview lists and what
        // anything downstream acts on, unchanged.
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: FinderSelectionSummary.sentence(naming: selection.map(\.name))
        )
    }

    private func whitelistedItems(context: CapabilityExecutionContext) throws -> [FinderSelectedItem] {
        try FinderSelectionResolver.whitelistedItems(
            whitelist: context.whitelist,
            finderContextReader: context.finderContextReader
        )
    }
}

/// The sentence a Finder-selection result reads (SONNY-441).
///
/// It used to be a count — "Finder selection contains 1 whitelisted item(s)." — and the founders'
/// pass read exactly that back: something is selected, and nothing says what. The paths were in
/// the preview's details, which the result panel does not show. So the summary names the items,
/// in the shape the executor already uses for a list it cannot show whole
/// (`AgentActionExecutor`'s clarification lists: five named, then "and N more"). "Whitelisted" was
/// an internal word and is gone from the sentence; the whitelist check itself is untouched.
///
/// **The count leads, and the names stop at a character budget, because the widget's result panel
/// shows three lines** (SONNY-441, PR #228's F1). `WidgetResultPanel` caps its summary at
/// `.lineLimit(3)` in a 472 pt panel with 18 pt of padding, at SF Pro 13; five names in the shape
/// macOS gives screenshots ran to four lines, and the part that fell off the end was ", and 2
/// more." — the one thing a clipped panel must not lose is how many items there are. So a
/// selection of more than one item opens with its total, which no clipping can reach, and names
/// are added only while the whole sentence stays within `characterBudget`, which
/// `FinderSelectionSentenceFitsTheWidgetTests` measures against the panel's real width and type
/// with AppKit's own layout. The first name is always given, however long.
public enum FinderSelectionSummary {
    /// The most items named before the rest is counted, whatever their length.
    public static let namedItemLimit = 5
    /// The most characters the sentence may run to while it still adds names: three lines of the
    /// widget's result panel for the Latin name shapes macOS produces, measured rather than chosen
    /// (`FinderSelectionSentenceFitsTheWidgetTests`). A budget in characters is a proxy for a
    /// width in points — wide glyphs run over it sooner — and the count leading is what holds when
    /// the proxy does not.
    public static let characterBudget = 150

    public static func sentence(for items: [URL]) -> String {
        sentence(naming: items.map(\.lastPathComponent))
    }

    public static func sentence(naming names: [String]) -> String {
        guard names.count > 1 else {
            return "Selected in Finder: \(names.joined())."
        }
        let opening = "\(names.count) selected in Finder: "
        var shown: [String] = []
        for name in names where shown.count < namedItemLimit {
            let candidate = shown + [name]
            let whole = opening + candidate.joined(separator: ", ") + remainder(names.count - candidate.count) + "."
            if !shown.isEmpty, whole.count > characterBudget {
                break
            }
            shown = candidate
        }
        return opening + shown.joined(separator: ", ") + remainder(names.count - shown.count) + "."
    }

    private static func remainder(_ count: Int) -> String {
        count > 0 ? ", and \(count) more" : ""
    }
}
