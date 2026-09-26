import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore
import MacAgentTestSupport

/// What the Insights page shows, from the app's own history.
@Suite(.serialized)
@MainActor
struct InsightsPageTests {
    /// "Don't save this task" keeps a task out of history (decision 10), and Insights reads only
    /// history, so a private task is in none of its figures or rows.
    @Test
    func aPrivateTaskNeverAppearsInInsights() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }

        _ = try await fixture.runToCompletion("Look up my test results", isPrivate: true)
        let ordinary = try await fixture.runToCompletion("Book a table for two")
        #expect(await eventually { fixture.app.desk.history.map(\.id) == [ordinary] })

        let overview = InsightsPage.overview(of: fixture.app.desk.history, now: Date())

        #expect(overview.summary.completedThisWeek == 1)
        #expect(overview.summary.weeklyCompletedCounts.reduce(0, +) == 1)
        #expect(overview.summary.completionRate == 1)
        #expect(overview.recent.map(\.goal) == ["Book a table for two"])
        #expect(!overview.recent.contains { $0.goal.contains("test results") })
    }

    /// The three most recent completed tasks, newest first; a stopped one isn't "completed".
    @Test
    func recentActivityListsTheThreeNewestCompletedTasks() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        // A Wednesday, so the whole test sits inside one week in every time zone.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
        for (offset, goal) in ["first", "second", "third", "fourth"].enumerated() {
            try await fixture.stores.history.record(fixture.finishedSnapshot(goal), finishedAt: now.addingTimeInterval(Double(offset)))
        }
        try await fixture.stores.history.record(
            fixture.finishedSnapshot("stopped", outcome: .cancelled),
            finishedAt: now.addingTimeInterval(10)
        )
        await fixture.app.desk.load()

        let overview = InsightsPage.overview(of: fixture.app.desk.history, now: now.addingTimeInterval(20))

        #expect(overview.recent.map(\.goal) == ["fourth", "third", "second"])
        #expect(overview.summary.completedThisWeek == 4)
    }

    @Test
    func theStatTilesReadAgainstLastWeek() throws {
        let week = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 7 * 86_400)
        let summary = TaskHistoryInsightsSummary(
            weekInterval: week,
            completedThisWeek: 5,
            completionRate: 0.8,
            currentStreakDays: 1,
            hasCompletedToday: false,
            weeklyCompletedCounts: [1, 1, 1, 1, 1, 0, 0],
            previousWeekCompleted: 3,
            previousWeekCompletionRate: 0.9
        )

        #expect(InsightStatPresentation.completedThisWeek(summary) == InsightStatPresentation(
            label: "Completed this week", value: "5", delta: "+2 vs last week", isPositiveDelta: true
        ))
        #expect(InsightStatPresentation.completionRate(summary) == InsightStatPresentation(
            label: "Completion rate", value: "80%", delta: "-10%", isPositiveDelta: false
        ))
        #expect(InsightStatPresentation.currentStreak(summary) == InsightStatPresentation(
            label: "Current streak", value: "1 day", delta: "Keep it going today", isPositiveDelta: false
        ))
    }
}

/// The weekly chart's hover-pill wording, driven with no view host.
@Suite
struct WeeklyCompletionChartPresentationTests {
    @Test
    func oneTaskReadsSingular() {
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 1) == "1 task")
    }

    @Test
    func everyOtherCountReadsPlural() {
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 0) == "0 tasks")
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 2) == "2 tasks")
        #expect(WeeklyCompletionChartPresentation.countLabel(for: 30) == "30 tasks")
    }
}
