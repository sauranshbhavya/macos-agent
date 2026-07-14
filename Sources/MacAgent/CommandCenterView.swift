import Foundation
import MacAgentCore
import SwiftUI

enum CommandCenterDestination: String, CaseIterable, Identifiable {
    case tasks
    case insights
    case routines
    case workspaces
    case settings

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }

    var systemImage: String {
        switch self {
        case .tasks:
            return "checklist"
        case .insights:
            return "chart.bar.xaxis"
        case .routines:
            return "repeat"
        case .workspaces:
            return "rectangle.3.group"
        case .settings:
            return "gearshape"
        }
    }
}

struct CommandCenterView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var selection: CommandCenterDestination

    init(
        viewModel: AgentViewModel,
        initialSelection: CommandCenterDestination = .tasks
    ) {
        self.viewModel = viewModel
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(SonnyTheme.border)
                .frame(width: 1)

            destinationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(SonnyTheme.ink)
        .foregroundStyle(SonnyTheme.text)
        .tint(SonnyTheme.accent)
        .environment(\.sonnyPointerCursorsEnabled, viewModel.usePointerCursors)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshSavedItems()
            viewModel.refreshTaskHistory()
            viewModel.refreshClipboardHistoryNotice()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.sidebarIcon)
                        .fill(SonnyTheme.accent.opacity(0.16))
                    RoundedRectangle(cornerRadius: SonnyRadius.sidebarIcon)
                        .stroke(SonnyTheme.accent.opacity(0.42), lineWidth: 1)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SonnyTheme.accent)
                }
                .frame(width: 36, height: 36)

                Text("Sonny")
                    .font(SonnyType.panelTitle)
                    .foregroundStyle(SonnyTheme.text)
            }

            VStack(spacing: 5) {
                ForEach(CommandCenterDestination.allCases) { destination in
                    sidebarButton(destination)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 226)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }

    private func sidebarButton(_ destination: CommandCenterDestination) -> some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(destination.title)
                    .font(SonnyType.body)
                Spacer(minLength: 8)
                if destination == .tasks, viewModel.activeTaskCount > 0 {
                    Text("\(viewModel.activeTaskCount)")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.ink)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(SonnyTheme.accent)
                        .clipShape(Capsule())
                        .accessibilityLabel("One active task")
                }
            }
            .foregroundStyle(isSelected(destination) ? SonnyTheme.text : SonnyTheme.muted)
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .fill(isSelected(destination) ? SonnyTheme.surfaceRaised : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(isSelected(destination) ? SonnyTheme.border : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .accessibilityLabel(destination.title)
    }

    private func isSelected(_ destination: CommandCenterDestination) -> Bool {
        selection == destination
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch selection {
        case .tasks:
            TasksFoundationView(viewModel: viewModel)
        case .insights:
            InsightsView(viewModel: viewModel)
        case .routines:
            RoutinesView(viewModel: viewModel)
        case .workspaces:
            WorkspacesView(viewModel: viewModel)
        case .settings:
            SettingsFoundationView(viewModel: viewModel)
        }
    }
}

private struct TasksFoundationView: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CommandCenterPageHeader(
                        title: "Tasks",
                        subtitle: "Your current Sonny task, live across both surfaces."
                    )

                    if viewModel.hasTaskActivity {
                        CommandCenterTaskActivitySurface(viewModel: viewModel)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("No active task", systemImage: "checkmark.circle")
                                .font(SonnyType.bodyEmphasis)
                                .foregroundStyle(SonnyTheme.text)
                            Text("Start a command below or from the menu-bar cockpit. The same task will appear here immediately.")
                                .font(SonnyType.body)
                                .foregroundStyle(SonnyTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SonnyTheme.surfaceRaised.opacity(0.46))
                        .overlay(
                            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                                .stroke(SonnyTheme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
                    }

                    TaskHistoryListPanel(
                        records: Array(viewModel.taskHistoryRecords.prefix(10)),
                        title: "Recent task history",
                        emptyTitle: "No completed tasks yet",
                        emptyMessage: "Run or cancel a Sonny task and it will appear here."
                    )
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            CommandCenterComposerFooter(viewModel: viewModel)
        }
        .background(SonnyTheme.ink)
        .onAppear {
            viewModel.refreshTaskHistory()
        }
    }
}

private struct CommandCenterTaskActivitySurface: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        AgentTaskActivityView(viewModel: viewModel, showsStartupWhenEmpty: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
    }
}

private struct InsightsView: View {
    @ObservedObject var viewModel: AgentViewModel

    private var summary: TaskHistoryInsightsSummary {
        TaskHistoryInsights.summarize(records: viewModel.taskHistoryRecords, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CommandCenterPageHeader(title: "Insights")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InsightsStatRow(summary: summary)
                    WeeklyCompletionChart(counts: summary.weeklyCompletedCounts)
                    TaskHistoryListPanel(
                        records: Array(viewModel.taskHistoryRecords.prefix(6)),
                        title: "Recent activity",
                        emptyTitle: "No activity yet",
                        emptyMessage: "Completed, failed, and canceled Sonny tasks will appear here."
                    )
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CommandCenterPalette.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
        .onAppear {
            viewModel.refreshTaskHistory()
        }
    }
}

private struct InsightsStatRow: View {
    let summary: TaskHistoryInsightsSummary

    private var stats: [InsightStatPresentation] {
        [
            .completedThisWeek(summary),
            .completionRate(summary),
            .averageCycleTime(summary),
            .currentStreak(summary)
        ]
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(stats) { stat in
                InsightStatCard(stat: stat)
            }
        }
    }
}

private struct InsightStatCard: View {
    let stat: InsightStatPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(stat.label)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)

            Text(stat.value)
                .font(SonnyType.heroStat)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(stat.delta)
                .font(SonnyType.micro)
                .foregroundStyle(stat.isPositiveDelta ? SonnyTheme.success : SonnyTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }
}

private struct WeeklyCompletionChart: View {
    let counts: [Int]

    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private var maxCount: Int { counts.max() ?? 0 }
    private var peakIndex: Int? {
        guard maxCount > 0 else {
            return nil
        }
        return counts.firstIndex(of: maxCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tasks completed this week")
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 9) {
                        GeometryReader { proxy in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(index == peakIndex ? SonnyTheme.accent : SonnyTheme.chartBarMuted)
                                    .frame(
                                        width: 24,
                                        height: barHeight(for: counts[safe: index] ?? 0, availableHeight: proxy.size.height)
                                    )
                                    .opacity((counts[safe: index] ?? 0) == 0 ? 0 : 1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(height: 112)

                        Text(day)
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day): \(counts[safe: index] ?? 0) completed task\(counts[safe: index] == 1 ? "" : "s")")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }

    private func barHeight(for count: Int, availableHeight: CGFloat) -> CGFloat {
        guard maxCount > 0, count > 0 else {
            return 0
        }
        return max(12, CGFloat(count) / CGFloat(maxCount) * availableHeight)
    }
}

private struct TaskHistoryListPanel: View {
    let records: [CompletedTaskRecord]
    let title: String
    let emptyTitle: String
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(emptyTitle)
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                    Text(emptyMessage)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        TaskHistoryRow(record: record)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }
}

private struct TaskHistoryRow: View {
    let record: CompletedTaskRecord

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.command.isEmpty ? "Untitled task" : record.command)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(statusText)
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.command), \(statusText), \(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))")
    }

    private var statusColor: Color {
        switch record.outcomeStatus {
        case .completed:
            return SonnyTheme.success
        case .failed:
            return SonnyTheme.danger
        case .canceled:
            return SonnyTheme.muted
        default:
            return SonnyTheme.muted
        }
    }

    private var statusText: String {
        let duration = TaskHistoryDurationFormatter.short(record.completedAt.timeIntervalSince(record.startedAt))
        switch record.outcomeStatus {
        case .completed:
            return "Completed in \(duration)"
        case .failed:
            return "Failed after \(duration)"
        case .canceled:
            return "Canceled after \(duration)"
        default:
            return record.outcomeStatus.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }
}

private struct InsightStatPresentation: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let delta: String
    let isPositiveDelta: Bool

    static func completedThisWeek(_ summary: TaskHistoryInsightsSummary) -> Self {
        let difference = summary.completedThisWeek - summary.previousWeekCompleted
        return Self(
            id: "completed-this-week",
            label: "Completed this week",
            value: "\(summary.completedThisWeek)",
            delta: deltaCountText(difference),
            isPositiveDelta: difference > 0
        )
    }

    static func completionRate(_ summary: TaskHistoryInsightsSummary) -> Self {
        let currentPercent = Int((summary.completionRate * 100).rounded())
        let previousPercent = Int((summary.previousWeekCompletionRate * 100).rounded())
        let difference = currentPercent - previousPercent
        return Self(
            id: "completion-rate",
            label: "Completion rate",
            value: "\(currentPercent)%",
            delta: deltaPercentText(difference),
            isPositiveDelta: difference > 0
        )
    }

    static func averageCycleTime(_ summary: TaskHistoryInsightsSummary) -> Self {
        let value = summary.averageCompletedCycleTime.map(TaskHistoryDurationFormatter.short) ?? "—"
        let delta: String
        let isPositive: Bool
        if let current = summary.averageCompletedCycleTime,
           let previous = summary.previousWeekAverageCompletedCycleTime {
            let difference = previous - current
            delta = difference == 0
                ? "No change"
                : "\(TaskHistoryDurationFormatter.short(abs(difference))) \(difference > 0 ? "faster" : "slower")"
            isPositive = difference > 0
        } else {
            delta = "No comparison available yet"
            isPositive = false
        }
        return Self(
            id: "average-cycle-time",
            label: "Avg cycle time",
            value: value,
            delta: delta,
            isPositiveDelta: isPositive
        )
    }

    static func currentStreak(_ summary: TaskHistoryInsightsSummary) -> Self {
        let days = summary.currentStreakDays
        let delta: String
        if days == 0 {
            delta = "No active streak"
        } else if summary.hasCompletedToday {
            delta = "Active today"
        } else {
            delta = "Keep it going today"
        }
        return Self(
            id: "current-streak",
            label: "Current streak",
            value: "\(days) day\(days == 1 ? "" : "s")",
            delta: delta,
            isPositiveDelta: days > 0
        )
    }

    private static func deltaCountText(_ difference: Int) -> String {
        if difference > 0 {
            return "+\(difference) vs last week"
        }
        if difference < 0 {
            return "\(difference) vs last week"
        }
        return "No change"
    }

    private static func deltaPercentText(_ difference: Int) -> String {
        if difference > 0 {
            return "+\(difference)%"
        }
        if difference < 0 {
            return "\(difference)%"
        }
        return "No change"
    }
}

private enum TaskHistoryDurationFormatter {
    static func short(_ rawDuration: TimeInterval) -> String {
        let duration = max(0, rawDuration)
        if duration < 60 {
            return "\(Int(duration.rounded()))s"
        }
        if duration < 60 * 60 {
            return "\(Int((duration / 60).rounded()))m"
        }
        if duration < 24 * 60 * 60 {
            let hours = duration / (60 * 60)
            return formatted(hours) + "h"
        }
        let days = duration / (24 * 60 * 60)
        return formatted(days) + "d"
    }

    private static func formatted(_ value: Double) -> String {
        if value >= 10 || value.rounded() == value {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}

private enum TaskHistoryDateFormatter {
    static func relativeTimestamp(
        for date: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        return dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct RoutineRowPresentation: Equatable {
    let name: String
    let stepCount: Int
    let stepCountText: String
    let detailText: String

    init(routine: StoredRoutine) {
        name = routine.name
        stepCount = routine.steps.count
        stepCountText = "\(routine.steps.count)"

        let visibleLabels = routine.steps.prefix(2).map(AgentActivityPresentation.operationTitle)
        let remainingCount = routine.steps.count - visibleLabels.count
        let visibleText = visibleLabels.joined(separator: " · ")
        if remainingCount > 0 {
            detailText = "\(visibleText) · +\(remainingCount) more"
        } else if visibleText.isEmpty {
            detailText = "No saved steps"
        } else {
            detailText = visibleText
        }
    }
}

struct WorkspaceCardPresentation: Equatable {
    let name: String
    let initial: String
    let savedItemCount: Int
    let savedItemCountText: String
    let appsText: String?
    let urlsText: String?

    init(workspace: StoredWorkspace) {
        name = workspace.name
        initial = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .first.map { String($0).uppercased() } ?? "W"
        savedItemCount = workspace.apps.count + workspace.urls.count
        savedItemCountText = "\(savedItemCount) saved item\(savedItemCount == 1 ? "" : "s")"
        appsText = workspace.apps.isEmpty ? nil : workspace.apps.joined(separator: ", ")
        urlsText = workspace.urls.isEmpty ? nil : workspace.urls.map(Self.shortURL).joined(separator: ", ")
    }

    private static func shortURL(_ rawValue: String) -> String {
        guard let url = URL(string: rawValue), let host = url.host else {
            return rawValue
        }
        return host.replacingOccurrences(of: "www.", with: "", options: .anchored)
    }
}

private struct RoutinesView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var composerFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                CommandCenterPageHeader(title: "Routines")

                VStack(spacing: 0) {
                    CollectionHeader(
                        title: "All routines",
                        actionTitle: "New routine",
                        action: beginNewRoutine
                    )

                    Rectangle()
                        .fill(SonnyTheme.border)
                        .frame(height: 1)

                    if viewModel.savedRoutines.isEmpty {
                        CollectionEmptyState(
                            systemImage: "repeat",
                            title: "No routines yet",
                            message: "Ask Sonny to save a repeatable sequence, then it will appear here."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(viewModel.savedRoutines.enumerated()), id: \.element.name) { index, routine in
                                    RoutineRow(
                                        presentation: RoutineRowPresentation(routine: routine),
                                        isLast: index == viewModel.savedRoutines.count - 1,
                                        isRunning: viewModel.isRunning || viewModel.isAwaitingApproval,
                                        run: { viewModel.runRoutineWidget(routine) }
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(CommandCenterPalette.collectionSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: SonnyRadius.container)
                        .stroke(SonnyTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))

                if viewModel.hasTaskActivity {
                    CommandCenterTaskActivitySurface(viewModel: viewModel)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CommandCenterComposerFooter(
                viewModel: viewModel,
                focusRequest: composerFocusRequest
            )
        }
        .background(SonnyTheme.ink)
    }

    private func beginNewRoutine() {
        viewModel.command = "Create a routine called "
        composerFocusRequest += 1
    }
}

private struct RoutineRow: View {
    let presentation: RoutineRowPresentation
    let isLast: Bool
    let isRunning: Bool
    let run: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.routineIcon)
                        .fill(CommandCenterPalette.routineIconBackground)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CommandCenterPalette.routineIconForeground)
                        .frame(width: 10, height: 10)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.name)
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                        .lineLimit(1)
                    Text(presentation.detailText)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 14)

                HStack(spacing: 6) {
                    Circle()
                        .fill(SonnyTheme.warning)
                        .frame(width: 8, height: 8)
                    Text(presentation.stepCountText)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.warning)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(presentation.stepCount) saved steps")

                Button(action: run) {
                    Text("Run")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel("Run \(presentation.name)")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if !isLast {
                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(height: 1)
            }
        }
    }
}

private struct WorkspacesView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var composerFocusRequest = 0

    private let columns = [
        GridItem(.adaptive(minimum: 356, maximum: 356), spacing: 14, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                CommandCenterPageHeader(title: "Workspaces")

                VStack(spacing: 0) {
                    CollectionHeader(
                        title: "All workspaces",
                        actionTitle: "Create workspace",
                        action: beginNewWorkspace
                    )

                    Rectangle()
                        .fill(SonnyTheme.border)
                        .frame(height: 1)

                    if viewModel.savedWorkspaces.isEmpty {
                        CollectionEmptyState(
                            systemImage: "rectangle.3.group",
                            title: "No workspaces yet",
                            message: "Ask Sonny to group apps and safe URLs for one-click opening."
                        )
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(viewModel.savedWorkspaces, id: \.name) { workspace in
                                    WorkspaceCard(
                                        presentation: WorkspaceCardPresentation(workspace: workspace),
                                        accent: SonnyTheme.accent,
                                        isRunning: viewModel.isRunning || viewModel.isAwaitingApproval,
                                        open: { viewModel.openWorkspaceWidget(workspace) }
                                    )
                                }
                                CreateWorkspaceGhostCard(action: beginNewWorkspace)
                            }
                            .padding(18)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(CommandCenterPalette.collectionSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: SonnyRadius.container)
                        .stroke(SonnyTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))

                if viewModel.hasTaskActivity {
                    CommandCenterTaskActivitySurface(viewModel: viewModel)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CommandCenterComposerFooter(
                viewModel: viewModel,
                focusRequest: composerFocusRequest
            )
        }
        .background(SonnyTheme.ink)
    }

    private func beginNewWorkspace() {
        viewModel.command = "Create a workspace called "
        composerFocusRequest += 1
    }
}

private struct WorkspaceCard: View {
    let presentation: WorkspaceCardPresentation
    let accent: Color
    let isRunning: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(presentation.initial)
                .font(SonnyType.avatar)
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .background(accent.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard))

            Text(presentation.name)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .padding(.top, 14)

            Text(presentation.savedItemCountText)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                if let appsText = presentation.appsText {
                    Label(appsText, systemImage: "app.dashed")
                }
                if let urlsText = presentation.urlsText {
                    Label(urlsText, systemImage: "link")
                }
            }
            .font(SonnyType.micro)
            .foregroundStyle(SonnyTheme.muted)
            .lineLimit(1)
            .padding(.top, 12)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button(action: open) {
                    Text("Open")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel("Open \(presentation.name)")
            }
        }
        .padding(18)
        .frame(maxWidth: 356, minHeight: 190, maxHeight: 190, alignment: .topLeading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard))
    }
}

private struct CreateWorkspaceGhostCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("+ Create workspace")
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                Text("Start a new team or personal space")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 356, minHeight: 190, maxHeight: 190)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .stroke(
                    SonnyTheme.border,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard))
        .sonnyPointerCursor()
        .accessibilityLabel("Create workspace")
        .accessibilityHint("Start a new team or personal space")
    }
}

private struct CollectionHeader: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
            Spacer()
            Button(action: action) {
                Label(actionTitle, systemImage: "plus")
            }
            .buttonStyle(CommandCenterHeaderActionStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
    }
}

private struct CollectionEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(SonnyTheme.muted)
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
            Text(message)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(24)
    }
}

private struct CommandCenterComposerFooter: View {
    @ObservedObject var viewModel: AgentViewModel
    var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SonnyTheme.border)
                .frame(height: 1)

            AgentCommandComposerView(
                viewModel: viewModel,
                autoFocus: false,
                focusRequest: focusRequest
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .background(CommandCenterPalette.composerSurface)
    }
}

private struct CommandCenterHeaderActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.microEmphasis)
            .foregroundStyle(SonnyTheme.text.opacity(configuration.isPressed ? 0.7 : 0.92))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CommandCenterPalette.buttonSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
            .sonnyPointerCursor()
            .opacity(isEnabled ? 1 : 0.46)
    }
}

private struct CommandCenterRowActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.microEmphasis)
            .foregroundStyle(SonnyTheme.text.opacity(configuration.isPressed ? 0.68 : 0.92))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(CommandCenterPalette.buttonSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
            .sonnyPointerCursor()
            .opacity(isEnabled ? 1 : 0.46)
    }
}

private enum CommandCenterPalette {
    static let collectionSurface = SonnyTheme.collectionSurface
    static let cardSurface = SonnyTheme.surfaceRaised
    static let buttonSurface = SonnyTheme.surfaceRaised
    static let composerSurface = SonnyTheme.collectionSurface
    static let routineIconBackground = SonnyTheme.accent.opacity(0.18)
    static let routineIconForeground = SonnyTheme.accent
}

private struct CommandCenterPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CommandCenterPageHeader(title: title, subtitle: "The shared product shell is ready for this section.")

            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(SonnyTheme.accent)
                Text(message)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
            }
            .padding(18)
            .frame(maxWidth: 520, alignment: .leading)
            .background(SonnyTheme.surfaceRaised.opacity(0.42))
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }
}

private struct CommandCenterPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SonnyType.hero)
                .foregroundStyle(SonnyTheme.text)
            if let subtitle {
                Text(subtitle)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
            }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case preferences
    case privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .preferences:
            return "Preferences"
        case .privacy:
            return "Privacy & Permissions"
        }
    }

    var detail: String {
        switch self {
        case .preferences:
            return "Interface behavior"
        case .privacy:
            return "Readiness and local data"
        }
    }

    var systemImage: String {
        switch self {
        case .preferences:
            return "switch.2"
        case .privacy:
            return "hand.raised"
        }
    }
}

private struct SettingsFoundationView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var selection: SettingsSection = .preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CommandCenterPageHeader(title: "Settings")

            HStack(spacing: 0) {
                settingsSidebar

                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(width: 1)

                ScrollView {
                    Group {
                        switch selection {
                        case .preferences:
                            SettingsPreferencesPage(viewModel: viewModel)
                        case .privacy:
                            SettingsPrivacyPage(viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SonnyTheme.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(SonnyType.body)
                                .lineLimit(1)
                            Text(section.detail)
                                .font(SonnyType.micro)
                                .foregroundStyle(SonnyTheme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == section ? SonnyTheme.text : SonnyTheme.muted)
                    .padding(.horizontal, 11)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: SonnyRadius.container)
                            .fill(selection == section ? SonnyTheme.surfaceRaised : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .accessibilityLabel(section.title)
            }

            Spacer()
        }
        .padding(14)
        .frame(width: 226, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsPreferencesPage: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageTitle(title: "Preferences", subtitle: "Manage your preferences")

            SettingsSectionBlock(title: "Display") {
                SettingsToggleRow(
                    title: "Use pointer cursors",
                    detail: "Change the cursor to a pointer when hovering over any interactive element.",
                    isOn: $viewModel.usePointerCursors
                )
            }

            SettingsSectionBlock(title: "Theme") {
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(
                        title: "Interface theme",
                        detail: "Select or customize your interface color scheme."
                    )
                } trailing: {
                    HStack(spacing: 8) {
                        SettingsThemeOption(title: "Dark", isSelected: true, isDisabled: false)
                        SettingsThemeOption(title: "Light", isSelected: false, isDisabled: true)
                        SettingsThemeOption(title: "System", isSelected: false, isDisabled: true)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(maxWidth: 700, alignment: .topLeading)
    }
}

private struct SettingsPrivacyPage: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var showDeleteLocalDataConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageTitle(title: "Privacy & Permissions", subtitle: "Review local readiness and data controls")

            SettingsSectionBlock(title: "Permission readiness") {
                VStack(alignment: .leading, spacing: 14) {
                    PermissionReadinessRows(items: viewModel.permissionItems)

                    Button {
                        viewModel.refreshPermissions()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CommandCenterRowActionStyle())
                    .accessibilityLabel("Refresh permission readiness")
                }
                .padding(.vertical, 16)
            }

            SettingsSectionBlock(title: "Local data") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsAdaptiveControlRow {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "trash")
                                .font(SonnyType.icon(15))
                                .foregroundStyle(SonnyTheme.danger)
                                .frame(width: 20)

                            SettingsControlLabel(
                                title: "Delete Sonny local data",
                                detail: "Saved routines, workspaces, clipboard history, snippets, recent artifacts, Shortcut run history, task history, and clipboard settings."
                            )
                        }
                    } trailing: {
                        Button {
                            showDeleteLocalDataConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(SonnyButtonStyle(tone: .danger, width: 96))
                        .disabled(viewModel.isRunning)
                        .help("Delete local Sonny data")
                    }

                    if let message = viewModel.localDataDeletionStatusMessage {
                        Label(message, systemImage: message.hasPrefix("Deleted") ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(SonnyType.micro)
                            .foregroundStyle(message.hasPrefix("Deleted") ? SonnyTheme.accent : SonnyTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: 760, alignment: .topLeading)
        .onAppear {
            viewModel.refreshPermissions()
        }
        .confirmationDialog(
            "Delete Sonny Local Data?",
            isPresented: $showDeleteLocalDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Local Data", role: .destructive) {
                viewModel.deleteLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes saved routines, workspaces, clipboard history, snippets, recent artifacts, Shortcut run history, task history, and clipboard settings. Generated files and API keys are not deleted.")
        }
    }
}

private struct SettingsAdaptiveControlRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                leading
                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)

                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
    }
}

private struct SettingsControlLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsPageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(SonnyType.hero)
                .foregroundStyle(SonnyTheme.text)
            Text(subtitle)
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.muted)
        }
        .padding(.bottom, 2)
    }
}

private struct SettingsSectionBlock<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SonnyTheme.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsAdaptiveControlRow {
            SettingsControlLabel(title: title, detail: detail)
        } trailing: {
            SonnySettingsToggle(isOn: $isOn)
                .accessibilityLabel(title)
        }
    }
}

private struct SonnySettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: SonnyRadius.pill)
                    .fill(isOn ? SonnyTheme.accent : SonnyTheme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: SonnyRadius.pill)
                            .stroke(isOn ? SonnyTheme.accent : SonnyTheme.cardBorder, lineWidth: 1)
                    )

                Circle()
                    .fill(SonnyTheme.text)
                    .frame(width: 14, height: 14)
                    .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 0)
                    .padding(3)
            }
            .frame(width: 34, height: 20)
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct SettingsThemeOption: View {
    let title: String
    let isSelected: Bool
    let isDisabled: Bool

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? SonnyTheme.accent : SonnyTheme.muted)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(SonnyType.microEmphasis)
                    .foregroundStyle(isDisabled ? SonnyTheme.muted : SonnyTheme.text)
            }
            if isDisabled {
                Text("Soon")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 72, minHeight: 42)
        .background(isSelected ? SonnyTheme.surfaceRaised : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.themeSwatch)
                .stroke(isSelected ? SonnyTheme.accent.opacity(0.72) : SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.themeSwatch))
        .opacity(isDisabled ? 0.58 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isDisabled ? "\(title) theme, coming soon" : "\(title) theme, selected")
    }
}
