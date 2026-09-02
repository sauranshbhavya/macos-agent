import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

// These two suites are the surviving half of SONNY-88 — the bidirectional dataLeavesDevice
// classification fix (SONNY-32) and its forcing function. The founder's 2026-08-14 decision
// deleted the Data-Sent-to-AI ledger these once shared a file with; the classification survives
// deliberately, because Safe mode's "Data leaves device: yes/no" approval line reads from it and
// the label is kept.

/// The forcing function for SONNY-32's bidirectional rule, stated at
/// `AgentActionExecutor.dataEgressOperations`: an operation is in the set (or in
/// `stepLeavesDevice`'s switch) if and only if executing it can send anything off the device.
/// The switch below has no `default`, so a new `AgentOperation` case fails compilation right
/// here until someone classifies it — landing an operation without deciding is the one path
/// this removes.
@MainActor
struct EgressClassificationTests {
    private enum ExpectedEgress {
        /// Sends something off the device on every execution → must be in `dataEgressOperations`.
        case alwaysLeavesDevice
        /// Egress depends on saved content the step merely names → handled by
        /// `stepLeavesDevice`'s switch, never the static set.
        case dependsOnSavedContent
        /// Cannot send anything off the device → must be in neither.
        case neverLeavesDevice
    }

    private func expectedClassification(for operation: AgentOperation) -> ExpectedEgress {
        switch operation {
        case .openHackerNews, .fetchHNHeadlines, .webToMarkdown, .openAppSearchURL, .openURL,
             .playMedia, .invokeShortcut:
            return .alwaysLeavesDevice
        // Row I. Every iteration sends a screenshot of the user's app window to the vision model —
        // redacted first, but redaction removes secrets, not the picture. "Always", not
        // "dependsOnSavedContent": a session that ends at iteration one still sent iteration one's
        // capture, so there is no shape of this operation that egresses nothing.
        case .visionSession:
            return .alwaysLeavesDevice
        // SONNY-382. Executing it fetches the watched page once, to record the baseline, so every
        // execution egresses. The repeated checks afterwards egress as well and are outside this
        // classification, which is about what a *step* does.
        case .startWatching:
            return .alwaysLeavesDevice
        case .openWorkspace, .runRoutine:
            return .dependsOnSavedContent
        case .scanSelectLargestFiles, .createZip, .scanDocx, .convertDocxToPDF, .openApp,
             .getFinderSelection, .revealInFinder, .showPermissionReadiness, .saveRoutine,
             .createWorkspace, .editWorkspace, .openGeneratedArtifact, .createLocalDraft,
             .calculateUtility, .lookupClipboardHistory, .expandSnippet, .saveSnippet,
             .switchRunningApp, .lookupRecentArtifacts, .clarify, .unsupported:
            return .neverLeavesDevice
        // `.writeMarkdown` is a local file write. It reads "no" honestly only because the
        // solitary-step shape can no longer be silently promoted into the Hacker News preset
        // (SONNY-32's false-"no", fixed with SONNY-88) — the companion pins live in
        // `SolitaryWriteMarkdownTests`.
        case .writeMarkdown:
            return .neverLeavesDevice
        }
    }

    @Test
    func everyAgentOperationIsClassifiedAgainstTheBidirectionalRule() {
        for operation in AgentOperation.allCases {
            let inSet = AgentActionExecutor.dataEgressOperations.contains(operation)
            switch expectedClassification(for: operation) {
            case .alwaysLeavesDevice:
                #expect(inSet, "\(operation.rawValue) always egresses and must be in dataEgressOperations")
            case .dependsOnSavedContent, .neverLeavesDevice:
                #expect(!inSet, "\(operation.rawValue) must not be in dataEgressOperations")
            }
        }
        // 7 before row I; the eighth is `.visionSession` and the ninth `.startWatching`
        // (SONNY-382). Re-measured, not incremented on faith.
        #expect(AgentActionExecutor.dataEgressOperations.count == 9)
    }
}

// MARK: - The solitary write_markdown fix (SONNY-32, absorbed by SONNY-88)

@MainActor
struct SolitaryWriteMarkdownTests {
    private final class CountingBrowserOpener: BrowserOpening {
        private(set) var openedURLs: [URL] = []

        func open(_ url: URL, using browser: MacApp?) async throws {
            openedURLs.append(url)
        }
    }

    private final class CountingHackerNewsFetcher: HackerNewsFetching {
        private(set) var fetchCount = 0

        func topHeadlines(limit: Int) async throws -> [HackerNewsHeadline] {
            fetchCount += 1
            return [HackerNewsHeadline(title: "Headline")]
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("solitary-write-markdown-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutor(root: URL, browserOpener: BrowserOpening, fetcher: HackerNewsFetching) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            browserOpener: browserOpener,
            hackerNewsFetcher: fetcher,
            // This file names `.showPermissionReadiness` in its classification list, so a test here
            // is one plan away from driving readiness through a live service (SONNY-123 PR #72 F1).
            permissionReadinessService: .deterministic(),
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            clipboardHistoryStore: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("artifacts.json")),
            shortcutCatalog: EmptyShortcutCatalog(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcuts.json")),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
        )
    }

    private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
        func shortcutNames() throws -> [String] { [] }
    }

    private func solitaryWriteMarkdownPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Save to a Markdown file.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "write",
                    operation: .writeMarkdown,
                    description: "Write Markdown.",
                    outputPath: output.path,
                    count: 5
                )
            ]
        )
    }

    /// SONNY-32's concrete failure, pinned shut: the solitary plan used to disclose "Data leaves
    /// device: no", then open news.ycombinator.com and fetch headlines. Now it never prepares —
    /// rejected with an error naming the real problem — and nothing reaches the network.
    @Test
    func aSolitaryWriteMarkdownPlanIsRejectedAsIncompleteBeforeAnythingRuns() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = CountingBrowserOpener()
        let fetcher = CountingHackerNewsFetcher()
        let executor = makeExecutor(root: root, browserOpener: browser, fetcher: fetcher)
        let plan = solitaryWriteMarkdownPlan(output: root.appendingPathComponent("note.md"))

        #expect(throws: AgentExecutionError.invalidPlan(
            "write_markdown is the Hacker News digest's write step and needs fetch_hn_headlines in the same plan. For a web research note, use web_to_markdown on its own — it writes its own file."
        )) {
            _ = try executor.prepare(plan: plan)
        }

        // The execute path is equally closed, and no network collaborator was ever touched.
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(plan: plan) { _, _ in }
        }
        #expect(browser.openedURLs.isEmpty)
        #expect(fetcher.fetchCount == 0)
    }

    /// The planner-instructed three-step shape is untouched: still the preset, still disclosing
    /// its egress through its two genuinely network-touching steps.
    @Test
    func theThreeStepHackerNewsShapeStillPreparesAsThePreset() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root, browserOpener: CountingBrowserOpener(), fetcher: CountingHackerNewsFetcher())
        let plan = AgentPlan(
            summary: "Save Hacker News headlines.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "open", operation: .openHackerNews, description: "Open Hacker News."),
                AgentStep(id: "fetch", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 5),
                AgentStep(id: "write", operation: .writeMarkdown, description: "Write Markdown.", outputPath: root.appendingPathComponent("hn.md").path, count: 5)
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        #expect(prepared.previews.first?.title == "Fetch Hacker News top 5")
    }

    @Test
    func aFetchPlusWritePairIsStillThePresetToo() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root, browserOpener: CountingBrowserOpener(), fetcher: CountingHackerNewsFetcher())
        let plan = AgentPlan(
            summary: "Save Hacker News headlines.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "fetch", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 3),
                AgentStep(id: "write", operation: .writeMarkdown, description: "Write Markdown.", outputPath: root.appendingPathComponent("hn.md").path, count: 3)
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        #expect(prepared.previews.first?.title == "Fetch Hacker News top 3")
    }

    /// **The other direction of SONNY-32's own fix, at the line a user actually reads.**
    ///
    /// The ticket asked for the decision about `.writeMarkdown` to be pinned "with a test asserting
    /// the disclosure line, the way SONNY-10's three executor tests do" — and SONNY-10's second test
    /// exists because a false-"yes" fix could have been bought with a blanket "no", which is the same
    /// defect inverted. Both tests above close the false-"no" half by proving the solitary shape never
    /// prepares; neither of them would fail if the surviving Hacker News shape started answering "no"
    /// as well. This one does, through the real `assessRisk` copy rather than the classification set,
    /// and through `safeModeLines` because Safe mode is the only surface that renders the sentence
    /// (E9, `AgentActivityPresentation.approvalDisclosureLines`).
    @Test
    func theSurvivingHackerNewsShapeStillDisclosesThatDataLeavesTheDevice() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root, browserOpener: CountingBrowserOpener(), fetcher: CountingHackerNewsFetcher())
        let plan = AgentPlan(
            summary: "Save Hacker News headlines.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "fetch", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 3),
                AgentStep(id: "write", operation: .writeMarkdown, description: "Write Markdown.", outputPath: root.appendingPathComponent("hn.md").path, count: 3)
            ]
        )

        let assessment = try executor.assessRisk(plan: plan, scope: .unscoped)

        let copy = try #require(assessment.approvalCopy)
        #expect(copy.dataLeavesDevice)
        #expect(copy.dataLeavesDeviceLine == "Data leaves device: yes")
        #expect(copy.safeModeLines.contains("Data leaves device: yes"))
        // And the label is still Safe-mode-only, so this assertion is about the sentence's content
        // rather than about it having quietly returned to every approval panel.
        #expect(!copy.lines.contains { $0.hasPrefix("Data leaves device") })
    }
}
