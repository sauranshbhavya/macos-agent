import Foundation

/// A finished run's outcome, as the notification fallback carries it (SONNY-56, extended by PR #67's
/// F4 decision).
///
/// Carries the task alongside the words because clicking the notification opens **that task's**
/// detail dialog — the founder's decision of 2026-08-17. Before it, the click expanded the floating
/// widget, which renders nothing for a Command-Center-origin result: `hasVisibleWidgetPanel` gates
/// the finished-summary panel on `.widget` origin, so the user arrived at an empty composer. Nobody
/// chose that; the outcome category inherited a handler written for the failure notification, whose
/// message really does live in the widget.
struct CompletedRunNotice: Equatable {
    var summary: String

    /// The `CompletedTaskRecord.id` of the row this run wrote, when it wrote one.
    ///
    /// `nil` for a suppressed run, which writes no row — so there is nothing to open and the click
    /// falls back to bringing Command Center forward without a dialog.
    var taskID: String?
}

/// A request to open one task's detail dialog, raised from outside the view that owns the sheet.
///
/// Identity is a fresh `UUID` per request rather than the task id, deliberately: two notifications
/// for the same task must each reopen the sheet, and a value that compares equal to the last one
/// would be dropped by SwiftUI's change tracking.
struct TaskDetailRequest: Equatable, Identifiable {
    let id = UUID()
    var taskID: String
}
