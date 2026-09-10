import Foundation

/// How the Tasks page divides its panel between the list and the receipt once a task is open:
/// the list takes `SonnyMetrics.tasksListShare` of the panel (the founders' 60/40, 2026-09-10),
/// unless the receipt's floor needs more of what is left. Kept out of the view for the reason
/// every presentation type in this target is: the arithmetic is the whole behaviour, and a view
/// body has no test to hold it.
///
/// **Why there is a floor at all.** The receipt's metadata row and its three action buttons have
/// no fallback under about 312pt of content (the worst metadata line, "Canceled after 1h 23m ·
/// Scheduled", measures about 307pt; the buttons about 248pt), and 40% of the panel is less than
/// that at the 900-wide minimum window in either sidebar state (phase 15's review, F1 and F2). The
/// draggable split this replaced arbitrated both sides' floors itself; here the receipt keeps the
/// floor it had, and the list is the side that gives, so the share holds from the default window
/// up and the receipt reads whole below it.
enum TasksSplitPresentation {
    static func listWidth(
        panelWidth: CGFloat,
        share: CGFloat = SonnyMetrics.tasksListShare,
        receiptMinWidth: CGFloat = SonnyMetrics.taskReceiptMinWidth,
        ruleWidth: CGFloat = SonnyMetrics.tasksSplitRuleWidth
    ) -> CGFloat {
        let shared = (panelWidth * share).rounded()
        let widestTheReceiptAllows = panelWidth - receiptMinWidth - ruleWidth
        return max(0, min(shared, widestTheReceiptAllows))
    }
}
