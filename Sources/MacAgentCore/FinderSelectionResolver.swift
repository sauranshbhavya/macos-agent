import Foundation

public enum FinderSelectionResolver {
    public static func whitelistedSelection(
        whitelist: PathWhitelist,
        finderContextReader: any FinderContextReading
    ) throws -> [URL] {
        try finderContextReader.selectedItems().map { url in
            try whitelist.validateInsideWhitelist(url.path)
        }
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

        var pinnedPlan = plan
        for index in matchingIndices where pinnedPlan.steps[index].inputPath?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            pinnedPlan.steps[index].inputPath = resolved
        }
        return pinnedPlan
    }
}
