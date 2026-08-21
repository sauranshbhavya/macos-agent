import Foundation
import Testing

/// Reads `Sources/MacAgent/` so a suite can pin a property of the code that no runtime assertion can
/// reach — which view calls which view-model entry point, which notification category a subscription
/// posts through, which guard a collapse rule consults.
///
/// **Why any of this is a test rather than a comment.** This repository has no SwiftUI inspection
/// harness and no way to drive the live app, and `SonnyNotificationService` cannot even be
/// constructed in a test process (`UNUserNotificationCenter.current()` aborts without bundle
/// identity, and it is an Objective-C exception rather than a Swift error, so it cannot be caught).
/// The wiring those two facts put out of reach is real behaviour, and leaving it unheld because the
/// obvious tool does not fit is how a rewired control ships green.
///
/// **Comments are removed, and that is the whole soundness of the thing.** Measured twice on
/// `fix/attention-reaches-user`, both times by a mutant that walked straight through a scan:
///
/// 1. A mutant rewired Command Center's Cancel button to `submitClarification()` and the scan
///    **survived**, because the `//` comment three lines above it mentioned `cancelCurrentRun()`.
///    The test was reading the sentence describing the code instead of the code.
/// 2. With line comments stripped, the PR #80 reviewer's own battery hid the same rewiring behind a
///    `/* was viewModel.cancelCurrentRun() */` block comment and it **survived again** — while this
///    doc comment claimed stripping was "the whole soundness of the thing". A scan any comment
///    syntax can satisfy holds nothing at all, and a scan that says otherwise is worse than none.
///
/// Both forms are stripped now. Line comments are matched comment-*prefixed*, not by every line
/// containing a double slash — the narrower `grep -v "//"` this repository was bitten by during row
/// C drops real constructions carrying a trailing note. Block comments are matched with a depth
/// counter, because Swift nests them.
///
/// **What still reaches the search, stated rather than glossed. Two things, and the first is not an
/// oversight:**
///
/// - **Trailing line comments.** Only comment-*prefixed* lines are dropped, so the note on
///   `foo() // was bar()` keeps `bar()` in the text a scan reads. That is a deliberate trade, not a
///   gap left open: dropping every line containing a double slash is the `grep -v "//"` that cost
///   this repository real constructions during row C, and it would silently delete any code line
///   carrying an explanatory note — which in this codebase is a great many of them. **A scan must
///   therefore not rely on a token's mere presence**, because a comment can add one. It can rely on
///   counts, because a comment can only ever add: rewiring a call moves a token from one side of a
///   pair to the other, and the side that gained cannot be talked back down. See
///   `ClarificationExitTests.bothClarificationSurfacesRouteTheirExitThroughOneEntryPointAndOneLabel`,
///   where a single-sided count survived exactly this mutant (PR #80 review cycle 2, N1) and the
///   paired one kills it.
/// - **String literals.** A Swift string containing `"cancelCurrentRun()"` satisfies any scan here,
///   and nothing short of parsing the language can tell one from a call. Narrower than the above —
///   a file would have to carry the searched symbol inside a literal — but real.
///
/// The honest limit of a textual scan is that it is textual. Anything needing more than that needs a
/// different tool, not a stronger claim about this one.
///
/// Same line-comment rule `TestSourceTree.codeLines` states for the test tree in the other target;
/// this is the source tree's counterpart, and it is not twinned because only this target scans
/// `Sources/`.
@MainActor
enum MacAgentSource {
    /// `Sources/MacAgent/`, resolved from this file's own location so a scan works from any
    /// checkout.
    static var appSourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacAgentTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/MacAgent")
    }

    /// Every `.swift` file compiled into the `MacAgent` target, at any depth, in a stable order —
    /// for a scan whose subject is a *population* rather than one file.
    ///
    /// **Recursive, and that is the whole reason this exists rather than a `contentsOfDirectory`
    /// call at the call site.** A SwiftPM target's `path:` is compiled recursively, so a file at
    /// `Sources/MacAgent/Anything/New.swift` is in the target and invisible to a one-level scan.
    /// `TestSourceTree` in the other target already paid for that lesson — its own doc records a
    /// review building exactly such a file and watching all nine pins pass — and there is no reason
    /// to relearn it on this side. No subdirectory exists here today, so the difference is latent
    /// rather than live.
    ///
    /// A second, one-level copy of this enumeration lives as `appSourceFiles()` inside
    /// `WidgetVoiceEntryTests` (SONNY-173's readiness scan). It is deliberately not consolidated
    /// here by SONNY-178, whose scope is a hover audit — noted so the duplication reads as seen
    /// rather than missed.
    static func appSourceFiles() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: appSourceDirectory, includingPropertiesForKeys: nil) else {
            throw ScanError.unreadableSourceDirectory(appSourceDirectory.path)
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// `Sources/MacAgentCore/`, resolved the same way.
    ///
    /// **Why a scanner named for the app target reads the other one.** The enumeration this was
    /// added for — that exactly one `AgentRunResult` construction site in the whole product declares
    /// `.modelAuthored` (row E, SONNY-147) — is a property of `MacAgentCore`'s sources, and the core
    /// test target has no source scanner. Building a second one there would put two independently
    /// maintained copies of the comment-stripping discipline in the repository, and this file's own
    /// doc records what a scan that any comment syntax can satisfy is worth. One scanner, reachable
    /// from the target that has it, with the test that needs it living beside the scanner.
    static var coreSourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacAgentTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/MacAgentCore")
    }

    /// Every `.swift` file compiled into the `MacAgentCore` target, at any depth, in a stable order.
    /// Recursive for the reason `appSourceFiles()` gives.
    static func coreSourceFiles() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: coreSourceDirectory, includingPropertiesForKeys: nil) else {
            throw ScanError.unreadableSourceDirectory(coreSourceDirectory.path)
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// A file's path relative to `Sources/MacAgentCore/`, slash-separated.
    static func coreRelativePath(of url: URL) -> String {
        let prefix = coreSourceDirectory.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// A file's path relative to `Sources/MacAgent/`, slash-separated — the key a population scan
    /// should group by. `lastPathComponent` collides across directories; this cannot.
    static func relativePath(of url: URL) -> String {
        let prefix = appSourceDirectory.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// The body of the brace-delimited block whose opening line contains `anchor`, matched by depth.
    ///
    /// **`region(of:from:to:)` cannot express "inside this conditional", and assuming it could is
    /// how a scan came to hold nothing (PR #84 review, F1).** That function ends the region *at* the
    /// `to:` anchor, so a test asserting the region excluded its own end anchor passed wherever that
    /// line sat — including with the guarded content moved inside the conditional, which was the
    /// mutation it was written to catch. A block has to be delimited by its own braces, not by
    /// whatever text happens to follow it.
    ///
    /// Braces inside string literals would miscount, the same residual `read` already names for
    /// searches: nothing here parses Swift. No literal in any block scanned today contains one.
    static func braceBlock(of source: String, openedBy anchor: String) throws -> String {
        let anchorRange = try #require(source.range(of: anchor), "Anchor not found: \(anchor)")
        let openIndex = try #require(
            source[anchorRange].lastIndex(of: "{"),
            "Anchor has no opening brace: \(anchor)"
        )
        var depth = 0
        var index = openIndex
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: openIndex)..<index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw ScanError.unbalancedBraces(anchor)
    }

    /// `block` with every nested brace span removed — what is left is the code at the block's own
    /// top level, inside no further conditional or closure.
    ///
    /// **This is what "renders unconditionally" means, and neither of the weaker forms says it.**
    /// Counting a token across the whole block cannot tell a direct child from one buried in an
    /// `if`; asserting a token is absent from *one* conditional cannot see it moved into a second.
    /// Both gaps were live at once on this branch: the reviewer's two mutants kept
    /// `Text(entry.value)` byte-identical and merely changed its depth, so a count and a
    /// single-branch check both passed (PR #84 review, F1).
    ///
    /// Same textual limits as everything here: braces inside string literals would miscount.
    static func topLevel(of block: String) -> String {
        var result = ""
        var depth = 0
        for character in block {
            switch character {
            case "{":
                depth += 1
            case "}":
                depth = max(depth - 1, 0)
            default:
                if depth == 0 {
                    result.append(character)
                }
            }
        }
        return result
    }

    enum ScanError: Error {
        case unreadableSourceDirectory(String)
        case unbalancedBraces(String)
    }

    /// A file under `Sources/MacAgent/`, by name — for the common case of scanning one known file.
    ///
    /// **Only resolves files sitting directly in that directory.** A caller iterating
    /// `appSourceFiles()` must pass the `URL`, not `lastPathComponent`: flattening a nested path to
    /// its basename here would either throw (a loud miss) or, worse, silently read a *different*
    /// top-level file of the same name. That was a real hole in the first version of this type — the
    /// recursion `appSourceFiles()` advertised could not actually be read (PR #84 review, F4).
    static func read(_ name: String) throws -> String {
        try read(appSourceDirectory.appendingPathComponent(name))
    }

    /// Any source file, by URL, with both comment syntaxes dropped. The form a population scan uses.
    static func read(_ url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        return strippingBlockComments(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Removes `/* … */` spans, counting depth because Swift nests block comments — `/* /* */ */`
    /// closes once, and a scanner that stopped at the first `*/` would hand back the tail of a
    /// comment as if it were code.
    ///
    /// Newlines inside a stripped span are kept, so the line structure the caller's line-comment
    /// filter and `region(of:from:to:)` both read is the file's own. Dropping them would let a
    /// block comment silently splice two unrelated code lines into one.
    ///
    /// Runs before the line filter, so a `//` line inside a block comment is gone either way.
    static func strippingBlockComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var depth = 0
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix("/*") {
                depth += 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if depth > 0, source[index...].hasPrefix("*/") {
                depth -= 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            let character = source[index]
            if depth == 0 || character == "\n" {
                result.append(character)
            }
            index = source.index(after: index)
        }
        return result
    }

    /// The text between two anchors, failing with the missing anchor named rather than silently
    /// searching an empty string — a scan that quietly matches nothing is indistinguishable from one
    /// that passes.
    ///
    /// Anchored on real code lines rather than line numbers. A rename fails this loudly, which is
    /// the intended behaviour: the rename is the moment to re-check that the property still holds.
    static func region(of source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start), "Anchor not found: \(start)")
        let endRange = try #require(
            source.range(of: end, range: startRange.upperBound..<source.endIndex),
            "Anchor not found after \(start): \(end)"
        )
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }

    /// How many times `needle` occurs in `name`, comments already stripped. For pinning the size of
    /// a population a suite claims to have enumerated.
    static func occurrences(of needle: String, in name: String) throws -> Int {
        count(of: needle, inText: try read(name))
    }

    /// The same count over a region already extracted by `region(of:from:to:)`.
    ///
    /// Counting rather than `contains` is what pins a *rewiring* in both directions: a button whose
    /// action is swapped for its neighbour's leaves the neighbour's token present and the swapped
    /// one absent, so only a per-token count sees both halves of the swap.
    static func count(of needle: String, inText text: String) -> Int {
        guard !needle.isEmpty else {
            return 0
        }
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}
