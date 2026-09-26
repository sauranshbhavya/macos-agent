import Foundation

/// "What's on my calendar" — one day of the user's calendars, answered as a short list (SONNY-453).
///
/// **Tier 0, and it asks nothing**: a read of the user's own data that changes nothing (founders'
/// decision 2026-09-12). What it can raise is macOS's own Calendars prompt, once, at the first read —
/// never at preview, which touches no calendar at all.
public struct ReadCalendarEventsCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.calendar.read-events",
        displayName: "Read calendar",
        description: "Read one day of the user's calendars through EventKit and answer with a short list.",
        operations: [.readCalendarEvents],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .calendarsAccess)
        ],
        defaultRiskTier: .tier0
    )

    /// How many events the answer names before it says how many more there are. The widget shows a
    /// result in three lines, and a list that cannot fit them is a list nobody reads.
    public static let listedEventLimit = 5

    /// The longest title the list prints before cutting it short.
    public static let titleLimit = 60

    /// Pins the day as `YYYY-MM-DD`, so preview, assessment and execution read the same one.
    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        var resolved = plan
        for index in resolved.steps.indices where resolved.steps[index].operation == .readCalendarEvents {
            let day: Date
            do {
                day = try CalendarDay.startOfDay(
                    named: resolved.steps[index].calendarDay,
                    now: context.now(),
                    calendar: context.calendar
                )
            } catch CalendarDayError.unrecognisedDay {
                return Self.clarification("Which day should Sonny look at?")
            }
            resolved.steps[index].calendarDay = CalendarDay.pinned(day, calendar: context.calendar)
        }
        return resolved
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let day = try day(in: plan, context: context)
        return [previewValue(day: day, context: context)]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let day = try day(in: plan, context: context)
        // **The start of the next day, not this day's start plus a day** (PR #244, F7). Adding a day
        // keeps the time of day, so on a day whose midnight does not exist — `America/Santiago` on
        // 2026-09-06 starts at 01:00 — the window ran to 01:00 the next day and listed its first hour
        // under the wrong day.
        guard let dayAfter = context.calendar.date(byAdding: .day, value: 1, to: day) else {
            throw CalendarDayError.unrecognisedDay(CalendarDay.pinned(day, calendar: context.calendar))
        }
        let nextDay = context.calendar.startOfDay(for: dayAfter)

        var access = context.eventKit.accessState(for: .calendars)
        if access == .notDetermined {
            log(.act, "Asking macOS for access to your calendars")
            access = await context.eventKit.requestAccess(to: .calendars)
        }
        if let refusal = access.refusal(for: .calendars) {
            log(.summarize, "No access to calendars")
            throw refusal
        }

        let spokenDay = CalendarDay.spokenName(of: day, now: context.now(), calendar: context.calendar)
        log(.act, "Reading your calendar for \(spokenDay)")
        let events = try context.eventKit.events(from: day, to: nextDay)
            .filter { $0.start < nextDay && ($0.end > day || $0.start >= day) }
        log(.summarize, "Found \(events.count) event\(events.count == 1 ? "" : "s")")

        return AgentRunResult(
            plan: plan,
            previews: [previewValue(day: day, context: context)],
            summary: Self.summary(of: events, day: day, now: context.now(), calendar: context.calendar)
        )
    }

    /// The answer, as one sentence: `Today: all day Holiday, 09:00 Standup, and 2 more.`
    ///
    /// All-day events first, then by start time. An event that began on an earlier day is listed by
    /// when it ends, because the time it started is not a time on the day asked about.
    public static func summary(
        of events: [CalendarEventRecord],
        day: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        let spokenDay = CalendarDay.spokenName(of: day, now: now, calendar: calendar)
        guard !events.isEmpty else {
            return "Nothing on your calendar \(spokenDay)."
        }

        let ordered = events.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay {
                return lhs.isAllDay
            }
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            return lhs.title < rhs.title
        }
        var items = ordered.prefix(listedEventLimit).map { event -> String in
            let title = displayTitle(event.title)
            if event.isAllDay {
                return "all day \(title)"
            }
            if event.start < day {
                return "until \(CalendarDay.clockTime(of: event.end, calendar: calendar)) \(title)"
            }
            return "\(CalendarDay.clockTime(of: event.start, calendar: calendar)) \(title)"
        }
        if ordered.count > listedEventLimit {
            items.append("and \(ordered.count - listedEventLimit) more")
        }

        let heading = spokenDay.hasPrefix("on ") ? String(spokenDay.dropFirst(3)) : spokenDay
        return "\(heading.prefix(1).uppercased())\(heading.dropFirst()): \(items.joined(separator: ", "))."
    }

    private static func displayTitle(_ raw: String) -> String {
        let folded = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else {
            return "Untitled event"
        }
        guard folded.count > titleLimit else {
            return folded
        }
        return String(folded.prefix(titleLimit - 1)) + "…"
    }

    private func previewValue(day: Date, context: CapabilityExecutionContext) -> ActionPreview {
        ActionPreview(
            title: "Read calendar",
            details: ["Day: \(CalendarDay.spokenName(of: day, now: context.now(), calendar: context.calendar))"]
        )
    }

    private func day(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> Date {
        guard let step = plan.steps.first(where: { $0.operation == .readCalendarEvents }) else {
            throw AgentExecutionError.invalidPlan("read_calendar_events step is missing.")
        }
        return try CalendarDay.startOfDay(named: step.calendarDay, now: context.now(), calendar: context.calendar)
    }

    static func clarification(_ question: String) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-calendar",
                    operation: .clarify,
                    description: "Ask a question before using the calendar.",
                    question: question
                )
            ]
        )
    }
}
