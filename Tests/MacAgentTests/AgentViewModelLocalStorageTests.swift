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
        viewModel.refreshClipboardHistoryNotice()

        #expect(viewModel.savedRoutines.isEmpty)
        #expect(viewModel.savedWorkspaces.isEmpty)
        #expect(viewModel.clipboardHistoryEnabled)
        #expect(viewModel.showClipboardHistoryNotice)
        #expect(viewModel.errorMessage == nil)
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

        let message = try #require(viewModel.errorMessage)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("A local data file exists but could not be decrypted or decoded"))
        #expect(message.contains("saved routines"))
        #expect(message.contains("saved workspaces"))
        #expect(viewModel.savedRoutines.isEmpty)
        #expect(viewModel.savedWorkspaces.isEmpty)
    }

    @Test
    func clipboardSettingsDecryptFailureSurfacesVisibleErrorAndDoesNotDefaultToEnabledNoticeState() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("clipboard-history-settings.json")
        try ClipboardHistorySettingsStore(fileURL: settingsURL, encryption: testEncryption(byte: 0x42))
            .save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshClipboardHistoryNotice()

        let message = try #require(viewModel.errorMessage)
        #expect(message.contains("Sonny could not load encrypted local data"))
        #expect(message.contains("clipboard history settings"))
        #expect(!viewModel.showClipboardHistoryNotice)
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
