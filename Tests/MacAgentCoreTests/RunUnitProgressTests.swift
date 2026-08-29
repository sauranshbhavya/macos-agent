import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The progress the executor reports as a run goes (row 13, SONNY-210) — the half of resuming that
/// decides *where* a resumed run starts.
///
/// Every assertion here is about the real `execute` path with a real plan, never about a seam: the
/// thing being pinned is that a boundary the executor genuinely crossed is the boundary reported,
/// and a test that called a reporter directly would pin nothing about that.
@Suite
@MainActor
struct RunUnitProgressTests {
    // MARK: - What gets reported

    /// A two-unit chain reports the first unit and stays silent about the last.
    ///
    /// Both halves matter. The report is what makes a resume start after the calculation instead of
    /// re-running it; the silence is the semantics — a boundary with nothing behind it changes no
    /// resume, and reporting it would let a listener see a state ("every step done") that a
    /// resumable record must never hold.
    @Test
    func aChainReportsEveryUnitButItsLast() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        var reported: [CompletedRunUnit] = []
        _ = try await executor.execute(
            plan: calculateThenOpenURL,
            onUnitCompleted: { reported.append($0) }
        ) { _, _ in }

        #expect(reported.map(\.stepIDs) == [["calc"]])
    }

    /// A plan of one unit reports nothing at all — there is no boundary inside it to report.
    @Test
    func aSingleUnitPlanReportsNothing() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        var reported: [CompletedRunUnit] = []
        _ = try await executor.execute(
            plan: AgentPlan(
                summary: "Open a page.",
                requiresConfirmation: false,
                steps: [openURLStep]
            ),
            onUnitCompleted: { reported.append($0) }
        ) { _, _ in }

        #expect(reported.isEmpty)
    }

    /// A run with no listener still runs. The control for every assertion above: without it, "nothing
    /// was reported" would be equally true of an executor that had stopped executing.
    @Test
    func aRunWithNoListenerStillExecutesEveryUnit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: opener)

        _ = try await executor.execute(plan: calculateThenOpenURL) { _, _ in }

        #expect(opener.opened == ["https://example.com/page"])
    }

    /// **A nested plan's units are not this run's units.** A routine runs as one unit of the plan
    /// that invoked it, and its own steps carry ids the outer plan does not contain — a resume
    /// rebuilt from them would subtract nothing and claim progress the outer plan cannot express.
    @Test
    func aRoutinesOwnUnitsAreNotReportedToTheRunThatInvokedIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        // Two workflows inside the routine, so the nested plan really is a chain and really does
        // reach `executeChain` a second time — the path the union comment in `executeChain` records.
        try routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "inner-calc", operation: .calculateUtility, description: "Add up.", searchQuery: "2 + 2"),
                    AgentStep(
                        id: "inner-url",
                        operation: .openURL,
                        description: "Open.",
                        targetURL: "https://example.com/inner"
                    )
                ]
            )
        )
        let executor = makeExecutor(root: root, routineStore: routineStore)

        var reported: [CompletedRunUnit] = []
        _ = try await executor.execute(
            plan: AgentPlan(
                summary: "Run the routine, then open a page.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(id: "run", operation: .runRoutine, description: "Run it.", routineName: "Morning"),
                    openURLStep
                ]
            ),
            onUnitCompleted: { reported.append($0) }
        ) { _, _ in }

        // The outer run's own first unit, and nothing from inside it.
        #expect(reported.map(\.stepIDs) == [["run"]])
        let everyReportedID = Set(reported.flatMap(\.stepIDs))
        #expect(!everyReportedID.contains("inner-calc"))
        #expect(!everyReportedID.contains("inner-url"))
    }

    /// The carried artifact path travels with the unit that produced it, because the steps that are
    /// left name it nowhere.
    @Test
    func aReportedUnitCarriesTheFileTheChainWouldHandTheNextOne() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = root.appendingPathComponent("notes.md")
        let executor = makeExecutor(root: root)

        var reported: [CompletedRunUnit] = []
        _ = try await executor.execute(
            plan: AgentPlan(
                summary: "Write a note, then open it.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(
                        id: "draft",
                        operation: .createLocalDraft,
                        description: "Write it.",
                        outputPath: draft.path,
                        draftTitle: "Notes",
                        draftContent: "Body."
                    ),
                    AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")
                ]
            ),
            onUnitCompleted: { reported.append($0) }
        ) { _, _ in }

        #expect(reported.map(\.stepIDs) == [["draft"]])
        #expect(reported.first?.chainedArtifactPath == draft.path)
    }

    // MARK: - What a resumed run is handed back

    /// **The carry applied to a remainder, on the shape a resume actually produces.** "Write a note,
    /// then open it", interrupted after the note, leaves the one-step plan
    /// `[open_generated_artifact]` with no path on it — and the whole run, `prepare` included, has to
    /// see that path.
    ///
    /// **`prepare`, and that ordering is the point.** The first version of this threaded the path as
    /// an execution parameter, and it failed here: `prepare` previews every step, and previewing a
    /// bare `open_generated_artifact` throws "needs outputPath or a previous chained artifact" long
    /// before anything reaches `execute`. Measured, by this test. So the path is written into the
    /// plan before dispatch, which is what `ChainedArtifactCarry` exists for.
    @Test
    func aRemainderCarryingTheEarlierRunsFilePreparesAndOpensIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = root.appendingPathComponent("notes.md")
        try Data("Body.".utf8).write(to: draft, options: .atomic)
        let opener = RecordingFileOpener()
        let executor = makeExecutor(root: root, fileOpener: opener)

        let remainder = AgentPlan(
            summary: "Write a note, then open it.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")]
        )
        let carried = ChainedArtifactCarry.applying(draft.path, toLeadingStepOf: remainder)

        // The gate that runs first accepts it — the assertion the parameter version failed.
        _ = try executor.prepare(plan: carried)
        _ = try await executor.execute(plan: carried) { _, _ in }

        #expect(opener.opened == [draft.path])
    }

    /// And the control: the same remainder with nothing carried in is refused at `prepare`, before
    /// anything runs. Without this, the assertion above is equally true of an executor that happened
    /// to find the file by another route.
    @Test
    func theSameRemainderWithNothingCarriedInIsRefusedBeforeItRuns() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = RecordingFileOpener()
        let executor = makeExecutor(root: root, fileOpener: opener)

        let remainder = AgentPlan(
            summary: "Open it.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it.")]
        )
        #expect(ChainedArtifactCarry.applying(nil, toLeadingStepOf: remainder) == remainder)
        #expect(throws: Error.self) {
            _ = try executor.prepare(plan: remainder)
        }
        #expect(opener.opened.isEmpty)
    }

    /// The carry writes onto the leading step and only when that step would take it — a step naming
    /// its own file is already satisfied and must not have it overwritten.
    @Test
    func theCarryLeavesAStepThatNamesItsOwnFileAlone() {
        let named = AgentPlan(
            summary: "Open that one.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "open",
                    operation: .openGeneratedArtifact,
                    description: "Open it.",
                    outputPath: "/already/named.md"
                )
            ]
        )
        #expect(ChainedArtifactCarry.applying("/somewhere/else.md", toLeadingStepOf: named) == named)
        #expect(!ChainedArtifactCarry.consumesPreviousArtifact(named.steps[0]))

        // And a step of an operation that never consumes one.
        let unrelated = AgentPlan(
            summary: "Open a page.",
            requiresConfirmation: false,
            steps: [openURLStep]
        )
        #expect(ChainedArtifactCarry.applying("/somewhere/else.md", toLeadingStepOf: unrelated) == unrelated)
        #expect(!ChainedArtifactCarry.consumesPreviousArtifact(openURLStep))
    }

    /// **The `inputPath` half of the predicate, which was held by nothing** (PR #105 review F6, M18).
    /// It is load-bearing rather than symmetric: `RevealInFinderCapabilityAdapter` resolves
    /// `step.outputPath ?? step.inputPath`, so writing a carried path onto a reveal step that named
    /// its own `inputPath` makes Finder reveal a different file from the one the plan named.
    @Test
    func theCarryLeavesARevealStepThatNamesItsOwnInputPathAlone() {
        let named = AgentPlan(
            summary: "Show that one.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "reveal",
                    operation: .revealInFinder,
                    description: "Reveal it.",
                    inputPath: "/the/one/the/plan/named.md"
                )
            ]
        )

        #expect(!ChainedArtifactCarry.consumesPreviousArtifact(named.steps[0]))
        #expect(ChainedArtifactCarry.applying("/some/other/file.md", toLeadingStepOf: named) == named)

        // The control: the same step with neither path takes the carry, so the assertion above is
        // about `inputPath` rather than about reveal steps being exempt.
        let bare = AgentPlan(
            summary: "Show it.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "reveal", operation: .revealInFinder, description: "Reveal it.")]
        )
        #expect(ChainedArtifactCarry.consumesPreviousArtifact(bare.steps[0]))
        #expect(
            ChainedArtifactCarry.applying("/some/other/file.md", toLeadingStepOf: bare).steps[0].outputPath
                == "/some/other/file.md"
        )
    }

    /// **The other shape a remainder takes: still a chain.** "Write a note, open it, then open the
    /// page", interrupted after the note, leaves a two-unit plan whose *first* unit is the bare
    /// consumer — so the carry has to reach the leading step of a multi-step plan too, which is a
    /// different branch of `ChainedArtifactCarry.applying` from the one-step case above.
    @Test
    func aResumedChainWhoseFirstUnitConsumesTheCarriedFileStillFindsIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = root.appendingPathComponent("notes.md")
        try Data("Body.".utf8).write(to: draft, options: .atomic)
        let fileOpener = RecordingFileOpener()
        let browserOpener = RecordingBrowserOpener()
        let executor = makeExecutor(root: root, browserOpener: browserOpener, fileOpener: fileOpener)

        let remainder = AgentPlan(
            summary: "Write a note, open it, then open the page.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open it."),
                openURLStep
            ]
        )
        let carried = ChainedArtifactCarry.applying(draft.path, toLeadingStepOf: remainder)
        _ = try executor.prepare(plan: carried)
        _ = try await executor.execute(plan: carried) { _, _ in }

        #expect(fileOpener.opened == [draft.path])
        #expect(browserOpener.opened == ["https://example.com/page"])
    }

    /// The invariant the whole partial-resume idea rests on: only whole units are ever recorded as
    /// finished, so what is left always begins at a unit boundary and re-segments into exactly the
    /// units that had not run.
    @Test
    func theRemainderOfAPlanSegmentsIntoTheUnitsThatHadNotRun() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root)

        var reported: [CompletedRunUnit] = []
        _ = try await executor.execute(
            plan: calculateThenOpenURL,
            onUnitCompleted: { reported.append($0) }
        ) { _, _ in }

        let record = ResumableTask(
            command: "Work it out, then open the page",
            plan: calculateThenOpenURL,
            completedStepIDs: reported.flatMap(\.stepIDs),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // The remainder is the second unit, whole, with no fragment of the first left in it.
        #expect(record.remainingPlan().steps.map(\.id) == ["url"])
        // And it really runs on its own: a remainder that had cut a unit in half would fail here,
        // which is what makes this an assertion about segmentation rather than about arithmetic.
        let opener = RecordingBrowserOpener()
        let resumingExecutor = makeExecutor(root: root, browserOpener: opener)
        _ = try await resumingExecutor.execute(plan: record.remainingPlan()) { _, _ in }
        #expect(opener.opened == ["https://example.com/page"])
    }

    // MARK: - Fixtures

    private var openURLStep: AgentStep {
        AgentStep(
            id: "url",
            operation: .openURL,
            description: "Open the page.",
            targetURL: "https://example.com/page"
        )
    }

    private var calculateThenOpenURL: AgentPlan {
        AgentPlan(
            summary: "Work out a number, then open a page.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "calc", operation: .calculateUtility, description: "What is 2 plus 2?", searchQuery: "2 + 2"),
                openURLStep
            ]
        )
    }

    private func makeExecutor(
        root: URL,
        browserOpener: BrowserOpening = RecordingBrowserOpener(),
        fileOpener: FileOpening = RecordingFileOpener(),
        routineStore: RoutineStore? = nil
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            browserOpener: browserOpener,
            fileOpener: fileOpener,
            // Deterministic rather than defaulted: this file builds executors *and* names
            // `.showPermissionReadiness` (in the classification's own safe set below), so a plan run
            // through it is one step away from live TCC and AVFoundation reads.
            // `LivePermissionCheckerScanTests.everyExecutorFixtureThatCanDriveReadinessInjectsTheSeam`
            // is what caught that, by counting the population rather than the tokens.
            permissionReadinessService: .deterministic(),
            routineStore: routineStore ?? RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            clipboardHistoryStore: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("artifacts.json")),
            shortcutCatalog: NoShortcutsForProgressTests(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcuts-history.json")
            )
        )
    }
}

@MainActor
private final class RecordingBrowserOpener: BrowserOpening {
    private(set) var opened: [String] = []

    func open(_ url: URL, using browser: MacApp?) async throws {
        opened.append(url.absoluteString)
    }
}

@MainActor
private final class RecordingFileOpener: FileOpening {
    private(set) var opened: [String] = []

    func openFile(_ url: URL) async throws {
        opened.append(url.path)
    }
}

private struct NoShortcutsForProgressTests: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

/// Which operations Sonny may repeat on its own when a resumed run re-runs the unit that was in
/// flight (PR #105 review F5).
///
/// The classification is one-directional — it can only withhold an offer — so every assertion here
/// is about *not* volunteering, never about permitting.
@Suite
struct ResumeRepeatSafetyTests {
    /// **The counterexample the review produced, named.** A Shortcut with clean history is tier 1,
    /// so a repeat of it prompts for nothing; if it sends a message, the message is sent twice.
    /// `CapabilityRiskEscalation.Consequence.affectsOthers` cannot answer this — its own doc says no
    /// v1 capability carries it, and `invoke_shortcut` raises no escalation at all.
    /// **Both sets named, both directions** (PR #105 re-check). This asserted the unsafe set by name
    /// and the safe one with three spot-checks plus `safe.count + unsafe.count == allCases.count` —
    /// which is a tautology: `resumeRepeatSafety` returns one of two values for every input, so the
    /// two filters partition `allCases` by construction and no reclassification can falsify it. A
    /// thirty-fourth operation classified `.safeToRepeat` by a hurried author would have compiled,
    /// passed, and read as deliberate. The compiler forces a decision; nothing forced a *right* one,
    /// and a rule that can only withhold has no wrong-default to fall back on.
    ///
    /// Same shape as the tautology PR #101's review caught in
    /// `destinations.count == MemoryCategory.allCases.count`, which is the second time it has
    /// survived a review in this area — hence naming the safe set rather than counting it.
    @Test
    func theOperationsSonnyWillNotRepeatOnItsOwnAreTheFourItCannotSeeInside() {
        let unsafe = Set(AgentOperation.allCases.filter { $0.resumeRepeatSafety == .mustNotRepeatSilently })
        #expect(unsafe == [.invokeShortcut, .runRoutine, .visionSession, .unsupported])

        let safe = Set(AgentOperation.allCases.filter { $0.resumeRepeatSafety == .safeToRepeat })
        #expect(safe == [
            .scanSelectLargestFiles, .createZip, .scanDocx, .convertDocxToPDF,
            .openHackerNews, .fetchHNHeadlines, .writeMarkdown, .webToMarkdown,
            .openApp, .openAppSearchURL, .openURL, .playMedia,
            .getFinderSelection, .revealInFinder, .showPermissionReadiness,
            .saveRoutine, .createWorkspace, .editWorkspace, .openWorkspace,
            .openGeneratedArtifact, .createLocalDraft, .calculateUtility,
            .lookupClipboardHistory, .expandSnippet, .saveSnippet,
            .switchRunningApp, .lookupRecentArtifacts, .clarify
        ])

        // And the two sets are the whole population, so an operation cannot be absent from both by
        // being absent from `allCases`' own iteration. Not a partition check — that one cannot fail,
        // which is what this test used to lean on.
        #expect(safe.union(unsafe) == Set(AgentOperation.allCases))
        #expect(safe.isDisjoint(with: unsafe))
    }

    /// A record is offerable only when every remaining step is safe to repeat — and the control is
    /// the same record with the Shortcut already behind it.
    @Test
    func aRecordWhoseRemainingWorkContainsAShortcutIsNotOfferedAndOneWithoutItIs() {
        let plan = AgentPlan(
            summary: "Write it up, then send it.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "draft", operation: .createLocalDraft, description: "Write it.", draftTitle: "Notes", draftContent: "Body."),
                AgentStep(id: "send", operation: .invokeShortcut, description: "Send it.", shortcutName: "Send Report")
            ]
        )
        let fixture = Date(timeIntervalSince1970: 1_700_000_000)

        let withShortcutLeft = ResumableTask(
            command: "Write it up and send it",
            plan: plan,
            completedStepIDs: ["draft"],
            startedAt: fixture,
            updatedAt: fixture
        )
        #expect(withShortcutLeft.isResumable)
        #expect(!withShortcutLeft.mayBeOfferedForResume)
        #expect(withShortcutLeft.stepsThatMustNotRepeatSilently.map(\.id) == ["send"])

        // The control: the Shortcut done, only a safe step left.
        let safePlan = AgentPlan(
            summary: "Send it, then open the page.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "send", operation: .invokeShortcut, description: "Send it.", shortcutName: "Send Report"),
                AgentStep(id: "open", operation: .openURL, description: "Open it.", targetURL: "https://example.com/page")
            ]
        )
        let withShortcutDone = ResumableTask(
            command: "Send it and open the page",
            plan: safePlan,
            completedStepIDs: ["send"],
            startedAt: fixture,
            updatedAt: fixture
        )
        #expect(withShortcutDone.mayBeOfferedForResume)
        #expect(withShortcutDone.stepsThatMustNotRepeatSilently.isEmpty)
    }

    /// A record with nothing left is not offerable either, for the reason it always was.
    @Test
    func aRecordWithNothingLeftIsNotOfferable() {
        let plan = AgentPlan(
            summary: "Open it.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "open", operation: .openURL, description: "Open.", targetURL: "https://example.com/page")]
        )
        let fixture = Date(timeIntervalSince1970: 1_700_000_000)
        let done = ResumableTask(
            command: "Open it",
            plan: plan,
            completedStepIDs: ["open"],
            startedAt: fixture,
            updatedAt: fixture
        )
        #expect(!done.mayBeOfferedForResume)
    }
}
