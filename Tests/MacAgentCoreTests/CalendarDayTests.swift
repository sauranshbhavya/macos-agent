import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-453: what a named day and a reminder's time mean, against a fixed clock and calendar.
struct CalendarDayTests {
    private let calendar = FixedCalendar.calendar
    private let now = FixedCalendar.now
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        FixedCalendar.date(y, m, d, h, min)
    }
    private func day(_ phrase: String?) throws -> Date {
        try CalendarDay.startOfDay(named: phrase, now: now, calendar: calendar)
    }

    @Test
    func theClosedVocabularyResolvesToTheDayItNames() throws {
        #expect(try day(nil) == date(2026, 9, 13))
        #expect(try day("") == date(2026, 9, 13))
        #expect(try day(" Today ") == date(2026, 9, 13))
        #expect(try day("tomorrow") == date(2026, 9, 14))
        #expect(try day("yesterday") == date(2026, 9, 12))
        // A weekday is the next one, today included.
        #expect(try day("sunday") == date(2026, 9, 13))
        #expect(try day("MONDAY") == date(2026, 9, 14))
        #expect(try day("saturday") == date(2026, 9, 19))
        #expect(try day("2026-12-25") == date(2026, 12, 25))
        #expect(try day("2025-01-02") == date(2025, 1, 2))
        // MM-DD is this year unless it has passed, then next year.
        #expect(try day("09-13") == date(2026, 9, 13))
        #expect(try day("12-25") == date(2026, 12, 25))
        #expect(try day("09-12") == date(2027, 9, 12))
    }

    @Test
    func anythingElseIsRefusedRatherThanRolledOver() {
        for phrase in ["someday", "02-30", "2026-02-30", "2026-13-01", "9-13", "fri", "2026-9-13"] {
            #expect(throws: CalendarDayError.unrecognisedDay(phrase), "\(phrase)") {
                _ = try day(phrase)
            }
        }
    }

    @Test
    func aPinnedDayResolvesToItselfWhateverTheClockSays() throws {
        let pinned = CalendarDay.pinned(try day("friday"), calendar: calendar)
        #expect(pinned == "2026-09-18")
        #expect(CalendarDay.isPinned(pinned, calendar: calendar))
        #expect(!CalendarDay.isPinned("friday", calendar: calendar))
        let aWeekLater = now.addingTimeInterval(7 * 24 * 3600)
        #expect(try CalendarDay.startOfDay(named: pinned, now: aWeekLater, calendar: calendar) == date(2026, 9, 18))
    }

    @Test
    func minutesFromNowRoundUpToTheMinuteAndNeverArriveEarly() throws {
        let due = { (minutes: Int, at: Date) in
            try ReminderDue.dueDate(minutesFromNow: minutes, time: nil, day: nil, now: at, calendar: calendar)
        }
        #expect(try due(5, now) == date(2026, 9, 13, 15, 6))
        #expect(try due(5, date(2026, 9, 13, 15, 0)) == date(2026, 9, 13, 15, 5))
        #expect(try due(120, now) == date(2026, 9, 13, 17, 1))
        #expect(try due(ReminderDue.maxMinutesFromNow, date(2026, 9, 13, 15, 0)) != nil)
        // Each end of the range has its own case, because each has its own true sentence (PR #244, F6).
        for minutes in [0, -5] {
            let thrown = #expect(throws: ReminderDueError.minutesNotAfterNow) { _ = try due(minutes, now) }
            #expect(thrown?.localizedDescription == "A reminder needs a time after now.")
        }
        let tooFar = #expect(throws: ReminderDueError.minutesOutOfRange) { _ = try due(ReminderDue.maxMinutesFromNow + 1, now) }
        #expect(tooFar?.localizedDescription == "Sonny can set a reminder up to a year ahead.")
    }

    @Test
    func aClockTimeRollsForwardOnlyWhenNoDayWasNamed() throws {
        let due = { (time: String, day: String?) in
            try ReminderDue.dueDate(minutesFromNow: nil, time: time, day: day, now: now, calendar: calendar)
        }
        #expect(try due("17:30", nil) == date(2026, 9, 13, 17, 30))
        #expect(try due("09:00", nil) == date(2026, 9, 14, 9))
        #expect(try due("15:00", nil) == date(2026, 9, 14, 15))
        #expect(try due("09:00", "today") == date(2026, 9, 13, 9))
        #expect(try due("09:00", "friday") == date(2026, 9, 18, 9))
        #expect(throws: ReminderDueError.twoTimes) {
            _ = try ReminderDue.dueDate(minutesFromNow: 5, time: nil, day: "tomorrow", now: now, calendar: calendar)
        }
        for bad in ["9:00", "24:00", "12:60", "noon", "12:00:00"] {
            #expect(throws: ReminderDueError.unrecognisedTime(bad)) { _ = try due(bad, nil) }
        }
        #expect(try ReminderDue.dueDate(minutesFromNow: nil, time: nil, day: "tomorrow", now: now, calendar: calendar) == nil)
    }
}
