import Testing
@testable import MacAgent

/// The weekly-completion chart's hover-count pill wording (phase 12), driven with no view host —
/// the same reason `JumpToPaletteTests` drives its presentation type directly.
@Suite
struct WeeklyCompletionChartPresentationTests {
    @Test
    func oneTaskReadsSingular() {
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 1) == "1 task")
    }

    @Test
    func everyOtherCountReadsPlural() {
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 0) == "0 tasks")
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 2) == "2 tasks")
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 30) == "30 tasks")
    }
}
