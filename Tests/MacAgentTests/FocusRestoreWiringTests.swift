import Foundation
import Testing
@testable import MacAgent

/// SONNY-451. The focus restorer's default on `AgentViewModel` is inert, so no fixture reads this
/// Mac's frontmost app by saying nothing; the shipping construction is therefore the one place
/// the real one is named, and this pins that it is.
@Suite
struct FocusRestoreWiringTests {
    @Test
    @MainActor
    func theShippingViewModelRestoresFocusThroughLaunchServices() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let shipping = try MacAgentSource.braceBlock(of: source, openedBy: "static func atItsRealStoreLocations(")

        #expect(MacAgentSource.count(of: "focusRestorer: FocusRestorer.forThisMac()", inText: shipping) == 1)
        // And nowhere else: a second real one would be a fixture reading the developer's screen.
        #expect(MacAgentSource.count(of: "FocusRestorer.forThisMac()", inText: source) == 1)
        #expect(source.contains("focusRestorer: any FocusRestoring = FocusRestorer.inert()"))
    }
}
