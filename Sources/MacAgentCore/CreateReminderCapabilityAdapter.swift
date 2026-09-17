import Foundation

/// "Remind me in 5 minutes to call the bank" — one reminder, with an alert, in the user's default
/// Reminders list (SONNY-453).
///
/// **Tier 2, and it asks first** (founders' decision 2026-09-12). See `assessRisk` for how a tier-2
/// action asks without the consequence rule changing.
public struct CreateReminderCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.reminders.create",
        displayName: "Add reminder",
        description: "Add one reminder with an alert to the user's default Reminders list through EventKit.",
        operations: [.createReminder],
        plannerTools: [
            AgentTool(
                operation: .createReminder,
                name: "Add a reminder",
                description: "Add one reminder with an alert to the user's Reminders. Set reminderTitle to what to remind them about, and exactly one of reminderMinutesFromNow or reminderTime, with calendarDay when they named a day. If the user named no time, ask a clarification question for when.",
                requiredFields: ["reminderTitle"],
                sideEffects: ["add reminder"],
                dryRunBehavior: "Show the reminder and when it is due, without adding it.",
                examples: ["Remind me in 5 minutes to call the bank", "Remind me tomorrow at 9am to send the invoice"]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .remindersAccess)
        ],
        defaultRiskTier: .tier2
    )

    /// Works out the instant the reminder is due and pins it as `resolvedReminderDueDate`.
    ///
    /// **This is what makes the approved time the time that is set.** Every gate runs the resolve
    /// phase again, and "in 5 minutes" resolved at execution would move the reminder by however long
    /// the approval sat open. A pinned step is left exactly as it is, so only the first pass decides
    /// anything — the pin-once rule `RunningAppSwitchCapabilityAdapter` follows for its app.
    ///
    /// **An instant, not the wall-clock day and time** (PR #244, F2): the first version rewrote
    /// `calendarDay` and `reminderTime` as `YYYY-MM-DD` and `HH:mm`, and a clock time in the hour a
    /// fall-back repeats came back as its first occurrence at the next gate, an hour early.
    ///
    /// A step with nothing to remind about, or no usable time, becomes the question that would
    /// answer it.
    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        var resolved = plan
        for index in resolved.steps.indices where resolved.steps[index].operation == .createReminder {
            let step = resolved.steps[index]
            guard step.resolvedReminderDueDate == nil else {
                continue
            }
            guard !Self.trimmed(step.reminderTitle).isEmpty else {
                return ReadCalendarEventsCapabilityAdapter.clarification("What should Sonny remind you about?")
            }
            let due: Date?
            do {
                due = try ReminderDue.dueDate(
                    minutesFromNow: step.reminderMinutesFromNow,
                    time: step.reminderTime,
                    day: step.calendarDay,
                    now: context.now(),
                    calendar: context.calendar
                )
            } catch CalendarDayError.unrecognisedDay {
                return ReadCalendarEventsCapabilityAdapter.clarification("Which day should Sonny remind you?")
            } catch ReminderDueError.twoTimes, ReminderDueError.unrecognisedTime, ReminderDueError.minutesNotAfterNow {
                // Zero or fewer minutes asks too (PR #244, F6): it is a time the model misheard
                // rather than one the user can be refused for, and the sentence that used to reach
                // them — "up to a year ahead" — was about the other end of the range.
                return ReadCalendarEventsCapabilityAdapter.clarification("When should Sonny remind you?")
            }
            guard let due else {
                return ReadCalendarEventsCapabilityAdapter.clarification("When should Sonny remind you?")
            }
            resolved.steps[index].resolvedReminderDueDate = due
        }
        return resolved
    }

    /// **A time that has already passed is refused here, and only here.**
    ///
    /// `prepare` previews, so a user who asks for "today at 9" at ten o'clock is told at once. The
    /// gates after it do not preview, and that is deliberate: a reminder pinned for 15:05 whose
    /// approval was pressed at 15:06 is still the reminder the user allowed, and refusing it then
    /// would lose it. It is added, overdue, and Reminders shows it as such.
    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan, context: context)
        guard spec.due > context.now() else {
            throw ReminderDueError.timeHasPassed
        }
        return [previewValue(spec, context: context)]
    }

    /// **Tier 2 with an escalation that asks, classified `.affectsOthers`.**
    ///
    /// Under the consequence rule no tier asks on its own — tiers 0 to 2 run unless an escalation
    /// whose class asks first is present — so "tier 2 and asks first" is an escalation that stays at
    /// tier 2, which the rule already answers (`aDestructiveEscalationAsksEvenWhenTheTierArithmeticStaysAtTierTwo`
    /// pins that cell). Nothing about the rule changes; this is the first adapter to reach that cell.
    ///
    /// **Why `.affectsOthers` and not `.destructive`.** Adding a reminder destroys and replaces
    /// nothing, so `.destructive` would be false. It goes into the user's default Reminders list,
    /// which may be a list shared with other people, and EventKit offers no public way to ask whether
    /// it is. The escalation type's own rule for that is to fail closed into a class that asks, and
    /// never `.advisory`; of the two that ask, only this one describes something that can happen.
    ///
    /// The reason names the title and not the time, so it reads the same at every gate — an approval
    /// is matched to its reasons, and a reason that moved with the clock would never match. The time
    /// reaches both approval panels through `RiskApprovalCopy.involvedResource` instead, which consent
    /// does not compare (`AgentActionExecutor.involvedResource(in:metadata:)`, PR #244 F1).
    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let spec = try spec(in: plan, context: context)
        return CapabilityRiskAssessment(
            defaultTier: metadata.defaultRiskTier,
            escalations: [
                CapabilityRiskEscalation(
                    fromTier: .tier2,
                    toTier: .tier2,
                    reason: Self.escalationReason(title: spec.title),
                    consequence: .affectsOthers
                )
            ]
        )
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let spec = try spec(in: plan, context: context)

        var access = context.eventKit.accessState(for: .reminders)
        if access == .notDetermined {
            log(.act, "Asking macOS for access to your reminders")
            access = await context.eventKit.requestAccess(to: .reminders)
        }
        if let refusal = access.refusal(for: .reminders) {
            log(.summarize, "No access to reminders")
            throw refusal
        }

        let when = whenText(spec.due, context: context)
        log(.act, "Adding a reminder for \(when)")
        try context.eventKit.addReminder(title: spec.title, dueDate: spec.due, calendar: context.calendar)
        log(.summarize, "Reminder added")

        return AgentRunResult(
            plan: plan,
            previews: [previewValue(spec, context: context)],
            summary: "Added a reminder for \(when): \(spec.title)."
        )
    }

    public static func escalationReason(title: String) -> String {
        "This adds \u{201C}\(title)\u{201D} to your Reminders, where anyone you share that list with can see it."
    }

    private struct ReminderSpec {
        var title: String
        var due: Date
    }

    private func spec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> ReminderSpec {
        guard let step = plan.steps.first(where: { $0.operation == .createReminder }) else {
            throw AgentExecutionError.invalidPlan("create_reminder step is missing.")
        }
        let title = Self.trimmed(step.reminderTitle)
        guard !title.isEmpty else {
            throw AgentExecutionError.invalidPlan("create_reminder needs reminderTitle: what to remind the user about.")
        }
        if let pinned = step.resolvedReminderDueDate {
            return ReminderSpec(title: title, due: pinned)
        }
        guard let due = try ReminderDue.dueDate(
            minutesFromNow: step.reminderMinutesFromNow,
            time: step.reminderTime,
            day: step.calendarDay,
            now: context.now(),
            calendar: context.calendar
        ) else {
            throw AgentExecutionError.invalidPlan("create_reminder needs reminderMinutesFromNow or reminderTime.")
        }
        return ReminderSpec(title: title, due: due)
    }

    private func previewValue(_ spec: ReminderSpec, context: CapabilityExecutionContext) -> ActionPreview {
        ActionPreview(
            title: "Add reminder",
            details: [
                "Reminder: \(spec.title)",
                "When: \(whenText(spec.due, context: context))"
            ]
        )
    }

    /// `15:05 today`, `09:00 on Friday 18 September`.
    private func whenText(_ due: Date, context: CapabilityExecutionContext) -> String {
        let day = context.calendar.startOfDay(for: due)
        let clock = CalendarDay.clockTime(of: due, calendar: context.calendar)
        return "\(clock) \(CalendarDay.spokenName(of: day, now: context.now(), calendar: context.calendar))"
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
