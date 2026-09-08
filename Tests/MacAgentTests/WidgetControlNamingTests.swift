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
    ///
    /// **Seven now, not four** (2026-09-08 modernization pass, widget lane). The original four are
    /// icon-only controls; the 2026-09-08 pass added three more on truncated text that clips under
    /// `lineLimit` — `WidgetResultPanel`'s summary, `WidgetFailurePanel`'s message and
    /// `WidgetStepRow`'s title — each carrying `.help()` with its own full text so a clipped line is
    /// still reachable on hover, and each paired with an `.accessibilityLabel()` of the same text
    /// immediately above it so the pairing convention this test enforces still holds for them too.
    @Test
    func everyTooltipInTheWidgetSitsBesideAVoiceOverName() throws {
        let lines = try widgetLines()
        let tooltipIndices = lines.indices.filter { lines[$0].hasPrefix(".help(") }

        // The population, enumerated rather than counted: seven tooltip sites (four icon-only
        // controls plus three truncated-text rows), and the count is asserted so an eighth cannot
        // arrive without this test being read.
        #expect(tooltipIndices.count == 7)

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

    /// **Each control is named after where it goes (SONNY-338).**
    ///
    /// `AppDelegate`'s menu item and the capsule both said "Open Sonny" and went to two different
    /// places — the Command Center window and the floating widget. SONNY-251 asserted that
    /// collision rather than resolving it, because the words are product vocabulary; the founders
    /// decided it on 2026-08-30, and this test is that assertion turned around. The menu item is
    /// named for the window it opens; the capsule keeps "Open Sonny" for the widget.
    ///
    /// **The third assertion is a relationship, and it deliberately replaces a literal rather than
    /// sitting beside one.** The two words each control says are pinned by value above it; what
    /// they cannot say is that the *pair* stays apart, so the collision could return through the
    /// other door — the capsule renamed onto whatever the menu bar ends up carrying — with both
    /// literal assertions edited to match and nothing left objecting. Reading the capsule's own
    /// constant back out and requiring that no menu item carries it is the same claim that
    /// outlives a rename of either control.
    ///
    /// **What that is worth today, stated rather than implied: it is exactly the literal it
    /// replaced.** `expandLabel` is asserted to be "Open Sonny" one line above, so at this tree
    /// this check and `count(of: "withTitle: \"Open Sonny\"") == 0` are the same bytes and kill the
    /// same mutants. Writing it the derived way buys nothing now and keeps meaning what it says
    /// after the next wording decision; writing *both* would have been a decorative assertion of
    /// exactly the kind the paragraph below removes.
    ///
    /// **The `count(of: "openCommandCenter") >= 1` this test used to carry is gone rather than
    /// renamed.** PR #155's review recorded it as decorative and SONNY-251's entry left it as a
    /// residual: the selector is declared in the same file it counts, so that assertion holds
    /// whether or not any menu item reaches it. What the item is actually wired to is asserted by
    /// target, selector and key equivalent in
    /// `ProductShellTests.newTaskMenuItemRoutesThroughTheSharedWidgetPresentationRequest`, which is
    /// where a rewiring is caught.
    @Test
    func theCapsuleAndTheMenuBarNameTheirOwnDestinations() throws {
        let appDelegate = try MacAgentSource.read("AppDelegate.swift")

        #expect(MacAgentSource.count(of: "withTitle: \"Open Command Center\"", inText: appDelegate) == 1)
        #expect(CompactCapsulePresentation.expandLabel == "Open Sonny")
        #expect(
            MacAgentSource.count(
                of: "withTitle: \"\(CompactCapsulePresentation.expandLabel)\"",
                inText: appDelegate
            ) == 0
        )
    }
}
