import Foundation

/// One selected Finder item, twice: as Finder reported it and as the whitelist resolved it
/// (SONNY-441, PR #228's F2). The two differ for a symbolic link (Finder names the link, the
/// whitelist follows it to the target) and for a name with a trailing space (the whitelist trims
/// the path it checks). What the user reads is the item they selected; what the run acts on is
/// the whitelisted path, exactly as before.
public struct FinderSelectedItem: Equatable, Sendable {
    public let selected: URL
    public let whitelisted: URL

    public init(selected: URL, whitelisted: URL) {
        self.selected = selected
        self.whitelisted = whitelisted
    }

    /// The name Finder shows for this item.
    public var name: String {
        selected.lastPathComponent
    }
}

public enum FinderSelectionResolver {
    /// Every selected item, each checked against the whitelist; a single item outside it throws,
    /// as `whitelistedSelection` always has.
    public static func whitelistedItems(
        whitelist: PathWhitelist,
        finderContextReader: any FinderContextReading
    ) throws -> [FinderSelectedItem] {
        try finderContextReader.selectedItems().map { url in
            FinderSelectedItem(selected: url, whitelisted: try whitelist.validateInsideWhitelist(url.path))
        }
    }

    public static func whitelistedSelection(
        whitelist: PathWhitelist,
        finderContextReader: any FinderContextReading
    ) throws -> [URL] {
        try whitelistedItems(whitelist: whitelist, finderContextReader: finderContextReader).map(\.whitelisted)
    }

    public static func selectedDirectoryPath(
        primary: String?,
        secondary: String?,
        contextSource: FinderContextSource?,
        whitelist: PathWhitelist,
        finderContextReader: any FinderContextReading
    ) throws -> String? {
        if let path = primary ?? secondary,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }

        guard contextSource == .finderSelection else {
            return nil
        }

        let selection = try whitelistedSelection(
            whitelist: whitelist,
            finderContextReader: finderContextReader
        )
        guard selection.count == 1 else {
            throw FinderContextError.noDirectorySelection
        }

        let url = selection[0]
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw FinderContextError.noDirectorySelection
        }
        return url.path
    }

    /// Resolves a Finder-selection-derived input folder exactly once and writes it back into
    /// every matching step's `inputPath`, so preview/assessRisk/execute all operate on the same
    /// folder the user saw when approving. Without this pinning, each phase re-reads the *live*
    /// Finder selection and can silently act on a different folder than the one previewed.
    public static func pinningSelectedDirectoryInput(
        in plan: AgentPlan,
        operations: [AgentOperation],
        whitelist: PathWhitelist,
        finderContextReader: any FinderContextReading
    ) throws -> AgentPlan {
        let matchingIndices = plan.steps.indices.filter { operations.contains(plan.steps[$0].operation) }
        guard !matchingIndices.isEmpty else {
            return plan
        }

        let inputPaths = matchingIndices.compactMap { index -> String? in
            let path = plan.steps[index].inputPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        }
        let contextSource = matchingIndices.compactMap { plan.steps[$0].contextSource }.first

        guard let resolved = try selectedDirectoryPath(
            primary: inputPaths.first,
            secondary: inputPaths.dropFirst().first,
            contextSource: contextSource,
            whitelist: whitelist,
            finderContextReader: finderContextReader
        ) else {
            return plan
        }

        // Whether Finder was contacted at all (SONNY-73). `selectedDirectoryPath` returns
        // `primary ?? secondary` before it looks at `contextSource`, so a non-empty `inputPaths` is
        // exactly the case where the Apple-Events reader was never called.
        let satisfiedWithoutContactingFinder = !inputPaths.isEmpty

        var pinnedPlan = plan
        for index in matchingIndices where pinnedPlan.steps[index].inputPath?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            pinnedPlan.steps[index].inputPath = resolved
            // Only the steps this pass back-fills: a step arriving with no path of its own did not
            // supply the path this resolution used, so if that resolution never reached Finder,
            // nothing about this step is selection-driven any more. Restricting it to back-filled
            // steps keeps a second pass over an already-pinned plan from changing anything.
            if satisfiedWithoutContactingFinder {
                pinnedPlan.steps[index].contextSource = nil
            }
        }
        return pinnedPlan
    }
}
