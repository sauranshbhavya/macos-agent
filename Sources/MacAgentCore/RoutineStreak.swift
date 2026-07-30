import Foundation

/// The number the Routines row's yellow badge shows.
///
/// Counted in **scheduled occurrences, not calendar days** — that is what makes it mean anything
/// for a weekly or monthly routine. `docs/sonny-ui-backend-gaps.md` records a prior attempt that
/// wired this badge to `routine.steps.count`, which is wrong on its face since a step count does
/// not decay the way a streak does; counting days instead would be a subtler version of the same
/// mistake, permanently pinning every weekly routine at 1.
///
/// Deliberately *not* the same computation as `TaskHistoryInsights.currentStreakDays`, which is a
/// per-day streak across all of Sonny. Both are called "streak" in the UI but they answer different
/// questions — "how many days running have you used Sonny" versus "how many times running has this
/// routine done its job" — and a weekly routine cannot have a meaningful day streak.
public enum RoutineStreak {
    /// Consecutive most-recent occurrences that have a run recorded on the same calendar day.
    ///
    /// The occurrence that has not had its chance yet does not break the streak: if the most recent
    /// one has no run but is still inside its catch-up window, counting starts from the one before
    /// it. Without that, a daily 9am routine would show 0 every morning until it ran, which reads
    /// as "you lost your streak" rather than "it hasn't run yet".
    public static func current(
        for routine: StoredRoutine,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard let schedule = routine.schedule else {
            return 0
        }
        let runDays = Set(routine.effectiveRecentRunDates.map { calendar.startOfDay(for: $0) })
        guard !runDays.isEmpty else {
            return 0
        }
        guard var occurrence = RoutineScheduler.mostRecentOccurrence(
            of: schedule,
            atOrBefore: now,
            calendar: calendar
        ) else {
            return 0
        }

        // Grace for the occurrence that is still pending. Past its window it counts as missed and
        // genuinely does break the streak.
        if !runDays.contains(calendar.startOfDay(for: occurrence)),
           now.timeIntervalSince(occurrence) <= schedule.cadence.catchUpWindow {
            guard let earlier = previousOccurrence(before: occurrence, of: schedule, calendar: calendar) else {
                return 0
            }
            occurrence = earlier
        }

        var streak = 0
        // Bounded by how much history is even retained — walking further back could never find a
        // run, and an unbounded loop over date math is not something to leave to chance.
        while streak < StoredRoutine.recentRunDateLimit {
            guard runDays.contains(calendar.startOfDay(for: occurrence)) else {
                break
            }
            streak += 1
            guard let earlier = previousOccurrence(before: occurrence, of: schedule, calendar: calendar) else {
                break
            }
            occurrence = earlier
        }
        return streak
    }

    private static func previousOccurrence(
        before occurrence: Date,
        of schedule: RoutineSchedule,
        calendar: Calendar
    ) -> Date? {
        RoutineScheduler.mostRecentOccurrence(
            of: schedule,
            atOrBefore: occurrence.addingTimeInterval(-1),
            calendar: calendar
        )
    }
}

public struct RoutineCadenceSection: Equatable, Sendable, Identifiable {
    public var title: String
    public var routines: [StoredRoutine]

    public var id: String { title }
}

public enum RoutineGrouping {
    /// Cadence-grouped sections in the wireframe's own order — Daily, Weekly, Monthly — with
    /// unscheduled routines last under their own heading rather than hidden.
    ///
    /// Grouping is by the schedule a routine *has*, not by whether it is currently enabled: a
    /// disabled daily routine is still a daily routine, and dropping it into "Unscheduled" would
    /// make turning the toggle off look like it deleted the schedule.
    public static func groupedByCadence(routines: [StoredRoutine]) -> [RoutineCadenceSection] {
        var sections = RoutineCadence.allCases.map { cadence in
            RoutineCadenceSection(
                title: cadence.displayName,
                routines: routines
                    .filter { $0.schedule?.cadence == cadence }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
        let unscheduled = routines
            .filter { $0.schedule == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sections.append(RoutineCadenceSection(title: "Unscheduled", routines: unscheduled))
        return sections.filter { !$0.routines.isEmpty }
    }
}

/// Row text for a routine's schedule: the cadence line under its name, and the next-run text in the
/// trailing slot. Lives here rather than in the view so the date rules are unit-tested.
public enum RoutineScheduleDisplay {
    /// "Daily", "Weekly · Mon", "Monthly · 1st" — matching `11-MainAppRoutines.svg`.
    public static func cadenceLabel(for schedule: RoutineSchedule, calendar: Calendar = .current) -> String {
        switch schedule.cadence {
        case .daily:
            return "Daily"
        case .weekly:
            guard let weekday = schedule.weekday,
                  (1...7).contains(weekday) else {
                return "Weekly"
            }
            return "Weekly · \(calendar.shortWeekdaySymbols[weekday - 1])"
        case .monthly:
            guard let dayOfMonth = schedule.dayOfMonth else {
                return "Monthly"
            }
            return "Monthly · \(ordinal(dayOfMonth))"
        }
    }

    /// "Today, 9:00 AM" for the same day, "Mon, Apr 15" within the week, "May 1" beyond it —
    /// the three forms the wireframe actually shows.
    public static func nextRunText(
        for schedule: RoutineSchedule,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard schedule.isEnabled,
              let next = RoutineScheduler.nextOccurrence(of: schedule, after: now, calendar: calendar) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale

        if calendar.isDate(next, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return "Today, \(formatter.string(from: next))"
        }
        let daysAway = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: next).day ?? 0
        formatter.setLocalizedDateFormatFromTemplate(daysAway <= 7 ? "EEEMMMd" : "MMMd")
        return formatter.string(from: next)
    }

    private static func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
