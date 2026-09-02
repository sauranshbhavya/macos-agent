import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// **"X runs left", and the one condition it is shown under** (SONNY-214).
///
/// The ticket's second half is a single rule — the figure appears when a *screen-control* task is
/// about to run and never on an ordinary free one — so the tests that matter here drive both kinds
/// of task down the same path, with the same allowance in hand, and read the same property. Anything
/// weaker proves the number can be rendered, which was never in doubt; what is in doubt is whether a
/// free task can render it too.
///
/// **Both runs stop at a Safe-mode approval, and that is deliberate rather than convenient.** Safe
/// mode floors every tier to `.explicitApproval` (`RiskApprovalPolicy.safeModeFloor`), so a
/// calculation and a screen-control session pause in the *identical* state — plan prepared, approval
/// outstanding, nothing executing — and the only difference left between the two cases is the one
/// the rule is about. It is also the literal moment the ticket names: a run about to start, waiting
/// on the person who will start it.
@Suite
@MainActor
struct ScreenControlUsageSurfaceTests {
    // MARK: - The gate, in both directions

    @Test
    func theRunsLeftFigureShowsForAScreenControlRunAndNotForAFreeOne() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.serveCredits(runsLeft: 12, runsIncluded: 20)

        await fixture.viewModel.refreshScreenControlAllowance()
        // The figure is in hand for *both* halves below, which is what makes the second half a test
        // of the gate rather than of a failed read.
        #expect(try #require(fixture.viewModel.screenControlAllowance).runsLeft == 12)

        // A screen-control run, about to start.
        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()

        #expect(fixture.viewModel.isScreenControlTaskInFlight)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == 12)

        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitForIdle()

        // The same allowance, the same surface, an ordinary free task.
        fixture.viewModel.command = "what is 2 + 2"
        fixture.viewModel.start(prebuiltPlan: Self.freePlan)
        try await fixture.waitForApproval()

        // **Asserted before the gate is read, and this is the half that carries the test** (PR
        // #188's F2). Every expectation below is also true of a view model that has never run
        // anything at all — `false`, `nil` and an allowance nobody consumed are exactly the empty
        // state — so on their own they prove that *nothing* is in flight rather than that a free
        // task is. These two say which task the gate is answering about: a free plan, prepared, and
        // parked in the same pause the screen-control run above was read in.
        #expect(fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.plan?.steps.first?.operation == .calculateUtility)

        #expect(fixture.viewModel.isScreenControlTaskInFlight == false)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)
        // And the figure really is still there to be shown, so the `nil` above is the gate's answer
        // and not a read that expired between the two halves.
        #expect(try #require(fixture.viewModel.screenControlAllowance).runsLeft == 12)
    }

    /// **The window between a dispatch and its plan**, which the gate used to answer wrongly (PR
    /// #188's F3, reviewer probe P2 — this is that probe, kept).
    ///
    /// `start()` flips `isRunning` synchronously and `performStart` is the body of an unstructured
    /// `Task`, so for one main-actor turn the two published properties the gate reads described two
    /// different runs: the new free task's `isRunning`, and the previous screen-control run's
    /// `plan`. Nothing is awaited between the dispatch and the expectation below, so this test has
    /// no race of its own — it reads exactly that turn, and it failed on the tree this branch was
    /// reviewed at.
    @Test
    func aFreeTaskDispatchedAfterAScreenControlRunShowsNoFigureInTheTurnBeforeItsPlanArrives() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.serveCredits(runsLeft: 12, runsIncluded: 20)
        await fixture.viewModel.refreshScreenControlAllowance()

        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()
        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitForIdle()
        // A cancel at the pause deliberately leaves the plan behind — that is what makes the window
        // reachable at all, and `aFigureThatWasReadDoesNotOutliveTheRunItWasShownBeside` is the
        // test of the property itself.
        #expect(fixture.viewModel.plan?.steps.first?.operation == .visionSession)

        fixture.viewModel.command = "what is 2 + 2"
        fixture.viewModel.start(prebuiltPlan: Self.freePlan)

        #expect(fixture.viewModel.isRunning)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil, "the gate answered a figure for a free task")

        try await fixture.waitForApproval()
        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitForIdle()
    }

    /// **A scheduled routine is not the user's screen-control task** (PR #188's F3, second door).
    ///
    /// `performScheduledRun` sets `isRunning` and deliberately leaves `plan` alone — its own doc
    /// comment lists `plan` among the properties a background run must not disturb — so a routine
    /// firing after a screen-control run inherited that plan and the gate answered `true` for the
    /// whole of it. The consequence was a `GET /v1/account/credits` for a run nobody is watching,
    /// against the widget's own comment that an ordinary task asks for nothing. The gate reads
    /// `activeTaskOrigin` now, which is the property that method names as the one keeping widget
    /// surfaces off a task the user never started.
    @Test
    func aScheduledRoutineRunNeverCarriesTheFigureEvenAfterAScreenControlRun() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.serveCredits(runsLeft: 12, runsIncluded: 20)
        await fixture.viewModel.refreshScreenControlAllowance()
        try fixture.saveScheduledRoutine()

        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()
        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.plan?.steps.first?.operation == .visionSession)

        fixture.viewModel.checkScheduledRoutines(now: UsageFixture.tenAM)

        // The routine really did start — without this the two expectations below are the empty
        // state again, which is the shape F2 was filed for.
        #expect(fixture.viewModel.isRunning)
        #expect(fixture.viewModel.isScreenControlTaskInFlight == false)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)

        try await fixture.waitForIdle()
    }

    /// **Signing out forgets the figure** (PR #188's F1).
    ///
    /// It is an account-scoped number read over an authenticated session, and nothing in the two
    /// surfaces re-reads it when the session changes: signing in is a sheet over Command Center and
    /// signing out a menu item, so neither re-fires the `onAppear` that is otherwise the only thing
    /// that asks. Left alone, a user who signed out went on reading their own figure and the next
    /// user on the same Mac read it too. `SignInView.signOut()` clears `subscription` synchronously
    /// for exactly this reason (PR #183's F13); this is the same class of datum.
    @Test
    func theFigureIsForgottenWhenTheSessionChanges() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.serveCredits(runsLeft: 12, runsIncluded: 20)

        await fixture.viewModel.refreshScreenControlAllowance()
        #expect(try #require(fixture.viewModel.screenControlAllowance).runsLeft == 12)

        fixture.viewModel.forgetScreenControlAllowance()

        #expect(fixture.viewModel.screenControlAllowance == nil)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)
    }

    /// The wiring itself: `main.swift` is the one file that holds both the account model and the
    /// view model, so it is the only place that can join a session change to this figure — and a
    /// method nothing calls would pass the test above while shipping the defect.
    @Test
    func theSessionChangeHandlerForgetsTheFigure() throws {
        let source = try MacAgentSource.read("main.swift")
        let handler = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "accountModel.sessionDidChange = { [weak agentViewModel] in"
        )
        #expect(MacAgentSource.count(of: "accountModel.sessionDidChange = {", inText: source) == 1)
        #expect(MacAgentSource.count(of: "forgetScreenControlAllowance()", inText: handler) == 1)
        #expect(MacAgentSource.count(of: "forgetScreenControlAllowance", inText: source) == 1)
    }

    @Test
    func aScreenControlRunWhoseReadFailedShowsNoFigureRatherThanAFabricatedOne() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.backend.register { _ in .failure(URLError(.notConnectedToInternet)) }

        await fixture.viewModel.refreshScreenControlAllowance()
        #expect(fixture.viewModel.screenControlAllowance == nil)

        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()

        // The run is a screen-control run — the half of the gate that holds — and the line is still
        // absent, because there is no number. `ScreenControlAllowanceService` states why no fallback
        // figure exists: zero locks a user out of what they paid for and any positive number
        // promises runs the server never granted.
        #expect(fixture.viewModel.isScreenControlTaskInFlight)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)
    }

    @Test
    func aFigureThatWasReadDoesNotOutliveTheRunItWasShownBeside() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.serveCredits(runsLeft: 3, runsIncluded: 20)
        await fixture.viewModel.refreshScreenControlAllowance()

        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == 3)

        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitForIdle()

        // Nothing is in flight, so nothing is shown — the widget's result and idle panels do not
        // inherit the line from the run that has just ended. The allowance itself is untouched,
        // because Command Center goes on showing it.
        #expect(fixture.viewModel.isScreenControlTaskInFlight == false)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)
        #expect(try #require(fixture.viewModel.screenControlAllowance).runsLeft == 3)
    }

    // MARK: - The two sentences

    @Test
    func theInTaskLineIsTheNumberAndNothingElse() {
        #expect(ScreenControlUsagePresentation.inTaskLine(runsLeft: 12) == "12 runs left")
        #expect(ScreenControlUsagePresentation.inTaskLine(runsLeft: 1) == "1 run left")
        #expect(ScreenControlUsagePresentation.inTaskLine(runsLeft: 0) == "0 runs left")
    }

    @Test
    func theUsageLineCarriesTheDenominatorAndThePeriod() {
        #expect(ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 12)) == "12 of 20 runs left this month")
        #expect(ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 1)) == "1 of 20 runs left this month")
        #expect(ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 0)) == "0 of 20 runs left this month")
        // **The denominator's own singular, which is the branch's one decided-and-unheld branch**
        // (PR #188's F6). Every case above holds `runsIncluded` at 20, so the ternary that makes the
        // noun agree with the denominator never took its true arm — and a mutant flipping its
        // boundary from `== 1` to `== 0` passed the whole suite. Whether a one-run plan exists in
        // `CREDIT_PLANS` today is the server's business and not this side's: the rule is that the
        // noun agrees with the number it counts, and it is held here at the only value that can
        // show it.
        #expect(
            ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 1, runsIncluded: 1))
                == "1 of 1 run left this month"
        )
        #expect(
            ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 0, runsIncluded: 1))
                == "0 of 1 run left this month"
        )
    }

    /// **The figure is observable, which is the branch's own central claim about it** (PR #188's
    /// F9).
    ///
    /// `isScreenControlTaskInFlight`'s doc rejects the `preparedRun` spelling because it is
    /// unpublished and "would leave a view showing the wrong answer until something else happened to
    /// redraw it". The same is true of this property the moment the attribute comes off it, and
    /// deleting it passed all 2710 tests — the two surfaces would go on compiling and simply stop
    /// updating. A scan is the available tool: this repository has no SwiftUI inspection harness,
    /// and `MacAgentSource` strips comments before counting, so the sentence above cannot satisfy it.
    @Test
    func theAllowanceIsPublishedSoTheTwoSurfacesSeeItChange() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        #expect(
            MacAgentSource.count(
                of: "@Published private(set) var screenControlAllowance: ScreenControlAllowance?",
                inText: source
            ) == 1
        )
        // The control: the declaration is found without its attribute too, so the count above is
        // reading the attribute rather than answering zero for a property that has been renamed.
        #expect(
            MacAgentSource.count(of: "var screenControlAllowance: ScreenControlAllowance?", inText: source) == 1
        )
    }

    /// **The standing rule, held by value** (`CLAUDE.md`: no explanatory or how-it-works copy in the
    /// product). Both sentences are read immediately above; this is the enumeration that a *third*
    /// clause cannot be appended to either of them without a test going red, which is the failure
    /// mode the rule exists for — nobody adds an explanation on purpose, they add it as a helpful
    /// half-sentence on the end of a line that already worked.
    @Test
    func neitherSentenceExplainsAnything() {
        let sentences = [
            ScreenControlUsagePresentation.inTaskLine(runsLeft: 12),
            ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 12))
        ]
        for sentence in sentences {
            #expect(sentence.split(separator: ".").count == 1, "\(sentence) carries a second sentence")
            for word in ["because", "each", "counts", "when you", "screen control uses", "will be"] {
                #expect(!sentence.lowercased().contains(word), "\(sentence) explains itself: \(word)")
            }
        }
    }

    // MARK: - Both surfaces are actually wired to the gate

    /// The widget renders the figure through the one property that carries the rule, and gates it on
    /// nothing else of its own.
    ///
    /// A source scan because this repository has no SwiftUI inspection harness — see
    /// `MacAgentSource` for what that is worth and what it is not. Sliced to the panel's own
    /// container so a match somewhere else in a 2,300-line file cannot stand in for this one.
    @Test
    func theWidgetShowsTheFigureThroughTheGateAndRefreshesWhenAScreenControlRunBegins() throws {
        let source = try MacAgentSource.read("FloatingWidgetView.swift")
        // **Each anchor is pinned to one occurrence before it is sliced on** (PR #188's F11).
        // `braceBlock` takes the *first* match, so a second identical anchor arriving later would
        // silently redirect the slice to a region that satisfies these counts for the wrong reason —
        // SONNY-378's own remedy, applied to the anchors rather than to the tokens inside them.
        #expect(MacAgentSource.count(of: "private var styledPanel: some View {", inText: source) == 1)
        #expect(
            MacAgentSource.count(of: ".onChange(of: viewModel.isScreenControlTaskInFlight) {", inText: source) == 1
        )
        let panel = try MacAgentSource.braceBlock(of: source, openedBy: "private var styledPanel: some View {")
        #expect(MacAgentSource.count(of: "viewModel.screenControlRunsLeftForTaskInFlight", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "ScreenControlUsagePresentation.inTaskLine(", inText: panel) == 1)
        // The Command Center line's denominator form must not leak onto the widget, which is the
        // one way these two surfaces could come to say the same thing in the wrong place.
        #expect(MacAgentSource.count(of: "ScreenControlUsagePresentation.usageLine(", inText: panel) == 0)

        // And the read that fills it is triggered by the run, not by a timer and not at launch.
        let trigger = try MacAgentSource.braceBlock(
            of: source,
            openedBy: ".onChange(of: viewModel.isScreenControlTaskInFlight) {"
        )
        #expect(MacAgentSource.count(of: "viewModel.refreshScreenControlAllowance()", inText: trigger) == 1)
        #expect(MacAgentSource.count(of: "refreshScreenControlAllowance", inText: source) == 1)
    }

    /// Command Center's stats area renders the row, and Insights is the page that asks for the
    /// figure.
    @Test
    func commandCenterShowsTheUsageRowInTheStatsAreaAndAsksForTheFigureThere() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        // Each anchor pinned to one occurrence before it is sliced on — see the widget test above.
        for anchor in [
            "private struct InsightsView: View {",
            "private struct InsightsOverviewBento: View {",
            "private struct ScreenControlUsageRow: View {"
        ] {
            #expect(MacAgentSource.count(of: anchor, inText: source) == 1, "anchor is not unique: \(anchor)")
        }

        let bento = try MacAgentSource.braceBlock(of: source, openedBy: "private struct InsightsOverviewBento: View {")
        #expect(MacAgentSource.count(of: "ScreenControlUsageRow(allowance:", inText: bento) == 1)

        let row = try MacAgentSource.braceBlock(of: source, openedBy: "private struct ScreenControlUsageRow: View {")
        #expect(MacAgentSource.count(of: "ScreenControlUsagePresentation.usageLine(allowance)", inText: row) == 1)
        // System A, and only System A — the widget's tokens have no business on this page.
        #expect(MacAgentSource.count(of: "WidgetTheme.", inText: row) == 0)
        #expect(MacAgentSource.count(of: "WidgetType.", inText: row) == 0)
        // **The control for the two zeros above** (PR #188's F11, and CLAUDE.md's rule that a search
        // has to be shown able to find something before its zero is evidence). Those tokens are
        // absent from this whole file, so the zeros would also be answered by a scan that cannot see
        // this token shape at all. The widget's file is where they live, and the count there is what
        // shows the shape is findable.
        let widgetSource = try MacAgentSource.read("FloatingWidgetView.swift")
        #expect(MacAgentSource.count(of: "WidgetTheme.", inText: widgetSource) > 0)
        #expect(MacAgentSource.count(of: "WidgetType.", inText: widgetSource) > 0)

        // **Sliced to the page's own `.onAppear`, not counted over the file** (PR #188's F5). The
        // file-wide count below is the "one place" backstop and says nothing about *where* — a
        // mutant that left the call in the file and made it unreachable passed the whole suite,
        // which in the product is a row that never appears for anyone who opens Insights while idle.
        let insights = try MacAgentSource.braceBlock(of: source, openedBy: "private struct InsightsView: View {")
        #expect(MacAgentSource.count(of: ".onAppear {", inText: insights) == 1)
        let appear = try MacAgentSource.braceBlock(of: insights, openedBy: ".onAppear {")
        #expect(MacAgentSource.count(of: "viewModel.refreshScreenControlAllowance()", inText: appear) == 1)
        // **And asked unconditionally, which slicing to the handler still does not say** (PR #188's
        // F5, and the first fix for it was not enough — the mutant that leaves the call where it is
        // and wraps it in `if viewModel.isRunning { … }` survived a scan that had been narrowed from
        // the file to this block, because the count is 1 either way). In the product that mutant is
        // a row nobody ever sees: it would appear only for someone who opens Insights while a task
        // happens to be running. The page asks for the figure whenever it appears, so there is
        // nothing in this handler for the ask to be conditional on.
        #expect(MacAgentSource.count(of: "if ", inText: appear) == 0)
        #expect(MacAgentSource.count(of: "guard ", inText: appear) == 0)
        // The control for those two zeros, per CLAUDE.md's make-the-search-find-something rule:
        // both shapes are plentiful in this file, so the zeros are a property of the handler rather
        // than of a scan that cannot see a conditional.
        #expect(MacAgentSource.count(of: "if ", inText: source) > 0)
        #expect(MacAgentSource.count(of: "guard ", inText: source) > 0)

        #expect(MacAgentSource.count(of: "refreshScreenControlAllowance", inText: source) == 1)
    }

    // MARK: - Fixtures

    static let screenControlPlan = AgentPlan(
        summary: "Control Safari: open my reading list",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "vision-1",
                operation: .visionSession,
                description: "Control Safari to open my reading list",
                appName: "Safari",
                visionGoal: "open my reading list"
            )
        ]
    )

    static let freePlan = AgentPlan(
        summary: "Add two and two",
        requiresConfirmation: false,
        steps: [
            AgentStep(id: "calc", operation: .calculateUtility, description: "Calculate 2 + 2.", searchQuery: "2 + 2")
        ]
    )

    static func allowance(runsLeft: Int, runsIncluded: Int = 20) -> ScreenControlAllowance {
        ScreenControlAllowance(
            plan: "test-plan-a",
            runsLeft: runsLeft,
            runsIncluded: runsIncluded,
            periodStart: Date(timeIntervalSince1970: 1_753_920_000),
            periodEnd: Date(timeIntervalSince1970: 1_756_598_400)
        )
    }
}

@MainActor
private struct UsageFixture {
    let viewModel: AgentViewModel
    let backend: SignedInBackendFixture
    let routineStore: RoutineStore
    let root: URL
    let defaultsSuiteName: String

    static var nineAM: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 31
        components.hour = 9
        return Calendar.current.date(from: components) ?? Date()
    }

    static var tenAM: Date { nineAM.addingTimeInterval(3_600) }

    /// A daily 9am routine, enabled a day earlier so `checkScheduledRoutines(now: tenAM)` finds an
    /// occurrence, and unattended-trusted so the run is not paused for an approval nobody is there
    /// to give. Its one step is a calculation: this fixture wires no vision environment, and the
    /// subject here is which task the gate answers about rather than what the routine does.
    func saveScheduledRoutine() throws {
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, unattendedTrusted: true)
        schedule.setEnabled(true, now: Self.nineAM.addingTimeInterval(-24 * 60 * 60))
        try routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "calc",
                        operation: .calculateUtility,
                        description: "Calculate 1 + 1.",
                        searchQuery: "1 + 1"
                    )
                ],
                schedule: schedule
            )
        )
        viewModel.refreshSavedItems()
    }

    /// The gateway's own body shape, field for field — `ScreenControlAllowanceTests` in the core
    /// target carries the same one, and contract §5.4 is where it comes from.
    func serveCredits(runsLeft: Int, runsIncluded: Int) {
        backend.register { _ in
            .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: [
                    "plan": "test-plan-a",
                    "period_start": "2026-08-01T00:00:00.000Z",
                    "period_end": "2026-09-01T00:00:00.000Z",
                    "screen_control_runs_left": runsLeft,
                    "screen_control_runs_included": runsIncluded,
                    "credits": ["allowance": 200, "drawn": 80, "remaining": 120, "per_run": 10]
                ])
            )
        }
    }

    /// Waits for the run to park on its approval.
    ///
    /// **`HangBackstop.waitOrAbandon`, and the reason is that the obvious hand-rolled loop returns
    /// silently when it gives up** (PR #188's F2). This suite's own first version did, and it was
    /// the only wait in either test tree that recorded nothing on timeout. Two things follow from
    /// that, both bad in the reassuring direction: every assertion after the wait then reads a state
    /// the run never reached — and the free-task half below is *satisfiable by an empty state*, so
    /// it would have gone green while proving nothing about the gate — and a red produced that way
    /// carries no declared signature, so `scripts/mutate` reads it as a kill (SONNY-224). The
    /// backstop records its own stuck/starved wording, both declared in
    /// `scripts/mutate-untrusted-failures`, and then throws so that nothing after it runs at all.
    func waitForApproval() async throws {
        try await HangBackstop.waitOrAbandon(for: "the run to park on its approval") {
            viewModel.isAwaitingApproval
        }
    }

    func waitForIdle() async throws {
        try await HangBackstop.waitOrAbandon(for: "the run to end") {
            !viewModel.isRunning && !viewModel.isAwaitingApproval
        }
    }

    func tearDown() {
        backend.unregister()
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Safe mode throughout, for the reason the suite's own doc gives: it is what puts a free task and a
/// screen-control task into the same pause, so the only difference the gate can be reading is the
/// one it claims to read.
@MainActor
private func makeUsageFixture() throws -> UsageFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScreenControlUsageSurfaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suiteName = "ScreenControlUsageSurfaceTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let backend = SignedInBackendFixture()
    let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
    let viewModel = AgentViewModel(
        routineStore: routineStore,
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: NoUsageShortcuts(),
        finderRevealer: hermeticFinderRevealer,
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json")
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            whitelist: PathWhitelist(roots: [root])
        ),
        resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: HermeticPasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings-monitor.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // The signed-in stub client, because this suite's subject is a figure read over the wire.
        backendClient: backend.client,
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        // Every run here carries a pre-built plan, so reaching a planner would be a test bug.
        makePlanner: { _, _ in UnreachableUsagePlanner() },
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )
    viewModel.interactionMode = .safe
    return UsageFixture(
        viewModel: viewModel,
        backend: backend,
        routineStore: routineStore,
        root: root,
        defaultsSuiteName: suiteName
    )
}

private struct UnreachableUsagePlanner: Planning {
    struct ReachedThePlanner: Error {}

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        throw ReachedThePlanner()
    }
}

private struct NoUsageShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}
