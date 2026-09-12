import Foundation
import Testing
import MacAgentCore
@testable import MacAgent

/// SONNY-446. One six-second timer used to drive both the idle collapse and the outcome clear, and
/// a result collapsed — which is to say cleared — before the founders could read it or press Open.
/// An outcome now counts down from its own, longer figure; these hold the two numbers, their order,
/// which states have a clock at all, that the twenty is for an outcome the widget is showing, and
/// that the view's timer reads this table rather than a literal of its own.
@Suite
struct WidgetAutoCollapseDelayTests {
    private static let result = WidgetState.result("Done.", nil)
    private static let failure = WidgetState.failure("Sonny couldn't finish this one.")

    @Test
    func anOutcomeWaitsLongerThanIdleAndIdleIsStillSixSeconds() {
        #expect(WidgetAutoCollapseDelay.idle == .seconds(6))
        #expect(WidgetAutoCollapseDelay.outcome == .seconds(20))
        #expect(WidgetAutoCollapseDelay.outcome > WidgetAutoCollapseDelay.idle)
    }

    @Test
    func aResultAndAFailureCountDownFromTheOutcomeFigureWhileThePanelShows() {
        #expect(WidgetAutoCollapseDelay.delay(for: Self.result, showsPanel: true) == WidgetAutoCollapseDelay.outcome)
        #expect(WidgetAutoCollapseDelay.delay(for: Self.failure, showsPanel: true) == WidgetAutoCollapseDelay.outcome)
    }

    /// **An outcome the widget does not show counts down from idle** (PR #231's fresh review, F2).
    /// A run started from Command Center leaves the widget showing its composer — the panel is
    /// drawn only for a widget-started run — and it must collapse at six seconds as idle does,
    /// not hold for the twenty that a result nobody can see does not need.
    @Test
    func anOutcomeTheWidgetDoesNotShowCountsDownFromIdle() {
        #expect(WidgetAutoCollapseDelay.delay(for: Self.result, showsPanel: false) == WidgetAutoCollapseDelay.idle)
        #expect(WidgetAutoCollapseDelay.delay(for: Self.failure, showsPanel: false) == WidgetAutoCollapseDelay.idle)
    }

    @Test
    func idleAndWorkingKeepTheIdleFigure() {
        #expect(WidgetAutoCollapseDelay.delay(for: .idle, showsPanel: false) == WidgetAutoCollapseDelay.idle)
        #expect(WidgetAutoCollapseDelay.delay(for: .working, showsPanel: false) == WidgetAutoCollapseDelay.idle)
    }

    /// A parked question has no clock: the view's `isCollapsible` refuses these first, and this
    /// type answers the same; the two switches are held in agreement by the test below.
    @Test
    func aParkedQuestionHasNoClock() {
        #expect(WidgetAutoCollapseDelay.delay(for: .clarification("Which folder?"), showsPanel: true) == nil)
    }

    /// **Every state in the table** (the fresh review's F1). Eight of thirteen were unchecked, and a
    /// state moved into the no-clock group — the version wall, the update prompt, the resume offer —
    /// would have held the widget open forever with no test failing, the outcome SONNY-210 and
    /// SONNY-402 decided against. The states a test can construct are asserted by value; the five
    /// whose payloads are session fixtures are pinned by the table's own case line, read from the
    /// source, so the grouping cannot move unread.
    @Test
    @MainActor
    func everyStateHasTheClockTheTableSays() throws {
        let prompt = ClientVersionPrompt(title: "Update", message: "A newer Sonny is out.", updateLabel: "Update", dismissLabel: nil, link: nil)
        let offer = ResumableTask(
            command: "Write notes and open the page",
            plan: AgentPlan(summary: "Write notes.", requiresConfirmation: false, steps: [
                AgentStep(id: "url", operation: .openURL, description: "Open the page.", targetURL: "https://example.com/")
            ]),
            startedAt: Date(timeIntervalSinceNow: -3_600),
            updatedAt: Date(timeIntervalSinceNow: -3_600)
        )
        let idleGroup: [WidgetState] = [.idle, .working, .resumeOffer(offer), .tooOld(prompt), .updateAvailable(prompt)]
        for state in idleGroup {
            #expect(WidgetAutoCollapseDelay.delay(for: state, showsPanel: true) == WidgetAutoCollapseDelay.idle, "\(state)")
            #expect(WidgetAutoCollapseDelay.delay(for: state, showsPanel: false) == WidgetAutoCollapseDelay.idle, "\(state)")
        }
        #expect(WidgetAutoCollapseDelay.delay(for: .clarification("Which folder?"), showsPanel: false) == nil)

        let source = try MacAgentSource.read("WidgetAutoCollapseDelay.swift")
        let table = try MacAgentSource.braceBlock(of: source, openedBy: "static func delay(for state: WidgetState, showsPanel: Bool) -> Duration? {")
        #expect(table.contains("case .result, .failure:\n            return showsPanel ? outcome : idle"))
        #expect(table.contains("case .idle, .resumeOffer, .working, .tooOld, .updateAvailable:\n            return idle"))
        #expect(table.contains("case .permission, .clarification, .captureReview, .delegationReview, .sessionPaused, .controlling:\n            return nil"))
        // Thirteen cases, three lines, none repeated: a case added to `WidgetState` fails to
        // compile the switch, and a case moved between lines fails one of the three pins above.
        #expect(table.components(separatedBy: "case .").count - 1 == 3)
    }

    /// **The view's timer reads this table and keeps no literal** (the fresh review's F1). The fix
    /// is at the sleep inside `scheduleAutoDismissIfNeeded`; nothing read that line, so the six
    /// seconds could have come back into the view with the suite green. The block is sliced from
    /// its own start by `braceBlock`, whose anchor and brace are `#require`d, so a split view fails
    /// here rather than widening the scan.
    @Test
    @MainActor
    func theViewsTimerReadsTheTableAndKeepsNoLiteral() throws {
        let view = try MacAgentSource.read("FloatingWidgetView.swift")
        let timer = try MacAgentSource.braceBlock(of: view, openedBy: "private func scheduleAutoDismissIfNeeded() {")

        #expect(timer.contains("guard let delay = WidgetAutoCollapseDelay.delay(for: state, showsPanel: showsPanel) else {"))
        #expect(timer.contains("try? await Task.sleep(for: delay)"))
        #expect(!timer.contains(".seconds("), "the view carries a delay literal of its own again")
        #expect(!timer.contains("WidgetAutoCollapseDelay.idle") && !timer.contains("WidgetAutoCollapseDelay.outcome"), "the view picks a figure itself rather than asking the table for the state")
    }
}
