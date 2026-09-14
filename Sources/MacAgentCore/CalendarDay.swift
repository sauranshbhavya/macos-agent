import Foundation

/// A day as a command names it, turned into a real day on this Mac's calendar (SONNY-453).
///
/// **Why the planner writes a phrase rather than a date.** The planner's prompt carries no clock —
/// it is one fixed string, golden-pinned and cached — so a model asked for "Friday" cannot know
/// which date that is, and a model asked for "September 20" guesses the year. So the step carries
/// what the user said in a small closed vocabulary, and the date is worked out here, on the Mac,
/// against the Mac's own clock and calendar.
///
/// **Once, in the resolve phase.** `ReadCalendarEventsCapabilityAdapter` writes the day back onto
/// the step as `YYYY-MM-DD` before anything previews it, and a `YYYY-MM-DD` resolves to itself.
/// `CreateReminderCapabilityAdapter` pins the instant the reminder is due instead
/// (`AgentStep.resolvedReminderDueDate`), because a clock time can occur twice on one day and a day
/// cannot. So the day a read runs on is the day its preview named, and the time a reminder is set for
/// is the time its approval named — both approval panels render it through
/// `RiskApprovalCopy.involvedResource`, spelled by `absoluteName(of:calendar:)` below — however long
/// the panel sat open.
public enum CalendarDay {
    /// The start of the day `phrase` names.
    ///
    /// - `nil`, empty, or `today`: today.
    /// - `tomorrow`, `yesterday`.
    /// - A weekday name, `monday` to `sunday`: the next such day, today included — "what's on
    ///   Friday", asked on a Friday, is today.
    /// - `YYYY-MM-DD`: that date.
    /// - `MM-DD`: that date this year if it has not passed, otherwise next year.
    ///
    /// Case and surrounding space are ignored. Anything else is refused by name rather than guessed.
    public static func startOfDay(named phrase: String?, now: Date, calendar: Calendar) throws -> Date {
        let today = calendar.startOfDay(for: now)
        let word = (phrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch word {
        case "", "today":
            return today
        case "tomorrow":
            return try day(byAdding: 1, to: today, calendar: calendar)
        case "yesterday":
            return try day(byAdding: -1, to: today, calendar: calendar)
        default:
            break
        }

        if let weekday = weekdayNumbers[word] {
            let todayWeekday = calendar.component(.weekday, from: today)
            let ahead = (weekday - todayWeekday + 7) % 7
            return try day(byAdding: ahead, to: today, calendar: calendar)
        }

        let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) {
            return try date(year: year, month: month, day: dayOfMonth, calendar: calendar, phrase: word)
        }
        if parts.count == 2, parts[0].count == 2, parts[1].count == 2,
           let month = Int(parts[0]), let dayOfMonth = Int(parts[1]) {
            let thisYear = calendar.component(.year, from: today)
            let candidate = try date(year: thisYear, month: month, day: dayOfMonth, calendar: calendar, phrase: word)
            if candidate >= today {
                return candidate
            }
            return try date(year: thisYear + 1, month: month, day: dayOfMonth, calendar: calendar, phrase: word)
        }

        throw CalendarDayError.unrecognisedDay(phrase ?? "")
    }

    /// The pinned spelling of a day: `YYYY-MM-DD` in `calendar`.
    public static func pinned(_ startOfDay: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: startOfDay)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Whether `phrase` is already a pinned `YYYY-MM-DD` that `calendar` accepts as a real date.
    public static func isPinned(_ phrase: String?, calendar: Calendar) -> Bool {
        guard let phrase, phrase.count == 10, phrase.split(separator: "-").count == 3 else {
            return false
        }
        return (try? startOfDay(named: phrase, now: Date(timeIntervalSince1970: 0), calendar: calendar)) != nil
    }

    /// How a result sentence names a day: `today`, `tomorrow`, `yesterday`, or `on Friday 18 September`.
    public static func spokenName(of startOfDay: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: today, to: startOfDay).day ?? 0
        switch offset {
        case 0:
            return "today"
        case 1:
            return "tomorrow"
        case -1:
            return "yesterday"
        default:
            return "on \(dayName(of: startOfDay, calendar: calendar))"
        }
    }

    /// A time and a date with no word relative to today: `15:06 on Sunday 13 September`.
    ///
    /// **What an approval panel says, and why it is not `spokenName`.** An approval is assessed again
    /// at every gate, and "today" read before midnight is "yesterday" after it, so a panel line built
    /// from a relative word would read differently at two gates of one run. This reads the same at
    /// every gate for a pinned instant.
    public static func absoluteName(of date: Date, calendar: Calendar) -> String {
        "\(clockTime(of: date, calendar: calendar)) on \(dayName(of: date, calendar: calendar))"
    }

    /// A date with no word relative to today: `Sunday 13 September`.
    public static func dayName(of date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date)
    }

    /// A clock time in the calendar's own locale, as a list line or a reminder sentence shows it.
    public static func clockTime(of date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    private static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7
    ]

    private static func day(byAdding days: Int, to day: Date, calendar: Calendar) throws -> Date {
        guard let result = calendar.date(byAdding: .day, value: days, to: day) else {
            throw CalendarDayError.unrecognisedDay("")
        }
        return calendar.startOfDay(for: result)
    }

    /// Refuses a date the calendar would silently roll over — February 30 is not March 2.
    private static func date(year: Int, month: Int, day: Int, calendar: Calendar, phrase: String) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            throw CalendarDayError.unrecognisedDay(phrase)
        }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else {
            throw CalendarDayError.unrecognisedDay(phrase)
        }
        return calendar.startOfDay(for: date)
    }
}

/// When a reminder is due, from the step's own fields (SONNY-453).
///
/// Two shapes and never both: minutes from now ("in 5 minutes"), or a clock time with an optional
/// day ("at 17:30", "tomorrow at 9"). The planner is told to use one; a step carrying both, or
/// neither, is answered here rather than guessed at.
public enum ReminderDue {
    /// The latest a reminder may be set, in minutes from now. A year: far enough for anything a
    /// person says as "in N minutes", near enough that a model's arithmetic slip is refused rather
    /// than filed a century out.
    public static let maxMinutesFromNow = 60 * 24 * 366

    /// The due date the fields describe, or `nil` when they name no time at all.
    ///
    /// - Minutes from now: now plus that many minutes, rounded up to the next whole minute, so a
    ///   reminder never arrives early. Instant arithmetic, so a daylight-saving change between now and
    ///   then moves nothing.
    /// - A clock time with no day: its next occurrence after now — today, or tomorrow if every
    ///   occurrence today has gone.
    /// - A clock time with a day: its first occurrence on that day that is still ahead, or the first
    ///   occurrence if none is — refusing a past time is `CreateReminderCapabilityAdapter.preview`'s
    ///   job, not this function's, and the reason is recorded there.
    ///
    /// **"Occurrence", because a clock time is not always one instant** (PR #244, F2). In the hour a
    /// daylight-saving fall-back repeats, `01:30` happens twice, and Foundation's
    /// `date(bySettingHour:minute:second:of:)` answers the first; asked at 01:10 in the second pass,
    /// that first one has gone and the time rolled to tomorrow. Both occurrences are considered, in
    /// order. A time the spring-forward skips (`02:30`) takes the next time that exists (`03:00`).
    public static func dueDate(
        minutesFromNow: Int?,
        time: String?,
        day: String?,
        now: Date,
        calendar: Calendar
    ) throws -> Date? {
        let trimmedTime = time?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clock = (trimmedTime?.isEmpty ?? true) ? nil : trimmedTime
        let trimmedDay = day?.trimmingCharacters(in: .whitespacesAndNewlines)
        let namedDay = (trimmedDay?.isEmpty ?? true) ? nil : trimmedDay

        if let minutesFromNow {
            guard clock == nil, namedDay == nil else {
                throw ReminderDueError.twoTimes
            }
            guard minutesFromNow >= 1 else {
                throw ReminderDueError.minutesNotAfterNow
            }
            guard minutesFromNow <= maxMinutesFromNow else {
                throw ReminderDueError.minutesOutOfRange
            }
            let due = now.addingTimeInterval(TimeInterval(minutesFromNow * 60))
            return try roundedUpToMinute(due, calendar: calendar)
        }

        // A day with no time — "remind me tomorrow" — names no time either, and gets the same
        // question as a step that names nothing.
        guard let clock else {
            return nil
        }
        let (hour, minute) = try parseClock(clock)
        let startOfDay = try CalendarDay.startOfDay(named: namedDay, now: now, calendar: calendar)
        let occurrences = try self.occurrences(hour: hour, minute: minute, on: startOfDay, calendar: calendar)
        if let ahead = occurrences.first(where: { $0 > now }) {
            return ahead
        }
        guard namedDay == nil else {
            return occurrences[0]
        }
        let tomorrow = try CalendarDay.startOfDay(named: "tomorrow", now: now, calendar: calendar)
        return try self.occurrences(hour: hour, minute: minute, on: tomorrow, calendar: calendar)[0]
    }

    private static func parseClock(_ clock: String) throws -> (Int, Int) {
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw ReminderDueError.unrecognisedTime(clock)
        }
        return (hour, minute)
    }

    /// Every instant `hour:minute` names on the day starting at `startOfDay`, earliest first: one on
    /// an ordinary day, two in a repeated hour, and the next time that exists for one a
    /// spring-forward skips.
    private static func occurrences(hour: Int, minute: Int, on startOfDay: Date, calendar: Calendar) throws -> [Date] {
        let found = [Calendar.RepeatedTimePolicy.first, .last].compactMap { policy in
            calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: startOfDay,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: policy,
                direction: .forward
            )
        }
        let distinct = Array(Set(found)).sorted()
        guard !distinct.isEmpty else {
            throw ReminderDueError.unrecognisedTime(String(format: "%02d:%02d", hour, minute))
        }
        return distinct
    }

    private static func roundedUpToMinute(_ date: Date, calendar: Calendar) throws -> Date {
        guard let floor = calendar.dateInterval(of: .minute, for: date)?.start else {
            throw ReminderDueError.minutesOutOfRange
        }
        return floor == date ? date : floor.addingTimeInterval(60)
    }
}

public enum CalendarDayError: Error, Equatable, LocalizedError {
    case unrecognisedDay(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognisedDay:
            return "Sonny couldn't tell which day you meant."
        }
    }
}

public enum ReminderDueError: Error, Equatable, LocalizedError {
    case twoTimes
    /// Zero or fewer minutes from now (PR #244, F6). Its own case, because the sentence for the other
    /// end of the range — "up to a year ahead" — is false about it.
    case minutesNotAfterNow
    case minutesOutOfRange
    case unrecognisedTime(String)
    case timeHasPassed

    public var errorDescription: String? {
        switch self {
        case .twoTimes, .unrecognisedTime:
            return "Sonny couldn't tell when to remind you."
        case .minutesNotAfterNow:
            return "A reminder needs a time after now."
        case .minutesOutOfRange:
            return "Sonny can set a reminder up to a year ahead."
        case .timeHasPassed:
            return "That time has already passed."
        }
    }
}
