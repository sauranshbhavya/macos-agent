import Testing
@testable import MacAgent

/// The task receipt's layout after the founder's 2026-09-10 passes, pinned by source scan since the
/// pane has no view test: the split as a fixed share, the candidate order of both `ViewThatFits`,
/// the `fixedSize` on every action button, and the delete confirmation on the node rendered once.
@MainActor
@Suite
struct TaskReceiptSourceScanTests {
    /// The founders' fifth round (2026-09-10): the list is 60% of the panel and the receipt 40%,
    /// as a share measured off the panel rather than an `HSplitView` with ideal widths, which
    /// keeps its divider where it was last dragged and so reads as 60/40 at one window size only.
    @Test
    func theSplitIsAFixedShareReadFromTheMetrics() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let page = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksFoundationView: View {")
        #expect(!page.contains("HSplitView"))
        let gate = try #require(page.range(of: "if selectedTaskID != nil {"))
        let withSelection = try MacAgentSource.braceBlock(of: String(page[gate.lowerBound...]), openedBy: "if selectedTaskID != nil {")
        // The bare token, not a closure signature: a second reader under another parameter name
        // would slip past "GeometryReader { proxy in" (phase 15 review, F1 of the rules lane).
        #expect(withSelection.components(separatedBy: "GeometryReader").count - 1 == 1)
        #expect(withSelection.contains("HStack(spacing: 0) {"))
        // The arithmetic lives in `TasksSplitPresentation` (unit-tested), and the view reads no
        // token of its own for the width: one call, its answer the list's frame.
        #expect(withSelection.components(separatedBy: "TasksSplitPresentation.listWidth(panelWidth: proxy.size.width)").count - 1 == 1)
        #expect(!withSelection.contains("SonnyMetrics.tasksListShare"))
        #expect(withSelection.contains("listPane\n                                .frame(width: listWidth)"))
        // The order is the layout: list, rule, receipt (the rules lane's F2 named the swap).
        let listRange = try #require(withSelection.range(of: "listPane"))
        let ruleRange = try #require(withSelection.range(of: "Rectangle()"))
        let receiptRange = try #require(withSelection.range(of: "TaskReceiptView("))
        #expect(listRange.lowerBound < ruleRange.lowerBound)
        #expect(ruleRange.lowerBound < receiptRange.lowerBound)
        // The receipt takes whatever the list leaves: its floor is applied by the arithmetic that
        // sizes the list, not by a frame of its own that would fight the HStack.
        let receipt = try #require(withSelection.range(of: "TaskReceiptView("))
        let receiptTail = String(withSelection[receipt.lowerBound...])
        #expect(receiptTail.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
        #expect(!receiptTail.contains("minWidth:"))
        #expect(!receiptTail.contains("idealWidth:"))
        // The rule between the two: the divider the split used to draw, the border token at the rule's width.
        #expect(withSelection.contains("Rectangle()\n                                .fill(SonnyTheme.border)\n                                .frame(width: SonnyMetrics.tasksSplitRuleWidth)"))
    }

    /// The one-line candidate comes first in both `ViewThatFits`, so the fallback is a fallback: swapped,
    /// the narrower candidate would always win and the pane would never read on one line.
    @Test
    func theOneLineCandidateLeadsInBothViewThatFits() throws {
        let source = try MacAgentSource.read("TaskReceiptView.swift")
        let header = try MacAgentSource.braceBlock(of: source, openedBy: "private func header(for record: CompletedTaskRecord) -> some View {")
        let headerFits = try MacAgentSource.braceBlock(of: header, openedBy: "ViewThatFits(in: .horizontal) {")
        let headerRow = try #require(headerFits.range(of: "HStack(spacing: SonnySpacing.sm) {"))
        let headerStack = try #require(headerFits.range(of: "VStack(alignment: .leading, spacing: SonnySpacing.xs) {"))
        #expect(headerRow.lowerBound < headerStack.lowerBound)

        let actions = try MacAgentSource.braceBlock(of: source, openedBy: "private func actionsRow(for record: CompletedTaskRecord) -> some View {")
        let actionsFits = try MacAgentSource.braceBlock(of: actions, openedBy: "ViewThatFits(in: .horizontal) {")
        let actionsRow = try #require(actionsFits.range(of: "HStack(spacing: SonnySpacing.sm) {"))
        let actionsStack = try #require(actionsFits.range(of: "VStack(alignment: .leading, spacing: SonnySpacing.sm) {"))
        #expect(actionsRow.lowerBound < actionsStack.lowerBound)
    }

    @Test
    func everyActionButtonIsFixedSizeSoNoLabelTruncates() throws {
        let source = try MacAgentSource.read("TaskReceiptView.swift")
        let buttons = try MacAgentSource.braceBlock(of: source, openedBy: "private func taskActionButtons(for record: CompletedTaskRecord) -> some View {")
        #expect(buttons.components(separatedBy: "Button(").count - 1 == 3)
        #expect(buttons.components(separatedBy: ".fixedSize()").count - 1 == 3)
    }

    /// A `confirmationDialog` on a node built once per `ViewThatFits` candidate is the shape SwiftUI has
    /// dropped a dialog for before in this app; the receipt's sits on the `ViewThatFits` itself.
    @Test
    func theDeleteConfirmationSitsOnTheNodeRenderedOnce() throws {
        let source = try MacAgentSource.read("TaskReceiptView.swift")
        let actions = try MacAgentSource.braceBlock(of: source, openedBy: "private func actionsRow(for record: CompletedTaskRecord) -> some View {")
        #expect(actions.components(separatedBy: ".confirmationDialog(").count - 1 == 1)
        #expect(actions.components(separatedBy: "moreActionsMenu").count - 1 == 2, "the menu is built once per candidate")
        let menu = try MacAgentSource.braceBlock(of: source, openedBy: "private var moreActionsMenu: some View {")
        #expect(!menu.contains(".confirmationDialog("))
    }
}
