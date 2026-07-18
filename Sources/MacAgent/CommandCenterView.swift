import AppKit
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
            HStack(spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: SonnyRadius.sidebarIcon)
                            .fill(SonnyTheme.accent.opacity(0.16))
                        RoundedRectangle(cornerRadius: SonnyRadius.sidebarIcon)
                            .stroke(SonnyTheme.accent.opacity(0.42), lineWidth: 1)
                        Image(systemName: "wand.and.stars")
                            .font(SonnyType.icon(16, weight: .medium))
                            .foregroundStyle(SonnyTheme.accent)
                    }
                    .frame(width: 36, height: 36)

                    HStack(spacing: 6) {
                        Text("Sonny")
                            .font(SonnyType.panelTitle)
                            .foregroundStyle(SonnyTheme.text)
                        // Wireframe shows a dropdown affordance next to the wordmark
                        // (`9-MainAppHomeScreen.svg:33`). Built as static chrome matching the
                        // wireframe's visual — no menu exists behind it; nothing in Sonny's
                        // current scope defines what it would open.
                        Image(systemName: "chevron.down")
                            .font(SonnyType.icon(9, weight: .semibold))
                            .foregroundStyle(SonnyTheme.muted)
                    }
                }

                Spacer(minLength: 8)

                // Wireframe search affordance (`9-MainAppHomeScreen.svg:38`). Same treatment as
                // the chevron above — static, no search feature exists behind it yet.
                Image(systemName: "magnifyingglass")
                    .font(SonnyType.icon(13, weight: .medium))
                    .foregroundStyle(SonnyTheme.muted)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: SonnyRadius.container)
                            .fill(SonnyTheme.surfaceRaised)
                    )
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
        .frame(width: 275)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }

    private func sidebarButton(_ destination: CommandCenterDestination) -> some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(SonnyType.icon(14, weight: .medium))
                    .frame(width: 18)
                Text(destination.title)
                    .font(SonnyType.body)
                Spacer(minLength: 8)
                if destination == .tasks, viewModel.activeTaskCount > 0 {
                    // Shape/fill match the wireframe's rounded-rect badge (`rx=4`, `#151619`) —
                    // its "22" count itself doesn't map to anything Sonny has (likely a Linear
                    // inbox-unread placeholder), so the conditional active-task display stays.
                    Text("\(viewModel.activeTaskCount)")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.text)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(SonnyTheme.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
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
            VStack(alignment: .leading, spacing: 18) {
                CommandCenterPageHeader(title: greeting)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
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

                        TaskHistoryGroupedPanel(records: viewModel.taskHistoryRecords)
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
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CommandCenterComposerFooter(viewModel: viewModel)
        }
        .background(SonnyTheme.ink)
        .onAppear {
            viewModel.refreshTaskHistory()
        }
    }

    /// Wireframe shows a time-of-day greeting ("Good Afternoon, User") in this exact slot
    /// (`9-MainAppHomeScreen.svg`) rather than a static page title. `NSFullUserName()` is the
    /// same macOS-account name source `DocumentConverter` already uses elsewhere in this codebase;
    /// `displayFullNames` (Settings) governs full vs. first-name-only, matching that toggle's
    /// existing meaning rather than inventing a second name-formatting rule.
    private var greeting: String {
        TaskGreetingFormatter.greeting(
            hour: Calendar.current.component(.hour, from: Date()),
            fullName: NSFullUserName(),
            displayFullNames: viewModel.displayFullNames
        )
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

    private var workspaceBreakdown: [WorkspaceTaskBreakdownEntry] {
        WorkspaceTaskBreakdown.summarize(records: viewModel.taskHistoryRecords, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CommandCenterPageHeader(title: "Insights")

            ScrollView {
                // No "Overview" (or other) section-group label — neither the wireframe nor
                // founder-decisions doc calls for one, and it was previously applied to only
                // one of these four sections rather than consistently to all of them.
                VStack(alignment: .leading, spacing: 16) {
                    InsightsOverviewBento(summary: summary)

                    WeeklyCompletionChart(counts: summary.weeklyCompletedCounts)

                    WorkspaceBreakdownPanel(entries: workspaceBreakdown)

                    TaskHistoryListPanel(
                        records: RecentCompletedTasks.recent(from: viewModel.taskHistoryRecords, limit: 6),
                        title: "Recently completed",
                        emptyTitle: "No activity yet",
                        emptyMessage: "Completed Sonny tasks will appear here."
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

/// Deliberately asymmetric, per `docs/sonny-founder-design-decisions.md`'s explicit verbal
/// direction — the wireframe export's own layout is uniform/symmetric and is NOT authoritative
/// here (unlike checkpoints 1-2, where the wireframe measurements were). A large flexible hero
/// tile, a stacked pair of medium tiles, and one tall narrow tile give three genuinely different
/// tile footprints from the same 4 stats, Apple-keynote/bento style rather than a uniform grid.
private struct InsightsOverviewBento: View {
    let summary: TaskHistoryInsightsSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            InsightStatCard(stat: .completedThisWeek(summary), size: .hero)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                InsightStatCard(stat: .completionRate(summary), size: .compact)
                InsightStatCard(stat: .averageCycleTime(summary), size: .compact)
            }
            .frame(width: 200)

            InsightStatCard(stat: .currentStreak(summary), size: .tall)
                .frame(width: 160)
        }
    }
}

private enum InsightStatCardSize: Equatable {
    case hero
    case compact
    case tall

    var minHeight: CGFloat {
        switch self {
        case .hero, .tall:
            return 196
        case .compact:
            return 92
        }
    }

    var horizontalPadding: CGFloat {
        self == .hero ? 20 : 16
    }

    var verticalPadding: CGFloat {
        self == .hero ? 20 : 14
    }
}

private struct InsightStatCard: View {
    let stat: InsightStatPresentation
    var size: InsightStatCardSize = .compact

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
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: size.minHeight, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 16) {
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
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
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

private struct WorkspaceBreakdownPanel: View {
    let entries: [WorkspaceTaskBreakdownEntry]

    private static let swatchColors: [Color] = [
        SonnyTheme.accent,
        SonnyTheme.success,
        SonnyTheme.warning,
        SonnyTheme.danger,
        SonnyTheme.muted
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Breakdown by Workspace")
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No workspace activity yet")
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                    Text("Tasks completed in a saved workspace over the last 30 days will appear here.")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        WorkspaceBreakdownRow(
                            entry: entry,
                            swatchColor: Self.swatchColors[index % Self.swatchColors.count]
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }
}

private struct WorkspaceBreakdownRow: View {
    let entry: WorkspaceTaskBreakdownEntry
    let swatchColor: Color

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(swatchColor)
                .frame(width: 8, height: 8)

            Text(entry.workspaceName)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(SonnyTheme.cardBorder)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(swatchColor)
                        .frame(width: proxy.size.width * entry.fractionOfTotal)
                }
            }
            .frame(height: 6)

            Text(percentageText)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.workspaceName): \(percentageText)")
    }

    private var percentageText: String {
        "\(Int((entry.fractionOfTotal * 100).rounded()))%"
    }
}

private struct TaskHistoryListPanel: View {
    let records: [CompletedTaskRecord]
    let title: String
    let emptyTitle: String
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }
}

private struct TaskHistoryGroupedPanel: View {
    let records: [CompletedTaskRecord]

    private var sections: [TaskHistorySection] {
        TaskHistoryGrouping.groupedByOutcome(records: records)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent task history")
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No completed tasks yet")
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                    Text("Run or cancel a Sonny task and it will appear here.")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(section.title) (\(section.records.count))")
                                .font(SonnyType.caption)
                                .foregroundStyle(SonnyTheme.muted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // `.ink`, not `.surfaceRaised` — this band sits inside the
                                // "Recent task history" card, whose own background *is*
                                // `.surfaceRaised`. Using the same token made the band invisible;
                                // `.ink` is the one token that actually contrasts against it.
                                .background(SonnyTheme.ink)
                                .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))

                            VStack(spacing: 0) {
                                ForEach(section.records, id: \.startedAt) { record in
                                    TaskHistoryRow(record: record)
                                }
                            }
                        }
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
            statusIcon
                .frame(width: 14, height: 14)
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

            if let workspaceName = record.workspaceName {
                Text(workspaceName)
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        Capsule().stroke(SonnyTheme.border, lineWidth: 1)
                    )
            }

            Text(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(record.command), \(statusText)\(record.workspaceName.map { ", \($0)" } ?? ""), " +
            "\(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))"
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.outcomeStatus {
        case .completed:
            // Wireframe "Done": filled indigo circle with a dark checkmark cutout.
            ZStack {
                Circle().fill(SonnyTheme.taskDone)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(SonnyTheme.ink)
            }
        case .canceled:
            // Wireframe "Canceled": filled blue-gray circle with a dark X cutout.
            ZStack {
                Circle().fill(SonnyTheme.taskCanceled)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(SonnyTheme.ink)
            }
        case .failed:
            // No wireframe evidence for a failure treatment — this screen only shows
            // In Progress/Done/Canceled. Reusing In Progress's stroked-ring shape, recolored to
            // the established danger token, as the most defensible reading absent a direct source.
            Circle()
                .strokeBorder(SonnyTheme.danger, lineWidth: 1.5)
        default:
            Circle()
                .fill(SonnyTheme.muted)
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
            label: "Avg. cycle time",
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
            // Always neutral, never green — unlike the other 3 cards, this delta isn't a
            // vs.-last-week comparison, so it doesn't get the "improved" color treatment.
            isPositiveDelta: false
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

/// Not `private` — unlike its neighbors below, this has real branching (hour boundaries, name
/// splitting, empty-name fallback) worth covering directly rather than only through the view.
enum TaskGreetingFormatter {
    static func greeting(hour: Int, fullName: String, displayFullNames: Bool) -> String {
        let period: String
        switch hour {
        case 5..<12: period = "morning"
        case 12..<17: period = "afternoon"
        case 17..<22: period = "evening"
        default: period = "night"
        }
        guard !fullName.isEmpty else { return "Good \(period)" }
        let name = displayFullNames
            ? fullName
            : (fullName.components(separatedBy: .whitespaces).first ?? fullName)
        return "Good \(period), \(name)"
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
    let detailText: String

    init(routine: StoredRoutine) {
        name = routine.name

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

struct WorkspaceAppIconPresentation: Equatable {
    let appName: String
    let icon: NSImage?

    @MainActor
    init(appName: String, resolver: any WorkspaceAppIconResolving) {
        self.appName = appName
        self.icon = resolver.icon(forAppName: appName)
    }

    /// Icon content isn't part of this presentation's logical identity — whether an icon resolves
    /// depends on what's installed on the machine rendering it, and two presentations for the same
    /// app name should compare equal regardless (this also keeps tests deterministic without
    /// depending on real installed apps).
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.appName == rhs.appName
    }
}

struct WorkspaceCardPresentation: Equatable {
    let name: String
    let effectiveTeamType: WorkspaceTeamType
    let isDefaultTeamType: Bool
    let taskCount: Int
    let taskCountText: String
    let appIcons: [WorkspaceAppIconPresentation]
    let urlsText: String?

    @MainActor
    init(
        workspace: StoredWorkspace,
        taskHistoryRecords: [CompletedTaskRecord],
        iconResolver: any WorkspaceAppIconResolving = WorkspaceAppIconResolver.shared
    ) {
        name = workspace.name
        effectiveTeamType = workspace.effectiveTeamType
        isDefaultTeamType = workspace.teamType == nil
        // All-time, `.completed`-only (matching the Insights breakdown's own definition of "a real
        // task happened here") — not windowed to the breakdown's trailing 30 days, since this is a
        // simple running count, not a recent-trend chart, and the store's 10,000-record cap is
        // already generously large for this to matter at v1 scale.
        taskCount = taskHistoryRecords.filter { $0.outcomeStatus == .completed && $0.workspaceName == workspace.name }.count
        taskCountText = "\(taskCount) task\(taskCount == 1 ? "" : "s")"
        appIcons = workspace.apps.map { WorkspaceAppIconPresentation(appName: $0, resolver: iconResolver) }
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
    @State private var selectedRoutine: StoredRoutine?

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
                                        run: { viewModel.runRoutineWidget(routine) },
                                        openDetail: { selectedRoutine = routine }
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
        .sheet(item: $selectedRoutine) { routine in
            RoutineDetailView(routine: routine)
        }
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
    let openDetail: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.routineIcon)
                        .fill(CommandCenterPalette.routineIconBackground)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CommandCenterPalette.routineIconForeground)
                        .frame(width: 12, height: 12)
                }
                .frame(width: 30, height: 30)

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

                Button(action: run) {
                    Text("Run")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel("Run \(presentation.name)")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .contentShape(Rectangle())
            .onTapGesture(perform: openDetail)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens routine details")

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
                                ForEach(Array(viewModel.savedWorkspaces.enumerated()), id: \.element.name) { index, workspace in
                                    WorkspaceCard(
                                        presentation: WorkspaceCardPresentation(
                                            workspace: workspace,
                                            taskHistoryRecords: viewModel.taskHistoryRecords
                                        ),
                                        accent: CommandCenterPalette.workspaceAvatarColors[
                                            index % CommandCenterPalette.workspaceAvatarColors.count
                                        ],
                                        isRunning: viewModel.isRunning || viewModel.isAwaitingApproval,
                                        open: { viewModel.openWorkspaceWidget(workspace) },
                                        markAsTeam: { viewModel.markWorkspaceAsTeam(workspace) }
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
        .onAppear {
            viewModel.refreshTaskHistory()
        }
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
    let markAsTeam: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceAvatar(name: presentation.name, color: accent)

            Text(presentation.name)
                .font(SonnyType.avatar)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .padding(.top, 14)

            teamTypeRow
                .padding(.top, 2)

            Text(presentation.taskCountText)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .padding(.top, 3)

            if let urlsText = presentation.urlsText {
                Label(urlsText, systemImage: "link")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
                    .padding(.top, 12)
            }

            Spacer(minLength: 12)

            HStack {
                WorkspaceAppIconStack(icons: presentation.appIcons, accent: accent)
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
        // Wireframe's measured 190pt fits the no-saved-URL case; the 36pt avatar (replacing an
        // 18pt icon stack in this slot) plus a populated `urlsText` row together exceed that
        // budget, which `.clipShape` below would silently cut off the footer instead of growing
        // the card. Worst case (empty icon-stack fallback + urlsText + full teamTypeRow) measures
        // ~209pt via actual Inter line-height metrics — 216 leaves real margin, not a ~1pt one.
        .frame(maxWidth: 356, minHeight: 190, maxHeight: 216, alignment: .topLeading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard))
    }

    @ViewBuilder
    private var teamTypeRow: some View {
        switch presentation.effectiveTeamType {
        case .team:
            Text("Team workspace")
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
        case .solo:
            HStack(spacing: 4) {
                // Wireframe specifies 12px for this label (`13-MainAppWorkspaces.svg:225`);
                // `.caption` applied uniformly across the row rather than leaving the "Mark as
                // team" affordance (a real Sonny feature, no wireframe equivalent) at the old 11px.
                Text("Just you")
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)

                if presentation.isDefaultTeamType {
                    Text("·")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)

                    Button(action: markAsTeam) {
                        Text("Mark as team")
                            .font(SonnyType.caption)
                            .foregroundStyle(SonnyTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .sonnyPointerCursor()
                    .accessibilityLabel("Mark \(presentation.name) as a team workspace")
                }
            }
        }
    }
}

enum WorkspaceAvatarInitial {
    static func from(name: String) -> String {
        guard let firstCharacter = name.trimmingCharacters(in: .whitespaces).first else {
            return "?"
        }
        return String(firstCharacter).uppercased()
    }
}

private struct WorkspaceAvatar: View {
    let name: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .fill(color.opacity(0.18))
            Text(WorkspaceAvatarInitial.from(name: name))
                .font(SonnyType.avatar)
                .foregroundStyle(color)
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}

private struct WorkspaceAppIconStack: View {
    let icons: [WorkspaceAppIconPresentation]
    let accent: Color

    private let iconSize: CGFloat = 18
    private let overlap: CGFloat = 10
    private let maxVisible = 2

    var body: some View {
        if icons.isEmpty {
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .fill(accent.opacity(0.18))
                .overlay(
                    Image(systemName: "rectangle.3.group")
                        .foregroundStyle(accent)
                )
                .frame(width: 36, height: 36)
        } else {
            let visible = Array(icons.prefix(maxVisible))
            ZStack(alignment: .leading) {
                // Reversed paint order: the wireframe draws the leftmost icon last (on top) —
                // ZStack paints later ForEach elements on top, so iterate index 1 before index 0
                // while keeping each icon's own offset tied to its original (unreversed) index.
                ForEach(Array(visible.enumerated().reversed()), id: \.offset) { index, icon in
                    iconTile(for: icon)
                        .offset(x: CGFloat(index) * overlap)
                }
            }
            .frame(
                width: iconSize + CGFloat(max(visible.count - 1, 0)) * overlap,
                height: iconSize,
                alignment: .leading
            )
        }
    }

    @ViewBuilder
    private func iconTile(for icon: WorkspaceAppIconPresentation) -> some View {
        Group {
            if let nsImage = icon.icon {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(SonnyTheme.muted)
            }
        }
        .frame(width: iconSize, height: iconSize)
        .background(SonnyTheme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .accessibilityHidden(true)
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
                .font(SonnyType.icon(20))
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
            .font(SonnyType.itemTitle)
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
    // Flat #242E52 per the wireframe (not a translucent accent tint) — SonnyTheme.chartBarMuted
    // is already exactly this hex, just previously unused here.
    static let routineIconBackground = SonnyTheme.chartBarMuted
    static let routineIconForeground = SonnyTheme.accent
    // Wireframe assigns each workspace card a distinct avatar color (`13-MainAppWorkspaces.svg`:
    // Personal=accent, Build in Public=warning, Client Work=success) rather than one fixed color
    // for every card — cycled by grid position, same pattern as Insights' workspace-breakdown swatches.
    static let workspaceAvatarColors: [Color] = [SonnyTheme.accent, SonnyTheme.warning, SonnyTheme.success]
}

private struct CommandCenterPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SonnyType.pageTitle)
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
            // Not `CommandCenterPageHeader` — this page's wireframe is the only one with a
            // two-tier title (a compact nav-level label here, a larger content-pane title inside
            // the bordered panel below). Every other page's title IS the shared header at 23px;
            // Settings' own "Settings" label is smaller (15px) because it's the parent of that
            // hierarchy, not a standalone page title.
            Text("Settings")
                .font(SonnyType.pageTitleCompact)
                .foregroundStyle(SonnyTheme.text)

            HStack(alignment: .top, spacing: 18) {
                // Flush/unbordered per the wireframe — only the content pane to the right has its
                // own border. A shared box around sidebar+content (the prior structure) put a
                // border around the sidebar the wireframe never gives it.
                settingsSidebar

                ScrollView {
                    Group {
                        switch selection {
                        case .preferences:
                            SettingsPreferencesPage(viewModel: viewModel)
                        case .privacy:
                            SettingsPrivacyPage(viewModel: viewModel)
                        }
                    }
                    // Wireframe's own static canvas measures 84pt here, but that number assumes
                    // a fixed 1093pt-wide frame that never has to survive this app's actual
                    // resizable window. At the app's declared 900pt minWidth, the content pane
                    // narrows to ~324pt; 84pt padding on both sides would leave only ~156pt for
                    // the Theme row's three swatch buttons, which have a fixedSize floor of
                    // 232pt (3×72 + 2×8 gaps) — a real, arithmetic overflow, not a hypothetical
                    // one. 40pt is still meaningfully more generous than the pre-fix 30pt while
                    // leaving safety margin at the floor width (324 - 80 = 244 > 232).
                    .padding(.horizontal, 40)
                    .padding(.vertical, 44)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SonnyTheme.collectionSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: SonnyRadius.container)
                        .stroke(SonnyTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(SonnyType.icon(12, weight: .medium))
                Text("My Account")
                    .font(SonnyType.itemTitle)
            }
            .foregroundStyle(SonnyTheme.muted)
            .padding(.horizontal, 11)
            .padding(.bottom, 2)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .font(SonnyType.icon(13, weight: .medium))
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

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SonnyTheme.border)
            .frame(height: 1)
    }
}

private struct SettingsPreferencesPage: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Preferences", subtitle: "Manage your preferences")
                .padding(.bottom, 20)

            SettingsDivider()

            SettingsSectionBlock(title: "Display") {
                SettingsToggleRow(
                    title: "Display full names",
                    detail: "Show full names of users instead of shorter display names.",
                    isOn: $viewModel.displayFullNames
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Use pointer cursors",
                    detail: "Change the cursor to a pointer when hovering over any interactive element.",
                    isOn: $viewModel.usePointerCursors
                )
            }
            .padding(.vertical, 20)

            SettingsDivider()

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
            .padding(.top, 20)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
    }
}

private struct SettingsPrivacyPage: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var showDeleteLocalDataConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Privacy & Permissions", subtitle: "Review local readiness and data controls")
                .padding(.bottom, 20)

            SettingsDivider()

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

            SettingsDivider()

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

                    LocalDataDeletionStatusMessage(message: viewModel.localDataDeletionStatusMessage)
                }
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: 760, alignment: .topLeading)
        .onAppear {
            viewModel.refreshPermissions()
        }
        .localDataDeletionConfirmationDialog(isPresented: $showDeleteLocalDataConfirmation, viewModel: viewModel)
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
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(SonnyType.body)
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
                .font(SonnyType.settingsContentTitle)
                .foregroundStyle(SonnyTheme.text)
            Text(subtitle)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.muted)
        }
        .padding(.bottom, 2)
    }
}

// Flat by design — the wireframe's Preferences/Privacy body is one continuous bordered panel
// (provided by the caller's ScrollView background) with hairline dividers between blocks and
// between rows within a block, not per-section cards. `SettingsSectionBlock` only groups a
// title with its rows now; `SettingsDivider()` between blocks/rows is the caller's job, since
// this view has no way to know how many un-typed children `content` actually contains.
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
