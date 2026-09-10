import MacAgentCore
import SwiftUI

/// The pure matching and grouping behind the ⌘K jump-to palette (phase 5). Kept free of `SwiftUI`
/// so `Tests/MacAgentTests/JumpToPaletteTests.swift` can drive it directly, with no view host —
/// the same reason `TaskSectionCollapsePresentation` and the other `*Presentation` value types in
/// this target exist.
struct JumpToPalettePresentation {
    /// The most a group ever shows, whatever the query.
    static let groupCap = 8
    /// What an empty query shows of a group that is not Pages, since "most recent" only means
    /// something once there is more than a handful of it.
    static let defaultRecentCount = 5
    /// The working set Tasks searches over — the palette is a way to *jump*, not a second Tasks
    /// history browser, so it never reaches further back than this.
    static let recentTaskWindow = 20

    struct Row: Identifiable {
        enum Kind {
            case page(CommandCenterDestination)
            case routine(StoredRoutine)
            case workspace(StoredWorkspace)
            case task(CompletedTaskRecord)
        }

        let id: String
        let kind: Kind
        let title: String
        /// A page's ⌘-number, or a task's relative timestamp. `nil` for a routine or a workspace,
        /// which have nothing of their own to show on the trailing side.
        let trailing: String?
    }

    struct Group: Identifiable {
        let id: String
        let label: String
        let rows: [Row]
    }

    /// Only the groups that actually have a row — a header over nothing reads as a bug, not as
    /// "nothing here yet".
    let groups: [Group]

    /// Every row across every group, in the one order the sheet's ↑/↓ selection walks.
    var flattenedRows: [Row] {
        groups.flatMap(\.rows)
    }

    var isEmpty: Bool {
        groups.isEmpty
    }

    static func results(
        query: String,
        pages: [CommandCenterDestination],
        routines: [StoredRoutine],
        workspaces: [StoredWorkspace],
        tasks: [CompletedTaskRecord],
        now: Date
    ) -> JumpToPalettePresentation {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmptyQuery = trimmed.isEmpty

        // Pages are always present under an empty query (they have no "recent" notion to fall
        // back to — there are only five of them), and filtered by title otherwise. The ⌘-number is
        // the destination's own ordinal in `pages`, not its position after filtering, so it never
        // drifts from the sidebar's `sidebarButton(_:ordinal:)` wiring.
        let pageRows: [Row] = pages.enumerated()
            .filter { isEmptyQuery || matches(trimmed, $0.element.title) }
            .prefix(groupCap)
            .map { offset, destination in
                Row(
                    id: "page-\(destination.rawValue)",
                    kind: .page(destination),
                    title: destination.title,
                    trailing: "⌘\(offset + 1)"
                )
            }

        let matchingRoutines = routines.filter { isEmptyQuery || matches(trimmed, $0.name) }
        let routineRows: [Row] = mostRecentFirst(matchingRoutines, count: isEmptyQuery ? defaultRecentCount : groupCap)
            .map { routine in
                Row(id: "routine-\(routine.id)", kind: .routine(routine), title: routine.name, trailing: nil)
            }

        let matchingWorkspaces = workspaces.filter { isEmptyQuery || matches(trimmed, $0.name) }
        let workspaceRows: [Row] = mostRecentFirst(matchingWorkspaces, count: isEmptyQuery ? defaultRecentCount : groupCap)
            .map { workspace in
                Row(id: "workspace-\(workspace.name)", kind: .workspace(workspace), title: workspace.name, trailing: nil)
            }

        // Tasks carry their own timestamp, so "most recent" is a real sort rather than the
        // array-order guess `mostRecentFirst` makes for routines and workspaces below.
        let recentTasks = tasks.sorted { $0.startedAt > $1.startedAt }.prefix(recentTaskWindow)
        let matchingTasks = recentTasks.filter { isEmptyQuery || matches(trimmed, $0.command) }
        let taskLimit = isEmptyQuery ? defaultRecentCount : groupCap
        let taskRows: [Row] = matchingTasks.prefix(taskLimit).map { record in
            Row(
                id: "task-\(record.id ?? record.command)",
                kind: .task(record),
                title: record.command,
                trailing: TaskHistoryDateFormatter.relativeTimestamp(for: record.startedAt, now: now)
            )
        }

        let groups: [Group] = [
            Group(id: "pages", label: "Pages", rows: pageRows),
            Group(id: "routines", label: "Routines", rows: routineRows),
            Group(id: "workspaces", label: "Workspaces", rows: workspaceRows),
            Group(id: "tasks", label: "Tasks", rows: taskRows)
        ].filter { !$0.rows.isEmpty }

        return JumpToPalettePresentation(groups: groups)
    }

    private static func matches(_ query: String, _ title: String) -> Bool {
        title.range(of: query, options: .caseInsensitive) != nil
    }

    /// Routines and workspaces carry no timestamp of their own — `save(_:)` merges by name, and the
    /// store's own array order is the only signal of insertion order this target has. Read as
    /// oldest-first (every other reader of `savedRoutines`/`savedWorkspaces` assumes the same), so
    /// "most recent" is the last `count` elements, newest first.
    private static func mostRecentFirst<T>(_ items: [T], count: Int) -> [T] {
        Array(items.suffix(count).reversed())
    }
}

/// A Mac app people live in has one key that goes anywhere. ⌘K opens this from `CommandCenterView`;
/// Escape (via `.onExitCommand`, since this sheet has no header of its own to carry a close button)
/// closes it.
struct JumpToPaletteSheet: View {
    @ObservedObject var viewModel: AgentViewModel
    @EnvironmentObject private var commands: CommandCenterCommands
    @Binding var isPresented: Bool
    /// `CommandCenterView`'s only writer of `selection` — passed in rather than duplicated, the
    /// same reason `MemoryView` takes it.
    let select: (CommandCenterDestination) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private static let searchPrompt = "Jump to a page, routine, workspace or task"

    private var presentation: JumpToPalettePresentation {
        JumpToPalettePresentation.results(
            query: query,
            pages: CommandCenterDestination.allCases,
            routines: viewModel.savedRoutines,
            workspaces: viewModel.savedWorkspaces,
            tasks: viewModel.taskHistoryRecords,
            now: Date()
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            SettingsDivider()
            resultsList
        }
        .sonnyDialogFrame(width: SonnyDialogSize.regular.size.width, height: 420)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onExitCommand { isPresented = false }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            activateSelected()
            return .handled
        }
    }

    private var searchField: some View {
        TextField(Self.searchPrompt, text: $query)
            .padding(.leading, SonnySpacing.xl)
            .sonnyTextField(size: .regular)
            .focused($isSearchFocused)
            .overlay(alignment: .leading) {
                Image(systemName: "magnifyingglass")
                    .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                    .foregroundStyle(SonnyTheme.textTertiary)
                    .padding(.leading, SonnySpacing.sm)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(Self.searchPrompt)
            .padding(SonnySpacing.lg)
    }

    @ViewBuilder
    private var resultsList: some View {
        if presentation.isEmpty {
            CollectionEmptyState(
                systemImage: "magnifyingglass",
                title: "Nothing matches",
                message: "\"\(query)\"",
                minHeight: 120
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(presentation.groups) { group in
                        Text(group.label)
                            .font(SonnyType.caption)
                            .foregroundStyle(SonnyTheme.muted)
                            .padding(.horizontal, SonnySpacing.lg)
                            .padding(.top, SonnySpacing.md)
                            .padding(.bottom, SonnySpacing.xs)

                        ForEach(group.rows) { row in
                            JumpToPaletteRow(
                                row: row,
                                isSelected: isSelected(row),
                                activate: { activate(row) }
                            )
                        }
                    }
                }
                .padding(.bottom, SonnySpacing.md)
            }
        }
    }

    private func isSelected(_ row: JumpToPalettePresentation.Row) -> Bool {
        let rows = presentation.flattenedRows
        guard rows.indices.contains(selectedIndex) else { return false }
        return rows[selectedIndex].id == row.id
    }

    private func moveSelection(by delta: Int) {
        let rows = presentation.flattenedRows
        guard !rows.isEmpty else { return }
        selectedIndex = max(0, min(rows.count - 1, selectedIndex + delta))
    }

    private func activateSelected() {
        let rows = presentation.flattenedRows
        guard rows.indices.contains(selectedIndex) else { return }
        activate(rows[selectedIndex])
    }

    /// What activation does, and nothing else: a page navigates through `select`, a routine or a
    /// workspace hands its identity to `CommandCenterCommands` for that page's own detail sheet to
    /// pick up, a task asks the view model to open its detail — the same entry point a Tasks-page
    /// history row already uses. Then the sheet closes.
    private func activate(_ row: JumpToPalettePresentation.Row) {
        switch row.kind {
        case .page(let destination):
            select(destination)
        case .routine(let routine):
            commands.routineToOpen = routine.id
            select(.routines)
        case .workspace(let workspace):
            commands.workspaceToOpen = workspace.name
            select(.workspaces)
        case .task(let record):
            _ = viewModel.requestTaskDetail(taskID: record.id ?? record.command)
        }
        isPresented = false
    }
}

private struct JumpToPaletteRow: View {
    let row: JumpToPalettePresentation.Row
    let isSelected: Bool
    let activate: () -> Void
    @Environment(\.sonnyDensity) private var density

    var body: some View {
        Button(action: activate) {
            HStack(spacing: SonnySpacing.sm) {
                Image(systemName: systemImage)
                    .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                    .foregroundStyle(SonnyTheme.textTertiary)
                    .frame(width: 18)
                Text(row.title)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                Spacer(minLength: SonnySpacing.sm)
                if let trailing = row.trailing {
                    Text(trailing)
                        .font(trailingFont)
                        .foregroundStyle(SonnyTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            // Text sits at the palette's usual `lg` inset; the highlight itself is inset only
            // `sm` from the row's true edge (the `TaskHistoryRow` shape), so hovering shows a
            // floating rounded rect with air on every side instead of a fill flush with the
            // dialog's own edges (founder, 2026-09-10).
            .padding(.horizontal, SonnySpacing.lg - SonnySpacing.sm)
            .frame(height: density.listRowHeight)
            .background(
                RoundedRectangle(cornerRadius: SonnyRadius.control)
                    .fill(isSelected ? SonnyTheme.fillSelected : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
        .padding(.horizontal, SonnySpacing.sm)
        .accessibilityLabel(row.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var systemImage: String {
        switch row.kind {
        case .page(let destination):
            return destination.systemImage
        case .routine:
            return "repeat"
        case .workspace:
            return "rectangle.3.group"
        case .task:
            return "checkmark.circle"
        }
    }

    /// Pages carry a ⌘-number, which reads like the sidebar's own key caps; a task's relative
    /// timestamp is prose, which reads like the rest of the row.
    private var trailingFont: Font {
        switch row.kind {
        case .page:
            return SonnyType.mono
        case .routine, .workspace, .task:
            return SonnyType.caption
        }
    }
}
