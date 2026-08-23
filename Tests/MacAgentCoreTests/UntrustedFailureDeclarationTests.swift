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
/// So every record carries a `source` line: literal text that must still exist somewhere under
/// `Tests/`. For the message-based signatures it is the message itself, which is where a reword
/// gets caught. For `Expectation failed: (elapsed →` — swift-testing's own rendering, which appears
/// in no source file — it is the expression that produces that rendering, so renaming the variable
/// the signature depends on fails here too.
///
/// **What this cannot check, stated rather than implied.** It holds one direction only: that a
/// declaration still matches something. Nothing mechanical can hold the other one — whether some
/// test that ought to be declared is missing from the file — because "this assertion depends on how
/// busy the machine is" is a judgment, not a token. `scripts/mutate --help` says so in the same
/// words under "What this does and does not prevent"; the list is a list, and it does not know what
/// it is missing (SONNY-224).
///
/// Comment-prefixed lines are dropped before the search, for the reason `MacAgentSource` gives at
/// length: a scan a comment can satisfy holds nothing. A prose mention of a backstop's wording is
/// exactly the thing that would keep this green after the backstop itself was reworded.
@Suite
struct UntrustedFailureDeclarationTests {
    private struct Record {
        let signature: String
        let source: String
        let reason: String
    }

    private static var declarationFile: URL {
        TestSourceTree.root
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/mutate-untrusted-failures")
    }

    /// Every record, in file order. Parsed the way `scripts/mutate` parses it: directives at column
    /// zero, everything else ignored.
    private static func records() throws -> [Record] {
        let text = try String(contentsOf: declarationFile, encoding: .utf8)
        var records: [Record] = []
        var signature: String?
        var source: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let value = line.dropping(prefix: ">>> signature ") {
                signature = value
                source = nil
            } else if let value = line.dropping(prefix: ">>> source ") {
                source = value
            } else if let value = line.dropping(prefix: ">>> reason ") {
                if let signature, let source {
                    records.append(Record(signature: signature, source: source, reason: value))
                }
                signature = nil
                source = nil
            }
        }
        return records
    }

    @Test
    func theDeclarationFileParsesAndEveryRecordIsComplete() throws {
        let text = try String(contentsOf: Self.declarationFile, encoding: .utf8)
        let signatureCount = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(">>> signature ") }
            .count

        let complete = try Self.records().count

        #expect(signatureCount > 0, "a declaration file that declares nothing is a deleted one")
        #expect(
            complete == signatureCount,
            """
            \(signatureCount) signature(s) declared but only \(complete) complete record(s) \
            parsed. Every `>>> signature` needs a `>>> source` and a `>>> reason` after it — the \
            source is what this suite checks it against, and without one the signature is \
            unverifiable.
            """
        )
    }

    @Test
    func everyDeclaredSignatureStillMatchesSomethingInTheTestTree() throws {
        let records = try Self.records()
        #expect(!records.isEmpty)

        var code = ""
        for target in TestSourceTree.targets {
            for file in try TestSourceTree.swiftFiles(in: target) {
                code += TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                    .map(\.text)
                    .joined(separator: "\n")
                code += "\n"
            }
        }
        #expect(!code.isEmpty, "the enumerator found no test sources — a scan matching nothing reads exactly like a passing one")

        for record in records {
            #expect(
                code.contains(record.source),
                """
                scripts/mutate-untrusted-failures declares a signature whose `source` no longer \
                appears anywhere under Tests/:

                  signature: \(record.signature)
                  source:    \(record.source)

                The declaration has stopped protecting anything, and a battery is counting that \
                failure as a kill again. Either the text it was written for was reworded — update \
                both lines together — or the test it covered is gone and the record should go with it.
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
