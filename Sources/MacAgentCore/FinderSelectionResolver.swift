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
        // Apple-Events reader was never called. Pooling is what makes that reachable without any
        // step misbehaving: the primary path and the context source are taken from the matching
        // steps independently, so a scan carrying an explicit folder beside a zip carrying
        // `contextSource` satisfies the plan from the scan's path while the zip still declares
        // itself selection-driven, and `PlanScopedResources` reports Finder off that declaration.
        // Always an over-report, never a silent blessing — but it named an app the run never
        // touched, on the ran-without-asking trace that exists to make the consequence rule's
        // silences legible.
        let satisfiedWithoutContactingFinder = !inputPaths.isEmpty

        var pinnedPlan = plan
        for index in matchingIndices where pinnedPlan.steps[index].inputPath?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            pinnedPlan.steps[index].inputPath = resolved
            // **Only the steps this pass back-fills, and that restriction is load-bearing rather
            // than conservative.** This function runs *twice* over one run: `AgentRunner.prepare`
            // resolves the plan, and `approvalRequest` re-resolves the plan `prepare` returned. On
            // that second pass a genuine selection-driven plan has an `inputPath` on every matching
            // step — pinned from the live selection moments earlier — so `inputPaths` is non-empty
            // and the flag above reads "no Finder contact" about a run that had just made it.
            // Restricted to back-filled steps, the second pass back-fills nothing and clears
            // nothing, so the rule is idempotent and SONNY-59's report survives. Applied to every
            // matching step instead, it deleted that report while the whole suite stayed green,
            // because every test of it calls `assessRisk` once on an unresolved plan.
            //
            // What being back-filled means is exactly the distinction that matters: a step arriving
            // with no path of its own did not supply the path this resolution used, so if that
            // resolution never reached Finder, nothing about this step is selection-driven any more.
            //
            // **That residual is closed, and it needed a second fact rather than a cleverer rule**
            // (SONNY-185). A step carrying `contextSource` *and* its own non-empty `inputPath` is
            // back-filled by nothing, so the clearing below never reaches it: it kept its marker and
            // `PlanScopedResources` named Finder for a run that never contacted it. After the first
            // pass such a step is byte-for-byte a genuine declaring step the pin filled in, so no
            // rule reading only `contextSource` and `inputPath` can tell the two apart. What can is
            // a fact only this function knows — whether Finder was read on the pass that filled this
            // step in — so it is written down here and the classifier is keyed on it.
            //
            // Written on the back-filled steps and only when Finder really was read, which is the
            // same restriction the clearing carries and for the same reason: on the second pass
            // nothing is back-filled, so nothing is written and nothing is lost, and a genuine
            // selection's pin survives from the first pass. In the genuine case every matching step
            // is back-filled — Finder is contacted only when no matching step brought a path — so
            // the declaring step is always among them and never misses its pin.
            if satisfiedWithoutContactingFinder {
                pinnedPlan.steps[index].contextSource = nil
            } else {
                pinnedPlan.steps[index].resolvedFromFinderSelection = true
            }
        }
        return pinnedPlan
    }
}
