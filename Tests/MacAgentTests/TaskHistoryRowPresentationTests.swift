import Testing
@testable import MacAgent

/// The Tasks list row's second line, after the founder's 2026-09-10 ask to give the title back the
/// width a trailing workspace column was spending. Kept out of the SwiftUI body for the same reason
/// `TaskSearchPresentation` and `TaskDetailPresentation` are: this repository has no view-rendering
/// tests.
struct TaskHistoryRowPresentationTests {
    @Test
    func statusAloneWhenThereIsNoWorkspace() {
        let line = TaskHistoryRowPresentation.detailLine(status: "Completed in 8s", workspaceName: nil)

        #expect(line == "Completed in 8s")
        #expect(!line.contains("·"))
    }

    @Test
    func statusJoinsTheWorkspaceNameWithADot() {
        let line = TaskHistoryRowPresentation.detailLine(status: "Completed in 8s", workspaceName: "Research")

        #expect(line == "Completed in 8s · Research")
    }

    /// An empty workspace name reads the same as none — a record whose workspace was deleted
    /// resolves to an empty string upstream, not a genuine name, so it must not appear as one.
    @Test
    func anEmptyWorkspaceNameIsTreatedAsNone() {
        let line = TaskHistoryRowPresentation.detailLine(status: "Failed after 3s", workspaceName: "")

        #expect(line == "Failed after 3s")
        #expect(!line.contains("·"))
    }
}
