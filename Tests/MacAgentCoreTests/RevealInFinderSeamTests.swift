import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// **The `reveal_in_finder` capability reveals through an injected seam, and nothing in
/// `MacAgentCore` can reach Finder at all** (SONNY-395).
///
/// `RevealInFinderCapabilityAdapter` used to call `NSWorkspace.shared.activateFileViewerSelecting`
/// inline. That made it the only capability adapter reaching the machine with no seam at all —
/// measured rather than assumed:
/// `git grep -nE 'NSWorkspace|NSAppleScript|Process\(|CGEvent|AXUIElement|NSSound' 15c7bd9 --
/// Sources/MacAgentCore | grep -E 'CapabilityAdapter[.]swift' | grep -vE ':[0-9]+: *//'` answers
/// that one line and nothing else, against 27 adapter files
/// (`git ls-tree --name-only 15c7bd9 Sources/MacAgentCore/ | grep -c 'CapabilityAdapter.swift$'`).
///
/// **The file filter is a pipe rather than a pathspec on purpose** — a pathspec naming the adapter
/// glob would put the two characters that open a block comment into this doc comment, and
/// `MacAgentSource` strips block comments before it drops `//` lines, so everything below it would
/// disappear from every scan that reads this file. `CLAUDE.md` records that happening from this
/// exact glob before (SONNY-220).
///
/// **What that cost, measured at `15c7bd9` with a probe on all six of the package's desktop
/// doors.** One full flagged run recorded **4** reveals — `ProductShellTests`'
/// `aJobOverManyItemsPublishesHowFarItHasGot` (three files) and `anOrdinaryRunPublishesNoJobProgress`
/// (one) — and **0** of `WorkspaceFileOpener.openFile`, `NativeMediaOpener.openURL`,
/// `MacAppService.open`, `WorkspaceBrowserOpener`'s default `openURL` or its `launchServicesOpen`.
/// The recorder those zeros came from is the same one the four reveals came from, so it is a
/// measurement rather than a clean zero from a probe nobody proved could fire. The reading is that
/// every other door already had a seam and every fixture that could reach one passed a double; this
/// door had none, so no fixture could opt out. A battery re-runs the suite once per mutant, which
/// is how four windows a run became the dozens the founder met in one working session.
///
/// **Both halves are needed and neither substitutes for the other**, which is the split
/// `RunSummaryProvenanceTests`' header argues for at length. The behavioural test below fails if
/// the reveal stops going through the seam — a mutant deleting it, or a rewrite calling
/// `NSWorkspace` *instead* of it, both leave the recorder empty. It cannot see a rewrite that calls
/// `NSWorkspace` *as well as* the seam, because the recorder still fills; that is what the sweep is
/// for.
@MainActor
struct RevealInFinderSeamTests {
    /// Records what would have been revealed. `@unchecked Sendable` with a lock for the reason
    /// `MemoryFixtureFinderRevealer` gives: the seam is a `@Sendable` closure.
    private final class RevealRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[URL]] = []

        func record(_ urls: [URL]) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(urls)
        }

        var revealed: [[URL]] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }



    /// **The sweep the behavioural tests cannot do: no line in the core names the Finder-reveal
    /// call.**
    ///
    /// A rewrite that called `NSWorkspace.shared.activateFileViewerSelecting` *as well as* the seam
    /// passes every test above, because the recorder still fills. This is what fails instead.
    ///
    /// **What this measures, stated narrowly because the wider claim it used to make is false**
    /// (PR #193 review, F3). This asserts that no non-comment line under `Sources/MacAgentCore`
    /// names `activateFileViewerSelecting`, and that `RevealInFinderCapabilityAdapter.swift` names
    /// no `NSWorkspace`. It does **not** establish that the core cannot reach Finder — the prose
    /// here and in the changelog said "names no way to reach Finder at all", and
    /// `FinderContextService.swift:43` is `tell application id "com.apple.finder"`, run through
    /// `osascript`, which is exactly that. It is behind the `finderContextReader` seam, so it is
    /// not a defect; the sentence was a negative claim established from one token, which is
    /// `CLAUDE.md`'s *enumerate before you subtract* shape. Other doors this sweep does not search:
    /// `NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)`, a `Process` running `open -R`, and
    /// `NSWorkspace.shared.open(folderURL)` — whose single-argument overload the core names **three**
    /// times today, in `AppWebsiteActionDescriptors.swift` (`WorkspaceFileOpener`),
    /// `MediaPlaybackService.swift` (`NativeMediaOpener`) and `WorkspaceBrowserOpener.swift`'s
    /// default `openURL`, all behind injected seams. (`git grep -nE
    /// 'NSWorkspace\.shared\.open\([^,)]*\)' HEAD -- Sources/MacAgentCore | grep -vE
    /// ':[0-9]+: *//'` → 3 at this branch's head, and 4 without the comment stage — the extra being the
    /// adapter's own prose, which is why the stage is there. This said "twice" until PR #193's
    /// cycle-3 re-check, N1.)
    ///
    /// **The enumeration is recursive, and that is not a precaution** (F1). `Package.swift` gives
    /// this target `path: "Sources/MacAgentCore"`, which SwiftPM compiles recursively, so a file at
    /// `Sources/MacAgentCore/Anything/Live.swift` is in the module. The first version of this used
    /// `FileManager.contentsOfDirectory`, which lists one directory — the identical hole
    /// `TestSourceTree`'s own header records finding and closing in the two `Tests/` scan suites.
    /// **The hole was latent rather than live**: no subdirectory exists under that target today, so
    /// nothing was being missed — `find Sources/MacAgentCore -mindepth 1 -type d` prints nothing, and
    /// `find Sources/MacAgentCore -name '*.swift' | wc -l` and the same with `-maxdepth 1` both
    /// answer 149 at this branch's head. (Written with `find` twice rather than a `ls` glob because the
    /// glob spells slash-star, which opens a block comment inside a line comment — the defect this
    /// branch already shipped and removed once, arriving again in the round that documents it.)
    /// "This scan was missing files" and "this scan would miss
    /// files" are different claims and only the second was ever true. What made it worth closing
    /// rather than recording is that the guard beside it could never have detected it: a
    /// `count > 100` floor is cleared by the top level alone.
    @Test
    func noLineInTheCoreNamesTheFinderRevealCall() throws {
        let sources = try TestSourceTree.sourceFiles(in: "MacAgentCore")
        #expect(sources.count > 100, "the sweep enumerated \(sources.count) files — too few to be the target")

        var naming: [String: Int] = [:]
        for file in sources {
            let code = Self.code(of: try TestSourceTree.read(file))
            let count = code.components(separatedBy: Self.revealCall).count - 1
            if count > 0 {
                naming[file.relativePath] = count
            }
        }

        #expect(
            naming.isEmpty,
            """
            MacAgentCore names the Finder-reveal call at \(naming). Every reveal in this package goes \
            through the seam on RevealInFinderCapabilityAdapter; a second door around it is what \
            opened four Finder windows per suite run before SONNY-395.
            """
        )

        // The other half, stated separately because the assertion above would also pass if the
        // adapter reached Finder through some other NSWorkspace call.
        let adapter = try #require(
            sources.first { $0.relativePath.hasSuffix("/RevealInFinderCapabilityAdapter.swift") },
            "the sweep did not enumerate the adapter itself"
        )
        #expect(
            !Self.code(of: try TestSourceTree.read(adapter)).contains("NSWorkspace"),
            "RevealInFinderCapabilityAdapter names NSWorkspace again — its whole point is that it cannot reach the desktop"
        )
    }

    // MARK: - Helpers

    static let revealCall = "activateFileViewerSelecting"

    /// Non-comment lines, from the shared reader.
    ///
    /// **`TestSourceTree` rather than a copy** (PR #193 review, F2). The first version of this file
    /// hand-rolled a line-comment stripper and derived the repository root from `#filePath`, and
    /// justified it by saying `MacAgentSource` — the block-comment-aware scanner — is in the app
    /// test target and unreachable from here. That is true of `MacAgentSource` and it was not the
    /// constraint actually hit: what got copied is the *line*-comment stripper, and that one is
    /// `TestSourceTree.codeLines` in this very target, used by four sites in
    /// `LocalStoreInjectionScanTests` and carrying the doc comment that already explains both
    /// limits the copy re-explained. Reusing it closes F1 for free, because the same type owns the
    /// recursive walker.
    private static func code(of source: String) -> String {
        TestSourceTree.codeLines(of: source).map(\.text).joined(separator: "\n")
    }

    /// The positive control on the zero above, and it controls the **enumeration** as well as the
    /// stripping — which is the half that can answer a reassuring zero (PR #193 review, F1).
    ///
    /// `CLAUDE.md`: before believing a zero, make the search find something. So this asserts the
    /// sweep reaches a file it must reach, sees a token that is really in that file's *code*, and
    /// does not see one that is only in its *comments* — and this file's subject matter guarantees
    /// the second, since `RevealInFinderCapabilityAdapter.swift` names the reveal call several times
    /// in prose and nowhere in code.
    @Test
    func theSweepFindsCodeAndNotComments() throws {
        let sources = try TestSourceTree.sourceFiles(in: "MacAgentCore")
        let adapter = try #require(
            sources.first { $0.relativePath.hasSuffix("/RevealInFinderCapabilityAdapter.swift") },
            "the sweep did not enumerate the adapter"
        )
        let source = try TestSourceTree.read(adapter)

        // The sweep can see code.
        #expect(Self.code(of: source).contains("public struct RevealInFinderCapabilityAdapter"))
        // It cannot see comments — and the raw file really does carry the token, so this is a
        // measurement of the stripper rather than of an absent string.
        #expect(source.contains(Self.revealCall), "the control's own premise is gone from the file")
        #expect(!Self.code(of: source).contains(Self.revealCall))
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevealInFinderSeamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
