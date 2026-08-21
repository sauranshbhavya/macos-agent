import Foundation
import Testing
@testable import MacAgent

/// The Settings → Security & Access → **Screen Control** copy, pinned on its literal strings
/// (SONNY-143).
///
/// **Why this reads the source file rather than the rendered view.** The section is built inside a
/// `private` SwiftUI view in a 4,000-line file, so there is no value a test can reach — and the
/// alternatives are worse than a source scan: making the view internal to test its copy would widen
/// a surface for the test's benefit, and hoisting the sentence into a constant would move product
/// copy away from the place a person editing the page actually looks. The same technique already
/// guards `clearInMemoryLocalDataState`'s enumeration in `ProductShellTests`, and for the same
/// reason: the claim is *about the source*, so the source is what gets read.
///
/// **The negative assertions are the point.** Each one names a sentence that was true before row J's
/// per-app gate shipped and is false after it. A test that only checked for the new copy would pass
/// against a build that added it and left the old claim sitting beside it.
@Suite
struct ScreenControlSettingsCopyTests {
    /// The file's text with every comment marker and run of whitespace collapsed to single spaces.
    ///
    /// **Without this the negative assertions passed for the wrong reason** (PR #88, F7). The
    /// sentence they forbid really is still in the file — quoted inside the comment that records the
    /// supersession — and it only failed to match because the quote wraps across two lines with a
    /// `//` between. A future edit that reflowed the paragraph, or an editor that rewrapped it,
    /// would have turned a passing guard into a passing guard about nothing. Normalizing first means
    /// the assertions are about the *words on the page*, which is what they claim to be about.
    private static func normalized(_ source: String) -> String {
        source
            .replacingOccurrences(of: "///", with: " ")
            .replacingOccurrences(of: "//", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func commandCenterSource() throws -> String {
        // <package root>/Tests/MacAgentTests/<this file>
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/MacAgent/CommandCenterView.swift"),
            encoding: .utf8
        )
    }

    /// The shipped promise that becomes false the day the gate lands: "Sonny can control any app
    /// installed on this Mac". It was the **only** place the product stated screen control's reach,
    /// which is exactly why leaving it would have been worse than never having written it.
    @Test
    func theScreenControlSectionNoLongerClaimsSonnyCanControlAnyInstalledApp() throws {
        let source = try Self.commandCenterSource()

        let flat = Self.normalized(source)
        #expect(!flat.contains("Sonny can control any app installed on this Mac"))
        #expect(flat.contains("Sonny asks before controlling an app it has not been allowed to control"))
        // The mode differences are stated, because "asks before controlling an app" is not the whole
        // truth in either of the two modes that differ from Normal.
        #expect(flat.contains("Safe mode asks about every app; Power mode asks about none."))
        // The one boundary the section has always stated, unchanged: a terminal is not a choice.
        #expect(flat.contains("Sonny will never control Terminal, iTerm, or any other terminal app."))
    }

    /// The comment above the section made the same claim twice more, in the developer-facing half.
    /// Both halves went false on 2026-08-16 when the founder revived per-app control consent.
    @Test
    func theSectionsOwnCommentNoLongerSaysThereAreNoGrantsAndNothingToRevoke() throws {
        let source = try Self.commandCenterSource()
        let flat = Self.normalized(source)

        // **Both sentences are still in the file, and that is correct** — the comment quotes them to
        // record that they went false. So the guard cannot be "the words are absent"; it has to be
        // "the words appear once, inside the quotation that supersedes them". Asserted against the
        // reflowed text, so a line break inside a phrase can neither hide a live claim nor break
        // this check.
        for claim in [
            "there is no grant list, because there are no grants",
            "there is no revoke, because there is nothing to revoke"
        ] {
            let parts = flat.components(separatedBy: claim)
            #expect(parts.count == 2, "\"\(claim)\" appears \(parts.count - 1) times; exactly one, the quotation, is right")
            let head = try #require(parts.first)
            let marker = try #require(head.range(of: "This block used to read", options: .backwards))
            #expect(
                head.distance(from: marker.upperBound, to: head.endIndex) < 200,
                "\"\(claim)\" is not inside the quotation that records it going false"
            )
        }
        // And it names where the revoke actually lands, so the next session reads a pointer rather
        // than re-deriving that this page is the home for it.
        #expect(flat.contains("SONNY-144"))
    }
}
