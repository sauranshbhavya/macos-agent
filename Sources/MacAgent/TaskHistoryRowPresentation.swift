import Foundation

/// The Tasks list row's second line, kept out of the SwiftUI body for the same reason
/// `TaskSearchPresentation` and `TaskDeletePresentation` are: this repository has no
/// view-rendering tests, so anything left inside a `body` is guarded only by the manual checklist.
///
/// **Why the workspace name moved here rather than staying a trailing column.** With the receipt
/// pane open the list narrowed to a 260 to 380pt column (phases 12 and 13; since the fifth round
/// it is `SonnyMetrics.tasksListShare` of the panel), and a trailing `Text(workspaceName)` was
/// spending that width on a second piece of metadata while the title — the thing a person
/// actually reads a row for — was truncated
/// to a few words (founder, 2026-09-10: "Allow claude a…", "Compare https://sim…"). Folding the
/// workspace into the row's existing status line, the way the receipt's own metadata row already
/// joins its phrases with " · ", gives the trailing edge back to the date alone.
enum TaskHistoryRowPresentation {
    /// `status` alone when there is no workspace name (or it is empty, which reads the same as
    /// none); `"\(status) · \(workspaceName)"` when there is one.
    static func detailLine(status: String, workspaceName: String?) -> String {
        guard let workspaceName, !workspaceName.isEmpty else {
            return status
        }
        return "\(status) · \(workspaceName)"
    }
}
