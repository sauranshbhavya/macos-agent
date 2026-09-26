import Foundation

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
