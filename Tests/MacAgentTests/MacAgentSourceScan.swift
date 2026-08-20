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
/// **Comment-prefixed lines are removed, and that is the whole soundness of the thing.** Measured on
/// `fix/attention-reaches-user`: a mutation battery rewired Command Center's Cancel button to
/// `submitClarification()` and the scan **survived**, because the comment three lines above it
/// mentioned `cancelCurrentRun()`. The test was reading the sentence describing the code instead of
/// the code. A scan a prose edit can satisfy holds nothing at all.
///
/// Comment-*prefixed*, not every line containing a double slash — the narrower `grep -v "//"` this
/// repository was bitten by during row C drops real constructions carrying a trailing note. Same
/// rule `TestSourceTree.codeLines` states for the test tree in the other target; this is the source
/// tree's counterpart, and it is not twinned because only this target scans `Sources/`.
@MainActor
enum MacAgentSource {
    /// A file under `Sources/MacAgent/`, resolved from this file's own location so the scan works
    /// from any checkout, with comment-prefixed lines dropped.
    static func read(_ name: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacAgentTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
        let url = repository
            .appendingPathComponent("Sources/MacAgent")
            .appendingPathComponent(name)
        let source = try String(contentsOf: url, encoding: .utf8)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
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

    /// How many times `needle` occurs in `name`, over code lines only. For pinning the size of a
    /// population a suite claims to have enumerated.
    static func occurrences(of needle: String, in name: String) throws -> Int {
        let source = try read(name)
        guard !needle.isEmpty else {
            return 0
        }
        var count = 0
        var searchStart = source.startIndex
        while let found = source.range(of: needle, range: searchStart..<source.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}
