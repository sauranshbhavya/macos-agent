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

    /// The pin that was missing when the banner started repeating itself (PR #41 cycle-3, R4).
    ///
    /// Every other assertion on this banner uses `contains`, which passes whether the explanation
    /// appears once or twice — so when SONNY-30 gave store load errors the same sentence the headline
    /// hardcoded, nothing went red and the per-source detail quietly degraded into a repeat of the
    /// line above it. Counting the occurrence is what `contains` cannot do.
    ///
    /// Asserted alongside the distinguishing content rather than instead of it: a banner that dropped
    /// the explanation entirely would also count one, and that would be a worse notice, not a better
    /// one.
    ///
    /// **One** corrupt store, deliberately. The duplication was headline-against-detail, so it is
    /// only visible at one affected store — with two, the explanation legitimately appears twice,
    /// once per store, and a count assertion would be pinning the store count instead of the defect.
    @Test
    func theLoadFailureBannerExplainsItselfOnceAndStillNamesTheAffectedStore() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try RoutineStore(
            fileURL: root.appendingPathComponent("routines.json"),
            encryption: testEncryption(byte: 0x42)
        ).save(StoredRoutine(name: "Unreadable", steps: [
            AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
        ]))
        let viewModel = try makeViewModel(root: root, encryption: testEncryption(byte: 0x99))

        viewModel.refreshSavedItems()

        let notice = try #require(viewModel.localStorageNotice)
        let explanation = "A local data file exists but could not be decrypted or decoded."
        #expect(notice.components(separatedBy: explanation).count - 1 == 1)
        #expect(notice == "Sonny could not load encrypted local data. saved routines: \(explanation)")
    }

    // MARK: - Per-task deletion (SONNY-116)

    @Test
    func deletingATaskRemovesItsHistoryRowAndItsScreenRecordTogether() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let doomed = try #require(viewModel.taskHistoryRecords.first { $0.command == "reply in Discord" })

        viewModel.deleteTask(doomed)

        #expect(viewModel.errorMessage == nil)
        // Published state agrees with the file: the row is gone from both.
        #expect(!viewModel.taskHistoryRecords.contains { $0.id == doomed.id })
        #expect(try fixture.history.loadAll().map(\.command) == ["unrelated"])
        // And the screen record went with it.
        #expect(try fixture.journal.record(withID: "session-1") == nil)
        // The unrelated task's own session is untouched — the delete is per-task, not a wipe.
        #expect(try fixture.journal.record(withID: "session-2") != nil)
    }

    /// **The ordering test the ticket asks for, and the reason it exists.** Dependents are deleted
    /// before the row because the row is the only thing that makes them reachable through the
    /// product. Forcing the row's delete to fail proves the order rather than commenting it: the
    /// screen record is already gone, and the row survives carrying a link that now resolves to
    /// nothing — the designed dangling state, and a state the user can retry out of.
    ///
    /// If a later refactor swaps the two writes, this test fails: the journal would still hold the
    /// session while the row had gone, which is the orphan the founder named as the real defect.
    @Test(.requiresUnprivilegedProcess)
    func whenTheRowDeleteFailsTheScreenRecordIsAlreadyGoneAndTheRowSurvives() throws {
        let root = try makeDirectory()
        let historyRoot = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyRoot.path)
            try? FileManager.default.removeItem(at: root)
        }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption, historyRoot: historyRoot)
        let viewModel = try makeViewModel(root: root, encryption: encryption, taskHistoryRoot: historyRoot)
        viewModel.refreshTaskHistory()
        let doomed = try #require(viewModel.taskHistoryRecords.first { $0.command == "reply in Discord" })
        // Read-only directory: task history still reads, but its rewrite cannot land. The journal
        // sits elsewhere and stays writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: historyRoot.path)

        viewModel.deleteTask(doomed)

        // The dependent went first and is gone.
        #expect(try fixture.journal.record(withID: "session-1") == nil)
        // The row survived, still carrying its now-unresolvable link.
        let survivingRow = try #require(try fixture.history.loadAll().first { $0.id == doomed.id })
        #expect(survivingRow.visionSessionID == "session-1")
        #expect(survivingRow.command == "reply in Discord")
        // A delete is a write, so the failure gets write wording and never the load-failure banner.
        let message = try #require(viewModel.errorMessage)
        #expect(message.hasPrefix("Could not delete this task: "))
        #expect(!message.contains("decrypted or decoded"))
        #expect(viewModel.localStorageNotice == nil)
    }

    @Test
    func deletingOnlyTheScreenRecordLeavesTheRowAndItsLinkInPlace() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let target = try #require(viewModel.taskHistoryRecords.first { $0.command == "reply in Discord" })

        viewModel.deleteScreenRecord(for: target)

        #expect(viewModel.errorMessage == nil)
        #expect(try fixture.journal.record(withID: "session-1") == nil)
        // The row is still there, and it keeps its link — deliberately, so a deleted screen record
        // and one that aged out look the same.
        let row = try #require(try fixture.history.loadAll().first { $0.id == target.id })
        #expect(row.visionSessionID == "session-1")
        #expect(try fixture.history.loadAll().count == 2)
    }

    @Test
    func deletingATaskThatRanNoScreenSessionRemovesJustTheRow() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let plainTask = try #require(viewModel.taskHistoryRecords.first { $0.command == "unrelated" })
        #expect(plainTask.visionSessionID == nil)

        viewModel.deleteTask(plainTask)

        #expect(viewModel.errorMessage == nil)
        #expect(try fixture.history.loadAll().map(\.command) == ["reply in Discord"])
        // Nothing reached the journal, so the other task's session is still there.
        #expect(try fixture.journal.record(withID: "session-1") != nil)
    }

    @Test
    func deletingATaskThatIsAlreadyGoneIsSilent() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption(byte: 0x42)
        let fixture = try seedLinkedTask(root: root, encryption: encryption)
        let viewModel = try makeViewModel(root: root, encryption: encryption)
        viewModel.refreshTaskHistory()
        let target = try #require(viewModel.taskHistoryRecords.first { $0.command == "unrelated" })

        viewModel.deleteTask(target)
        viewModel.deleteTask(target)

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.localStorageNotice == nil)
        #expect(try fixture.history.loadAll().map(\.command) == ["reply in Discord"])
    }

    private struct LinkedTaskFixture {
        var history: TaskHistoryStore
        var journal: VisionSessionJournalStore
    }

    /// Two tasks: one that ran a screen-control session and one that did not, plus a second session
    /// belonging to nothing under test, so a delete that reached too far is visible.
    private func seedLinkedTask(
        root: URL,
        encryption: LocalStorageEncryption,
        historyRoot: URL? = nil
    ) throws -> LinkedTaskFixture {
        let history = TaskHistoryStore(
            fileURL: (historyRoot ?? root).appendingPathComponent("task-history.json"),
            encryption: encryption
        )
        let journal = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for id in ["session-1", "session-2"] {
            try journal.save(
                VisionSessionRecord(
                    id: id,
                    goal: "goal \(id)",
                    appDisplayName: "Discord",
                    startedAt: base
                )
            )
        }
        try history.record(
            CompletedTaskRecord(
                command: "reply in Discord",
                startedAt: base,
                completedAt: base.addingTimeInterval(30),
                outcomeStatus: .completed,
                visionSessionID: "session-1"
            )
        )
        try history.record(
            CompletedTaskRecord(
                command: "unrelated",
                startedAt: base.addingTimeInterval(100),
                completedAt: base.addingTimeInterval(130),
                outcomeStatus: .completed
            )
        )
        return LinkedTaskFixture(history: history, journal: journal)
    }
}

@MainActor
/// `taskHistoryRoot` exists for the delete-ordering test, which needs task history in a directory
/// it can make read-only while the journal stays writable. Everything else defaults to `root`.
///
/// The vision journal is injected rather than defaulted for the reason the hermetic-seams comment
/// below already gives: an un-injected `VisionSessionJournalStore()` resolves to the real
/// `~/Library/Application Support/Sonny/vision-sessions.json`. No test in this file read it before
/// SONNY-116, so nothing was wrong yet — which is exactly the shape of the bug that comment
/// describes, a fixture that is hermetic by accident rather than by construction.
private func makeViewModel(
    root: URL,
    encryption: LocalStorageEncryption,
    taskHistoryRoot: URL? = nil
) throws -> AgentViewModel {
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
            fileURL: (taskHistoryRoot ?? root).appendingPathComponent("task-history.json"),
            encryption: encryption
        ),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
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
