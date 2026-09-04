import Foundation
import Testing

/// A line comment may not open a block-comment span that nothing closes (SONNY-409).
///
/// **The defect this refuses, and why one repair was never the deliverable.**
/// `MacAgentSource.read` strips block-comment spans *before* it drops comment-prefixed lines —
/// deliberately, so that a line comment sitting inside a block comment is gone either way. The cost
/// of that order is that an opening delimiter written inside a *line* comment opens a span the
/// stripper has no reason to close, and every line after it disappears from the text a scan reads.
/// A scan then counts zero occurrences of a line plainly present in the file, which is this
/// repository's clean-zero family reached through a doc comment.
///
/// At `2856840` that had happened three times in three branches — SONNY-220 wrote the gotcha into
/// `CLAUDE.md`, SONNY-395 shipped it and removed it inside its own branch, and
/// `Sources/MacAgentCore/EditWorkspaceCapabilityAdapter.swift:417` was carrying it on `main`, where
/// a markdown bold around the word *edit* put an opening delimiter into a doc comment and hid lines
/// 418 to 940 from every scan built on `MacAgentSource`. Each instance was written by somebody
/// obeying the rule that puts globs and shell commands into comments. A class that arrives from
/// obeying a rule is not closed by remembering harder, which is why this is a test.
///
/// **The probe runs the real stripper rather than re-implementing it.** A second copy of the depth
/// counter would be a second thing to keep in step, and the first thing it would stop agreeing with
/// is the code it exists to police. So a candidate line is handed to
/// `MacAgentSource.strippingBlockComments` with a sentinel appended after a newline: if the sentinel
/// survives, the line closed everything it opened; if the sentinel is gone, the line left a span
/// open and would have swallowed whatever followed it in the file.
///
/// **Scope is comment-*prefixed* lines, and the boundary is measured rather than assumed.** Two
/// other shapes put an opening delimiter into a file and neither is this class:
///
/// - **An opening delimiter inside a string literal.** `strippingBlockComments` cannot tell a
///   literal from code — its own doc says so, and says nothing short of parsing Swift could. Two
///   live instances sit in `Tests/` at `2856840`: `TestSourceTree.swift:146`, whose array of
///   TypeScript comment prefixes holds the token as data, and
///   `ShellSurfaceDetectorTests.swift:371`, a shell glob inside a multi-line string fixture. Both
///   are code lines, so this scan never examines them, and refusing them would be a second class of
///   work wearing this one's name.
/// - **A trailing note on a code line.** Measured across all 368 Swift files of the five targets:
///   one line matches, and it is `TestSourceTree.swift:146` again — a string literal, not a comment.
///   The population of genuine trailing instances is empty, so narrowing to comment-prefixed lines
///   costs no coverage today and buys the string-literal false positive never firing.
///
/// **A span opened and closed on one line is not a defect and must not fire.** The delimiters cancel
/// before the line ends, nothing after them is swallowed, and the line is still comment-prefixed so
/// `read` drops it whole. `MacAgentSourceScan.swift:22` and `LocalStoreInjectionScanTests.swift:1499`
/// are both that shape and both correct.
///
/// **This file writes no block-comment delimiter of its own, in any comment or literal.** Both
/// tokens are built by concatenation in ``spanOpen`` and ``spanClose``. A refusal that trips itself
/// is the hole one level in, and building the tokens is cheaper than remembering not to.
@Suite
@MainActor
struct LineCommentMayNotOpenABlockTests {
    /// The opening block-comment delimiter, assembled so it appears nowhere in this file as itself.
    private static let spanOpen = "/" + "*"

    /// The closing block-comment delimiter, assembled for the same reason.
    private static let spanClose = "*" + "/"

    /// Appended after a newline so its survival answers whether the line above it closed its spans.
    /// Carries no delimiter character, so it cannot alter the stripping it is measuring.
    private static let sentinel = "SONNY409-SPAN-PROBE"

    /// The repository root, from this file's own path — a test process's working directory is
    /// SwiftPM's to choose, so it is never the thing to derive a tree from.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacAgentTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    enum ScanFailure: Error {
        case unreadableTree(String)
    }

    /// Whether `line` leaves a block-comment span open past its own end, decided by the real
    /// stripper rather than by counting delimiters.
    ///
    /// Counting is the wrong instrument and was tried first: a naive tally of openers against
    /// closers double-counts an overlapping run of delimiters — the vitest `include` glob quoted in
    /// `TestSourceTree.swift:95` reads as two opens and one close and is reported a defect — while
    /// the stripper's cursor consumes two characters per match and sees one balanced pair. That
    /// over-report is correct code, and it is why this asks the stripper instead of counting.
    static func leavesASpanOpen(_ line: String) -> Bool {
        !MacAgentSource.strippingBlockComments(line + "\n" + sentinel).contains(sentinel)
    }

    /// Every line of `source` that is a line comment leaving a span open, with its 1-based number.
    ///
    /// The selection is `MacAgentSource.read`'s own filter — trimmed text beginning with a double
    /// slash — so this scan examines exactly the lines that reader treats as comments.
    static func spanOpeningLineComments(in source: String) -> [(number: Int, text: String)] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { offset, raw in
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("//"), leavesASpanOpen(line) else { return nil }
                return (offset + 1, trimmed)
            }
    }

    /// Every directory `Package.swift` compiles Swift from, read out of the manifest.
    ///
    /// Read rather than restated, for the reason `LivePermissionCheckerScanTests` gives about
    /// `TestSourceTree.targets`: a hand-written list that stops covering a directory reads exactly
    /// like one that covers everything. A sixth target added to the manifest joins this scan on the
    /// day it lands.
    static func manifestTreePaths() throws -> [String] {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        var paths: [String] = []
        for rawLine in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), let opening = line.range(of: "path: \"") else { continue }
            let rest = line[opening.upperBound...]
            guard let closing = rest.firstIndex(of: "\"") else { continue }
            paths.append(String(rest[..<closing]))
        }
        return paths.sorted()
    }

    /// Every `.swift` file under a manifest tree, at any depth, in a stable order.
    ///
    /// Recursive because a SwiftPM target's `path:` is compiled recursively — the hole both
    /// `MacAgentSource` and `TestSourceTree` record paying for, and there is no reason to relearn it
    /// a third time.
    static func swiftFiles(under treePath: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(treePath)
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw ScanFailure.unreadableTree(treePath)
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - The refusal

    /// No line comment in any compiled Swift tree opens a span that its own line does not close.
    @Test
    func noLineCommentOpensABlockCommentSpanNothingCloses() throws {
        var offenders: [String] = []
        var filesRead = 0
        var lineCommentsRead = 0

        for treePath in try Self.manifestTreePaths() {
            let files = try Self.swiftFiles(under: treePath)
            for url in files {
                filesRead += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                lineCommentsRead += text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .count { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                let relative = url.path.hasPrefix(Self.repositoryRoot.path + "/")
                    ? String(url.path.dropFirst(Self.repositoryRoot.path.count + 1))
                    : url.lastPathComponent
                for offender in Self.spanOpeningLineComments(in: text) {
                    offenders.append("\(relative):\(offender.number) — \(offender.text)")
                }
            }
        }

        // The population is asserted before the verdict is read, or an empty walk passes as a clean
        // tree. Floors rather than exact counts: files land every week and this must not be the test
        // that fails for it.
        #expect(filesRead > 300, "the scan read \(filesRead) files, which is too few to be the tree")
        #expect(
            lineCommentsRead > 1_000,
            "the scan saw \(lineCommentsRead) comment-prefixed lines, too few to be this tree's comments"
        )

        #expect(
            offenders.isEmpty,
            """
            A line comment opens a block-comment span its own line never closes, at:
            \(offenders.joined(separator: "\n"))
            MacAgentSource.read strips spans before it drops comment lines, so every line after each \
            of these vanishes from the text scans read — they count zero occurrences of code plainly \
            present in the file and pass. Rewrite the comment so the delimiter is not adjacent: a \
            markdown bold reads the same written as _edit_, and a shell glob can be written with the \
            path split or the whole command wrapped in backticks without the star touching a slash.
            """
        )
    }

    // MARK: - Selftest: the refusal fires, and does not fire on the shapes that are not defects

    /// The probe fires on the exact line this ticket was filed for, not on a synthetic stand-in.
    ///
    /// Verbatim `Sources/MacAgentCore/EditWorkspaceCapabilityAdapter.swift:417` as `main` carried it
    /// at `2856840`, with the opening delimiter assembled so this file does not carry the defect it
    /// is quoting. The repair on this branch removes that line from the tree, so holding it here is
    /// what keeps the refusal proven against the real thing rather than against a line written to
    /// pass.
    @Test
    func theRefusalFiresOnTheDefectItWasBuiltFor() {
        let line417 = "        /// creation/"
            + "**edit** time\", and its note to this ticket said the edit path should read the"

        let found = Self.spanOpeningLineComments(in: line417)
        #expect(found.count == 1, "expected the real defect to be caught once, got \(found)")
        #expect(found.first?.number == 1)
    }

    /// A line comment carrying no delimiter at all is not an offender — the control that says the
    /// arm above is reading the delimiter rather than every comment it is shown.
    @Test
    func theRefusalDoesNotFireOnAnOrdinaryLineComment() {
        let ordinary = "        /// SONNY-44's decoupling decision is normalize on save plus a warning"
        #expect(Self.spanOpeningLineComments(in: ordinary).isEmpty)
    }

    /// A span opened and closed on the same line swallows nothing and must not fire.
    ///
    /// The live shape at `MacAgentSourceScan.swift:22`, which quotes a block comment a reviewer's
    /// mutant hid a rewiring behind.
    @Test
    func theRefusalDoesNotFireOnASpanOpenedAndClosedOnOneLine() {
        let balanced = "///    `\(Self.spanOpen) was viewModel.cancelCurrentRun() \(Self.spanClose)` block comment"
        #expect(Self.spanOpeningLineComments(in: balanced).isEmpty)
    }

    /// Nested delimiters that balance on one line must not fire either — Swift nests block comments,
    /// and `MacAgentSourceScan.swift:226` documents that with a nested pair inside its own doc.
    @Test
    func theRefusalDoesNotFireOnNestedSpansClosedOnOneLine() {
        let nested = "/// counting depth because Swift nests them — "
            + "\(Self.spanOpen) \(Self.spanOpen) \(Self.spanClose) \(Self.spanClose)"
        #expect(Self.spanOpeningLineComments(in: nested).isEmpty)
    }

    /// An opening delimiter inside a string literal on a code line is a different class and is not
    /// examined: `TestSourceTree.swift:146` holds the token as data, and this scan reads only
    /// comment-prefixed lines.
    @Test
    func theRefusalDoesNotReadAStringLiteralOnACodeLine() {
        let literal = "    static let typeScriptCommentPrefixes = [\"//\", \"\(Self.spanOpen)\", \"*\"]"
        #expect(Self.spanOpeningLineComments(in: literal).isEmpty)
    }

    /// The same, for a glob inside a multi-line string fixture —
    /// `ShellSurfaceDetectorTests.swift:371`, which is shell script rather than Swift at all.
    @Test
    func theRefusalDoesNotReadAGlobInsideAStringFixture() {
        let glob = "        10  for f in build/" + "*.tar.gz; do"
        #expect(Self.spanOpeningLineComments(in: glob).isEmpty)
    }

    /// A defect on a line the scan reads is still found when ordinary lines surround it, so the
    /// per-line selection is not an artefact of a one-line input.
    @Test
    func theRefusalFindsADefectSurroundedByOrdinaryLines() {
        let source = [
            "struct Thing {",
            "    /// a note",
            "    /// creation/" + "**edit** time",
            "    let value: Int",
            "}"
        ].joined(separator: "\n")

        let found = Self.spanOpeningLineComments(in: source)
        #expect(found.map(\.number) == [3], "expected only line 3, got \(found)")
    }

    // MARK: - The scan covers every tree, and reads them

    /// Every tree the manifest compiles Swift from is scanned, pinned by value.
    ///
    /// By value rather than by count: a completeness check comparing the scan against the same
    /// parse that built it sees a missing tree and never a wrong one, and a refusal that reads one
    /// tree while claiming five is the mutant this arm exists to kill.
    @Test
    func theScanCoversEveryTreeTheManifestCompilesSwiftFrom() throws {
        let paths = try Self.manifestTreePaths()
        #expect(
            paths == [
                "Sources/MacAgent",
                "Sources/MacAgentCore",
                "Tests/MacAgentCoreTests",
                "Tests/MacAgentTestSupport",
                "Tests/MacAgentTests"
            ],
            "Package.swift declares Swift trees \(paths); a tree missing here is a tree this refusal skips"
        )
    }

    /// Each tree actually yields files — a walker that returned nothing would agree with a clean
    /// tree, which is the failure this whole ticket is about.
    @Test
    func everyScannedTreeYieldsFiles() throws {
        for treePath in try Self.manifestTreePaths() {
            let count = try Self.swiftFiles(under: treePath).count
            #expect(count > 0, "\(treePath) yielded no Swift files")
        }
    }
}
