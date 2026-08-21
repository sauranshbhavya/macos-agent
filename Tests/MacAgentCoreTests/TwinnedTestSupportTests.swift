import Foundation
import Testing

/// **The twinned test-support files cannot drift apart, and the unprivileged gate cannot be
/// inverted or moved** (SONNY-123, PR #72 F4, F5, C2 and C3).
///
/// Two helpers exist once per test target — `DeterministicPermissions.swift`'s
/// `DeterministicScreenPermissions` and `UnprivilegedProcess.swift`'s trait — because a source file
/// belongs to exactly one target here. Both headers ask the reader to "keep the two in step", and
/// until this file existed that was a request with no mechanism behind it: deleting the
/// grants-on-request flip from the **core** copy survived the whole suite, because nothing in that
/// target reads it. The app copy is held by `ScreenAccessOnboardingTests`; the core copy was held by
/// nothing at all.
///
/// The gate had the same shape. Inverting `geteuid() != 0` to `== 0` survived: three tests silently
/// stopped running, the suite still reported green, and the total dropped from 1377 to 1374 with
/// nobody told. There is no CI in this repository, so that gate has never fired anywhere and its
/// correctness is neither exercised nor checked.
///
/// **Comparison is on code, not prose.** Comment lines are stripped before comparing, because the
/// two copies deliberately differ in their doc comments — each names its own twin, and the app copy
/// carries the F2 correction in full. Reformatting and reindentation are normalized away; member
/// *order* is not, because the surviving lines are joined in order and compared as strings. Brace
/// matching is naive: it counts `{` and `}` without tracking string literals, which is safe for these
/// two files and would need revisiting if either grew one containing an unbalanced brace.
@Suite
struct TwinnedTestSupportTests {
    /// This file carries both scans' search strings as literals, so it matches itself unless
    /// excluded — the same self-reference the permission scan exempts by path.
    private static let thisFile = "MacAgentCoreTests/TwinnedTestSupportTests.swift"

    private static func twin(_ fileName: String, in target: String) throws -> String {
        try String(
            contentsOf: TestSourceTree.root.appendingPathComponent(target).appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    /// Drops comment-only and blank lines and collapses runs of whitespace, so that reindentation and
    /// prose differences do not read as drift while a changed statement does.
    private static func code(_ source: String) -> String {
        TestSourceTree.codeLines(of: source)
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
        let bodies = try TestSourceTree.targets.map { target in
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

    /// **The class body is not the whole type** (PR #72 C3). Comparing bodies leaves an extension on
    /// one copy invisible — measured: adding `extension DeterministicScreenPermissions { ... }` to the
    /// app twin alone left both bodies byte-identical and the suite green, while the twins had
    /// genuinely diverged. Extending it anywhere is therefore refused outright: put the member in the
    /// class body, in both copies, where the drift pin can see it.
    @Test
    func neitherTwinIsExtendedOutsideItsClassBody() throws {
        var extensions: [String] = []
        for target in TestSourceTree.targets {
            for file in try TestSourceTree.swiftFiles(in: target) where file.relativePath != Self.thisFile {
                for line in TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                where line.text.contains("extension DeterministicScreenPermissions") {
                    extensions.append("\(file.relativePath):\(line.number)")
                }
            }
        }
        #expect(
            extensions.isEmpty,
            """
            DeterministicScreenPermissions is extended at \(extensions.joined(separator: ", ")). An \
            extension on one twin is drift the body comparison cannot see. Add the member to the class \
            body in both copies instead.
            """
        )
    }

    @Test
    func theTwinnedUnprivilegedTraitsAreTheSameCode() throws {
        let files = try TestSourceTree.targets.map { try Self.code(Self.twin("UnprivilegedProcess.swift", in: $0)) }
        #expect(files[0] == files[1], "The two UnprivilegedProcess.swift copies have drifted.")
        #expect(files[0].contains("static var requiresUnprivilegedProcess: Self {"))
    }

    /// The gate's predicate, pinned as text because there is no way to observe a skip from inside
    /// the run that was skipped. Inverting it is a mutant this kills; nothing else does.
    @Test
    func theUnprivilegedGatePredicateIsNotInverted() throws {
        for target in TestSourceTree.targets {
            let source = try Self.twin("UnprivilegedProcess.swift", in: target)
            #expect(source.contains("if: geteuid() != 0,"), "\(target)'s gate is not the expected predicate")
            #expect(
                !source.contains("geteuid() == 0"),
                "\(target)'s gate is inverted: it would run these tests only as root, and skip them everywhere else"
            )
        }
    }

    /// **Every test that locks a directory carries the gate, and no other test does — matched per
    /// test rather than in aggregate** (PR #72 C2).
    ///
    /// The first version counted two populations across the tree and compared totals, which never
    /// asked whether a given `chmod` and a given tag belonged to the same test. Measured: moving
    /// `@Test(.requiresUnprivilegedProcess)` off the directory-locking test and onto its neighbour
    /// left both totals at four and the suite green, with one forced-failure test silently ungated
    /// and an unrelated one needlessly gated. That is a plausible merge accident — an attribute
    /// landing on the wrong function is what an inserted test does — not only an adversarial one.
    ///
    /// So each file is segmented at its `@Test` lines and the two facts are required to agree inside
    /// every segment. Both directions matter: a lock without a gate fails on a root runner for a
    /// reason that is not a defect, and a gate without a lock silently stops running a test that had
    /// no need of it.
    @Test
    func everyDirectoryLockingTestCarriesTheGateAndNoOtherTestDoes() throws {
        var lockedAndGated = 0
        var mismatches: [String] = []

        for target in TestSourceTree.targets {
            for file in try TestSourceTree.swiftFiles(in: target)
            where file.relativePath != Self.thisFile {
                var header: (number: Int, text: String)?
                var locksDirectory = false

                func closeSegment() {
                    guard let header else { return }
                    let gated = header.text.contains(".requiresUnprivilegedProcess")
                    if gated && locksDirectory {
                        lockedAndGated += 1
                    } else if gated != locksDirectory {
                        mismatches.append(
                            "\(file.relativePath):\(header.number) — locks=\(locksDirectory) gated=\(gated)"
                        )
                    }
                }

                for line in TestSourceTree.codeLines(of: try TestSourceTree.read(file)) {
                    if line.text.trimmingCharacters(in: .whitespaces).hasPrefix("@Test") {
                        closeSegment()
                        header = line
                        locksDirectory = false
                    } else if line.text.contains("posixPermissions: 0o500") {
                        locksDirectory = true
                    }
                }
                closeSegment()
            }
        }

        // Six since row E (SONNY-151, PR #89's two fix rounds). Both new ones make the plan store's
        // directory read-only while task history stays writable, which is the only way to fail the
        // second of a path's two writes without failing the first — one per path, because the
        // scheduled and foreground writes are separate functions rather than one shared helper:
        // `ScheduledRoutineRunTests.aPlanWriteFailureKeepsTheScheduledRowAndSaysWhatActuallyFailed`
        // and `ProductShellTests.aPlanWriteFailureLeavesTheTaskLookingSuccessfulAndSaysWhatActuallyFailed`.
        #expect(lockedAndGated == 6, "expected six gated directory-locking tests, found \(lockedAndGated)")
        #expect(
            mismatches.isEmpty,
            """
            A test locks a directory to 0o500 without .requiresUnprivilegedProcess, or carries the \
            trait without locking one. Root bypasses directory permission bits, so an ungated lock \
            fails on a root-running runner for a reason that is not a defect, and a stray gate skips \
            a test that never needed gating (SONNY-106 section D). \(mismatches.joined(separator: " | "))
            """
        )
    }
}
