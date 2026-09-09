import Testing
@testable import MacAgent

/// The menu-bar item's state mapping. A value type, so the precedence is asserted directly rather
/// than read off an `NSStatusItem` this repository has no way to render.
@Suite("Menu bar item state")
struct StatusItemPresentationTests {
    @Test
    func idleIsTheUntintedInverseGlyphWithTheBareName() {
        let presentation = StatusItemPresentation.forState(isRunning: false, isAwaitingApproval: false, hasFailure: false)
        #expect(presentation == .idle)
        #expect(presentation.systemImageName == "wand.and.stars.inverse")
        #expect(presentation.tint == .plain)
        #expect(presentation.accessibilityLabel == "Sonny")
    }

    @Test
    func workingIsTheAccentTint() {
        let presentation = StatusItemPresentation.forState(isRunning: true, isAwaitingApproval: false, hasFailure: false)
        #expect(presentation == .working)
        #expect(presentation.tint == .accent)
    }

    /// A question waiting for the user outranks the work it is waiting inside of: the widget's own
    /// precedence, mirrored so the bar and the panel never disagree about what Sonny is doing.
    @Test
    func waitingOutranksWorking() {
        let presentation = StatusItemPresentation.forState(isRunning: true, isAwaitingApproval: true, hasFailure: false)
        #expect(presentation == .waiting)
        #expect(presentation.tint == .attention)
    }

    /// A failure shows only once the run has stopped, the same rule `CommandCenterAttentionPanel`
    /// applies to its failure state.
    @Test
    func aFailureShowsOnlyWhenNothingIsRunning() {
        #expect(StatusItemPresentation.forState(isRunning: true, isAwaitingApproval: false, hasFailure: true) == .working)
        #expect(StatusItemPresentation.forState(isRunning: false, isAwaitingApproval: false, hasFailure: true) == .failed)
    }

    /// Every state that is not idle draws the filled glyph; the inverse glyph is idle's alone, so a
    /// glance at the bar distinguishes "nothing happening" from everything else before colour.
    @Test
    func onlyIdleUsesTheInverseGlyph() {
        for presentation in [StatusItemPresentation.working, .waiting, .failed] {
            #expect(presentation.systemImageName == "wand.and.stars")
        }
    }
}
