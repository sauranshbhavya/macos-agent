import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgentCore

/// A store file that will not decrypt, and the one mechanism that gets a user out of it (SONNY-239).
///
/// **The enumeration this ticket owed comes first.** The ticket said the read-before-write pattern
/// meant "almost certainly every local store, not just this one", and asked for that to be
/// established rather than assumed. `everyLocalStoreIsUnreadableWhenItsFileWasWrittenUnderAnotherKey`
/// walks `LocalStore.allCases` and proves it for all thirteen, and the switch inside `probe(_:at:)`
/// is exhaustive with no `default`, so a fourteenth store joins the population by failing to compile
/// rather than by being remembered.
///
/// **The failure is reproduced the way the founder's Mac produced it**, not with random bytes: each
/// file is written as a valid `SONNYENC1` blob under one key and read back under another. That is
/// what SONNY-240's fixtures did to `output-locations.json` and `resumable-tasks.json`, and it is
/// also what a Keychain item replaced by a restore or a migration would do to all thirteen at once.
/// Bytes that merely fail to parse would exercise the JSON half of `decode` and say nothing about
/// the decrypt half, which is the half that actually happened.
@Suite(.serialized)
struct LocalDataQuarantineTests {
    // MARK: - The gap, enumerated

    @Test
    func everyLocalStoreIsUnreadableWhenItsFileWasWrittenUnderAnotherKey() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for store in LocalStore.allCases {
            let probe = Self.probe(store, at: root)
            try Self.writeUnreadableFile(at: probe.fileURL)

            #expect(throws: LocalStorageEncryptionError.self, "\(store) read a file it should not have") {
                try probe.read()
            }
        }

        // The population, so a broken enumerator cannot pass this vacuously — and so the number
        // lives in exactly one assertion rather than in a test name that goes stale.
        #expect(LocalStore.allCases.count == 13)
    }

    /// The same walk, one step further: the mechanism clears every one of them.
    ///
    /// **This is the claim the fix rests on** — that recovery is one mechanism rather than thirteen.
    /// It operates on a file URL and knows nothing about what is in it, which is exactly why it can
    /// run at all: every door into a store loads before it acts, so a recovery written *inside* a
    /// store would be a recovery that cannot run on the file it exists for.
    @Test
    func movingTheFileAsideLetsEveryStoreReadAgainAndKeepsTheOriginalBytes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantine = LocalDataQuarantine()

        for store in LocalStore.allCases {
            let probe = Self.probe(store, at: root)
            let original = try Self.writeUnreadableFile(at: probe.fileURL)

            let setAside = try quarantine.moveAside(probe.fileURL)

            // Reads again, because there is no longer a file to fail on.
            try probe.read()
            #expect(!FileManager.default.fileExists(atPath: probe.fileURL.path), "\(store)")
            // And nothing was destroyed: byte-for-byte the file that would not open, which is the
            // whole of the founder's decision of 2026-08-23 (SONNY-253's key migration can make
            // these bytes readable again).
            #expect(try Data(contentsOf: setAside) == original, "\(store)")
        }
    }

    // MARK: - What the set-aside file is called

    @Test
    func theSetAsideNameKeepsTheOriginalInFullAndCarriesAUTCStamp() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("output-locations.json")
        try Data("bytes".utf8).write(to: fileURL, options: .atomic)

        // 2026-08-23T18:42:11Z, chosen so every field is two digits and a transposed format string
        // cannot pass by coincidence.
        let moment = Date(timeIntervalSince1970: 1_787_510_531)
        let setAside = try LocalDataQuarantine().moveAside(fileURL, at: moment)

        #expect(setAside.lastPathComponent == "output-locations.json.unreadable-20260823T184211Z")
        // Which store it came from is readable off the name alone — by a person in the Finder, and
        // by the wipe's own sweep, which matches on exactly this prefix.
        #expect(setAside.lastPathComponent.hasPrefix("output-locations.json" + LocalDataQuarantine.filenameSuffix))
        #expect(setAside.deletingLastPathComponent().path == fileURL.deletingLastPathComponent().path)
    }

    /// The stamp is whole seconds, and one press can move four files — the Task history row covers
    /// four stores. Without the counter the second move would land on the first one's name.
    @Test
    func twoFilesSetAsideInTheSameSecondDoNotOverwriteEachOther() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let moment = Date(timeIntervalSince1970: 1_787_510_531)
        let quarantine = LocalDataQuarantine()
        let fileURL = root.appendingPathComponent("task-history.json")

        try Data("first".utf8).write(to: fileURL, options: .atomic)
        let first = try quarantine.moveAside(fileURL, at: moment)
        try Data("second".utf8).write(to: fileURL, options: .atomic)
        let second = try quarantine.moveAside(fileURL, at: moment)

        #expect(first.lastPathComponent == "task-history.json.unreadable-20260823T184211Z")
        #expect(second.lastPathComponent == "task-history.json.unreadable-20260823T184211Z-2")
        #expect(try String(decoding: Data(contentsOf: first), as: UTF8.self) == "first")
        #expect(try String(decoding: Data(contentsOf: second), as: UTF8.self) == "second")
    }

    // MARK: - Moving a set of files

    @Test
    func movingASetAsideCountsWhatMovedAndWhatWasNotThere() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("snippets.json")
        let absent = root.appendingPathComponent("approved-apps.json")
        try Data("bytes".utf8).write(to: present, options: .atomic)

        let result = try LocalDataQuarantine().moveAsideAll([present, absent])

        #expect(result.movedFileURLs.count == 1)
        #expect(result.missingFileCount == 1)
        #expect(result.failedFilePaths.isEmpty)
    }

    /// **A move that cannot happen is reported, never swallowed** — the same rule
    /// `deleteAllLocalData` follows, and it matters more here: the caller writes "the file Sonny
    /// could not read is still on your Mac" off this result, and a silent failure would make that
    /// sentence accidentally true while the row it describes was never cleared.
    ///
    /// Locking the directory is what blocks a rename, so this needs the unprivileged gate.
    @Test(.requiresUnprivilegedProcess)
    func aMoveThatCannotHappenIsReportedRatherThanSwallowed() throws {
        let root = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let fileURL = root.appendingPathComponent("routines.json")
        try Data("bytes".utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        var thrown: LocalDataQuarantineError?
        do {
            _ = try LocalDataQuarantine().moveAsideAll([fileURL])
        } catch let error as LocalDataQuarantineError {
            thrown = error
        }

        let error = try #require(thrown)
        #expect(error.result.movedFileURLs.isEmpty)
        #expect(error.result.failedFilePaths == [fileURL.path])
        #expect(try #require(error.errorDescription).contains("routines.json"))
        // The premise: the file really is still there, which is what makes the report true.
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - The privacy wipe reaches what this leaves behind

    /// **The one place destruction is asked for, and it has to reach these files** (SONNY-239).
    ///
    /// `LocalDataQuarantine` deliberately leaves the user's bytes on disk under another name. Those
    /// bytes are theirs — folder paths, commands, whole routines — so a Settings wipe that deleted
    /// only the thirteen exact filenames would report "Deleted 13 local data files" while leaving
    /// every set-aside file untouched. Sonny not being able to read them is not the same as their
    /// holding nothing.
    @Test
    func theWholeDataWipeDeletesTheFilesTheQuarantineLeftBehind() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputLocations = root.appendingPathComponent("output-locations.json")
        let taskHistory = root.appendingPathComponent("task-history.json")
        let quarantine = LocalDataQuarantine()

        // One store cleared twice, so the sweep is shown to take every set-aside file rather than
        // the newest, and one store still holding its own readable file.
        try Data("first".utf8).write(to: outputLocations, options: .atomic)
        _ = try quarantine.moveAside(outputLocations, at: Date(timeIntervalSince1970: 1_787_510_531))
        try Data("second".utf8).write(to: outputLocations, options: .atomic)
        _ = try quarantine.moveAside(outputLocations, at: Date(timeIntervalSince1970: 1_787_596_931))
        try Data("live".utf8).write(to: taskHistory, options: .atomic)

        let result = try LocalDataDeletionService(fileURLs: [outputLocations, taskHistory])
            .deleteAllLocalData()

        // Two set aside plus the one live file.
        #expect(result.deletedFileCount == 3)
        // The store whose own file had already been moved aside counts as missing, which it is.
        #expect(result.missingFileCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// **A set-aside file the wipe cannot delete is reported by name, not silently left behind.**
    ///
    /// The sibling loop's catch branch is a near-copy of the one below it, which is tested — but it
    /// is the branch that decides whether a privacy wipe tells the truth about what survived it, and
    /// "near-copy of a tested branch" is how an untested one gets written off (PR #110 review).
    ///
    /// Locking the directory is what blocks the unlink, so this needs the unprivileged gate.
    @Test(.requiresUnprivilegedProcess)
    func aSetAsideFileTheWipeCannotDeleteIsNamedInWhatSurvived() throws {
        let root = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let fileURL = root.appendingPathComponent("output-locations.json")
        try Data("bytes".utf8).write(to: fileURL, options: .atomic)
        let setAside = try LocalDataQuarantine().moveAside(fileURL, at: Date(timeIntervalSince1970: 1_787_510_531))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        var thrown: LocalDataDeletionError?
        do {
            _ = try LocalDataDeletionService(fileURLs: [fileURL]).deleteAllLocalData()
        } catch let error as LocalDataDeletionError {
            thrown = error
        }

        let error = try #require(thrown)
        #expect(error.result.failedFilePaths == [setAside.path])
        #expect(try #require(error.errorDescription).contains("output-locations.json.unreadable-"))
        // The premise: it really is still there, which is what the report is about.
        #expect(FileManager.default.fileExists(atPath: setAside.path))
    }

    /// **The per-row Delete leaves set-aside files alone — the one door that sweeps is the wipe.**
    ///
    /// For one round of this branch both doors were the same call, so an ordinary Delete on a row
    /// that had recovered destroyed the file an earlier press promised to keep (PR #110 review, F2).
    @Test
    func deletingStoreFilesOnlyLeavesWhatWasSetAsideWhereItIs() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("output-locations.json")
        let quarantine = LocalDataQuarantine()

        try Data("the unreadable one".utf8).write(to: fileURL, options: .atomic)
        let setAside = try quarantine.moveAside(fileURL, at: Date(timeIntervalSince1970: 1_787_510_531))
        try Data("the live one".utf8).write(to: fileURL, options: .atomic)

        let result = try LocalDataDeletionService(fileURLs: [fileURL]).deleteStoreFilesOnly()

        #expect(result.deletedFileCount == 1, "the figure must count only what the user can see")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try String(decoding: Data(contentsOf: setAside), as: UTF8.self) == "the unreadable one")

        // And the wipe's door, over the same directory, does take it — so the asymmetry is the
        // decision rather than a sweep that stopped working.
        _ = try LocalDataDeletionService(fileURLs: [fileURL]).deleteAllLocalData()
        #expect(!FileManager.default.fileExists(atPath: setAside.path))
    }

    /// A file that merely *starts* with another store's name is not that store's, and must survive.
    ///
    /// `output-locations.json` and a hypothetical `output-locations.json.backup` share a prefix; the
    /// sweep matches on the name plus the suffix this type owns, not on the name alone.
    @Test
    func theWipeSweepMatchesTheSuffixRatherThanAnyNameThatSharesAPrefix() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputLocations = root.appendingPathComponent("output-locations.json")
        let neighbour = root.appendingPathComponent("output-locations.json.backup")
        try Data("live".utf8).write(to: outputLocations, options: .atomic)
        try Data("not ours".utf8).write(to: neighbour, options: .atomic)

        #expect(LocalDataQuarantine().quarantinedSiblings(of: outputLocations).isEmpty)

        _ = try LocalDataDeletionService(fileURLs: [outputLocations]).deleteAllLocalData()

        #expect(FileManager.default.fileExists(atPath: neighbour.path))
    }

    // MARK: - Fixtures

    /// One store, built at `root`, plus the read door a load failure surfaces through.
    ///
    /// Exhaustive over `LocalStore` with no `default`, which is the point: a fourteenth store cannot
    /// be added without somebody deciding how this suite reads it, and the two walks above then
    /// cover it for free.
    private static func probe(_ store: LocalStore, at root: URL) -> (fileURL: URL, read: () throws -> Void) {
        switch store {
        case .visionSessionJournal:
            let store = VisionSessionJournalStore(fileURL: root.appendingPathComponent("vision-sessions.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .routines:
            let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .workspaces:
            let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .clipboardHistory:
            let store = ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .clipboardHistorySettings:
            let store = ClipboardHistorySettingsStore(fileURL: root.appendingPathComponent("clipboard-history-settings.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.load() })
        case .snippets:
            let store = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .recentArtifacts:
            let store = RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .shortcutRunHistory:
            let store = ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcuts-run-history.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .taskHistory:
            let store = TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .taskPlanDetails:
            let store = TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .approvedApps:
            let store = ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .outputLocations:
            let store = OutputLocationStore(fileURL: root.appendingPathComponent("output-locations.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .resumableTasks:
            let store = ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        }
    }

    /// Valid ciphertext under a key the reader does not have — the founder's failure, not a
    /// malformed-JSON stand-in. Returns the bytes, so the move-aside walk can prove they survived.
    @discardableResult
    private static func writeUnreadableFile(at fileURL: URL) throws -> Data {
        let bytes = try writerEncryption.encode(["placeholder": UUID().uuidString])
        // The premise the whole suite rests on: this really is a well-formed store file, so what
        // fails below is the decrypt rather than a header check.
        #expect(bytes.starts(with: LocalStorageEncryption.fileHeader))
        try bytes.write(to: fileURL, options: .atomic)
        return bytes
    }

    private static let writerEncryption = LocalStorageEncryption(
        keyManager: QuarantineTestKeyManager(bytes: Data(repeating: 0x42, count: 32))
    )
    private static let readerEncryption = LocalStorageEncryption(
        keyManager: QuarantineTestKeyManager(bytes: Data(repeating: 0x99, count: 32))
    )
}

private struct QuarantineTestKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data { bytes }
}
