import EventKit
import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// SONNY-453: the Calendars and Reminders rows, in the microphone row's three states, and one
/// meaning for a system status shared with the two capabilities.
struct PermissionReadinessEventKitTests {
    private func row(_ id: String, calendars: EKAuthorizationStatus = .fullAccess, reminders: EKAuthorizationStatus = .fullAccess) throws -> PermissionReadinessItem {
        let items = PermissionReadinessService
            .deterministic(calendarsStatus: calendars, remindersStatus: reminders)
            .currentStatus(modelAccess: .signedIn, planAccess: .confirmed, hotKeyReady: true)
        return try #require(items.first { $0.id == id })
    }

    @Test
    func theCalendarsRowReadsEachStatusInPlainWords() throws {
        let cases: [(EKAuthorizationStatus, PermissionReadinessState, String)] = [
            (.fullAccess, .ready, "Sonny can read your calendars."),
            (.notDetermined, .unknown, "Sonny will ask the first time you check your calendar."),
            (.denied, .needsAction, "Allow Sonny in System Settings \u{203A} Privacy & Security \u{203A} Calendars."),
            (.restricted, .needsAction, "Allow Sonny in System Settings \u{203A} Privacy & Security \u{203A} Calendars."),
            // Write-only cannot read, and reading is all Sonny does with a calendar.
            (.writeOnly, .needsAction, "Allow Sonny in System Settings \u{203A} Privacy & Security \u{203A} Calendars.")
        ]
        for (status, state, detail) in cases {
            let item = try row("calendars", calendars: status)
            #expect(item.title == "Calendars")
            #expect(item.state == state, "\(status.rawValue)")
            #expect(item.detail == detail, "\(status.rawValue)")
        }
    }

    @Test
    func theRemindersRowReadsEachStatusInPlainWords() throws {
        let cases: [(EKAuthorizationStatus, PermissionReadinessState, String)] = [
            (.fullAccess, .ready, "Sonny can add reminders."),
            (.notDetermined, .unknown, "Sonny will ask the first time you add a reminder."),
            (.denied, .needsAction, "Allow Sonny in System Settings \u{203A} Privacy & Security \u{203A} Reminders."),
            (.restricted, .needsAction, "Allow Sonny in System Settings \u{203A} Privacy & Security \u{203A} Reminders.")
        ]
        for (status, state, detail) in cases {
            let item = try row("reminders", reminders: status)
            #expect(item.title == "Reminders")
            #expect(item.state == state, "\(status.rawValue)")
            #expect(item.detail == detail, "\(status.rawValue)")
        }
    }

    /// The two rows read their own grants and not each other's.
    @Test
    func eachRowReadsItsOwnGrant() throws {
        #expect(try row("calendars", calendars: .denied, reminders: .fullAccess).state == .needsAction)
        #expect(try row("reminders", calendars: .denied, reminders: .fullAccess).state == .ready)
        #expect(try row("calendars", calendars: .fullAccess, reminders: .denied).state == .ready)
        #expect(try row("reminders", calendars: .fullAccess, reminders: .denied).state == .needsAction)
    }

    /// The one mapping the rows and the capabilities share.
    @Test
    func aSystemStatusHasOneMeaning() {
        #expect(EventKitAccessState(.fullAccess) == .granted)
        #expect(EventKitAccessState(.notDetermined) == .notDetermined)
        #expect(EventKitAccessState(.denied) == .denied)
        #expect(EventKitAccessState(.restricted) == .denied)
        #expect(EventKitAccessState(.writeOnly) == .denied)
    }
}
