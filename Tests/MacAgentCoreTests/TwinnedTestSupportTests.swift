import Foundation
import Testing

/// **The twinned test-support files cannot drift apart, and the unprivileged gate cannot be
/// inverted** (SONNY-123, PR #72 F4 and F5).
///
/// Two helpers exist once per test target — `DeterministicPermissions.swift`'s
/// `DeterministicScreenPermissions` and `UnprivilegedProcess.swift`'s trait — because one source
/// file belongs to exactly one target here. Both headers ask the reader to "keep the two in step",
/// and until this file existed that was a request with no mechanism behind it: deleting the
/// grants-on-request flip from the **core** copy survived the whole suite, because nothing in that
/// target reads it. The app copy is held by `ScreenAccessOnboardingTests`; the core copy was held by
/// nothing at all.
///
/// The gate had the same shape. Inverting `geteuid() != 0` to `== 0` survived: three tests silently
/// stopped running, the suite still reported green, and the total dropped from 1377 to 1374 with
/// nobody told. There is no CI in this repository, so that gate has never fired anywhere and its
/// correctness was neither exercised nor checked.
///
/// **Comparison is on code, not prose.** Comment lines are stripped before comparing, because the
/// two copies deliberately differ in their doc comments — each names its own twin, and the app copy
/// carries one extra sentence about the Screen Recording asymmetry. Brace matching is naive: it
/// counts `{` and `}` without tracking string literals, which is safe for these two files and would
/// need revisiting if either grew one containing an unbalanced brace.
@Suite
struct TwinnedTestSupportTests {
    private static let targets = ["MacAgentCoreTests", "MacAgentTests"]

    private static var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func twin(_ fileName: String, in target: String) throws -> String {
        try String(
            contentsOf: testsDirectory.appendingPathComponent(target).appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    /// Drops comment-only lines and blank lines, and collapses runs of whitespace, so that
    /// reindentation and prose differences do not read as drift while a changed statement does.
    private static func code(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            .map { $0.split(separator: " ").joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// The declaration and its body, from `declaration` to the brace that closes it.
    private static func declarationBody(_ source: String, startingWith declaration: String) throws -> String {
        let start = try #require(source.range(of: declaration)?.lowerBound)
        let openBrace = try #require(source.range(of: "{", range: start..<source.endIndex)?.lowerBound)
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            if source[index] == "{" {
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[start...index])
                }
            }
            index = source.index(after: index)
        }
        throw TwinExtractionError.unbalancedBraces(declaration)
    }

    private enum TwinExtractionError: Error {
        case unbalancedBraces(String)
    }

    @Test
    func theTwinnedPermissionStubsAreTheSameCode() throws {
        let bodies = try Self.targets.map { target in
            Self.code(
                try Self.declarationBody(
                    try Self.twin("DeterministicPermissions.swift", in: target),
                    startingWith: "final class DeterministicScreenPermissions"
                )
            )
        }
        #expect(
            bodies[0] == bodies[1],
            """
            The two DeterministicScreenPermissions copies have drifted. They are twinned because one \
            source file belongs to one target; a behaviour added to either belongs in both. Only one \
            of the two is exercised by tests, so drift is silent in whichever direction leaves the \
            core copy behind.
            """
        )
        // The comparison is worth nothing if it is comparing empty strings.
        #expect(bodies[0].contains("func isAccessibilityTrusted() -> Bool { accessibilityTrusted }"))
        #expect(bodies[0].contains("if accessibilityGrantsOnRequest {"))
        #expect(bodies[0].count > 400)
    }

    @Test
    func theTwinnedUnprivilegedTraitsAreTheSameCode() throws {
        let files = try Self.targets.map { try Self.code(Self.twin("UnprivilegedProcess.swift", in: $0)) }
        #expect(files[0] == files[1], "The two UnprivilegedProcess.swift copies have drifted.")
        #expect(files[0].contains("static var requiresUnprivilegedProcess: Self {"))
    }

    /// The gate's predicate, pinned as text because there is no way to observe a skip from inside
    /// the run that was skipped. Inverting it is a mutant this kills; nothing else does.
    @Test
    func theUnprivilegedGatePredicateIsNotInverted() throws {
        for target in Self.targets {
            let source = try Self.twin("UnprivilegedProcess.swift", in: target)
            #expect(source.contains("if: geteuid() != 0,"), "\(target)'s gate is not the expected predicate")
            #expect(
                !source.contains("geteuid() == 0"),
                "\(target)'s gate is inverted: it would run these tests only as root, and skip them everywhere else"
            )
        }
    }

    /// **Every forced-filesystem-failure test is gated, and no other test is.** A relational pin
    /// rather than a bare constant: it fails when a new `0o500` test arrives ungated *and* when a
    /// gate is deleted from an existing one. It holds because each gated test locks exactly one
    /// directory — a test that ever needs two chmods makes this a deliberate update, in the same
    /// spirit as the wipe's nine-store pin.
    @Test
    func theGateCoversExactlyTheTestsThatForceAFilesystemFailure() throws {
        var lockedDirectoryCount = 0
        var gatedTestCount = 0
        // This file holds both search strings as literals, so it counts itself if included — the
        // same self-reference the permission scan excludes by name.
        let thisFileName = URL(fileURLWithPath: #filePath).lastPathComponent

        for target in Self.targets {
            let directory = Self.testsDirectory.appendingPathComponent(target)
            let files = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" && $0.lastPathComponent != thisFileName }
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    if trimmed.contains("posixPermissions: 0o500") { lockedDirectoryCount += 1 }
                    if trimmed.contains("@Test(.requiresUnprivilegedProcess)") { gatedTestCount += 1 }
                }
            }
        }

        #expect(lockedDirectoryCount == 4)
        #expect(
            gatedTestCount == lockedDirectoryCount,
            """
            \(lockedDirectoryCount) tests force a filesystem failure by locking a directory to 0o500, \
            but \(gatedTestCount) carry .requiresUnprivilegedProcess. Root bypasses directory \
            permission bits, so an ungated one fails on a root-running runner for a reason that is \
            not a defect (SONNY-106 section D).
            """
        )
    }
}
