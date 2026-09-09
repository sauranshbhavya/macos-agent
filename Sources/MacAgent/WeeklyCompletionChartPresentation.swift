import Foundation

/// The weekly-completion chart's hover-count label, pulled out of the view so the pluralization can
/// be tested without a view host (phase 12, founder report: the label used to replace the day name
/// in place, which wrapped to three lines in a narrow column — the fix moves the count into its own
/// pill, and this is the pill's wording).
enum WeeklyCompletionChartPresentation {
    /// "1 task", "0 tasks", "30 tasks".
    static func countLabel(for count: Int) -> String {
        "\(count) task\(count == 1 ? "" : "s")"
    }
}
