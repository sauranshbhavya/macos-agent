import Testing
@testable import MacAgent

/// The task receipt's layout after the founder's 2026-09-10 pass, pinned by source scan since the
/// pane has no view test: the split's named widths, the candidate order of both `ViewThatFits`,
/// the `fixedSize` on every action button, and the delete confirmation on the node rendered once.
@MainActor
@Suite
struct TaskReceiptSourceScanTests {
    @Test
    func theSplitReadsItsWidthsFromTheMetrics() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let page = try MacAgentSource.braceBlock(of: source, openedBy: "private struct TasksFoundationView: View {")
        for token in ["SonnyMetrics.tasksListMinWidth", "SonnyMetrics.tasksListIdealWidth", "SonnyMetrics.tasksListMaxWidth",
                      "SonnyMetrics.taskReceiptMinWidth", "SonnyMetrics.taskReceiptIdealWidth"] {
            #expect(page.components(separatedBy: token).count - 1 == 1, "\(token) is read once by the split")
        }
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
