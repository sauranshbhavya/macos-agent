import Foundation
import MacAgentCore

/// The calendar-and-reminders seam every test uses instead of this Mac's own (SONNY-453).
///
/// The founders' rule is that no test ever touches a real calendar, so this records every call a
/// capability makes and answers from its own fields. `calls` is what lets a test say that a preview
/// or an assessment reached no calendar at all — the property a dry run has to have — rather than
/// only that it produced the right words.
@MainActor
public final class RecordingEventKitStore: EventKitAccessing {
    public enum Call: Equatable, Sendable {
        case accessState(EventKitDataKind)
        case requestAccess(EventKitDataKind)
        case events(from: Date, to: Date)
        case addReminder(title: String, dueDate: Date)
    }

    public var calendarsAccess: EventKitAccessState
    public var remindersAccess: EventKitAccessState
    /// What a first-use request answers. The stored access becomes this, the way a real grant does.
    public var requestAnswer: EventKitAccessState
    public var storedEvents: [CalendarEventRecord]
    public var addReminderError: EventKitAccessError?
    public private(set) var calls: [Call] = []

    public init(
        calendarsAccess: EventKitAccessState = .granted,
        remindersAccess: EventKitAccessState = .granted,
        requestAnswer: EventKitAccessState = .granted,
        storedEvents: [CalendarEventRecord] = [],
        addReminderError: EventKitAccessError? = nil
    ) {
        self.calendarsAccess = calendarsAccess
        self.remindersAccess = remindersAccess
        self.requestAnswer = requestAnswer
        self.storedEvents = storedEvents
        self.addReminderError = addReminderError
    }

    public var addedReminders: [(title: String, dueDate: Date)] {
        calls.compactMap { call in
            guard case .addReminder(let title, let dueDate) = call else { return nil }
            return (title, dueDate)
        }
    }

    public func accessState(for kind: EventKitDataKind) -> EventKitAccessState {
        calls.append(.accessState(kind))
        switch kind {
        case .calendars:
            return calendarsAccess
        case .reminders:
            return remindersAccess
        }
    }

    public func requestAccess(to kind: EventKitDataKind) async -> EventKitAccessState {
        calls.append(.requestAccess(kind))
        switch kind {
        case .calendars:
            calendarsAccess = requestAnswer
        case .reminders:
            remindersAccess = requestAnswer
        }
        return requestAnswer
    }

    public func events(from start: Date, to end: Date) throws -> [CalendarEventRecord] {
        calls.append(.events(from: start, to: end))
        return storedEvents
    }

    public func addReminder(title: String, dueDate: Date, calendar: Calendar) throws {
        calls.append(.addReminder(title: title, dueDate: dueDate))
        if let addReminderError {
            throw addReminderError
        }
    }
}
