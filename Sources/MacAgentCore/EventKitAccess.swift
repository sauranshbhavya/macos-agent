@preconcurrency import EventKit
import Foundation

/// Which of the two EventKit stores a question is about (SONNY-453).
public enum EventKitDataKind: String, CaseIterable, Equatable, Sendable {
    case calendars
    case reminders
}

/// What Sonny may do with one EventKit store, as the system answers it (SONNY-453).
///
/// **Three values rather than `EKAuthorizationStatus` itself**, which is the opposite of the choice
/// `MicrophonePermissionChecking` makes and for a reason that choice does not have: here two callers
/// read the same system value — the Permission Readiness rows and the two capabilities — and they must
/// not disagree about what it means. `init(_:)` below is the one place a status becomes a meaning.
public enum EventKitAccessState: Equatable, Sendable {
    /// Nobody has asked yet. The capability asks at first use; the readiness row says it will.
    case notDetermined
    /// Full access. Reading events and writing reminders both need it.
    case granted
    /// Denied, or write-only access. Sonny refuses rather than asking again, because macOS will not
    /// show the prompt a second time — and the user can change it in System Settings.
    case denied
    /// Restricted: something other than the user — device management, Screen Time — decides, and
    /// the switch in System Settings is not theirs to turn (PR #244, F6). Refused in words that do
    /// not send them to it.
    case restricted
    /// No calendar store is wired into this copy of Sonny. **Never a system answer** — `init(_:)`
    /// cannot produce it — only `UnavailableEventKitStore`'s, so an unwired seam says so rather than
    /// reading as a refusal the user could fix (PR #244, F6).
    case unavailable

    /// **Write-only counts as denied**, because a calendar read is the only thing Sonny does with
    /// calendars and write-only access cannot read. Reminders have no write-only grant at all.
    ///
    /// `default` rather than naming `.denied` and `.writeOnly` beside `@unknown default`:
    /// `.authorized` is `.fullAccess` under a name deprecated in macOS 14, and both spellings of an
    /// exhaustive switch over this enum warn. Anything that is not full access, not-yet-asked or
    /// restricted is refused, which is also the direction a status macOS adds later should fail in
    /// until someone decides what it means.
    public init(_ status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess:
            self = .granted
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        default:
            self = .denied
        }
    }
}

/// One event on the user's calendar, as much of it as a short list needs.
public struct CalendarEventRecord: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// **The one seam between Sonny and the user's calendars and reminders** (SONNY-453).
///
/// The founders' decision of 2026-09-12 is that no test ever touches a real calendar, so every
/// EventKit call a capability makes goes through this protocol and nothing else. The live
/// implementation is `EventKitStore`; the default everywhere a construction site can say nothing is
/// `UnavailableEventKitStore`, which touches nothing and refuses — the focus restorer's shape
/// (SONNY-451), and for its reason: a fixture that never heard of calendars must not be one plan away
/// from reading the developer's.
///
/// Main-actor isolated because every caller is a capability adapter, which is, and because
/// `EKEventStore` is not `Sendable`: keeping the store on one actor is what lets the live
/// implementation hold one at all.
public protocol EventKitAccessing: Sendable {
    @MainActor
    func accessState(for kind: EventKitDataKind) -> EventKitAccessState

    /// Asks macOS for access and returns the answer. Called only when `accessState(for:)` says
    /// `.notDetermined`, so it is the first-use prompt and nothing else.
    @MainActor
    func requestAccess(to kind: EventKitDataKind) async -> EventKitAccessState

    /// Every event overlapping `[start, end)`, from every calendar, cancelled events excluded.
    @MainActor
    func events(from start: Date, to end: Date) throws -> [CalendarEventRecord]

    /// Adds one reminder to the default Reminders list, due at `dueDate`, with an alert at that time.
    @MainActor
    func addReminder(title: String, dueDate: Date, calendar: Calendar) throws
}

extension EventKitAccessState {
    /// The refusal for a state that is not `.granted`, or `nil` when it is — one place, so the two
    /// capabilities cannot give one state two sentences. `.notDetermined` is answered too, as a
    /// denial, for the caller that reads it after a request that came back unanswered.
    func refusal(for kind: EventKitDataKind) -> EventKitAccessError? {
        switch (self, kind) {
        case (.granted, _):
            return nil
        case (.denied, .calendars), (.notDetermined, .calendars):
            return .calendarsDenied
        case (.denied, .reminders), (.notDetermined, .reminders):
            return .remindersDenied
        case (.restricted, .calendars):
            return .calendarsRestricted
        case (.restricted, .reminders):
            return .remindersRestricted
        case (.unavailable, _):
            return .unavailable
        }
    }
}

public enum EventKitAccessError: Error, Equatable, LocalizedError {
    /// The user has not allowed Sonny to read their calendars, or allowed less than a read needs.
    case calendarsDenied
    /// The user has not allowed Sonny to use their reminders.
    case remindersDenied
    /// Access to calendars is restricted on this Mac, which the user cannot change themselves.
    case calendarsRestricted
    /// Access to reminders is restricted on this Mac, which the user cannot change themselves.
    case remindersRestricted
    /// A construction site that never wired the live store asked for calendar data.
    case unavailable
    /// The user has no list new reminders can go into.
    case noDefaultReminderList
    /// EventKit refused a save or a read for a reason of its own.
    case storeFailed

    public var errorDescription: String? {
        switch self {
        case .calendarsDenied:
            return "Sonny doesn't have access to your calendars. Allow it in System Settings \u{203A} Privacy & Security \u{203A} Calendars."
        case .remindersDenied:
            return "Sonny doesn't have access to your reminders. Allow it in System Settings \u{203A} Privacy & Security \u{203A} Reminders."
        case .calendarsRestricted:
            return "Access to calendars is restricted on this Mac, so Sonny can't read them."
        case .remindersRestricted:
            return "Access to reminders is restricted on this Mac, so Sonny can't add one."
        case .unavailable:
            return "This copy of Sonny isn't connected to calendars or reminders."
        case .noDefaultReminderList:
            return "Sonny couldn't find a Reminders list to add this to."
        case .storeFailed:
            return "Sonny couldn't reach your calendars or reminders."
        }
    }
}

/// The default seam: refuses everything and touches nothing. It answers `.unavailable` rather than
/// `.denied`, so a construction site that never wired a store reads as exactly that (PR #244, F6).
public struct UnavailableEventKitStore: EventKitAccessing {
    public init() {}

    public func accessState(for kind: EventKitDataKind) -> EventKitAccessState {
        .unavailable
    }

    public func requestAccess(to kind: EventKitDataKind) async -> EventKitAccessState {
        .unavailable
    }

    public func events(from start: Date, to end: Date) throws -> [CalendarEventRecord] {
        throw EventKitAccessError.unavailable
    }

    public func addReminder(title: String, dueDate: Date, calendar: Calendar) throws {
        throw EventKitAccessError.unavailable
    }
}

/// The live seam, over one `EKEventStore`.
@MainActor
public final class EventKitStore: EventKitAccessing {
    private let store = EKEventStore()

    private init() {}

    public static func forThisMac() -> EventKitStore {
        EventKitStore()
    }

    public func accessState(for kind: EventKitDataKind) -> EventKitAccessState {
        EventKitAccessState(EKEventStore.authorizationStatus(for: Self.entityType(for: kind)))
    }

    /// The completion-handler form rather than the `async` one: the `async` form is nonisolated, so
    /// calling it would send this actor's non-`Sendable` store across an isolation boundary. The
    /// handler hands back only a `Bool` and an error, which cross freely.
    ///
    /// The answer is read back from `authorizationStatus` rather than taken from the `Bool`, so a
    /// grant and a refusal are both reported through the one mapping every other reader uses.
    public func requestAccess(to kind: EventKitDataKind) async -> EventKitAccessState {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume: @Sendable (Bool, (any Error)?) -> Void = { _, _ in continuation.resume() }
            switch kind {
            case .calendars:
                store.requestFullAccessToEvents(completion: resume)
            case .reminders:
                store.requestFullAccessToReminders(completion: resume)
            }
        }
        return accessState(for: kind)
    }

    public func events(from start: Date, to end: Date) throws -> [CalendarEventRecord] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { event in
                CalendarEventRecord(
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay
                )
            }
    }

    public func addReminder(title: String, dueDate: Date, calendar: Calendar) throws {
        guard let list = store.defaultCalendarForNewReminders() else {
            throw EventKitAccessError.noDefaultReminderList
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        var due = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        due.calendar = calendar
        due.timeZone = calendar.timeZone
        reminder.dueDateComponents = due
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitAccessError.storeFailed
        }
    }

    private static func entityType(for kind: EventKitDataKind) -> EKEntityType {
        switch kind {
        case .calendars:
            return .event
        case .reminders:
            return .reminder
        }
    }
}
