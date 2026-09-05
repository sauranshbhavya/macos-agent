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

    /// The live verdict both population checks reach, extracted so a selftest can drive it on a
    /// known-bad input.
    ///
    /// **Weakening it in place is the mutant a clean tree could not otherwise catch.** PR #199's
    /// reviewer softened `offenders.isEmpty` to `offenders.count >= 0` and the whole suite passed
    /// (R1, SURVIVED): the walk, the population floors and the message were all intact and only the
    /// predicate had gone. `theVerdictRejectsANonEmptyOffenderList` drives this function over a
    /// non-empty list inside `withKnownIssue`, which fails when no issue is recorded — so a weakened
    /// predicate fails every run, on a clean tree, with no battery.
    ///
    /// **Deleting the assertion outright is a different mutant and stays unkillable, which is an
    /// answer rather than a gap.** An assertion that would pass, removed from a tree that satisfies
    /// it, is unobservable by construction, and no fixture changes that; the reviewer's R6 measured
    /// it surviving. What holds that direction is W5 — restore the real defect and the verdict fires.
    static func verdictHolds(offenders: [String]) -> Bool {
        offenders.isEmpty
    }

    /// Every line of `source` that is a line comment leaving a span open, with its 1-based number.
    ///
    /// The selection is `MacAgentSource.read`'s own filter — trimmed text beginning with a double
    /// slash — applied to the **raw** line. `read` applies it after stripping, so the two are not
    /// identical: measured over the five trees, 0 lines become comment-prefixed only after the strip
    /// (the direction that would be a coverage gap) and 170 raw comment-prefixed lines are not
    /// comment-prefixed after it, all downstream of the two `Tests/` string-literal spans, where
    /// scanning more is safe. The same test, on the raw line.
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
            Self.verdictHolds(offenders: offenders),
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

    // MARK: - The guard: no file the reader scans ends with a span open (SONNY-409 F1)

    /// Whether `source` ends with a block-comment span still open, decided by the real stripper.
    ///
    /// **The per-line probe answers a different question, and the gap between them is a live hole.**
    /// It evaluates each line from depth 0 and looks only at comment-prefixed lines, while
    /// `MacAgentSource.read` strips a whole file in one pass and does not care where an opener sits.
    /// So a *code* line carrying a trailing note that opens a span blinds `read` from that line to
    /// end of file exactly as `EditWorkspaceCapabilityAdapter.swift:417` did, and the per-line
    /// selection never examines it. PR #199's reviewer demonstrated that rather than arguing it:
    /// mutant R4 put a trailing note whose glob carries an opener into a shipping target, hid
    /// `var plannerSelectionKey: String { "SONNY_PLANNER" }` behind it, and **all 2856 tests
    /// passed** while `ClientNamesNoProviderScanTests` was reading a truncated file. R5, the same
    /// token with the note removed, was killed by name — so the scan works and R4's survival was
    /// the blinding.
    static func leavesASpanOpenAtEndOfFile(_ source: String) -> Bool {
        !MacAgentSource.strippingBlockComments(source + "\n" + sentinel).contains(sentinel)
    }

    /// The 1-based line that opened the span still hanging at end of file: the line after the last
    /// prefix of the file that was balanced.
    ///
    /// Asks the same question as the check above, of a growing prefix, rather than counting
    /// delimiters — a count is what reads a vitest glob as two opens and one close. It runs only for
    /// a file already known to end unbalanced, so the prefix walk costs nothing on a green tree.
    static func lineOpeningTheUnclosedSpan(in source: String) -> Int? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var lastBalanced = 0
        for index in lines.indices
        where !leavesASpanOpenAtEndOfFile(lines[...index].joined(separator: "\n")) {
            lastBalanced = index + 1
        }
        return lastBalanced < lines.count ? lastBalanced + 1 : nil
    }

    /// **No file of the two trees `MacAgentSource.read` actually reads ends with a span open.**
    ///
    /// This is the guard; the per-line refusal above is the diagnostic that names the comment. The
    /// trees are `appSourceFiles()` and `coreSourceFiles()` — taken from `MacAgentSource` itself
    /// rather than restated, so the scan cannot drift from what the reader reads.
    ///
    /// **Scoping it to those two trees is what dissolves the conflict the per-line narrowing was
    /// built around.** Blinding is only live where something strips block comments, which is these
    /// two directories and nowhere else; both string-literal residuals that made a wider check
    /// awkward sit in `Tests/`, which no stripper reads. So this closes the comment door, the
    /// code-line door and SONNY-413's literal door at once, for the only region where any of them
    /// bites, and it needs no string-literal parsing to do it.
    ///
    /// Measured across this branch: **0 offending files at the head, 1 at `2856840`** —
    /// `EditWorkspaceCapabilityAdapter.swift`, the defect the ticket was filed for.
    @Test
    func noSourceFileTheReaderScansEndsWithABlockCommentSpanOpen() throws {
        let appFiles = try MacAgentSource.appSourceFiles()
        let coreFiles = try MacAgentSource.coreSourceFiles()

        // Both trees, named rather than inferred from a total: a floor alone would be satisfied by
        // one large tree while the other went unread.
        #expect(!appFiles.isEmpty, "Sources/MacAgent yielded no files")
        #expect(!coreFiles.isEmpty, "Sources/MacAgentCore yielded no files")

        var offenders: [String] = []
        var filesRead = 0
        for url in appFiles + coreFiles {
            filesRead += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            guard Self.leavesASpanOpenAtEndOfFile(text) else { continue }
            let opener = Self.lineOpeningTheUnclosedSpan(in: text).map(String.init) ?? "unknown line"
            let relative = url.path.hasPrefix(Self.repositoryRoot.path + "/")
                ? String(url.path.dropFirst(Self.repositoryRoot.path.count + 1))
                : url.lastPathComponent
            offenders.append("\(relative):\(opener)")
        }
        #expect(filesRead > 150, "the scan read \(filesRead) files, too few to be both shipping trees")

        #expect(
            Self.verdictHolds(offenders: offenders),
            """
            A block-comment span is still open at end of file, opened at:
            \(offenders.joined(separator: "\n"))
            Everything after that line is invisible to MacAgentSource.read, so every scan built on \
            it — the provider-name scan, the entitlement scans, the sign-in scans — searches a \
            truncated file and passes. The opener may be in a doc comment, in a note trailing a \
            line of code, or inside a string literal; this check does not care which, because the \
            reader does not either.
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
    /// examined: `TestSourceTree.swift:147` at this head holds the token as data, and this scan
    /// reads only comment-prefixed lines.
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

    // MARK: - The stripping order itself (SONNY-417)

    /// `MacAgentSource.read` over a fixture written to a temporary file, which is the only way to
    /// reach the `URL` overload — the ordering being pinned lives inside it, not inside
    /// `strippingBlockComments`, so nothing short of the real `read` measures it.
    private static func readingFixture(_ contents: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SONNY409-\(UUID().uuidString).swift")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try MacAgentSource.read(url)
    }

    /// **The control every absence assertion below depends on.** `read` returning an empty string
    /// would satisfy all three of them, which is this repository's clean-zero family arriving inside
    /// the test written to close one. So real code must survive first.
    @Test
    func readKeepsRealCodeSoTheAbsenceAssertionsAreNotVacuous() throws {
        let text = try Self.readingFixture(
            """
            struct Thing {
                let survivingCode = 1
            }
            """
        )
        #expect(text.contains("survivingCode"))
        #expect(text.contains("struct Thing"))
    }

    /// A line-comment-shaped line inside a block comment does not reach the text a scan reads.
    ///
    /// **This is the fixture SONNY-417's description names, and on its own it does not pin the
    /// order** — measured rather than assumed, by running both orderings over it: the line is
    /// comment-prefixed, so the line filter drops it whichever half runs first, and the mutant
    /// reversing the order passes this test. It is kept because it is a true property of `read` and
    /// the one a reader expects to find here; the arm below is the one that fails when the order
    /// moves.
    @Test
    func aLineCommentInsideABlockCommentDoesNotReachTheScannedText() throws {
        let text = try Self.readingFixture(
            """
            struct Thing {
                \(Self.spanOpen) opening
                // let hidden = "insideTheBlock"
                \(Self.spanClose)
                let survivingCode = 1
            }
            """
        )
        #expect(!text.contains("insideTheBlock"))
        #expect(text.contains("survivingCode"), "the fixture must still carry code, or this proves nothing")
    }

    /// **The order is load-bearing here, and this is the arm that says so.** A line comment that
    /// only *becomes* comment-prefixed once the block span in front of it is removed is dropped by
    /// the shipped order and survives under the reversed one.
    ///
    /// That is not a contrived shape. It is PR #80's mutant class exactly: a comment naming
    /// `cancelCurrentRun()` reaching the text a scan searches, so the scan reads the sentence
    /// describing the code instead of the code. `MacAgentSourceScan`'s header records that mutant
    /// surviving twice before both comment syntaxes were stripped.
    ///
    /// Measured at `1ffd52ae` by running both orderings over all four candidate fixtures: this is
    /// the only one whose result differs between them, which is why W4 survived a battery whose
    /// other five mutants died.
    @Test
    func aLineCommentUncoveredByTheBlockStripIsStillDropped() throws {
        let text = try Self.readingFixture(
            """
            struct Thing {
                \(Self.spanOpen) note \(Self.spanClose) // was viewModel.cancelCurrentRun()
                let survivingCode = 1
            }
            """
        )
        #expect(
            !text.contains("cancelCurrentRun"),
            """
            A comment survived into the text a scan reads. `MacAgentSource.read` must strip block \
            spans BEFORE it drops comment-prefixed lines: reversing those two steps leaves a line \
            comment that sat behind a block comment in the scanned text, and a scan searching for a \
            symbol then matches the sentence about it. That is the mutant PR #80's reviewer used.
            """
        )
        #expect(text.contains("survivingCode"), "the fixture must still carry code, or this proves nothing")
    }

    /// The mirror SONNY-417 asks for: an ordinary line comment, behind no block at all, still drops.
    /// **The verdict's strength, held on every run rather than by a battery nobody re-runs.**
    ///
    /// `withKnownIssue` fails when its body records *no* issue, so this arm passes only while
    /// ``verdictHolds(offenders:)`` genuinely rejects a non-empty list. Soften the predicate — the
    /// reviewer's R1 made it `offenders.count >= 0` — and the expectation below stops failing, the
    /// known issue never arrives, and this test goes red on a clean tree.
    @Test
    func theVerdictRejectsANonEmptyOffenderList() {
        withKnownIssue("the verdict must reject a non-empty offender list") {
            #expect(Self.verdictHolds(offenders: ["Sources/MacAgentCore/Planted.swift:1 — planted"]))
        }
    }

    @Test
    func aLineCommentOutsideAnyBlockStillDrops() throws {
        let text = try Self.readingFixture(
            """
            struct Thing {
                // let dropped = "outsideAnyBlock"
                let survivingCode = 1
            }
            """
        )
        #expect(!text.contains("outsideAnyBlock"))
        #expect(text.contains("survivingCode"), "the fixture must still carry code, or this proves nothing")
    }
}
