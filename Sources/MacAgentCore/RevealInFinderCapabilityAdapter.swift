import Foundation

public struct RevealInFinderCapabilityAdapter: CapabilityAdapter {
    /// What revealing a path actually does.
    ///
    /// The live implementation is `NSWorkspace.activateFileViewerSelecting`, and after SONNY-395 it
    /// exists at exactly one place in the repository — the `finderRevealer:` argument
    /// `AgentViewModel.atItsRealStoreLocations()` passes, which
    /// `LocalStoreInjectionScanTests.theRealStoreFactoryHandsTheAppTheLiveFinderReveal` holds.
    /// `MacAgentCore` names no way to reach Finder at all, which is stronger than naming one and
    /// is what `noLineInTheCoreOpensAFinderWindow` asserts.
    ///
    /// The package deliberately ships no live revealer of its own to pass here. One would be a
    /// constant nothing in the package calls, and a caller reaching for it by name is the shape a
    /// default is — the thing this seam exists to remove.
    public typealias Reveal = @MainActor @Sendable ([URL]) -> Void

    private let reveal: Reveal

    /// **Undefaulted, and that is the whole of SONNY-395** — SONNY-350's rule applied to the one
    /// adapter that had no seam at all.
    ///
    /// This adapter used to call `NSWorkspace.shared.activateFileViewerSelecting` inline, which made
    /// it the only one of the 27 `*CapabilityAdapter.swift` files reaching the machine directly:
    /// `git grep -nE 'NSWorkspace|NSAppleScript|Process\(|CGEvent|AXUIElement|NSSound' 619ba62 --
    /// 'Sources/MacAgentCore/*CapabilityAdapter.swift' | grep -vE ':[0-9]+: *//'` answers **1** at
    /// `619ba62`, the line at `:53`, and **0** with this change in the tree. The comment stage
    /// earns its place and its control fires — without it the same command answers 2, the extra
    /// line being `RunRoutineCapabilityAdapter`'s prose about `NSWorkspace.shared.open`.
    ///
    /// Every other door — `WorkspaceFileOpener`, `NativeMediaOpener`, `MacAppService`,
    /// `WorkspaceBrowserOpener` — was already behind an injected seam, which is why a probe on all
    /// six recorded **4** reveals across a full suite run and **0** of anything else: a fixture
    /// could opt out of the others and could not opt out of this one.
    ///
    /// Those four were `ProductShellTests.aJobOverManyItemsPublishesHowFarItHasGot` (three files)
    /// and `anOrdinaryRunPublishesNoJobProgress` (one), and both fixtures were already passing
    /// `hermeticFinderRevealer` to the view model — the reveal went around it, through the
    /// executor's registry. A battery re-runs the suite once per mutant, so four windows a run is
    /// how the founder met dozens of them in one working session.
    ///
    /// A default here would put every one of those back at the first call site that predates the
    /// parameter, which is SONNY-240's argument and does not care that this parameter opens a
    /// window rather than writing a file.
    public init(reveal: @escaping Reveal) {
        self.reveal = reveal
    }

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.finder.reveal-path",
        displayName: "Reveal in Finder",
        description: "Reveal a whitelisted path in Finder.",
        operations: [.revealInFinder],
        plannerTools: [
            AgentTool(
                operation: .revealInFinder,
                name: "Reveal path in Finder",
                description: "Reveal a specific whitelisted path in Finder, or reveal the most recent file produced earlier in the same chain when outputPath is null.",
                requiredFields: [],
                sideEffects: ["open Finder"],
                dryRunBehavior: "Show the path that would be revealed.",
                examples: ["Reveal the zip in Finder", "Show the generated Markdown in Finder"]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess),
            CapabilityPermissionMetadata(requirement: .appOpening)
        ],
        defaultRiskTier: .tier1
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let url = try revealSpec(in: plan, context: context, requiresExistingPath: false)
        return [
            ActionPreview(
                title: "Reveal in Finder",
                details: ["Reveal \(url.path)"],
                opens: ["Finder"]
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let url = try revealSpec(in: plan, context: context, requiresExistingPath: true)
        log(.act, "Revealing \(url.path) in Finder")
        reveal([url])
        log(.summarize, "Revealed in Finder")
        let summary = "Revealed \(url.path) in Finder."
        return AgentRunResult(plan: plan, previews: previews, summary: summary)
    }

    private func revealSpec(
        in plan: AgentPlan,
        context: CapabilityExecutionContext,
        requiresExistingPath: Bool
    ) throws -> URL {
        guard let step = plan.steps.first(where: { $0.operation == .revealInFinder }) else {
            throw AgentExecutionError.invalidPlan("reveal_in_finder step is missing.")
        }

        if let rawPath = step.outputPath ?? step.inputPath,
           !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = try context.whitelist.validateInsideWhitelist(rawPath)
            guard !requiresExistingPath || context.fileManager.fileExists(atPath: url.path) else {
                throw PathValidationError.notFound(url.path)
            }
            return url
        }

        throw AgentExecutionError.invalidPlan("reveal_in_finder needs outputPath or a previous chained artifact.")
    }
}
