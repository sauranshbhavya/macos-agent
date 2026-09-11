import Foundation
import Testing
@testable import MacAgent

/// Phase 15's split arithmetic: the list's share of the panel, and the receipt's floor taking
/// from it when the panel cannot hold both (the review's F1 and F2, at the 900-wide minimum
/// window). Panel widths below are the real ones: 1175 and 1011 are the default 1280 window with
/// the sidebar collapsed and expanded, 795 and 631 the 900 minimum in the same two states
/// (window less the sidebar, its 1pt rule and two 24pt page insets).
@Suite
struct TasksSplitPresentationTests {
    @Test
    func theListTakesItsShareWhenThePanelHasRoomForBoth() {
        #expect(TasksSplitPresentation.listWidth(panelWidth: 1000) == 600)
        #expect(TasksSplitPresentation.listWidth(panelWidth: 1175) == 705)
        #expect(CGFloat(1175 - 705 - 1) >= SonnyMetrics.taskReceiptMinWidth, "the default window leaves the receipt above its floor")
    }

    @Test
    func theShareIsRoundedToTheNearestPoint() {
        // 1011 × 0.6 is 606.6: nearest, not truncated, so the rule never lands on a half point.
        #expect(TasksSplitPresentation.listWidth(panelWidth: 1011) == 607)
    }

    @Test
    func theReceiptsFloorTakesFromTheListAtANarrowPanel() {
        // 631 × 0.6 would be 379 and leave the receipt 251; the floor wins and the list gives:
        // 631 less the 360 floor and the 1pt rule. (Literals, not the subtraction spelled out:
        // `#expect` compares a CGFloat against an integer expression as unequal at 270 == 270.)
        #expect(TasksSplitPresentation.listWidth(panelWidth: 631) == 270)
        // 795 less 361, the same way.
        #expect(TasksSplitPresentation.listWidth(panelWidth: 795) == 434)
    }

    @Test
    func theCrossoverIsThePanelWhereTheShareLeavesExactlyTheFloor() {
        // 902 × 0.6 rounds to 541 and leaves 360: the share holds from here up.
        #expect(TasksSplitPresentation.listWidth(panelWidth: 902) == 541)
        // 901 × 0.6 rounds to 541 too and would leave 359: one point under, the floor wins.
        #expect(TasksSplitPresentation.listWidth(panelWidth: 901) == 540)
    }

    @Test
    func theListNeverGoesNegative() {
        #expect(TasksSplitPresentation.listWidth(panelWidth: 300) == 0)
        #expect(TasksSplitPresentation.listWidth(panelWidth: 361) == 0)
    }

    /// The defaults the view relies on, so a token drift shows here and not only in a screenshot.
    @Test
    func theTokensAreTheOnesTheFoundersAskedFor() {
        #expect(SonnyMetrics.tasksListShare == 0.6)
        #expect(SonnyMetrics.taskReceiptMinWidth == 360)
        #expect(SonnyMetrics.tasksSplitRuleWidth == 1)
    }
}
