import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// PR #244, F1: what the two approval panels actually put in front of the user for a reminder, and
/// that it names the pinned time before Allow.
@Suite
@MainActor
struct ReminderApprovalPanelTests {
    private static func request() throws -> RiskApprovalRequest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 16, minute: 55))!
        let executor = AgentActionExecutor(
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
            eventKit: RecordingEventKitStore(),
            now: { now },
            calendar: calendar
        )
        let plan = AgentPlan(
            summary: "Remind you to call mum.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "remind",
                    operation: .createReminder,
                    description: "Remind you to call mum.",
                    reminderTitle: "call mum",
                    reminderTime: "17:00"
                )
            ]
        )
        let runner = AgentRunner(planner: NoPlanner(), executor: executor)
        return try runner.approvalRequest(
            for: try runner.prepare(plan: plan),
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )
    }

    /// Command Center renders `approvalDisclosureLines` in full, in both modes.
    @Test
    func commandCentersPanelNamesTheTimeOnItsInvolvesLineInEitherMode() throws {
        let request = try Self.request()
        for safeMode in [false, true] {
            let lines = AgentActivityPresentation.approvalDisclosureLines(for: request, safeMode: safeMode)
            #expect(lines.contains("Involves: Reminder at 17:00 on Sunday, 13 September 2026"), "safe mode \(safeMode): \(lines)")
        }
    }

    /// The widget's one line is "Allow access to " followed by `involvedResource`, spelled in the
    /// view itself, so the source is what says which value it renders; the value is then the one
    /// the request carries.
    @Test
    func theWidgetsPanelRendersTheResourceLineThatNamesTheTime() throws {
        let source = try MacAgentSource.read("FloatingWidgetView.swift")
        let allow = try #require(source.range(of: "Text(\"Allow access to \")"))
        let rest = String(source[allow.upperBound...].prefix(200))
        #expect(rest.contains("Text(request.approvalCopy.involvedResource)"))

        let request = try Self.request()
        #expect("Allow access to " + request.approvalCopy.involvedResource == "Allow access to Reminder at 17:00 on Sunday, 13 September 2026")
    }
}

private struct NoPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("The planner must not be consulted in this suite.")
        throw AgentExecutionError.invalidPlan("planner should not be called")
    }
}
