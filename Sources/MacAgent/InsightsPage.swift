import MacAgentCore
import SwiftUI

/// Insights: how the week went, from the finished tasks in `TaskDesk.history`. A private task is
/// never written there (decision 10), so it never counts here.
struct InsightsPage: View {
    @ObservedObject var model: SonnyAppModel
    /// Selects the task on the Tasks page.
    let openTask: (TaskID) -> Void

    /// Everything the page shows, from one read of history.
    struct Overview: Equatable {
        let summary: TaskHistoryInsightsSummary
        let recent: [FinishedTask]
    }

    static func overview(of history: [FinishedTask], now: Date) -> Overview {
        Overview(
            summary: TaskHistoryInsights.summarize(history: history, now: now),
            recent: RecentCompletedTasks.recent(from: history, limit: 3)
        )
    }

    var body: some View {
        let overview = Self.overview(of: model.desk.history, now: Date())
        VStack(alignment: .leading, spacing: SonnySpacing.lg) {
            CommandCenterPageHeader(title: "Insights")
            ScrollView {
                InsightsOverviewBento(summary: overview.summary, recent: overview.recent, openTask: openTask)
                    .padding(.horizontal, SonnySpacing.xxxl)
                    .padding(.vertical, SonnySpacing.xxl)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .commandCenterPanel()
        }
        .commandCenterPageFrame()
    }
}

/// V1's bento over a four-column grid: the three stats, the first spanning two columns as the hero
/// tile; the weekly chart; then recent activity at full width. V1 put a per-workspace breakdown
/// beside the chart, and workspaces are gone in V2, so the chart takes the whole row.
///
/// No usage or quota figure belongs on this page, by founder decision: this page is meant to be
/// encouraging, and a usage figure creates cancellation anxiety in heavy users.
private struct InsightsOverviewBento: View {
    let summary: TaskHistoryInsightsSummary
    let recent: [FinishedTask]
    let openTask: (TaskID) -> Void

    var body: some View {
        Grid(horizontalSpacing: SonnySpacing.md, verticalSpacing: SonnySpacing.md) {
            GridRow {
                InsightStatCard(stat: .completedThisWeek(summary), isWide: true)
                    .gridCellColumns(2)
                InsightStatCard(stat: .completionRate(summary))
                InsightStatCard(stat: .currentStreak(summary))
            }
            GridRow {
                WeeklyCompletionChart(counts: summary.weeklyCompletedCounts)
                    .gridCellColumns(4)
            }
            GridRow {
                TaskHistoryListPanel(
                    tasks: recent,
                    title: "Recently completed",
                    emptyTitle: "No activity yet",
                    emptyMessage: "Completed Sonny tasks will appear here.",
                    openTask: openTask
                )
                .gridCellColumns(4)
            }
        }
    }
}

private struct InsightStatCard: View {
    let stat: InsightStatPresentation
    /// The hero tile reads its delta at `caption` size, where the room is; the two single-column
    /// stats keep it at `micro`.
    var isWide: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.sm) {
            Text(stat.label)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)

            Text(stat.value)
                .font(SonnyType.pageTitle.monospacedDigit())
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(stat.delta)
                .font(isWide ? SonnyType.caption : SonnyType.micro)
                .foregroundStyle(stat.isPositiveDelta ? SonnyTheme.success : SonnyTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .padding(SonnySpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .sonnyCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stat.label): \(stat.value), \(stat.delta)")
    }
}

/// One stat tile's words.
struct InsightStatPresentation: Equatable {
    let label: String
    let value: String
    let delta: String
    let isPositiveDelta: Bool

    static func completedThisWeek(_ summary: TaskHistoryInsightsSummary) -> Self {
        let difference = summary.completedThisWeek - summary.previousWeekCompleted
        return Self(
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
            label: "Completion rate",
            value: "\(currentPercent)%",
            delta: deltaPercentText(difference),
            isPositiveDelta: difference > 0
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
            label: "Current streak",
            value: "\(days) day\(days == 1 ? "" : "s")",
            delta: delta,
            // Always neutral: unlike the other two, this delta isn't a comparison with last week.
            isPositiveDelta: false
        )
    }

    private static func deltaCountText(_ difference: Int) -> String {
        if difference > 0 { return "+\(difference) vs last week" }
        if difference < 0 { return "\(difference) vs last week" }
        return "No change"
    }

    private static func deltaPercentText(_ difference: Int) -> String {
        if difference > 0 { return "+\(difference)%" }
        if difference < 0 { return "\(difference)%" }
        return "No change"
    }
}
