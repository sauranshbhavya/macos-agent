import Testing
@testable import MacAgent

/// The Tasks page's list beside its pane (phase 11 of ui-ux-claude), pinned by source scan since
/// the page has no view test. Two review skeptics read SwiftUI's key routing two ways, whether a
/// ⌫ typed into the focused search field can reach the page's `.onKeyPress(.delete)`; the focus
/// guard is right under either reading, and the first test holds that every list key carries it.
@Suite
@MainActor
struct TasksPaneSourceScanTests {
    @Test
    func everyListKeyHandlerStandsAsideWhileTheSearchFieldHasFocus() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let page = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksFoundationView: View {")

        #expect(page.components(separatedBy: ".onKeyPress(").count - 1 == 3)
        #expect(page.components(separatedBy: "guard !isSearchFocused else { return .ignored }").count - 1 == 3)
        #expect(page.contains("@FocusState private var isSearchFocused: Bool"))
        #expect(page.contains("TasksToolbarRow(viewModel: viewModel, isFocused: $isSearchFocused)"))
    }

    /// The receipt's delete leaves the selection to the history refresh, which clears it only when
    /// the record is gone; a refused delete keeps the task and its receipt on screen (review, F1).
    @Test
    func theReceiptsDeleteDoesNotClearTheSelectionItself() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let page = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksFoundationView: View {")
        let onDelete = try MacAgentSource.braceBlock(of: page, openedBy: "onDeleteTask: {")

        #expect(onDelete.contains("viewModel.deleteTask(selectedRecord)"))
        #expect(!onDelete.contains("selectedTaskID = nil"))
        // The control: the refresh path is the one that clears it, and it is still wired.
        #expect(page.contains("TasksSelectionPresentation.selectionAfterRefresh(current: selectedTaskID, records: records)"))
    }
}
