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

        // **Whether Finder was contacted at all, recorded where it is knowable** (SONNY-73).
        //
        // `selectedDirectoryPath` returns `primary ?? secondary` before it so much as looks at
        // `contextSource`, and `inputPaths` is already filtered to non-empty entries — so a
        // non-empty `inputPaths` is exactly the case where it took that early return and the
        // Apple-Events reader was never called. Pooling is what makes this reachable without any
        // step misbehaving: the primary path and the context source are taken from the matching
        // steps independently, so a scan carrying an explicit folder and a zip carrying
        // `contextSource` satisfy the plan from the scan's path while the zip still declares itself
        // selection-driven, and `PlanScopedResources` reports Finder off that declaration. The
        // report was an over-report, never a silent blessing — but it named an app the run never
        // touched, on the ran-without-asking trace that exists to make the consequence rule's
        // silences legible.
        //
        // Cleared on every matching step rather than only the back-filled ones, because the honest
        // statement is about the *resolution*, not about which steps it wrote to: one step carrying
        // both an explicit path and `contextSource` is satisfied by the same early return, contacts
        // Finder just as little, and is back-filled by nothing.
        //
        // The classifier stays keyed on `contextSource` alone and stays pure — it is still true
        // there that a populated `inputPath` is evidence the selection *was* read, because this is
        // the only place that can tell the two apart and it now says so in the field itself.
        let satisfiedWithoutContactingFinder = !inputPaths.isEmpty

        var pinnedPlan = plan
        for index in matchingIndices {
            if pinnedPlan.steps[index].inputPath?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                pinnedPlan.steps[index].inputPath = resolved
            }
            if satisfiedWithoutContactingFinder {
                pinnedPlan.steps[index].contextSource = nil
            }
        }
        return pinnedPlan
    }
}
