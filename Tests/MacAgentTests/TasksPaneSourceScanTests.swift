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

        // The branch with no selection holds the list alone: no split, no receipt (phase 12
        // review, F8), scoped to the first `else` after the gate rather than any `else` in the page.
        let gate = try #require(page.range(of: "if selectedTaskID != nil {"))
        let withoutSelection = try MacAgentSource.braceBlock(of: String(page[gate.upperBound...]), openedBy: "} else {")
        #expect(withoutSelection.contains("listPane"))
        #expect(!withoutSelection.contains("HSplitView"))
        #expect(!withoutSelection.contains("TaskReceiptView"))
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

        // The guard's polarity and the ternary's direction, pinned by their text (phase 12 review,
        // F5, F6 and F7): the override fires only for a task the current size does not show.
        #expect(consumeRequest.contains("if !shownAtCurrentSize.contains"))
        #expect(page.contains("showsAllForRequest ? .all : pageSize"))
        // A size that shrinks below the selection clears it through the refresh rule (F1).
        let onPageSize = try MacAgentSource.braceBlock(of: page, openedBy: ".onChange(of: pageSize) { _, newValue in")
        #expect(onPageSize.contains("TasksSelectionPresentation.selectionAfterRefresh(current: selectedTaskID, records: displayedRecords)"))
    }

    /// The row's own width goes to the title now (founder, 2026-09-10): the workspace name left the
    /// trailing column for the second line's `detailLine(`, and the toolbar drops to two rows,
    /// one-row candidate leading, rather than clip the search field further.
    @Test
    func theRowsTrailingEdgeHoldsNoWorkspaceTextAndTheToolbarOffersTheOneRowFormFirst() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")

        let row = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TaskHistoryRow: View {")
        #expect(row.components(separatedBy: "TaskHistoryRowPresentation.detailLine(").count - 1 == 1)
        // The shape, not one spelling: outside the `detailLine(` call, nothing in the row names the
        // workspace, so a trailing `Text(record.workspaceName ?? "")` cannot come back either
        // (phase 13 review, F3). The control: the call itself names it twice.
        #expect(row.components(separatedBy: "workspaceName").count - 1 == 2, "named only by the detailLine call: its label and its argument")
        #expect(!row.contains("Text(record.workspaceName"))
        #expect(!row.contains("Text(workspaceName"))
        // The tooltips carry the full texts, the title's with the same fallback its label has.
        #expect(row.contains(".help(record.command.isEmpty ? \"Untitled task\" : record.command)"))
        #expect(row.contains(".help(detailLine)"))
        // The accessibility label reads the same detail line the eye reads.
        let label = try MacAgentSource.region(of: row, from: ".accessibilityLabel(", to: ".accessibilityAddTraits(")
        #expect(label.contains("\\(detailLine)"))
        #expect(!label.contains("workspaceName"))

        let toolbar = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksToolbarRow: View {")
        let toolbarBody = try MacAgentSource.braceBlock(of: toolbar, openedBy: "var body: some View {")
        #expect(toolbarBody.contains(".frame(minHeight: density.toolbarHeight)"))

        let fits = try MacAgentSource.braceBlock(of: toolbarBody, openedBy: "ViewThatFits(in: .horizontal) {")
        let oneRow = try #require(fits.range(of: "HStack {"))
        // `SonnySpacing.md`, not `.sm` — phase 14's founder ask ("the spacing between each list
        // thing is very, very tight"): the picker row and the search row of the two-row candidate
        // now keep `.md` between them rather than the tighter `.sm` this pin held through phase 13.
        let twoRow = try #require(fits.range(of: "VStack(alignment: .leading, spacing: SonnySpacing.md) {"))
        #expect(oneRow.lowerBound < twoRow.lowerBound, "the one-row candidate must lead so it wins whenever it fits")
        // Both candidates hold the search field once; the hidden ⌘F button is built once, outside them.
        let narrow = try MacAgentSource.braceBlock(of: fits, openedBy: "VStack(alignment: .leading, spacing: SonnySpacing.md) {")
        #expect(narrow.components(separatedBy: "searchField(").count - 1 == 1)
        #expect(fits.components(separatedBy: "searchField(").count - 1 == 2)
        #expect(fits.components(separatedBy: "focusShortcutButton").count - 1 == 0)
        #expect(toolbarBody.components(separatedBy: "focusShortcutButton").count - 1 == 1)
        #expect(toolbar.components(separatedBy: ".keyboardShortcut(\"f\"").count - 1 == 1)
    }

    /// The founders' ask of 2026-09-10: the toolbar's content was sitting hard against the panel's
    /// top edge, and the two-line task rows had almost no air above or below their text. Both are
    /// now explicit literals rather than a `minHeight`-centered box or a single-line row height, so
    /// a regression to either shows up here by name.
    @Test
    func theToolbarKeepsItsMarginsAndTheRowsReadTwoLineHeight() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")

        let toolbar = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksToolbarRow: View {")
        let toolbarBody = try MacAgentSource.braceBlock(of: toolbar, openedBy: "var body: some View {")
        #expect(toolbarBody.contains(".padding(.top, SonnySpacing.md)"))
        #expect(toolbarBody.contains(".padding(.bottom, SonnySpacing.sm)"))

        let row = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TaskHistoryRow: View {")
        #expect(row.contains(".frame(height: density.twoLineRowHeight)"))
        #expect(!row.contains(".frame(height: density.listRowHeight)"))
    }
}
