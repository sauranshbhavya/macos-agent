import MacAgentCore
import SwiftUI

/// Tasks: what's running now and what finished, newest first. A private task never appears here
/// once it ends (decision 10).
struct TasksPage: View {
    @ObservedObject var model: SonnyAppModel
    @Environment(\.sonnyDensity) private var density
    @State private var search = ""
    @State private var selected: TaskID?
    @State private var isConfirmingDeleteAll = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.lg) {
            HStack(spacing: SonnySpacing.md) {
                CommandCenterPageHeader(title: "Tasks")
                Spacer()
                TextField("Search tasks", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($searchFocused)
                    .onExitCommand { search = "" }
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button("Delete all", role: .destructive) { isConfirmingDeleteAll = true }
                    .buttonStyle(SonnyButtonStyle(tone: .danger))
                    .disabled(model.desk.history.isEmpty)
            }

            HStack(alignment: .top, spacing: SonnySpacing.lg) {
                list
                    .frame(minWidth: 320, maxWidth: .infinity)
                    .commandCenterPanel()
                detail
                    .frame(width: 340)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .commandCenterPanel()
            }
        }
        .commandCenterPageFrame()
        .confirmationDialog("Delete every task in history?", isPresented: $isConfirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                selected = nil
                Task { await model.desk.deleteAllHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They're removed from this Mac.")
        }
    }

    // MARK: List

    private var running: [TaskSnapshot] {
        TasksPage.inProgress(model.controller.tasks, history: model.desk.history)
    }

    /// Unfinished tasks, newest first. A task already in history is finished, whatever its latest
    /// snapshot still says, so it is never listed twice.
    static func inProgress(_ tasks: [TaskSnapshot], history: [FinishedTask]) -> [TaskSnapshot] {
        let finished = Set(history.map(\.id))
        return tasks.filter { !$0.phase.isTerminal && !finished.contains($0.id) }.reversed()
    }

    private var finished: [FinishedTask] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.desk.history }
        return model.desk.history.filter {
            $0.goal.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var list: some View {
        if running.isEmpty && finished.isEmpty {
            if search.isEmpty {
                CollectionEmptyState(
                    systemImage: "checklist",
                    title: "No tasks yet",
                    message: "What you ask Sonny to do shows up here.",
                    action: .init(title: "Ask Sonny", run: model.showWidget)
                )
            } else {
                CollectionEmptyState(systemImage: "magnifyingglass", title: "No matches", message: "No task mentions \"\(search)\".")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Every row's identity is its group's as well as its task's: a lazy stack reuses a
                    // row by identity, and a task moving between the groups under one id showed the
                    // wrong heading and a stale row.
                    if !running.isEmpty {
                        groupHeader("In progress").id("heading-in-progress")
                        ForEach(running, id: \.id) { task in
                            row(title: task.goal, detail: task.progress ?? "Working…", icon: "circle.dotted", tint: SonnyTheme.accent, id: task.id) {
                                model.showWidget()
                            }
                            .id("in-progress-\(task.id)")
                        }
                    }
                    if !finished.isEmpty {
                        groupHeader("Finished").id("heading-finished")
                        ForEach(finished) { task in
                            row(
                                title: task.goal,
                                detail: TasksPage.relative(task.finishedAt),
                                icon: TasksPage.icon(for: task.outcome),
                                tint: TasksPage.tint(for: task.outcome),
                                id: task.id
                            ) { selected = task.id }
                            .id("finished-\(task.id)")
                        }
                    }
                }
                .padding(SonnySpacing.sm)
            }
        }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(SonnyType.microEmphasis)
            .foregroundStyle(SonnyTheme.muted)
            .padding(.horizontal, SonnySpacing.sm)
            .padding(.top, SonnySpacing.md)
            .padding(.bottom, SonnySpacing.xs)
    }

    private func row(title: String, detail: String, icon: String, tint: Color, id: TaskID, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(spacing: SonnySpacing.sm) {
                Image(systemName: icon)
                    .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                Spacer(minLength: SonnySpacing.sm)
                Text(detail)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, SonnySpacing.sm)
            .frame(height: density.listRowHeight)
            .background(RoundedRectangle(cornerRadius: SonnyRadius.control).fill(selected == id ? SonnyTheme.fillSelected : .clear))
            .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
        .accessibilityLabel("\(title), \(detail)")
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let task = model.desk.history.first(where: { $0.id == selected }) {
            ScrollView {
                VStack(alignment: .leading, spacing: SonnySpacing.md) {
                    Text(task.goal)
                        .font(SonnyType.headline)
                        .foregroundStyle(SonnyTheme.text)
                        .textSelection(.enabled)
                    Label(TasksPage.outcomeTitle(task.outcome), systemImage: TasksPage.icon(for: task.outcome))
                        .font(SonnyType.caption)
                        .foregroundStyle(TasksPage.tint(for: task.outcome))
                    Text(task.summary)
                        .font(SonnyType.body)
                        .foregroundStyle(SonnyTheme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !task.steps.isEmpty {
                        SettingsDivider()
                        VStack(alignment: .leading, spacing: SonnySpacing.sm) {
                            ForEach(Array(task.steps.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .top, spacing: SonnySpacing.sm) {
                                    Image(systemName: WidgetTaskPanel.icon(for: step.status))
                                        .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .medium))
                                        .foregroundStyle(step.status == .done ? SonnyTheme.success : SonnyTheme.muted)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(step.title).font(SonnyType.caption).foregroundStyle(SonnyTheme.text)
                                        if let evidence = step.evidence, !evidence.isEmpty {
                                            Text(evidence)
                                                .font(SonnyType.micro)
                                                .foregroundStyle(SonnyTheme.muted)
                                                .lineLimit(4)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SettingsDivider()
                    HStack(spacing: SonnySpacing.sm) {
                        Button("Follow up") { model.followUp(on: task.id, goal: task.goal) }
                            .buttonStyle(SonnyButtonStyle(tone: .secondary))
                        Button("Run again") { model.runAgain(task.goal) }
                            .buttonStyle(SonnyButtonStyle(tone: .secondary))
                        Spacer()
                        Button("Delete", role: .destructive) {
                            selected = nil
                            Task { await model.desk.deleteHistory(task.id) }
                        }
                        .buttonStyle(SonnyButtonStyle(tone: .danger))
                    }
                }
                .padding(SonnySpacing.lg)
            }
        } else {
            CollectionEmptyState(systemImage: "text.alignleft", title: "No task selected", message: "Pick a finished task to see what Sonny did.")
        }
    }

    // MARK: Words

    static func icon(for outcome: FinishedTask.Outcome) -> String {
        switch outcome {
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        }
    }

    static func tint(for outcome: FinishedTask.Outcome) -> Color {
        switch outcome {
        case .completed: SonnyTheme.success
        case .failed: SonnyTheme.warning
        case .cancelled: SonnyTheme.muted
        }
    }

    static func outcomeTitle(_ outcome: FinishedTask.Outcome) -> String {
        switch outcome {
        case .completed: "Done"
        case .failed: "Didn't finish"
        case .cancelled: "Stopped"
        }
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
