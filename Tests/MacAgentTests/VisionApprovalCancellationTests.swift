import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

// SONNY-80, PR #42 review finding F3 — the vision-approval continuation leak.
//
// `awaitVisionApproval` parks a continuation while a vision-delegated coordinator action waits on
// the widget's approval card. `start()` cancels `currentTask` on every new command, so with a bare
// `withCheckedContinuation` that continuation was never resumed: the vision run stayed suspended
// forever and `visionApprovalContinuation` stayed armed. The damage lands on the *next* run —
// `approvePendingRun` checks the vision continuation first, so the next approval click resumed the
// stale one with the new request's tier and the click the user actually made was swallowed.
//
// Both halves are pinned below, because the leak is only observable through the second one.

@Suite
@MainActor
struct VisionApprovalCancellationTests {
    @Test
    func newCommandDuringAPendingVisionApprovalReleasesTheContinuationAndLeavesTheNextApprovalIntact() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let viewModel = fixture.viewModel

        // `delegateToCoordinator` is the real entry point the vision loop calls, parked here on the
        // same tier-2 approval any `snippet save` raises. Only the *owner* of the task is the
        // test's: in the app this runs inside `currentTask`, and `start()` cancels that task —
        // exactly what `delegationTask.cancel()` below stands in for. The continuation mechanics
        // under test are identical either way.
        let delegation = DelegationOutcome()
        let delegationTask = Task { @MainActor in
            do {
                delegation.value = .returned(try await viewModel.delegateToCoordinator(
                    VisionCoordinatorRequest(
                        instruction: "snippet save ;vision-delegated = Alpha",
                        rationale: "The screen offers no way to do this."
                    )
                ))
            } catch {
                delegation.value = .threw(error)
            }
        }
        try await waitUntil("the vision-delegated approval to be raised") {
            viewModel.approvalRequest != nil
        }
        #expect(delegation.value == nil)

        delegationTask.cancel()

        // Half one — the cleanup. The parked continuation is resumed rather than leaked, and the
        // card it raised goes with it. Remove the cancellation handler and this is the wait that
        // times out, because nothing resumes the continuation at all.
        try await waitUntil("the parked vision approval continuation to be released") {
            delegation.value != nil
        }
        #expect(delegation.value?.isCancellation == true)
        #expect(viewModel.approvalRequest == nil)

        // Half two — the next run's approval has to land on itself, not on the corpse of the
        // cancelled vision run.
        viewModel.command = "snippet save ;fresh-command = Beta"
        viewModel.start()
        try await waitUntilIdle(viewModel)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.approvalRequest != nil)

        // `start()` while awaiting approval *is* the approval click — the same call the widget's
        // Approve control makes.
        viewModel.start()
        try await waitUntilIdle(viewModel)

        let saved = try fixture.snippetStore.loadAll()
        #expect(saved[";fresh-command"]?.expansion == "Beta")
        // The other half of the cross-wire: a swallowed click also resumed the stale delegation,
        // which would then have executed the *previous* command's prepared plan.
        #expect(saved[";vision-delegated"] == nil)
        #expect(viewModel.taskHistoryRecords.map(\.command) == ["snippet save ;fresh-command = Beta"])
        #expect(viewModel.taskHistoryRecords.last?.outcomeStatus == .completed)
        #expect(viewModel.approvalRequest == nil)
    }
}

// MARK: - Test doubles and fixture

/// A mailbox for the delegation's terminal outcome, polled instead of `await`ed on purpose: with
/// the continuation leaked, `await delegationTask.value` never returns and the test would hang
/// rather than fail. Every wait in this file is bounded for the same reason.
@MainActor
private final class DelegationOutcome {
    enum Value {
        case returned(VisionCoordinatorResult)
        case threw(any Error)

        var isCancellation: Bool {
            guard case .threw(let error) = self else {
                return false
            }
            return error is CancellationError
        }
    }

    var value: Value?
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() {
        if Date() > deadline {
            Issue.record("Timed out waiting for \(description).")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private func waitUntilIdle(_ viewModel: AgentViewModel, timeout: TimeInterval = 2) async throws {
    try await waitUntil("the view model to become idle", timeout: timeout) { !viewModel.isRunning }
}

@MainActor
private func makeFixture(root: URL) throws -> (viewModel: AgentViewModel, snippetStore: SnippetStore) {
    let encryption = LocalStorageEncryption(
        keyManager: FixedLocalStorageKeyManager(bytes: Data(repeating: 0x5A, count: 32))
    )
    let snippetStore = SnippetStore(
        fileURL: root.appendingPathComponent("snippets.json"),
        encryption: encryption
    )
    let suiteName = "VisionApprovalCancellationTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    let viewModel = AgentViewModel(
        routineStore: RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: encryption
        ),
        workspaceStore: WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: encryption
        ),
        snippetStore: snippetStore,
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: encryption
        ),
        shortcutCatalog: EmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). This test executes a
        // real plan, and hermeticity has to be structural rather than a property of the one command
        // it happens to run — a fixture that grew a URL step is exactly how the suite once opened
        // real pages in the user's browser.
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
            fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
            encryption: encryption
        ),
        taskHistoryStore: TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: encryption
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
            encryption: encryption
        ),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: SilentPasteboardReader(),
            store: ClipboardHistoryStore(
                fileURL: root.appendingPathComponent("clipboard-history.json"),
                encryption: encryption
            ),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
                encryption: encryption
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
    return (viewModel, snippetStore)
}

private struct FixedLocalStorageKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class SilentPasteboardReader: PasteboardReading {
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
