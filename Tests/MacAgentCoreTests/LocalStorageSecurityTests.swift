import Foundation
import Testing
@testable import MacAgentCore

@Suite(.serialized)
struct LocalStorageSecurityTests {
    @Test
    func routineStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive routine \(UUID().uuidString)"
        let store = RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: testEncryption()
        )

        try store.save(
            StoredRoutine(
                name: marker,
                steps: [AgentStep(id: "open", operation: .openApp, description: marker, appName: "Safari")]
            )
        )

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.routine(named: marker).name == marker)
    }

    @Test
    func workspaceStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive workspace \(UUID().uuidString)"
        let store = WorkspaceStore(
            fileURL: root.appendingPathComponent("workspaces.json"),
            encryption: testEncryption()
        )

        try store.save(StoredWorkspace(name: marker, apps: ["Safari"], urls: ["https://example.com/\(marker)"]))

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.workspace(named: marker).name == marker)
    }

    @Test
    func legacyWorkspaceJSONMissingTheTeamTypeKeyDecodesWithASoloDefault() throws {
        // Hand-written, not encoded from the current StoredWorkspace struct — a fixture built by
        // encoding the current struct would already include "teamType" and couldn't catch a
        // missing-key regression on real pre-existing user files.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy-workspaces-no-team-type.json")
        let legacyJSON = """
        {
            "research": {
                "name": "Research",
                "apps": ["Safari"],
                "urls": ["https://example.com/reference"]
            }
        }
        """
        try Data(legacyJSON.utf8).write(to: url, options: .atomic)
        let store = WorkspaceStore(fileURL: url, encryption: testEncryption())

        let workspace = try store.workspace(named: "Research")

        #expect(workspace.teamType == nil)
        #expect(workspace.effectiveTeamType == .solo)
        try expectEncryptedFile(url, hiding: "Research")
    }

    @Test
    func clipboardHistoryStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive clipboard \(UUID().uuidString)"
        let store = ClipboardHistoryStore(
            fileURL: root.appendingPathComponent("clipboard-history.json"),
            encryption: testEncryption()
        )

        try store.record(marker, copiedAt: .fixture)

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.loadAll(now: .fixture).first?.text == marker)
    }

    @Test
    func clipboardSettingsStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
            encryption: testEncryption()
        )

        try store.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: false))

        let raw = try Data(contentsOf: store.fileURL)
        #expect(raw.starts(with: LocalStorageEncryption.fileHeader))
        #expect(raw.range(of: Data("\"noticeDismissed\"".utf8)) == nil)
        #expect(try store.load() == ClipboardHistorySettings(noticeDismissed: true, isEnabled: false))
    }

    @Test
    func snippetStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive snippet \(UUID().uuidString)"
        let store = SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: testEncryption()
        )

        try store.save(StoredSnippet(trigger: ";secret", expansion: marker, updatedAt: .fixture))

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.snippet(matchingTrigger: ";secret").expansion == marker)
    }

    @Test
    func recentArtifactStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive-artifact-\(UUID().uuidString).md"
        let artifact = root.appendingPathComponent(marker)
        try Data("artifact".utf8).write(to: artifact, options: .atomic)
        let store = RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: testEncryption()
        )

        try store.record(path: artifact.path, recordedAt: .fixture)

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.loadAll(now: .fixture).first?.path == artifact.path)
    }

    @Test
    func shortcutRunHistoryStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive shortcut \(UUID().uuidString)"
        let store = ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
            encryption: testEncryption()
        )

        try store.recordSuccess(shortcutName: marker, at: .fixture)

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.hasCleanObservedSuccess(for: marker))
    }

    @Test
    func taskHistoryStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive task \(UUID().uuidString)"
        let store = TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: testEncryption()
        )
        let record = CompletedTaskRecord(
            command: marker,
            startedAt: .fixture,
            completedAt: Date(timeInterval: 14, since: .fixture),
            outcomeStatus: .completed
        )

        try store.record(record)

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.loadAll() == [record])
    }

    @Test
    func legacyPlaintextFilesMigrateToEncryptedFilesAfterSuccessfulLoad() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()

        try assertRoutineMigration(root: root, encryption: encryption)
        try assertWorkspaceMigration(root: root, encryption: encryption)
        try assertClipboardHistoryMigration(root: root, encryption: encryption)
        try assertClipboardSettingsMigration(root: root, encryption: encryption)
        try assertSnippetMigration(root: root, encryption: encryption)
        try assertRecentArtifactMigration(root: root, encryption: encryption)
        try assertShortcutHistoryMigration(root: root, encryption: encryption)
        try assertTaskHistoryMigration(root: root, encryption: encryption)
    }

    @Test
    func keyManagerGeneratesStoresAndReusesSymmetricKeyData() throws {
        let generated = Data(repeating: 0xAB, count: 32)
        let replacement = Data(repeating: 0xCD, count: 32)
        let secrets = FakeKeychainSecretStore()
        let first = LocalStorageEncryptionKeyManager(
            secretStore: secrets,
            service: "test.local-storage",
            account: "key",
            generateKeyData: { generated }
        )

        #expect(try first.keyData() == generated)
        #expect(secrets.savedData == generated)

        let second = LocalStorageEncryptionKeyManager(
            secretStore: secrets,
            service: "test.local-storage",
            account: "key",
            generateKeyData: { replacement }
        )
        #expect(try second.keyData() == generated)
    }

    @Test
    func keyManagerRejectsInvalidStoredKeyLength() throws {
        let secrets = FakeKeychainSecretStore()
        try secrets.save(Data(repeating: 0x01, count: 16), service: "test.local-storage", account: "key")
        let manager = LocalStorageEncryptionKeyManager(
            secretStore: secrets,
            service: "test.local-storage",
            account: "key"
        )

        #expect(throws: LocalStorageEncryptionError.invalidKeyLength(16)) {
            try manager.keyData()
        }
    }

    @Test
    func encryptionCachesKeychainKeyAfterFirstSuccessfulRetrieval() throws {
        let secrets = CountingKeychainSecretStore(existingData: Data(repeating: 0x7A, count: 32))
        let manager = LocalStorageEncryptionKeyManager(
            secretStore: secrets,
            service: "test.local-storage",
            account: "key"
        )
        let encryption = LocalStorageEncryption(keyManager: manager)

        let first = try encryption.encode(["first": "value"])
        #expect(try encryption.decode([String: String].self, from: first).value["first"] == "value")

        let second = try encryption.encode(["second": "value"])
        #expect(try encryption.decode([String: String].self, from: second).value["second"] == "value")

        _ = try encryption.encode(["third": "value"])

        #expect(secrets.dataCallCount == 1)
        #expect(secrets.saveCallCount == 0)
    }

    @Test
    func localDataDeletionServiceRemovesAllStoreFilesAndToleratesMissingFiles() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let fileURLs = try createAllLocalStoreFiles(root: root, encryption: encryption)
        let service = LocalDataDeletionService(fileURLs: fileURLs)

        let result = try service.deleteAllLocalData()

        #expect(result == LocalDataDeletionResult(deletedFileCount: 8, missingFileCount: 0))
        for fileURL in fileURLs {
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }

        let secondResult = try service.deleteAllLocalData()
        #expect(secondResult == LocalDataDeletionResult(deletedFileCount: 0, missingFileCount: 8))
    }
}

private func createAllLocalStoreFiles(root: URL, encryption: LocalStorageEncryption) throws -> [URL] {
    let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: encryption)
    let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: encryption)
    let clipboardStore = ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json"), encryption: encryption)
    let clipboardSettingsStore = ClipboardHistorySettingsStore(
        fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
        encryption: encryption
    )
    let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: encryption)
    let recentArtifactStore = RecentArtifactStore(
        fileURL: root.appendingPathComponent("recent-artifacts.json"),
        encryption: encryption
    )
    let shortcutRunHistoryStore = ShortcutRunHistoryStore(
        fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
        encryption: encryption
    )
    let taskHistoryStore = TaskHistoryStore(
        fileURL: root.appendingPathComponent("task-history.json"),
        encryption: encryption
    )

    try routineStore.save(
        StoredRoutine(
            name: "Delete Me",
            steps: [AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")]
        )
    )
    try workspaceStore.save(StoredWorkspace(name: "Delete Workspace", apps: ["Safari"], urls: []))
    try clipboardStore.record("delete clipboard", copiedAt: .fixture)
    try clipboardSettingsStore.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
    try snippetStore.save(StoredSnippet(trigger: ";delete", expansion: "delete snippet", updatedAt: .fixture))

    let artifact = root.appendingPathComponent("delete-artifact.md")
    try Data("artifact".utf8).write(to: artifact, options: .atomic)
    try recentArtifactStore.record(path: artifact.path, recordedAt: .fixture)
    try shortcutRunHistoryStore.recordSuccess(shortcutName: "Delete Shortcut", at: .fixture)
    try taskHistoryStore.record(
        CompletedTaskRecord(
            command: "delete task",
            startedAt: .fixture,
            completedAt: Date(timeInterval: 3, since: .fixture),
            outcomeStatus: .completed
        )
    )

    return [
        routineStore.fileURL,
        workspaceStore.fileURL,
        clipboardStore.fileURL,
        clipboardSettingsStore.fileURL,
        snippetStore.fileURL,
        recentArtifactStore.fileURL,
        shortcutRunHistoryStore.fileURL,
        taskHistoryStore.fileURL
    ]
}

private func assertRoutineMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy routine \(UUID().uuidString)"
    let url = root.appendingPathComponent("legacy-routines.json")
    let legacy = [
        normalized(marker): StoredRoutine(
            name: marker,
            steps: [AgentStep(id: "open", operation: .openApp, description: marker, appName: "Safari")]
        )
    ]
    try JSONEncoder.prettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = RoutineStore(fileURL: url, encryption: encryption)

    #expect(try store.routine(named: marker).name == marker)
    try expectEncryptedFile(url, hiding: marker)
}

private func assertWorkspaceMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy workspace \(UUID().uuidString)"
    let url = root.appendingPathComponent("legacy-workspaces.json")
    let legacy = [
        normalized(marker): StoredWorkspace(name: marker, apps: ["Safari"], urls: ["https://example.com/\(marker)"])
    ]
    try JSONEncoder.prettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = WorkspaceStore(fileURL: url, encryption: encryption)

    #expect(try store.workspace(named: marker).name == marker)
    try expectEncryptedFile(url, hiding: marker)
}

private func assertClipboardHistoryMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy clipboard \(UUID().uuidString)"
    let url = root.appendingPathComponent("legacy-clipboard-history.json")
    let legacy = [ClipboardHistoryItem(copiedAt: .fixture, text: marker)]
    try JSONEncoder.iso8601PrettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = ClipboardHistoryStore(fileURL: url, encryption: encryption)

    #expect(try store.loadAll(now: .fixture).first?.text == marker)
    try expectEncryptedFile(url, hiding: marker)
}

private func assertClipboardSettingsMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let url = root.appendingPathComponent("legacy-clipboard-settings.json")
    let legacy = ClipboardHistorySettings(noticeDismissed: true, isEnabled: false)
    try JSONEncoder.iso8601PrettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = ClipboardHistorySettingsStore(fileURL: url, encryption: encryption)

    #expect(try store.load() == legacy)
    let raw = try Data(contentsOf: url)
    #expect(raw.starts(with: LocalStorageEncryption.fileHeader))
    #expect(raw.range(of: Data("\"noticeDismissed\"".utf8)) == nil)
}

private func assertSnippetMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy snippet \(UUID().uuidString)"
    let url = root.appendingPathComponent("legacy-snippets.json")
    let legacy = [
        ";legacy": StoredSnippet(trigger: ";legacy", expansion: marker, updatedAt: .fixture)
    ]
    try JSONEncoder.iso8601PrettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = SnippetStore(fileURL: url, encryption: encryption)

    #expect(try store.snippet(matchingTrigger: ";legacy").expansion == marker)
    try expectEncryptedFile(url, hiding: marker)
}

private func assertRecentArtifactMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy-artifact-\(UUID().uuidString).md"
    let artifact = root.appendingPathComponent(marker)
    try Data("artifact".utf8).write(to: artifact, options: .atomic)
    let url = root.appendingPathComponent("legacy-recent-artifacts.json")
    let legacy = [
        RecentArtifact(path: artifact.path, title: marker, recordedAt: .fixture)
    ]
    try JSONEncoder.iso8601PrettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = RecentArtifactStore(fileURL: url, encryption: encryption)

    #expect(try store.loadAll(now: .fixture).first?.path == artifact.path)
    try expectEncryptedFile(url, hiding: marker)
}

private func assertShortcutHistoryMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy shortcut \(UUID().uuidString)"
    let url = root.appendingPathComponent("legacy-shortcuts-run-history.json")
    let legacy = [
        normalized(marker): ShortcutRunHistoryRecord(
            shortcutName: marker,
            lastSuccessfulInvocationAt: .fixture
        )
    ]
    try JSONEncoder.iso8601PrettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = ShortcutRunHistoryStore(fileURL: url, encryption: encryption)

    #expect(try store.hasCleanObservedSuccess(for: marker))
    try expectEncryptedFile(url, hiding: marker)
}

private func assertTaskHistoryMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy task \(UUID().uuidString)"
    let url = root.appendingPathComponent("legacy-task-history.json")
    let legacy = [
        CompletedTaskRecord(
            command: marker,
            startedAt: .fixture,
            completedAt: Date(timeInterval: 9, since: .fixture),
            outcomeStatus: .failed
        )
    ]
    try JSONEncoder.iso8601PrettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = TaskHistoryStore(fileURL: url, encryption: encryption)

    #expect(try store.loadAll() == legacy)
    try expectEncryptedFile(url, hiding: marker)
}

private func testEncryption() -> LocalStorageEncryption {
    LocalStorageEncryption(
        keyManager: FixedLocalStorageKeyManager(bytes: Data(repeating: 0x42, count: 32))
    )
}

private func expectEncryptedFile(_ url: URL, hiding plaintext: String) throws {
    let raw = try Data(contentsOf: url)
    #expect(raw.starts(with: LocalStorageEncryption.fileHeader))
    #expect(raw.range(of: Data(plaintext.utf8)) == nil)
}

private struct FixedLocalStorageKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private final class FakeKeychainSecretStore: KeychainSecretStoring, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private(set) var savedData: Data?

    func data(service: String, account: String) throws -> Data? {
        values[key(service: service, account: account)]
    }

    func save(_ data: Data, service: String, account: String) throws {
        values[key(service: service, account: account)] = data
        savedData = data
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: key(service: service, account: account))
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}

private final class CountingKeychainSecretStore: KeychainSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    private var dataCalls = 0
    private var saveCalls = 0

    init(existingData: Data) {
        values = ["test.local-storage\u{0}key": existingData]
    }

    var dataCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dataCalls
    }

    var saveCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCalls
    }

    func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        dataCalls += 1
        return values[key(service: service, account: account)]
    }

    func save(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        saveCalls += 1
        values[key(service: service, account: account)] = data
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key(service: service, account: account))
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}

private extension JSONEncoder {
    static var prettySortedForTest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var iso8601PrettySortedForTest: JSONEncoder {
        let encoder = prettySortedForTest
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private func normalized(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}
