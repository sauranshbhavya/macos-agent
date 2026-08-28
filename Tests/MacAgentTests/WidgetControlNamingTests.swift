import Foundation
import Testing
@testable import MacAgent

/// What the floating widget's icon-only controls call themselves (SONNY-251).
///
/// **The ticket was filed as four controls sharing one doubt and it was not that.** Its finding was
/// that four `.help` call sites in `FloatingWidgetView.swift` name their controls only through a
/// tooltip the same file recorded as unreliable, and that "VoiceOver is unaffected throughout — the
/// accessibility labels are separate and solid". Two things had changed by the time it was picked
/// up, and one of them was never true:
///
/// - The file no longer records `.help` as unreliable in the widget. SONNY-295 scoped that claim to
///   the mic button, which is the control it was measured on, after the founder hovered the resume
///   offer's tick and cross on 2026-08-26 and both tooltips appeared.
/// - The compact capsule had no `.accessibilityLabel` at all. So the one control the ticket calls
///   "the collapsed widget's only name" named itself on neither channel, while the other three
///   carried a full accessibility name throughout.
///
/// **So the durable thing to hold is the pairing, not the tooltip.** A tooltip is evidence about one
/// hover on one Mac; whether a control has a VoiceOver name is a property of the source, and it is
/// the property that was actually broken. These scans read `Sources/MacAgent/` because this
/// repository has no SwiftUI inspection harness — the same footing every other panel-shape pin in
/// this target is on (`MacAgentSource`).
@MainActor
struct WidgetControlNamingTests {
    private func widgetSource() throws -> String {
        try MacAgentSource.read("FloatingWidgetView.swift")
    }

    /// Lines of the comment-stripped file, trimmed. Comment lines are already gone, so a note
    /// written between a control's two names does not separate them here.
    private func widgetLines() throws -> [String] {
        try widgetSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// **Every tooltip in the widget sits directly beneath a VoiceOver name.**
    ///
    /// The convention is positional on purpose: adjacency is what a diff shows and what a textual
    /// scan can read without parsing Swift, and the failure it guards against — a `.help` added to a
    /// wordless control with nothing else naming it — is exactly what shipped on the compact
    /// capsule. A control that wants a tooltip and no accessibility name has to break this test to
    /// get one, which is the point.
    @Test
    func everyTooltipInTheWidgetSitsBesideAVoiceOverName() throws {
        let lines = try widgetLines()
        let tooltipIndices = lines.indices.filter { lines[$0].hasPrefix(".help(") }

        // The population, enumerated rather than counted: four icon-only controls, and the count is
        // asserted so a fifth cannot arrive without this test being read.
        #expect(tooltipIndices.count == 4)

        for index in tooltipIndices {
            #expect(index > 0, "a tooltip cannot be the file's first line")
            let previous = lines[index - 1]
            #expect(
                previous.hasPrefix(".accessibilityLabel("),
                "\(lines[index]) has \(previous) above it, not a VoiceOver name"
            )
        }
    }

    /// The four, by the words each one carries — so a reader meets the population rather than a
    /// number, and so a control that quietly changed owner is visible here.
    ///
    /// Three read their words from a presentation type shared with Command Center or with the
    /// task-naming helpers; the capsule's own owner is `CompactCapsulePresentation`, added by this
    /// ticket for exactly that reason.
    @Test
    func theWidgetsFourTooltipsReadTheirWordsFromAnOwnerRatherThanALiteral() throws {
        let source = try widgetSource()

        #expect(MacAgentSource.count(of: ".help(CompactCapsulePresentation.expandLabel)", inText: source) == 1)
        #expect(MacAgentSource.count(of: ".help(ClarificationPresentation.cancelLabel)", inText: source) == 1)
        #expect(MacAgentSource.count(of: ".help(ResumeOfferPresentation.declineLabel)", inText: source) == 1)
        #expect(MacAgentSource.count(of: ".help(ResumeOfferPresentation.continueLabel)", inText: source) == 1)

        // No literal anywhere in the view. The words were a bare string until this ticket, which is
        // how the tooltip and the (absent) VoiceOver name could ever have said different things.
        #expect(MacAgentSource.count(of: "\"Open Sonny\"", inText: source) == 0)
    }

    /// The capsule's own two names come from one string, so they cannot drift apart.
    @Test
    func theCompactCapsuleNamesItselfOnBothChannelsFromOneString() throws {
        let capsule = try MacAgentSource.region(
            of: widgetSource(),
            from: "private var compactCapsule: some View {",
            to: "var state: WidgetState {"
        )

        #expect(MacAgentSource.count(of: ".accessibilityLabel(CompactCapsulePresentation.expandLabel)", inText: capsule) == 1)
        #expect(MacAgentSource.count(of: ".help(CompactCapsulePresentation.expandLabel)", inText: capsule) == 1)
        #expect(CompactCapsulePresentation.expandLabel == "Open Sonny")
    }

    /// **The words the capsule and the menu bar share, and the fact that they do different things.**
    ///
    /// `AppDelegate`'s menu item titled "Open Sonny" opens the Command Center window; the capsule
    /// expands the floating widget. Renaming either is the founders' call, so this asserts the
    /// collision rather than resolving it — if one of them is reworded, this test says so and the
    /// record on `CompactCapsulePresentation` and SONNY-338 gets read instead of rediscovered.
    @Test
    func theCapsuleAndTheMenuBarStillShareThreeWordsForTwoDestinations() throws {
        let appDelegate = try MacAgentSource.read("AppDelegate.swift")

        #expect(MacAgentSource.count(of: "withTitle: \"Open Sonny\"", inText: appDelegate) == 1)
        #expect(MacAgentSource.count(of: "openCommandCenter", inText: appDelegate) >= 1)
        #expect(CompactCapsulePresentation.expandLabel == "Open Sonny")
    }
}
