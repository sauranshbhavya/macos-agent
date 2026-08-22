import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// Branch 10 checkpoint 1. Command Center gains its own permission/clarification/failure surface,
/// which was framed as a hard prerequisite for unattended scheduled runs: a scheduled routine has
/// nobody watching the widget, and at the time the system-notification fallback could not fire —
/// every post was gated on `isAnySonnySurfaceVisible`, permanently true once the widget became a
/// permanent overlay. **That gate is gone** (SONNY-56, the founder's rule of 2026-08-17: notify
/// when Sonny is not the app the user is working in), so nothing here should be read as saying a
/// notification cannot reach the user today. Kept in the past tense rather than deleted because it
/// is why the surface was built. Corrected 2026-08-21 by SONNY-189.
///
/// Two things are asserted here, and they pull in opposite directions on purpose:
/// the new surface must be reachable from a `.commandCenter`-origin task, *and* the floating
/// widget's existing behavior for those same three states must not change at all.
@Suite
@MainActor
struct CommandCenterAttentionSurfaceTests {
    /// The widget deliberately does **not** origin-gate permission/clarification/failure — it is
    /// the permanent, always-visible overlay, so for an unattended run it is the more reliable
    /// place for an approval, not the less. Adding a Command Center surface must not quietly turn
    /// that into duplicate-avoidance gating: `hasVisibleWidgetPanel` is the single source of truth
    /// for the widget's own panel and for its mic-hover-hint slot, and a second reader disagreeing
    /// with it already made the widget vanish at launch once. (That second reader used to be
    /// `FloatingWidgetWindowController`'s compositing decision, which is where the vanishing came
    /// from; the mode was superseded on 2026-07-21 and nothing composites anymore — SONNY-189.)
    @Test
    func widgetStillShowsAllThreeAttentionStatesForACommandCenterOriginTask() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        // The trigger already exists with different text, so the save is a destructive replace —
        // the approval the consequence rule still raises (a first-time save auto-runs).
        try SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
            .save(StoredSnippet(trigger: ";sig", expansion: "Old text"))

        viewModel.command = "snippet save ;sig = Best, Sonny"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // A real destructive approval, raised by a task this surface submitted.
        #expect(viewModel.activeTaskOrigin == .commandCenter)
        #expect(viewModel.approvalRequest != nil)
        #expect(viewModel.hasVisibleWidgetPanel)

        viewModel.cancelCurrentRun()
        viewModel.clarificationQuestion = "Which folder did you mean?"
        #expect(viewModel.hasVisibleWidgetPanel)

        viewModel.clarificationQuestion = nil
        viewModel.errorMessage = "Something failed."
        #expect(viewModel.hasVisibleWidgetPanel)
    }

    /// `retryLastCommand()` hardcoded `origin: .widget`, justified by a doc comment reading
    /// "Command Center has no retry control" — true until this checkpoint, false after it. Left
    /// alone, a retry pressed on Command Center's own failure row would tag the run `.widget`,
    /// which is exactly the origin confusion `TaskOrigin` exists to prevent.
    @Test
    func retryFromCommandCenterKeepsCommandCenterOrigin() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)

        viewModel.command = "= 1 + 1"
        viewModel.start(origin: .commandCenter)
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(viewModel.hasRetryableCommand)

        viewModel.retryLastCommand(origin: .commandCenter)
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.activeTaskOrigin == .commandCenter)
    }

    // The argument-less `retryLastCommand()` → `.widget` half is already covered by
    // `ProductShellTests.retryLastCommandTagsOriginAsWidgetRegardlessOfOriginalOrigin`, so it is
    // deliberately not repeated here.
}

@MainActor
private func makeViewModel(root: URL) throws -> AgentViewModel {
    let suiteName = "CommandCenterAttentionSurfaceTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json")
        ),
        shortcutCatalog: EmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). These tests execute
        // real plans; their commands touch no side-effect seam *today*, but that is a property of
        // the commands rather than of the fixture — this bug arrived exactly that way, when a
        // routine fixture gained a URL step. Injected so hermeticity is structural.
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json")
        ),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: FakePasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
}

private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class FakePasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacAgentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
