import Foundation
import Testing
@testable import MacAgentCore

/// Every `AgentViewModel` a test constructs must hand it an `OutputLocationStore` of its own
/// (SONNY-209 fix round, from the founder's manual pass).
///
/// **The failure this exists for actually happened, on the founder's Mac.** `AgentViewModel.init`
/// defaults `outputLocationStore` to a store at the *real*
/// `~/Library/Application Support/Sonny/output-locations.json`, and 13 of the 14 fixtures that build
/// a view model did not pass one. Their whitelists point at temp directories, so a test that wrote a
/// file recorded that folder — into the user's real store file, encrypted with the deterministic key
/// `LocalStorageEncryption` substitutes inside a test process. The packaged app then could not
/// decrypt its own file and showed a storage banner on the first manual item. Diagnosed at
/// `f7d3553`: the file decrypted under `Data(repeating: 0x53, count: 32)` and not under the Keychain
/// key, and all 50 of its entries were test temp directories belonging to four named suites.
///
/// **A defaulted parameter is invisible to the call sites that predate it**, which is the whole
/// mechanism: adding one compiles every existing fixture unchanged and silently points the new store
/// at the user's home directory. Nine other stores on this initializer default the same way and are
/// safe only because fixtures happen to pass them — two of them, `visionSessionJournalStore` and
/// `approvedAppStore`, are *not* passed by every fixture even today. That is **SONNY-240**, filed at
/// high priority, and this scan is deliberately narrow: it covers this store only, and SONNY-240
/// generalises it.
///
/// **In the core target because `TestSourceTree` is**, and a second copy of this repository's
/// comment-stripping discipline is exactly what its own doc warns against. `LivePermissionCheckerScanTests`
/// already scans across targets from here, so the direction is precedented.
@Suite
struct OutputLocationFixtureWiringScanTests {
    /// The fixtures, scanned as a population rather than as a list — a sixteenth file fails this by
    /// arriving, not by being remembered here. (Fifteen since SONNY-210 added one; the number is
    /// here and in the floor below, and nowhere else.)
    @Test
    func everyTestConstructedAgentViewModelIsHandedItsOwnOutputLocationStore() throws {
        let files = try TestSourceTree.swiftFiles(in: "MacAgentTests")
        #expect(!files.isEmpty, "the enumerator found no test sources — a scan matching nothing reads exactly like a passing one")

        var sitesScanned = 0
        var filesWithSites: Set<String> = []
        for file in files {
            let code = TestSourceTree.codeLines(of: try TestSourceTree.read(file))
                .map(\.text)
                .joined(separator: "\n")

            for call in Self.argumentLists(of: "AgentViewModel(", in: code) {
                sitesScanned += 1
                filesWithSites.insert(file.relativePath)

                // Matched at the start of a line, not merely present. `codeLines` drops
                // comment-*prefixed* lines and deliberately keeps trailing ones, so a note reading
                // `// outputLocationStore:` survives into the text — and a bare `contains` would let
                // a comment satisfy a wiring check. An argument label begins its line; a trailing
                // comment cannot.
                let argumentLines = call
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                #expect(
                    argumentLines.contains { $0.hasPrefix("outputLocationStore:") },
                    """
                    \(file.relativePath) builds an AgentViewModel without passing `outputLocationStore:`. \
                    The default is a store at the real ~/Library/Application Support/Sonny path, which a \
                    test process writes with a key the packaged app cannot read. Pass one at this \
                    fixture's own temp root.
                    """
                )

                // A store passed but left to its own default file URL is the same defect one layer
                // in: `OutputLocationStore()` satisfies a presence check and still writes to the
                // user's home directory.
                if let store = Self.argumentLists(of: "OutputLocationStore(", in: call).first {
                    #expect(
                        store.contains("fileURL:"),
                        "\(file.relativePath) passes an OutputLocationStore that names no fileURL, so it still defaults to the real path"
                    )
                }

                // **The same two checks for SONNY-210's store, which has the identical hazard**
                // (PR #105 review). `resumableTaskStore` defaults the same way and holds whole plans
                // — a fixture that missed it wrote a neighbouring suite's runs into the user's real
                // file, which is how the seventh registration step got found in the first place.
                // Named rather than generalised on purpose: **SONNY-240** is the ticket that turns
                // this into a scan over every defaulted store on the initializer, and a second
                // hard-coded name here is what it will replace.
                #expect(
                    argumentLines.contains { $0.hasPrefix("resumableTaskStore:") },
                    """
                    \(file.relativePath) builds an AgentViewModel without passing `resumableTaskStore:`. \
                    The default is a store at the real ~/Library/Application Support/Sonny path, which a \
                    test process writes with a key the packaged app cannot read. Pass one at this \
                    fixture's own temp root.
                    """
                )
                if let store = Self.argumentLists(of: "ResumableTaskStore(", in: call).first {
                    #expect(
                        store.contains("fileURL:"),
                        "\(file.relativePath) passes a ResumableTaskStore that names no fileURL, so it still defaults to the real path"
                    )
                }
            }
        }

        // The population, so a broken enumerator or a renamed type cannot pass this vacuously.
        #expect(sitesScanned >= 15, "expected at least the 15 known construction sites, scanned \(sitesScanned)")
        #expect(filesWithSites.count == sitesScanned, "a file with two construction sites — check both are wired, then relax this")
    }

    /// The default really is the user's home directory, which is the premise the scan above rests on.
    ///
    /// Both stores, since SONNY-210 joined the scan: a premise asserted for one of the two it covers
    /// is a premise for half of it.
    /// Asserted rather than assumed: if the default ever became temp-aware, this scan would be
    /// guarding nothing and should be re-argued rather than left standing.
    @Test
    func theDefaultStorePathIsUnderApplicationSupport() {
        let defaultPath = OutputLocationStore().fileURL.path
        let applicationSupport = ClipboardHistoryStore.defaultDirectory(fileManager: .default).path

        #expect(defaultPath.hasPrefix(applicationSupport + "/"))
        #expect(defaultPath.hasSuffix("/output-locations.json"))
        #expect(!defaultPath.contains("/var/folders/"), "the default must not already be a temp path")

        let resumablePath = ResumableTaskStore().fileURL.path
        #expect(resumablePath.hasPrefix(applicationSupport + "/"))
        #expect(resumablePath.hasSuffix("/resumable-tasks.json"))
        #expect(!resumablePath.contains("/var/folders/"))
    }

    /// Every argument list of a call to `name`, depth-matched on parentheses.
    ///
    /// Depth-matching rather than line slicing because these calls nest — a fixture's
    /// `AgentViewModel(` argument list contains a dozen further constructions, and a scan that
    /// stopped at the first `)` would read one argument and call it the call.
    ///
    /// **Textual, with the residuals this repository already names for its other scans:** a
    /// parenthesis inside a string literal would miscount, and nothing here parses Swift. No literal
    /// in any scanned call contains one today.
    private static func argumentLists(of name: String, in source: String) -> [String] {
        var results: [String] = []
        var searchStart = source.startIndex
        while let found = source.range(of: name, range: searchStart..<source.endIndex) {
            var depth = 0
            var index = source.index(before: found.upperBound)   // the opening paren
            var closed: String.Index?
            while index < source.endIndex {
                if source[index] == "(" {
                    depth += 1
                } else if source[index] == ")" {
                    depth -= 1
                    if depth == 0 {
                        closed = index
                        break
                    }
                }
                index = source.index(after: index)
            }
            guard let closed else {
                break
            }
            results.append(String(source[found.upperBound..<closed]))
            searchStart = closed
        }
        return results
    }
}
