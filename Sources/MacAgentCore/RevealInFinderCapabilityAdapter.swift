import Foundation

public struct RevealInFinderCapabilityAdapter: CapabilityAdapter {
    /// What revealing a path actually does.
    ///
    /// The live implementation is `NSWorkspace.activateFileViewerSelecting`, and after SONNY-395 it
    /// exists at exactly one place in the repository — the `finderRevealer:` argument
    /// `AgentViewModel.atItsRealStoreLocations()` passes, which
    /// `LocalStoreInjectionScanTests.theRealStoreFactoryHandsTheAppTheLiveFinderReveal` holds.
    /// No line under `Sources/MacAgentCore` names that call, which is what
    /// `noLineInTheCoreNamesTheFinderRevealCall` asserts.
    ///
    /// **That is the narrow claim, and the wider one this used to make was false** (PR #193 review,
    /// F3). It read "`MacAgentCore` names no way to reach Finder at all", and
    /// `FinderContextService.swift:43` is `tell application id "com.apple.finder"` run through
    /// `osascript` — which is precisely a way to reach Finder, sitting in this package the whole
    /// time the sentence claimed otherwise. It is behind the `finderContextReader` seam on
    /// `CapabilityExecutionContext`, so it was never a defect; the sentence was a negative
    /// established from one token, which is `CLAUDE.md`'s *enumerate before you subtract* shape,
    /// and a scan searching one literal can only ever support a claim about that literal.
    /// `NSWorkspace.shared.open(folderURL)` opens a Finder window too and the core names it twice,
    /// in `WorkspaceFileOpener` and `NativeMediaOpener` — both seamed, neither searched.
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
    /// it the only capability adapter reaching the machine directly:
    /// `git grep -nE 'NSWorkspace|NSAppleScript|Process\(|CGEvent|AXUIElement|NSSound' 619ba62 --
    /// Sources/MacAgentCore | grep -E 'CapabilityAdapter[.]swift' | grep -vE ':[0-9]+: *//'`
    /// answers **1** at `619ba62` — the line at `:53` — and **0** at `3c0a481`.
    ///
    /// **The comment stage earns its place, and the control has to be read at the head you are
    /// standing on** (PR #193 review, F5). Dropping that stage answers **2** at `619ba62`, the
    /// extra line being `RunRoutineCapabilityAdapter`'s prose about `NSWorkspace.shared.open` — and
    /// **5** at `3c0a481`, because four of the five are this very doc comment. The sentence used to
    /// give the 2 with no head beside it, two clauses after naming two different heads, which is
    /// `CLAUDE.md`'s ninth write-the-command defect exactly: a citation greping a population its
    /// own file belongs to needs a comment stage *and* a control that fires, and the control here
    /// goes up by the citations written since. It went up by four and the prose said one.
    ///
    /// **The file filter is a pipe rather than the pathspec you would reach for first**, and that
    /// is not style. A `pathspec` naming the adapter glob puts the two characters that open a
    /// block comment into this doc comment, and `MacAgentSource.read` strips block comments
    /// *before* it drops `//` lines — so every line below would vanish from every source scan that
    /// reads this file, silently. `CLAUDE.md` records that arriving from this exact glob once
    /// already (SONNY-220), from a session obeying the write-the-command-beside-the-number rule,
    /// which is why it keeps arriving from sessions doing the right thing.
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
