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
        // The row 12 page-size picker (the founders' ask of 2026-09-09) added a third argument.
        #expect(page.contains("TasksToolbarRow(viewModel: viewModel, isFocused: $isSearchFocused, pageSize: $pageSize)"))
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

    /// The founders' ask of 2026-09-09: "when no task is selected, the side panel should not be
    /// shown", and no more auto-selecting the first row just to make sure one always is. The close
    /// control is the other half of the same ask ("there is no way to close that view when a task
    /// is chosen") and lives in `TaskReceiptView.swift`, not this file — read from there rather than
    /// this page's own braceBlock.
    @Test
    func thePaneOnlyExistsWithASelectionAndTheOnAppearNoLongerPicksOne() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let page = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksFoundationView: View {")
        let onAppear = try MacAgentSource.braceBlock(of: page, openedBy: ".onAppear {")

        #expect(!onAppear.contains("TasksSelectionPresentation.next(after: nil"))
        #expect(!onAppear.contains("selectTask(id:"))
        #expect(page.contains("if selectedTaskID != nil {"))
        #expect(page.contains("onClose: { selectedTaskID = nil }"))

        let receipt = try MacAgentSource.read("TaskReceiptView.swift")
        #expect(receipt.contains("let onClose: () -> Void"))
        #expect(receipt.contains("\"Close task\""))
    }

    /// The page-size cap (the founders' ask of 2026-09-09, Gmail's "first 50 / 100" idiom) applies
    /// to the search-filtered records before they are grouped into sections, and a task requested
    /// from elsewhere that falls outside the cap still opens by showing everything for that visit.
    /// Read as a source scan since `showsAllForRequest` has no view test to drive it (its own doc
    /// comment says why).
    @Test
    func thePageSizeCapAppliesBeforeGroupingAndARequestedTaskOutsideItShowsAll() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let page = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksFoundationView: View {")

        #expect(page.contains("@State private var showsAllForRequest = false"))
        #expect(page.contains("TaskListPageSize.visible(searchFilteredRecords, size: effectivePageSize)"))
        #expect(page.contains(
            "TaskSectionPresentation.sections(\n            for: TaskHistoryGrouping.groupedByOutcome(records: displayedRecords),"
        ))

        let consumeRequest = try MacAgentSource.braceBlock(of: page, openedBy: "private func consumeTaskDetailRequest() {")
        #expect(consumeRequest.contains("showsAllForRequest = true"))

        let onChangePageSize = try MacAgentSource.braceBlock(of: page, openedBy: ".onChange(of: pageSize) { _, newValue in")
        #expect(onChangePageSize.contains("pageSizeStore.save(newValue)"))
        #expect(onChangePageSize.contains("showsAllForRequest = false"))

        let onDisappear = try MacAgentSource.braceBlock(of: page, openedBy: ".onDisappear {")
        #expect(onDisappear.contains("showsAllForRequest = false"))
    }
}
