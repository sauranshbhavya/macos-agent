import Foundation
import Testing
@testable import MacAgent

/// SONNY-453. The calendar seam's default on `AgentViewModel` refuses and touches nothing, so no
/// fixture reaches this Mac's calendars by saying nothing; the shipping construction is therefore the
/// one place the live store is named, and this pins that it is — and that the executor it builds is
/// handed that store rather than the refusing default.
@Suite
struct EventKitWiringTests {
    @Test
    @MainActor
    func theShippingViewModelReadsTheRealCalendarAndItsExecutorIsHandedIt() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        // Spelled in two halves for `FocusRestoreWiringTests`' reason.
        let factory = "static func atItsRealStore" + "Locations("
        let start = try #require(source.range(of: factory), "the shipping construction is gone")
        let shipping = try MacAgentSource.braceBlock(
            of: String(source[start.lowerBound...]),
            openedBy: ") -> AgentViewModel {"
        )

        #expect(MacAgentSource.count(of: "eventKit: EventKitStore.forThisMac()", inText: shipping) == 1)
        // And nowhere else in the file: a second live store would be a fixture reading a calendar.
        #expect(MacAgentSource.count(of: "EventKitStore.forThisMac()", inText: source) == 1)
        #expect(source.contains("eventKit: any EventKitAccessing = UnavailableEventKitStore()"))
        // The executor is handed the view model's store, not left at its own refusing default.
        #expect(MacAgentSource.count(of: "eventKit: eventKit,", inText: source) == 1)
    }
}
