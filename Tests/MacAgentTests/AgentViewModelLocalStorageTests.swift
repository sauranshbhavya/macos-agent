import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

@Suite
@MainActor
struct AgentViewModelLocalStorageTests {
    @Test
    func missingLocalStoreFilesRemainSilentFirstRunState() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x42))

        viewModel.refreshSavedItems()
        viewModel.refreshTaskHistory()
        viewModel.refreshClipboardHistoryNotice()

        #expect(viewModel.savedRoutines.isEmpty)
        #expect(viewModel.savedWorkspaces.isEmpty)
        #expect(viewModel.taskHistoryRecords.isEmpty)
        #expect(viewModel.clipboardHistoryEnabled)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.localStorageNotice == nil)
    }

    @Test
    func savedItemsDecryptFailureSurfacesVisibleErrorInsteadOfSilentEmptyState() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineURL = root.appendingPathComponent("routines.json")
        let workspaceURL = root.appendingPathComponent("workspaces.json")
        try RoutineStore(fileURL: routineURL, encryption: testEncryption(byte: 0x42)).save(
            StoredRoutine(
                name: "Encrypted Morning",
                steps: [
                    AgentStep(
                        id: "open",
                        operation: .openApp,
                        description: "Open Safari.",
                        appName: "Safari"
                    )
                ]
            )
        )
        try WorkspaceStore(fileURL: workspaceURL, encryption: testEncryption(byte: 0x42)).save(
            StoredWorkspace(name: "Encrypted Research", apps: ["Safari"], urls: ["https://example.com"])
        )
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshSavedItems()

        let message = try #require(viewModel.localStorageNotice)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("A local data file exists but could not be decrypted or decoded"))
        #expect(message.contains("saved routines"))
        #expect(message.contains("saved workspaces"))
        #expect(viewModel.savedRoutines.isEmpty)
        #expect(viewModel.savedWorkspaces.isEmpty)
    }

    @Test
    func clipboardSettingsDecryptFailureSurfacesVisibleError() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("clipboard-history-settings.json")
        try ClipboardHistorySettingsStore(fileURL: settingsURL, encryption: testEncryption(byte: 0x42))
            .save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshClipboardHistoryNotice()

        let message = try #require(viewModel.localStorageNotice)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("clipboard history settings"))
    }

    @Test
    func taskHistoryDecryptFailureSurfacesVisibleErrorInsteadOfSilentEmptyState() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskHistoryURL = root.appendingPathComponent("task-history.json")
        try TaskHistoryStore(fileURL: taskHistoryURL, encryption: testEncryption(byte: 0x42))
            .record(
                CompletedTaskRecord(
                    command: "Encrypted task",
                    startedAt: .fixture,
                    completedAt: Date(timeInterval: 5, since: .fixture),
                    outcomeStatus: .completed
                )
            )
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshTaskHistory()

        let message = try #require(viewModel.localStorageNotice)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("task history"))
        #expect(viewModel.taskHistoryRecords.isEmpty)
    }

    /// The shipped bug this branch fixes: `refreshSavedItems()` runs after every successful task,
    /// so a corrupt store unrelated to that task used to overwrite `errorMessage` and make the
    /// widget render `.failure` instead of the real result.
    @Test
    func corruptStoreDoesNotMakeASuccessfulTaskLookLikeAFailure() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredRoutine(name: "Unreadable", steps: [
            AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
        ]))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.command = "= 1 + 1"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // The task itself succeeded and its result is intact...
        #expect(viewModel.finalSummary.contains("2"))
        #expect(viewModel.errorMessage == nil)
        // ...while the unrelated storage problem is reported on its own channel.
        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.contains("saved routines"))
    }

    @Test
    func silentlyReadStoresReportCorruptionThatWouldOtherwiseBeInvisible() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredSnippet(trigger: ";sig", expansion: "Best,\nSonny"))
        // `record` no-ops unless the artifact really exists on disk, so create it first —
        // otherwise nothing is written and there is no corrupt store to detect.
        let artifactURL = root.appendingPathComponent("note.md")
        try Data("note".utf8).write(to: artifactURL)
        try RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: testEncryption(byte: 0x42)
        ).record(path: artifactURL.path, recordedAt: .fixture)
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshSavedItems()

        // Snippets and recent artifacts are otherwise only read through `try?` paths, so without
        // this probe a corrupt file just silently stops those features working.
        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.contains("snippets"))
        #expect(notice.contains("recent artifacts"))
    }
}

@MainActor
private func makeViewModel(root: URL, encryption: LocalStorageEncryption) throws -> AgentViewModel {
    let suiteName = "AgentViewModelLocalStorageTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: encryption),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: encryption),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: encryption),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: encryption
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
            reader: FakePasteboardReader(),
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
}

private func testEncryption(byte: UInt8) -> LocalStorageEncryption {
    LocalStorageEncryption(
        keyManager: FixedLocalStorageKeyManager(bytes: Data(repeating: byte, count: 32))
    )
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

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
