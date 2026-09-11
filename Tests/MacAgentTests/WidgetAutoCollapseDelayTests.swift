import Foundation
import Testing
@testable import MacAgent

/// SONNY-446. One six-second timer used to drive both the idle collapse and the outcome clear, and
/// a result collapsed — which is to say cleared — before the founders could read it or press Open.
/// An outcome now counts down from its own, longer figure; these hold the two numbers, their order,
/// and which states have a clock at all.
@Suite
struct WidgetAutoCollapseDelayTests {
    @Test
    func anOutcomeWaitsLongerThanIdleAndIdleIsStillSixSeconds() {
        #expect(WidgetAutoCollapseDelay.idle == .seconds(6))
        #expect(WidgetAutoCollapseDelay.outcome == .seconds(20))
        #expect(WidgetAutoCollapseDelay.outcome > WidgetAutoCollapseDelay.idle)
    }

    @Test
    func aResultAndAFailureCountDownFromTheOutcomeFigure() {
        #expect(WidgetAutoCollapseDelay.delay(for: .result("Done.", nil)) == WidgetAutoCollapseDelay.outcome)
        #expect(WidgetAutoCollapseDelay.delay(for: .failure("Sonny couldn't finish this one.")) == WidgetAutoCollapseDelay.outcome)
    }

    @Test
    func idleAndWorkingKeepTheIdleFigure() {
        #expect(WidgetAutoCollapseDelay.delay(for: .idle) == WidgetAutoCollapseDelay.idle)
        #expect(WidgetAutoCollapseDelay.delay(for: .working) == WidgetAutoCollapseDelay.idle)
    }

    /// A parked question has no clock: the view's `isCollapsible` refuses these first, and this
    /// type answers the same so the two cannot disagree about which states have one.
    @Test
    func aParkedQuestionHasNoClock() {
        #expect(WidgetAutoCollapseDelay.delay(for: .clarification("Which folder?")) == nil)
    }
}
