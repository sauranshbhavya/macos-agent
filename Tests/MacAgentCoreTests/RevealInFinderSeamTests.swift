import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// **The `reveal_in_finder` capability reveals through an injected seam, and nothing in
/// `MacAgentCore` can reach Finder any other way** (SONNY-395).
///
/// `RevealInFinderCapabilityAdapter` used to call `NSWorkspace.shared.activateFileViewerSelecting`
/// inline. That made it the only one of the 27 `*CapabilityAdapter.swift` files reaching the
/// machine with no seam at all — measured rather than assumed:
/// `git grep -nE 'NSWorkspace|NSAppleScript|Process\(|CGEvent|AXUIElement|NSSound' 619ba62 --
/// 'Sources/MacAgentCore/*CapabilityAdapter.swift' | grep -vE ':[0-9]+: *//'` answers that one
/// line and nothing else, against 27 files
/// (`git ls-tree --name-only 619ba62 Sources/MacAgentCore/ | grep -c 'CapabilityAdapter.swift$'`).
///
/// **What that cost, measured at `619ba62` with a probe on all six of the package's desktop
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

    /// **The property the ticket asked for: a test that fails if the real call comes back.**
    ///
    /// Driven through `AgentActionExecutor` rather than by calling the adapter directly, because the
    /// executor is what resolves the plan and builds the context, and a test that skipped it would
    /// exercise a path production never takes.
    @Test
    func aRevealReachesTheSeamTheRegistryWasBuiltWith() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("shown.pdf")
        try Data("x".utf8).write(to: file, options: .atomic)

        let recorder = RevealRecorder()
        let executor = makeExecutor(root: root, registry: .revealing(with: { recorder.record($0) }))

        let result = try await executor.execute(
            plan: AgentPlan(
                summary: "Reveal it.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(
                        id: "reveal",
                        operation: .revealInFinder,
                        description: "Reveal it.",
                        inputPath: file.path
                    )
                ]
            ),
            log: { _, _ in }
        )

        // The control: the run really did reach the reveal capability rather than failing early.
        #expect(result.summary == "Revealed \(file.path) in Finder.")
        // The property: exactly one reveal, of exactly the resolved URL, through the seam.
        #expect(recorder.revealed.count == 1, "the seam was called \(recorder.revealed.count) times")
        let revealed = try #require(recorder.revealed.first)
        #expect(revealed == [file])
    }

    /// Two registries do not share a revealer.
    ///
    /// The mutant this is against is a seam stored somewhere process-wide — a static, a shared box —
    /// which the test above cannot see, because with one registry in play a global and a per-registry
    /// closure behave identically.
    @Test
    func eachRegistryRevealsThroughItsOwnSeamAndNotItsNeighbours() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("shown.pdf")
        try Data("x".utf8).write(to: file, options: .atomic)

        let mine = RevealRecorder()
        let theirs = RevealRecorder()
        // Built first and deliberately never run: a shared seam would have it filling anyway.
        _ = CapabilityRegistry.revealing(with: { theirs.record($0) })

        let executor = makeExecutor(root: root, registry: .revealing(with: { mine.record($0) }))
        _ = try await executor.execute(
            plan: AgentPlan(
                summary: "Reveal it.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(
                        id: "reveal",
                        operation: .revealInFinder,
                        description: "Reveal it.",
                        inputPath: file.path
                    )
                ]
            ),
            log: { _, _ in }
        )

        #expect(mine.revealed == [[file]])
        #expect(theirs.revealed.isEmpty, "a second registry's seam saw \(theirs.revealed)")
    }

    /// **The sweep the behavioural tests cannot do: no file in `MacAgentCore` reaches Finder except
    /// the one named closure.**
    ///
    /// A rewrite that called `NSWorkspace.shared.activateFileViewerSelecting` *as well as* the seam
    /// passes every test above, because the recorder still fills. This is what fails instead.
    ///
    /// It is anchored on `DefaultCapabilityAdapters.liveFinderReveal` rather than on a count alone,
    /// because a count of one is satisfied by the wrong one of two sites — the shape CLAUDE.md
    /// records as a shared-token scan standing in for a property of one of them.
    @Test
    func onlyOneLineInTheCoreOpensAFinderWindow() throws {
        let sources = try FileManager.default
            .contentsOfDirectory(at: Self.coreSourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(sources.count > 100, "the sweep enumerated \(sources.count) files — too few to be the target")

        var naming: [String: Int] = [:]
        for url in sources {
            let code = try Self.codeLines(of: String(contentsOf: url, encoding: .utf8))
            let count = code.components(separatedBy: "activateFileViewerSelecting").count - 1
            if count > 0 {
                naming[url.lastPathComponent] = count
            }
        }

        #expect(
            naming == ["DefaultCapabilityAdapters.swift": 1],
            """
            the live Finder reveal is named at \(naming) rather than once in DefaultCapabilityAdapters.swift. \
            A second site is a door around the injected seam, which is what opened four Finder windows \
            per suite run before SONNY-395.
            """
        )

        // The other half, stated separately because the assertion above would also pass if the
        // adapter reached Finder by some other API.
        let adapter = try String(
            contentsOf: Self.coreSourceDirectory.appendingPathComponent("RevealInFinderCapabilityAdapter.swift"),
            encoding: .utf8
        )
        #expect(
            !Self.codeLines(of: adapter).contains("NSWorkspace"),
            "RevealInFinderCapabilityAdapter names NSWorkspace again — its whole point is that it cannot reach the desktop"
        )
    }

    /// **The executor's default registry reveals nowhere.**
    ///
    /// Unobservable at run time — a registry that reveals nowhere and one that reveals for real are
    /// behaviourally identical to everything a test can read, which is the whole reason the live one
    /// went unnoticed. So this is a scan, and it is the one guard on the inverted default that
    /// `.revealingNowhere`'s own doc comment explains.
    @Test
    func theExecutorsDefaultRegistryIsTheOneThatRevealsNowhere() throws {
        let executor = try String(
            contentsOf: Self.coreSourceDirectory.appendingPathComponent("AgentActionExecutor.swift"),
            encoding: .utf8
        )
        let code = Self.codeLines(of: executor)

        #expect(
            code.contains("capabilityRegistry: CapabilityRegistry = .revealingNowhere"),
            "AgentActionExecutor's capabilityRegistry default is no longer the registry that cannot open a window"
        )
        #expect(
            !code.contains("CapabilityRegistry = .revealing(with:"),
            "AgentActionExecutor defaults its registry to a live revealer again"
        )
    }

    // MARK: - Helpers

    private static let coreSourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/MacAgentCore", isDirectory: true)

    /// Line comments only. A block-comment stripper is what `MacAgentSource` is for, and it lives in
    /// the app test target where this one cannot reach it; the files this sweep reads carry their
    /// prose in `///` and `//`, and `theSweepReadsPastAComment` is the arm that proves the stripping
    /// happens at all.
    private static func codeLines(of source: String) -> String {
        source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The control on the stripper above: a scan that cannot see a comment is a scan whose zero
    /// means nothing, and this file's own prose names both searched tokens many times over.
    @Test
    func theSweepReadsPastAComment() {
        let source = """
        // NSWorkspace.shared.activateFileViewerSelecting(urls)
            /// activateFileViewerSelecting again
        let kept = "activateFileViewerSelecting"
        """
        let code = Self.codeLines(of: source)
        #expect(code.components(separatedBy: "activateFileViewerSelecting").count - 1 == 1)
        #expect(!code.contains("NSWorkspace"))
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevealInFinderSeamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutor(root: URL, registry: CapabilityRegistry) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
            capabilityRegistry: registry
        )
    }
}
