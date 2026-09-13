import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// London on the Gregorian calendar in an English locale, so "tomorrow" and "09:00" mean one thing
/// on every machine that runs this.
enum FixedCalendar {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    /// Sunday 13 September 2026, 15:00:30.
    static let now = date(2026, 9, 13, 15, 0, 30)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}

/// SONNY-453: reading a calendar and adding a reminder, through the runner and executor every real
/// command takes. Every calendar call goes to `RecordingEventKitStore`, so nothing here touches this
/// Mac's calendars, and the clock and calendar are fixed so "tomorrow" means one day.
@Suite
@MainActor
struct CalendarAndReminderCapabilityTests {
    static var calendar: Calendar { FixedCalendar.calendar }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        FixedCalendar.date(year, month, day, hour, minute, second)
    }

    final class Clock {
        var now = FixedCalendar.now
    }

    private let normal = ApprovalContext(mode: .normal, appControl: .notApplicable)

    private func runner(eventKit: RecordingEventKitStore, clock: Clock) -> AgentRunner {
        AgentRunner(planner: RefusingPlanner(), executor: executor(eventKit: eventKit, clock: clock))
    }

    private func executor(eventKit: (any EventKitAccessing)?, clock: Clock) -> AgentActionExecutor {
        if let eventKit {
            return AgentActionExecutor(
                routineStore: UnreachableLocalStores.routines(),
                workspaceStore: UnreachableLocalStores.workspaces(),
                clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
                snippetStore: UnreachableLocalStores.snippets(),
                recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
                shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
                resumableTaskStore: UnreachableLocalStores.resumableTasks(),
                eventKit: eventKit,
                now: { clock.now },
                calendar: Self.calendar
            )
        }
        return AgentActionExecutor(
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
            now: { clock.now },
            calendar: Self.calendar
        )
    }

    static func readPlan(day: String? = nil) -> AgentPlan {
        AgentPlan(
            summary: "Read the calendar.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "read", operation: .readCalendarEvents, description: "Read the calendar.", calendarDay: day)]
        )
    }

    static func reminderPlan(
        title: String? = "call the bank",
        minutes: Int? = nil,
        time: String? = nil,
        day: String? = nil
    ) -> AgentPlan {
        AgentPlan(
            summary: "Add a reminder.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "remind",
                    operation: .createReminder,
                    description: "Add a reminder.",
                    calendarDay: day,
                    reminderTitle: title,
                    reminderMinutesFromNow: minutes,
                    reminderTime: time
                )
            ]
        )
    }

    // MARK: - Tiers, and what asks

    @Test
    func aCalendarReadIsTierZeroAndRunsWithoutAsking() throws {
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: Clock())
        let request = try runner.approvalRequest(for: runner.prepare(plan: Self.readPlan()), scope: .unscoped, context: normal)

        #expect(request.assessment.defaultTier == .tier0)
        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.assessment.escalations.isEmpty)
        #expect(request.requirement == .autoRun)
    }

    @Test
    func aReminderIsTierTwoAndAsksFirstThroughAnEscalationThatAffectsOthers() async throws {
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: Clock())
        let prepared = try runner.prepare(plan: Self.reminderPlan(minutes: 5))
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: normal)

        #expect(request.assessment.defaultTier == .tier2)
        #expect(request.assessment.effectiveTier == .tier2)
        #expect(request.assessment.escalations == [
            CapabilityRiskEscalation(
                fromTier: .tier2,
                toTier: .tier2,
                reason: "This adds \u{201C}call the bank\u{201D} to your Reminders, where anyone you share that list with can see it.",
                consequence: .affectsOthers
            )
        ])
        #expect(request.requirement == .explicitApproval)
        #expect(request.approvalCopy.riskReason == "This adds a reminder to your Reminders.")
        #expect(request.approvalCopy.undoDescription == "Delete the reminder in Reminders if needed.")
        #expect(request.approvalCopy.involvedResource == "Reminder: call the bank")
        #expect(request.approvalCopy.dataLeavesDevice == false)

        // Nothing is added without the answer.
        await #expect(throws: RiskApprovalError.self) {
            _ = try await runner.execute(prepared, scope: .unscoped, context: normal)
        }
        #expect(eventKit.addedReminders.isEmpty)

        _ = try await runner.execute(prepared, approvalDecision: .approved(answering: request), scope: .unscoped, context: normal)
        #expect(eventKit.addedReminders.map(\.title) == ["call the bank"])
    }

    /// The standing tier-2 grant a scheduled routine runs under would pass the reminder unasked,
    /// which is exactly why a routine may not carry one — pinned from both sides.
    @Test
    func aStandingTierTwoGrantWouldPassAReminderSoRoutinesRefuseIt() async throws {
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: Clock())
        let prepared = try runner.prepare(plan: Self.reminderPlan(minutes: 5))
        _ = try await runner.execute(prepared, approvalDecision: .approved(.tier2), scope: .unscoped, context: normal)
        #expect(eventKit.addedReminders.count == 1)

        #expect(StoredRoutine.forbiddenStepOperations.isSuperset(of: [.readCalendarEvents, .createReminder]))
        let store = UnreachableLocalStores.routines()
        for (operation, sentence) in [
            (AgentOperation.readCalendarEvents, "A routine can't read your calendar."),
            (.createReminder, "A routine can't add a reminder.")
        ] {
            let thrown = #expect(throws: AutomationStoreError.self) {
                try store.save(StoredRoutine(name: "Morning", steps: [AgentStep(id: "x", operation: operation, description: "x")]))
            }
            #expect(thrown?.localizedDescription == sentence)
        }
    }

    // MARK: - Dry runs touch no calendar

    @Test
    func preparingAndAssessingEitherOperationTouchesNoCalendar() throws {
        for plan in [Self.readPlan(day: "tomorrow"), Self.reminderPlan(minutes: 5)] {
            let eventKit = RecordingEventKitStore(calendarsAccess: .notDetermined, remindersAccess: .notDetermined)
            let runner = runner(eventKit: eventKit, clock: Clock())
            let prepared = try runner.prepare(plan: plan)
            _ = try runner.approvalRequest(for: prepared, scope: .unscoped, context: normal)
            #expect(!prepared.previews.isEmpty)
            #expect(eventKit.calls.isEmpty, "\(plan.steps[0].operation.rawValue) reached the calendar before it ran: \(eventKit.calls)")
        }
    }

    // MARK: - Permission at first use, and refusal in plain words

    @Test
    func theFirstReadAsksMacOSOnceAndThenReadsTheDay() async throws {
        let eventKit = RecordingEventKitStore(calendarsAccess: .notDetermined, requestAnswer: .granted)
        let runner = runner(eventKit: eventKit, clock: Clock())
        let result = try await runner.execute(try runner.prepare(plan: Self.readPlan()), scope: .unscoped, context: normal)

        #expect(eventKit.calls == [
            .accessState(.calendars),
            .requestAccess(.calendars),
            .events(from: Self.date(2026, 9, 13), to: Self.date(2026, 9, 14))
        ])
        #expect(result.summary == "Nothing on your calendar today.")
    }

    @Test
    func aReadWithoutAccessRefusesInPlainWordsAndReadsNothing() async throws {
        for (stored, answer, expectedCalls) in [
            (EventKitAccessState.denied, EventKitAccessState.granted, [RecordingEventKitStore.Call.accessState(.calendars)]),
            (.notDetermined, .denied, [.accessState(.calendars), .requestAccess(.calendars)])
        ] {
            let eventKit = RecordingEventKitStore(calendarsAccess: stored, requestAnswer: answer)
            let runner = runner(eventKit: eventKit, clock: Clock())
            let prepared = try runner.prepare(plan: Self.readPlan())
            let thrown = await #expect(throws: EventKitAccessError.calendarsDenied) {
                _ = try await runner.execute(prepared, scope: .unscoped, context: normal)
            }
            #expect(thrown?.localizedDescription == "Sonny doesn't have access to your calendars. Allow it in System Settings \u{203A} Privacy & Security \u{203A} Calendars.")
            #expect(eventKit.calls == expectedCalls)
        }
    }

    @Test
    func theFirstReminderAsksMacOSOnceAndARefusalAddsNothing() async throws {
        let granting = RecordingEventKitStore(remindersAccess: .notDetermined, requestAnswer: .granted)
        let grantingRunner = runner(eventKit: granting, clock: Clock())
        let prepared = try grantingRunner.prepare(plan: Self.reminderPlan(minutes: 5))
        _ = try await grantingRunner.execute(prepared, approvalDecision: .approved(.tier2), scope: .unscoped, context: normal)
        #expect(granting.calls == [
            .accessState(.reminders),
            .requestAccess(.reminders),
            .addReminder(title: "call the bank", dueDate: Self.date(2026, 9, 13, 15, 6))
        ])

        for (stored, answer) in [(EventKitAccessState.denied, EventKitAccessState.granted), (.notDetermined, .denied)] {
            let refusing = RecordingEventKitStore(remindersAccess: stored, requestAnswer: answer)
            let refusingRunner = runner(eventKit: refusing, clock: Clock())
            let refusedPlan = try refusingRunner.prepare(plan: Self.reminderPlan(minutes: 5))
            let thrown = await #expect(throws: EventKitAccessError.remindersDenied) {
                _ = try await refusingRunner.execute(refusedPlan, approvalDecision: .approved(.tier2), scope: .unscoped, context: normal)
            }
            #expect(thrown?.localizedDescription == "Sonny doesn't have access to your reminders. Allow it in System Settings \u{203A} Privacy & Security \u{203A} Reminders.")
            #expect(refusing.addedReminders.isEmpty)
            #expect(refusing.calls.filter { $0 == .requestAccess(.reminders) }.count == (stored == .notDetermined ? 1 : 0))
        }
    }

    /// The seam's default: an executor nobody handed a calendar refuses rather than reaching one.
    @Test
    func anExecutorBuiltWithoutACalendarRefusesRatherThanReachingOne() async throws {
        let runner = AgentRunner(planner: RefusingPlanner(), executor: executor(eventKit: nil, clock: Clock()))
        let prepared = try runner.prepare(plan: Self.readPlan())
        await #expect(throws: EventKitAccessError.calendarsDenied) {
            _ = try await runner.execute(prepared, scope: .unscoped, context: normal)
        }
        #expect(throws: EventKitAccessError.unavailable) {
            _ = try UnavailableEventKitStore().events(from: Date(), to: Date())
        }
    }

    // MARK: - When a reminder is due

    @Test
    func inFiveMinutesIsPinnedAtPrepareAndTheApprovedTimeIsTheTimeSet() async throws {
        let clock = Clock()
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: clock)
        let prepared = try runner.prepare(plan: Self.reminderPlan(minutes: 5))

        let step = try #require(prepared.plan.steps.first)
        #expect(step.calendarDay == "2026-09-13")
        #expect(step.reminderTime == "15:06")
        #expect(step.reminderMinutesFromNow == nil)
        #expect(prepared.previews.map(\.details) == [["Reminder: call the bank", "When: 15:06 today"]])

        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: normal)
        // The approval sits open for four minutes; re-resolving "in 5 minutes" now would say 15:10.
        clock.now = clock.now.addingTimeInterval(4 * 60)
        let result = try await runner.execute(prepared, approvalDecision: .approved(answering: request), scope: .unscoped, context: normal)

        #expect(eventKit.addedReminders.map(\.dueDate) == [Self.date(2026, 9, 13, 15, 6)])
        #expect(result.summary == "Added a reminder for 15:06 today: call the bank.")
    }

    @Test
    func aClockTimeWithNoDayRollsToTomorrowOnceItHasPassedButOneTheUserDatedIsRefused() throws {
        let runner = runner(eventKit: RecordingEventKitStore(), clock: Clock())

        let rolled = try runner.prepare(plan: Self.reminderPlan(time: "09:00"))
        #expect(rolled.plan.steps.first?.calendarDay == "2026-09-14")
        #expect(rolled.plan.steps.first?.reminderTime == "09:00")
        #expect(rolled.previews.map(\.details) == [["Reminder: call the bank", "When: 09:00 tomorrow"]])

        let later = try runner.prepare(plan: Self.reminderPlan(time: "17:30"))
        #expect(later.plan.steps.first?.calendarDay == "2026-09-13")

        let thrown = #expect(throws: ReminderDueError.timeHasPassed) {
            _ = try runner.prepare(plan: Self.reminderPlan(time: "09:00", day: "today"))
        }
        #expect(thrown?.localizedDescription == "That time has already passed.")
    }

    @Test
    func aReminderMissingItsTimeItsTitleOrAReadableDayAsks() throws {
        let runner = runner(eventKit: RecordingEventKitStore(), clock: Clock())
        let cases: [(AgentPlan, String)] = [
            (Self.reminderPlan(), "When should Sonny remind you?"),
            (Self.reminderPlan(day: "tomorrow"), "When should Sonny remind you?"),
            (Self.reminderPlan(minutes: 5, time: "17:00"), "When should Sonny remind you?"),
            (Self.reminderPlan(time: "25:00"), "When should Sonny remind you?"),
            (Self.reminderPlan(title: "  ", minutes: 5), "What should Sonny remind you about?"),
            (Self.reminderPlan(time: "09:00", day: "someday"), "Which day should Sonny remind you?"),
            (Self.readPlan(day: "next-ish"), "Which day should Sonny look at?")
        ]
        for (plan, question) in cases {
            let prepared = try runner.prepare(plan: plan)
            #expect(prepared.clarificationQuestion == question, "\(plan.steps[0])")
        }
    }

    // MARK: - The answer

    @Test
    func aNamedDayIsPinnedAndTheAnswerListsItsEventsInOrder() async throws {
        let friday = Self.date(2026, 9, 18)
        let eventKit = RecordingEventKitStore(storedEvents: [
            CalendarEventRecord(title: "Lunch with Priya", start: Self.date(2026, 9, 18, 12, 30), end: Self.date(2026, 9, 18, 13, 30), isAllDay: false),
            CalendarEventRecord(title: "Standup", start: Self.date(2026, 9, 18, 9), end: Self.date(2026, 9, 18, 9, 15), isAllDay: false),
            CalendarEventRecord(title: "Holiday", start: friday, end: Self.date(2026, 9, 18, 23, 59, 59), isAllDay: true)
        ])
        let runner = runner(eventKit: eventKit, clock: Clock())
        let prepared = try runner.prepare(plan: Self.readPlan(day: "Friday"))
        #expect(prepared.plan.steps.first?.calendarDay == "2026-09-18")
        #expect(prepared.previews.map(\.details) == [["Day: on Friday 18 September"]])

        let result = try await runner.execute(prepared, scope: .unscoped, context: normal)
        #expect(eventKit.calls.last == .events(from: friday, to: Self.date(2026, 9, 19)))
        #expect(result.summary == "Friday 18 September: all day Holiday, 09:00 Standup, 12:30 Lunch with Priya.")
    }

    @Test
    func theListStopsAtItsLimitAndNamesEventsThatBeganTheDayBefore() {
        let today = Self.date(2026, 9, 13)
        let now = Self.date(2026, 9, 13, 15)
        let seven = (0..<7).map { index in
            CalendarEventRecord(title: "Event \(index)", start: Self.date(2026, 9, 13, 8 + index), end: Self.date(2026, 9, 13, 8 + index, 30), isAllDay: false)
        }
        #expect(
            ReadCalendarEventsCapabilityAdapter.summary(of: seven, day: today, now: now, calendar: Self.calendar)
                == "Today: 08:00 Event 0, 09:00 Event 1, 10:00 Event 2, 11:00 Event 3, 12:00 Event 4, and 2 more."
        )

        let overnight = CalendarEventRecord(title: "", start: Self.date(2026, 9, 12, 22), end: Self.date(2026, 9, 13, 2), isAllDay: false)
        #expect(
            ReadCalendarEventsCapabilityAdapter.summary(of: [overnight], day: today, now: now, calendar: Self.calendar)
                == "Today: until 02:00 Untitled event."
        )
        #expect(
            ReadCalendarEventsCapabilityAdapter.summary(of: [], day: Self.date(2026, 9, 14), now: now, calendar: Self.calendar)
                == "Nothing on your calendar tomorrow."
        )
    }

    // MARK: - The planner

    @Test
    func thePlannerIsToldBothOperationsAndStillRefusesWeatherInItsOwnSentence() throws {
        let prompt = OpenAIPlanner.systemPrompt(toolRegistry: .default)
        #expect(prompt.contains("produce one read_calendar_events step with calendarDay holding the day they asked about, or null for today."))
        #expect(prompt.contains("produce one create_reminder step with reminderTitle and exactly one of reminderMinutesFromNow or reminderTime"))
        #expect(prompt.contains("If the user named no time, return exactly one clarify step asking when."))
        #expect(AgentOperation.plannerVisibleCases.contains(.readCalendarEvents))
        #expect(AgentOperation.plannerVisibleCases.contains(.createReminder))
        // Weather stays deferred (founders, 2026-09-12): no tool names it, and a planner refusal of
        // it reaches the user as SONNY-447's one sentence.
        #expect(!prompt.localizedCaseInsensitiveContains("weather"))
        let runner = runner(eventKit: RecordingEventKitStore(), clock: Clock())
        let weather = AgentPlan(
            summary: "Weather.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "u", operation: .unsupported, description: "There is no weather tool.")]
        )
        let thrown = #expect(throws: AgentExecutionError.self) {
            _ = try runner.prepare(plan: weather)
        }
        #expect(thrown?.localizedDescription == "Sonny can't do that yet.")
    }
}

/// Every test here prepares its plan directly.
private struct RefusingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("The planner must not be consulted in this suite.")
        throw AgentExecutionError.invalidPlan("planner should not be called")
    }
}
