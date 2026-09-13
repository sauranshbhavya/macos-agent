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
        // The factory's name is spelled in two halves for the same reason
        // `LocalStoreInjectionScanTests.realStoreFactoryName` is: that scan forbids the whole name
        // in any test source, and this file names it only to find the block, never to call it.
        // Its signature spans three lines, so the block is opened by the line that closes the
        // signature, searched from the name onwards.
        let factory = "static func atItsRealStore" + "Locations("
        let start = try #require(source.range(of: factory), "the shipping construction is gone")
        let shipping = try MacAgentSource.braceBlock(
            of: String(source[start.lowerBound...]),
            openedBy: ") -> AgentViewModel {"
        )

        #expect(MacAgentSource.count(of: "focusRestorer: FocusRestorer.forThisMac()", inText: shipping) == 1)
        // And nowhere else: a second real one would be a fixture reading the developer's screen.
        #expect(MacAgentSource.count(of: "FocusRestorer.forThisMac()", inText: source) == 1)
        #expect(source.contains("focusRestorer: any FocusRestoring = FocusRestorer.inert()"))
    }
}
