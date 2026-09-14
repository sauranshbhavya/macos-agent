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

    private func runner(eventKit: RecordingEventKitStore, clock: Clock, calendar: Calendar = FixedCalendar.calendar) -> AgentRunner {
        AgentRunner(planner: RefusingPlanner(), executor: executor(eventKit: eventKit, clock: clock, calendar: calendar))
    }

    private func executor(eventKit: (any EventKitAccessing)?, clock: Clock, calendar: Calendar = FixedCalendar.calendar) -> AgentActionExecutor {
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
                calendar: calendar
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
            calendar: calendar
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
        #expect(request.approvalCopy.involvedResource == "Reminder at 15:06 on Sunday 13 September")
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

    /// The seam's default: an executor nobody handed a calendar refuses rather than reaching one, and
    /// says that it is not connected rather than sending the user to a System Settings switch that
    /// would change nothing (PR #244, F6).
    @Test
    func anExecutorBuiltWithoutACalendarRefusesRatherThanReachingOne() async throws {
        let runner = AgentRunner(planner: RefusingPlanner(), executor: executor(eventKit: nil, clock: Clock()))
        for plan in [Self.readPlan(), Self.reminderPlan(minutes: 5)] {
            let prepared = try runner.prepare(plan: plan)
            let thrown = await #expect(throws: EventKitAccessError.unavailable) {
                _ = try await runner.execute(prepared, approvalDecision: .approved(.tier2), scope: .unscoped, context: normal)
            }
            #expect(thrown?.localizedDescription == "This copy of Sonny isn't connected to calendars or reminders.")
        }
        #expect(UnavailableEventKitStore().accessState(for: .calendars) == .unavailable)
        #expect(throws: EventKitAccessError.unavailable) {
            _ = try UnavailableEventKitStore().events(from: Date(), to: Date())
        }
    }

    /// Restricted access is not the user's switch to turn, so its sentence does not send them to
    /// System Settings, and nothing asks macOS or touches the store (PR #244, F6).
    @Test
    func restrictedAccessRefusesInWordsThatDoNotSendTheUserToSettings() async throws {
        let eventKit = RecordingEventKitStore(calendarsAccess: .restricted, remindersAccess: .restricted)
        let runner = runner(eventKit: eventKit, clock: Clock())

        let read = await #expect(throws: EventKitAccessError.calendarsRestricted) {
            _ = try await runner.execute(try runner.prepare(plan: Self.readPlan()), scope: .unscoped, context: normal)
        }
        #expect(read?.localizedDescription == "Access to calendars is restricted on this Mac, so Sonny can't read them.")

        let reminder = await #expect(throws: EventKitAccessError.remindersRestricted) {
            _ = try await runner.execute(try runner.prepare(plan: Self.reminderPlan(minutes: 5)), approvalDecision: .approved(.tier2), scope: .unscoped, context: normal)
        }
        #expect(reminder?.localizedDescription == "Access to reminders is restricted on this Mac, so Sonny can't add one.")

        #expect(eventKit.calls == [.accessState(.calendars), .accessState(.reminders)])
        for sentence in [read?.localizedDescription, reminder?.localizedDescription] {
            #expect(sentence?.contains("System Settings") == false)
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
        #expect(step.resolvedReminderDueDate == Self.date(2026, 9, 13, 15, 6))
        // The model's own words are left as it wrote them; the pin is the instant.
        #expect(step.reminderMinutesFromNow == 5)
        #expect(step.calendarDay == nil)
        #expect(step.reminderTime == nil)
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
        #expect(rolled.plan.steps.first?.resolvedReminderDueDate == Self.date(2026, 9, 14, 9))
        #expect(rolled.previews.map(\.details) == [["Reminder: call the bank", "When: 09:00 tomorrow"]])

        let later = try runner.prepare(plan: Self.reminderPlan(time: "17:30"))
        #expect(later.plan.steps.first?.resolvedReminderDueDate == Self.date(2026, 9, 13, 17, 30))

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
            // Zero or fewer minutes asks when, rather than reading "up to a year ahead" (PR #244, F6).
            (Self.reminderPlan(minutes: 0), "When should Sonny remind you?"),
            (Self.reminderPlan(minutes: -5), "When should Sonny remind you?"),
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

    // MARK: - What the approval says (PR #244, F1)

    /// Both approval panels render `involvedResource` — the widget after "Allow access to", Command
    /// Center on its "Involves:" line (`ReminderApprovalPanelTests` holds the two surfaces) — so
    /// that is where the pinned time is. Built across midnight, because a line that said "today"
    /// would read differently at the gate after it; and answered with the first gate's request, to
    /// show the time on the panel re-arms nothing.
    @Test
    func theApprovalNamesThePinnedTimeTheSameAtEveryGateAndReArmsNothing() async throws {
        let clock = Clock()
        clock.now = Self.date(2026, 9, 13, 23, 58, 30)
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: clock)
        let prepared = try runner.prepare(plan: Self.reminderPlan(minutes: 5))

        let first = try runner.approvalRequest(for: prepared, scope: .unscoped, context: normal)
        #expect(first.approvalCopy.involvedResource == "Reminder at 00:04 on Monday 14 September")
        #expect(first.approvalCopy.lines.contains("Involves: Reminder at 00:04 on Monday 14 September"))
        #expect(first.approvalCopy.safeModeLines.contains("Involves: Reminder at 00:04 on Monday 14 September"))

        clock.now = Self.date(2026, 9, 14, 0, 2)
        let later = try runner.approvalRequest(for: prepared, scope: .unscoped, context: normal)
        #expect(later.approvalCopy == first.approvalCopy)
        #expect(later.assessment.escalations == first.assessment.escalations)

        _ = try await runner.execute(prepared, approvalDecision: .approved(answering: first), scope: .unscoped, context: normal)
        #expect(eventKit.addedReminders.map(\.dueDate) == [Self.date(2026, 9, 14, 0, 4)])
    }

    /// A step the planner sends cannot carry the pin: the key is not one the decoder accepts, at any
    /// nesting depth, so the instant a reminder is due is always the Mac's own reading.
    @Test
    func aPlannerCannotAssertTheInstantAReminderIsDue() {
        #expect(throws: AgentPlanDecodingError.unexpectedStepKey("resolvedReminderDueDate")) {
            _ = try AgentPlanDecoder.decodeStrict(from: """
            {"summary":"x","requiresConfirmation":true,"itemJob":null,"steps":[
              {"id":"1","operation":"create_reminder","description":"d","reminderTitle":"t","resolvedReminderDueDate":0}
            ]}
            """)
        }
    }

    // MARK: - A pin that passes while the approval is open (PR #244, F4)

    /// The time is refused as passed at preview and nowhere after it, so a reminder whose pinned
    /// time goes by while its approval sits open is still the reminder the user allowed, and is added
    /// at that time rather than lost.
    @Test
    func aReminderWhosePinnedTimePassesWhileItsApprovalIsOpenIsStillAddedAtThatTime() async throws {
        let clock = Clock()
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: clock)
        let prepared = try runner.prepare(plan: Self.reminderPlan(minutes: 5))
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: normal)

        clock.now = Self.date(2026, 9, 13, 15, 20)
        #expect(clock.now > Self.date(2026, 9, 13, 15, 6))
        let result = try await runner.execute(prepared, approvalDecision: .approved(answering: request), scope: .unscoped, context: normal)

        #expect(eventKit.addedReminders.map(\.dueDate) == [Self.date(2026, 9, 13, 15, 6)])
        #expect(result.summary == "Added a reminder for 15:06 today: call the bank.")
    }

    // MARK: - Daylight saving (PR #244, F2)

    /// New York: clocks go back from 02:00 EDT to 01:00 EST on 1 November 2026, and forward from 02:00
    /// EST to 03:00 EDT on 8 March 2026. Every instant here is written in UTC and every assertion is
    /// on an instant, never on a formatted time.
    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func utc(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Prepares at one instant, lets fifteen minutes pass with the approval open, and returns the
    /// instant the approved run added the reminder for.
    private func addedDue(for plan: AgentPlan, at start: Date) async throws -> Date? {
        let clock = Clock()
        clock.now = start
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: clock, calendar: Self.newYork)
        let prepared = try runner.prepare(plan: plan)
        let request = try runner.approvalRequest(for: prepared, scope: .unscoped, context: normal)
        clock.now = start.addingTimeInterval(15 * 60)
        _ = try await runner.execute(prepared, approvalDecision: .approved(answering: request), scope: .unscoped, context: normal)
        return eventKit.addedReminders.first?.dueDate
    }

    @Test
    func minutesFromNowAcrossTheFallBackAreAddedThatManyMinutesLater() async throws {
        // 00:50 EDT; "in 90 minutes" is 01:20 EST, ninety minutes on — not 01:20 EDT, thirty on.
        let beforeTheChange = Self.utc(11, 1, 4, 50)
        #expect(try await addedDue(for: Self.reminderPlan(minutes: 90), at: beforeTheChange) == beforeTheChange.addingTimeInterval(90 * 60))
        // 01:50 EDT, in the first pass; "in 20 minutes" is 01:10 EST, not a time already gone.
        let firstPass = Self.utc(11, 1, 5, 50)
        #expect(try await addedDue(for: Self.reminderPlan(minutes: 20), at: firstPass) == firstPass.addingTimeInterval(20 * 60))
    }

    @Test
    func minutesFromNowInsideTheRepeatedHourAreNotRefusedAsPassed() async throws {
        // 01:28 EST, in the second pass through 01:00–02:00.
        let secondPass = Self.utc(11, 1, 6, 28)
        #expect(try await addedDue(for: Self.reminderPlan(minutes: 5), at: secondPass) == secondPass.addingTimeInterval(5 * 60))
    }

    @Test
    func anUndatedClockTimeInTheRepeatedHourTakesItsNextOccurrenceNotTomorrow() async throws {
        // 01:10 EST, in the second pass: 01:30 EDT has gone, 01:30 EST is twenty minutes on.
        let secondPass = Self.utc(11, 1, 6, 10)
        #expect(try await addedDue(for: Self.reminderPlan(time: "01:30"), at: secondPass) == Self.utc(11, 1, 6, 30))
        // 00:10 EDT: the first 01:30 is still ahead, and that is the one.
        #expect(try await addedDue(for: Self.reminderPlan(time: "01:30"), at: Self.utc(11, 1, 4, 10)) == Self.utc(11, 1, 5, 30))
    }

    @Test
    func aClockTimeTheSpringForwardSkipsTakesTheNextTimeThatExistsAndKeepsIt() async throws {
        // 01:00 EST on 8 March; 02:30 does not exist, and 03:00 EDT is the next time that does.
        #expect(try await addedDue(for: Self.reminderPlan(time: "02:30"), at: Self.utc(3, 8, 6, 0)) == Self.utc(3, 8, 7, 0))
        // "In 90 minutes" across the same change is ninety minutes on.
        let start = Self.utc(3, 8, 6, 20)
        #expect(try await addedDue(for: Self.reminderPlan(minutes: 90), at: start) == start.addingTimeInterval(90 * 60))
    }

    // MARK: - A day whose midnight does not exist (PR #244, F7)

    /// `America/Santiago` springs forward at midnight: 6 September 2026 starts at 01:00 (04:00 UTC)
    /// and 7 September starts at 00:00 (03:00 UTC). The read's window for the 6th ends where the 7th
    /// starts, not an hour into it.
    @Test
    func aReadOnADayWhoseMidnightIsSkippedEndsWhereTheNextDayStarts() async throws {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        santiago.locale = Locale(identifier: "en_GB")
        let clock = Clock()
        clock.now = Self.utc(9, 6, 15, 0)
        let eventKit = RecordingEventKitStore()
        let runner = runner(eventKit: eventKit, clock: clock, calendar: santiago)

        _ = try await runner.execute(try runner.prepare(plan: Self.readPlan(day: "2026-09-06")), scope: .unscoped, context: normal)

        #expect(eventKit.calls.last == .events(from: Self.utc(9, 6, 4, 0), to: Self.utc(9, 7, 3, 0)))
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
