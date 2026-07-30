import Foundation

public enum RoutineScheduleDecision: Equatable, Sendable {
    /// Nothing to do: disabled, or the most recent occurrence has already been handled.
    case notDue
    /// Run it now, for this occurrence.
    case due(occurrence: Date)
    /// An occurrence went unhandled and is now too old to be worth running — record it and move
    /// the baseline past it rather than firing a stale unattended run.
    case missed(occurrence: Date)
}

public struct OutstandingRoutine: Equatable, Sendable {
    public var routine: StoredRoutine
    public var decision: RoutineScheduleDecision

    public init(routine: StoredRoutine, decision: RoutineScheduleDecision) {
        self.routine = routine
        self.decision = decision
    }

    /// The occurrence this decision is about. Both non-`notDue` cases carry one, and the caller
    /// needs it for either outcome — a run and a skip both advance the baseline past it.
    public var occurrence: Date? {
        switch decision {
        case .notDue:
            return nil
        case .due(let occurrence), .missed(let occurrence):
            return occurrence
        }
    }
}

/// Pure date math: given schedules and a `now`, which routines have an outstanding occurrence.
///
/// Deliberately knows nothing about timers, execution, approval, or storage — everything here is a
/// function of its arguments, so the awkward cases (DST, month ends, window boundaries) are
/// testable without running anything. The calendar is injected rather than read from
/// `Calendar.current` so tests mean the same thing on any machine.
public enum RoutineScheduler {
    public static func decision(
        for schedule: RoutineSchedule,
        now: Date,
        calendar: Calendar = .current
    ) -> RoutineScheduleDecision {
        guard schedule.isEnabled else {
            return .notDue
        }
        guard let occurrence = mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar) else {
            return .notDue
        }
        // A nil baseline should not happen while enabled — `setEnabled(_:now:)` always anchors it —
        // but a hand-edited file could produce one. Treating it as "no baseline" cannot resurrect
        // history, because the catch-up window below still bounds how stale a run may be.
        let baseline = schedule.lastRunAt ?? .distantPast
        guard occurrence > baseline else {
            return .notDue
        }
        guard now.timeIntervalSince(occurrence) <= schedule.cadence.catchUpWindow else {
            return .missed(occurrence: occurrence)
        }
        return .due(occurrence: occurrence)
    }

    /// Routines with an outstanding occurrence, oldest occurrence first.
    ///
    /// Ordered rather than left in store order: `RoutineStore` hands back a dictionary, whose
    /// iteration order is not stable between loads, and a backlog should be worked through in the
    /// order it actually happened.
    public static func outstanding(
        in routines: [StoredRoutine],
        now: Date,
        calendar: Calendar = .current
    ) -> [OutstandingRoutine] {
        routines
            .compactMap { routine -> OutstandingRoutine? in
                guard let schedule = routine.schedule else {
                    return nil
                }
                let decision = decision(for: schedule, now: now, calendar: calendar)
                guard decision != .notDue else {
                    return nil
                }
                return OutstandingRoutine(routine: routine, decision: decision)
            }
            .sorted { ($0.occurrence ?? .distantPast) < ($1.occurrence ?? .distantPast) }
    }

    /// The latest scheduled occurrence at or exactly on `now`.
    ///
    /// "At or on" matters: a tick landing precisely on 09:00:00 must resolve to today's 09:00, not
    /// yesterday's, or the scheduler would fire a day-old catch-up instead of the run that just
    /// came due.
    public static func mostRecentOccurrence(
        of schedule: RoutineSchedule,
        atOrBefore now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        switch schedule.cadence {
        case .daily:
            return mostRecentDaily(schedule, atOrBefore: now, calendar: calendar)
        case .weekly:
            return mostRecentWeekly(schedule, atOrBefore: now, calendar: calendar)
        case .monthly:
            return mostRecentMonthly(schedule, atOrBefore: now, calendar: calendar)
        }
    }

    private static func mostRecentDaily(
        _ schedule: RoutineSchedule,
        atOrBefore now: Date,
        calendar: Calendar
    ) -> Date? {
        // Walks whole calendar days rather than subtracting 86,400 seconds: a spring-forward day is
        // 23 hours long, so fixed-second arithmetic drifts an hour and eventually skips or repeats
        // a day outright.
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now),
                  let candidate = time(schedule.hour, schedule.minute, on: day, calendar: calendar),
                  candidate <= now else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func mostRecentWeekly(
        _ schedule: RoutineSchedule,
        atOrBefore now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let weekday = schedule.weekday else {
            return nil
        }
        // At most 8 steps back: 7 covers every weekday, and the 8th covers the case where today is
        // the matching weekday but the run time has not arrived yet, which needs the previous week.
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now),
                  calendar.component(.weekday, from: day) == weekday,
                  let candidate = time(schedule.hour, schedule.minute, on: day, calendar: calendar),
                  candidate <= now else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func mostRecentMonthly(
        _ schedule: RoutineSchedule,
        atOrBefore now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let dayOfMonth = schedule.dayOfMonth else {
            return nil
        }
        // Two steps back is enough to find the most recent occurrence from anywhere in a month.
        for monthOffset in 0...1 {
            guard let monthAnchor = calendar.date(byAdding: .month, value: -monthOffset, to: now),
                  let candidate = occurrence(
                      dayOfMonth: dayOfMonth,
                      hour: schedule.hour,
                      minute: schedule.minute,
                      inMonthOf: monthAnchor,
                      calendar: calendar
                  ),
                  candidate <= now else {
                continue
            }
            return candidate
        }
        return nil
    }

    /// Resolves a day-of-month within whatever month `anchor` falls in, clamping past the end of
    /// short months. "Run on the 31st" reads as "end of month" — silently not running at all in
    /// April, June, September and November would be the more surprising reading, and February
    /// would lose the routine entirely.
    private static func occurrence(
        dayOfMonth: Int,
        hour: Int,
        minute: Int,
        inMonthOf anchor: Date,
        calendar: Calendar
    ) -> Date? {
        guard let monthRange = calendar.range(of: .day, in: .month, for: anchor) else {
            return nil
        }
        var components = calendar.dateComponents([.year, .month], from: anchor)
        components.day = min(dayOfMonth, monthRange.upperBound - 1)
        components.hour = hour
        components.minute = minute
        guard let day = calendar.date(from: components) else {
            return nil
        }
        return time(hour, minute, on: day, calendar: calendar)
    }

    /// `Calendar`'s own hour/minute setter, which resolves a wall-clock time that does not exist on
    /// a spring-forward day to the next valid instant instead of returning nil. A routine scheduled
    /// for 02:30 must still run on the day the clock jumps 02:00 → 03:00.
    private static func time(_ hour: Int, _ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}
