import Foundation
import Testing

/// `scripts/mutate-untrusted-failures` names the failures a mutation battery must not read as a
/// kill. This suite is the half of that file's correctness which can be checked mechanically.
///
/// **Why it needs checking at all.** A signature is a literal fragment of the message a test
/// records when it fails. Nothing in Swift knows the file exists, so rewording a hang backstop —
/// an ordinary, blameless edit — silently stops the signature matching, and the next battery goes
/// back to counting that failure as a kill with nothing anywhere saying so. That is the same defect
/// as a listed test name that no longer resolves, and it is worse than never having declared it:
/// the file still reads as protection.
///
/// So every record carries a `source` line — literal text that must still exist under `Tests/` —
/// and a `sites` count of how many times it appears there. The count is the half that bites. A
/// presence check alone asks only whether the text survives *somewhere*, and four of the five
/// records have more than one site, so rewording one of six copies left this suite green while that
/// copy's failures went quietly back to counting as kills (PR #112 review, F4).
///
/// **Nothing this suite records may quote a declaration.** Its failure message used to interpolate
/// the signature and source it had caught going stale, and `scripts/mutate` matches signatures
/// against recorded issue text — so the guard's own failure matched a declaration, the battery
/// marked it untrusted, and it printed "BASELINE RED, and only on failures this harness does not
/// trust ... Continuing" and ran the whole battery against the file it had just been told was
/// stale (PR #112 review, F1). Two things close that: nothing below interpolates file text, which
/// `noDeclaredSignatureAppearsInThisSuitesOwnSource` enforces on the whole file rather than on
/// today's wording; and `scripts/mutate` names these tests in `ALWAYS_TRUSTED` and treats them as
/// evidence whatever they record, which `theHarnessAlwaysTrustsExactlyTheTestsInThisSuite` keeps
/// from going stale under a rename.
///
/// Expectations here take a `Bool` computed beforehand rather than an expression over the scanned
/// text, for a reason that is not style: swift-testing renders a failing expression's operands into
/// the issue, and `#expect(code.contains(...))` rendered the entire concatenated test tree — one
/// failing record produced a 2,128,166-byte log, and five stale records would produce five of them.
///
/// **What this cannot check, stated rather than implied.** It holds one direction only: that a
/// declaration still matches what it says it matches. Nothing mechanical can hold the other one —
/// whether some test that ought to be declared is missing from the file — because "this assertion
/// depends on how busy the machine is" is a judgment, not a token. `scripts/mutate --help` says so
/// in the same words under "What this does and does not prevent"; the list is a list, and it does
/// not know what it is missing (SONNY-224).
///
/// Comment-prefixed lines are dropped before the search, for the reason `MacAgentSource` gives at
/// length: a scan a comment can satisfy holds nothing. A prose mention of a backstop's wording is
/// exactly the thing that would keep this green after the backstop itself was reworded.
@Suite
struct UntrustedFailureDeclarationTests {
    private struct Record {
        let signature: String
        let source: String
        let sites: Int
        let reason: String
        /// 1-based line of this record's `source` directive, which is how a failure below points at
        /// a record without quoting one.
        let sourceLine: Int
    }

    private static var declarationFile: URL {
        repositoryRoot.appendingPathComponent("scripts/mutate-untrusted-failures")
    }

    private static var harnessFile: URL {
        repositoryRoot.appendingPathComponent("scripts/mutate")
    }

    private static var repositoryRoot: URL {
        TestSourceTree.root.deletingLastPathComponent()
    }

    /// Every record, in file order. Parsed the way `scripts/mutate` parses it: directives at column
    /// zero, everything else ignored.
    private static func records() throws -> [Record] {
        let text = try String(contentsOf: declarationFile, encoding: .utf8)
        var records: [Record] = []
        var signature: String?
        var source: String?
        var sourceLine = 0
        var sites: Int?

        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).enumerated() {
            if let value = line.dropping(prefix: ">>> signature ") {
                signature = value
                source = nil
                sites = nil
            } else if let value = line.dropping(prefix: ">>> source ") {
                source = value
                sourceLine = offset + 1
            } else if let value = line.dropping(prefix: ">>> sites ") {
                sites = Int(value)
            } else if let value = line.dropping(prefix: ">>> reason ") {
                if let signature, let source, let sites {
                    records.append(
                        Record(
                            signature: signature,
                            source: source,
                            sites: sites,
                            reason: value,
                            sourceLine: sourceLine
                        )
                    )
                }
                signature = nil
                source = nil
                sites = nil
            }
        }
        return records
    }

    /// The test tree the way a `source` is counted against it: every file SwiftPM compiles into a
    /// test target, comment lines dropped, joined.
    private static func testTreeCode() throws -> String {
        var code = ""
        for target in TestSourceTree.targets {
            for file in try TestSourceTree.swiftFiles(in: target) {
                code += TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                    .map(\.text)
                    .joined(separator: "\n")
                code += "\n"
            }
        }
        return code
    }

    /// Non-overlapping occurrences, which is what a site count means and what the declaration file's
    /// numbers were measured as.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// The `@Test` function names declared in this file, read from its own source.
    private static func testNamesInThisSuite() throws -> Set<String> {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        var names: Set<String> = []
        var pendingTestAttribute = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@Test") {
                pendingTestAttribute = true
                continue
            }
            guard pendingTestAttribute, let range = trimmed.range(of: "func ") else { continue }
            let rest = trimmed[range.upperBound...]
            if let open = rest.firstIndex(of: "(") {
                names.insert(String(rest[rest.startIndex..<open]))
            }
            pendingTestAttribute = false
        }
        return names
    }

    /// The names `scripts/mutate` refuses to let any declaration excuse, read out of its own
    /// `ALWAYS_TRUSTED` literal.
    private static func alwaysTrustedNamesInTheHarness() throws -> Set<String> {
        let text = try String(contentsOf: harnessFile, encoding: .utf8)
        var names: Set<String> = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.contains("ALWAYS_TRUSTED = frozenset({") {
                inside = true
                continue
            }
            guard inside else { continue }
            if line.contains("})") { break }
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            if parts.count >= 2 {
                names.insert(String(parts[1]))
            }
        }
        return names
    }

    @Test
    func theDeclarationFileParsesAndEveryRecordIsComplete() throws {
        let text = try String(contentsOf: Self.declarationFile, encoding: .utf8)
        let signatureCount = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(">>> signature ") && $0.dropFirst(">>> signature ".count).trimmingCharacters(in: .whitespaces).isEmpty == false }
            .count

        let complete = try Self.records().count

        #expect(signatureCount > 0, "a declaration file that declares nothing is a deleted one")
        #expect(
            complete == signatureCount,
            """
            \(signatureCount) signature(s) declared but only \(complete) complete record(s) \
            parsed. Every non-empty `>>> signature` needs a `>>> source`, a `>>> sites` count and a \
            `>>> reason` after it — the first two are what this suite checks it against, and \
            without them the signature is unverifiable.
            """
        )
    }

    @Test
    func everyDeclaredSourceStillAppearsAtTheSiteCountItDeclares() throws {
        let records = try Self.records()
        let haveRecords = !records.isEmpty
        #expect(haveRecords, "the declaration file parsed to nothing")

        let code = try Self.testTreeCode()
        let scannedSomething = !code.isEmpty
        #expect(
            scannedSomething,
            "the enumerator found no test sources — a scan matching nothing reads exactly like a passing one"
        )

        // Deliberately quoting neither the signature nor the source: `scripts/mutate` matches
        // signatures against issue text, so a message carrying one disarms this guard in the
        // battery that most needs it. The declaration file's own line number is the pointer.
        for record in records {
            let found = Self.occurrences(of: record.source, in: code)
            #expect(
                found == record.sites,
                """
                scripts/mutate-untrusted-failures:\(record.sourceLine) declares a source that \
                appears \(record.sites) time(s) under Tests/. It appears \(found).

                Fewer than declared means a site was reworded or removed, and that site's failures \
                are being counted as mutation kills again — put the wording back, or give the new \
                wording its own record, or lower the number as a decision rather than a fix-up. \
                More than declared usually means a new test picked up the same helper, which is \
                the case this file is meant to cover for free: check that it is the same construct \
                and raise the number.
                """
            )
        }
    }

    @Test
    func theHarnessAlwaysTrustsExactlyTheTestsInThisSuite() throws {
        let declared = try Self.alwaysTrustedNamesInTheHarness()
        let actual = try Self.testNamesInThisSuite()

        #expect(!actual.isEmpty, "no @Test function was found in this file — the scan is broken, not passing")

        let missing = actual.subtracting(declared).sorted()
        let extra = declared.subtracting(actual).sorted()

        #expect(
            missing.isEmpty,
            """
            scripts/mutate's ALWAYS_TRUSTED does not name \(missing.joined(separator: ", ")). \
            A test in this suite that is not named there can be excused by the very declarations it \
            guards: when it fails, the battery reads the failure as one it cannot attribute, prints \
            a reassuring line, and runs the whole run against a declaration file it has just been \
            told is stale.
            """
        )
        #expect(
            extra.isEmpty,
            """
            scripts/mutate's ALWAYS_TRUSTED names \(extra.joined(separator: ", ")), which is not a \
            test in this suite. A name that resolves to nothing protects nothing, and reads exactly \
            like one that does.
            """
        )
    }

    @Test
    func noDeclaredSignatureAppearsInThisSuitesOwnSource() throws {
        let records = try Self.records()
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)

        // The whole file, comments included, rather than its code lines: swift-testing prints a
        // failing test's doc comment into the log beside the failure, so prose here reaches the
        // same text the classifier reads.
        for (index, record) in records.enumerated() {
            let quoted = text.contains(record.signature)
            #expect(
                !quoted,
                """
                This file quotes the text of the declaration at record \(index + 1) \
                (scripts/mutate-untrusted-failures:\(record.sourceLine)). Anything this suite writes \
                can end up in the issue text scripts/mutate classifies, and a guard whose failure \
                matches a declaration is a guard the declaration file switches off. Name the record \
                by its line number instead of quoting it.
                """
            )
        }
    }
}

private extension String {
    /// The remainder after `prefix`, or nil when this line does not start with it.
    func dropping(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
