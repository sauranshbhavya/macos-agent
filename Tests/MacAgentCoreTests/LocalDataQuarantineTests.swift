import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// A store file that will not decrypt, and the one mechanism that gets a user out of it (SONNY-239).
///
/// **The enumeration this ticket owed comes first.** The ticket said the read-before-write pattern
/// meant "almost certainly every local store, not just this one", and asked for that to be
/// established rather than assumed. `everyLocalStoreIsUnreadableWhenItsFileWasWrittenUnderAnotherKey`
/// walks `LocalStore.allCases` and proves it for every store that does not recover on its own, and
/// the switch inside `probe(_:at:)` is exhaustive with no `default`, so a new store joins the
/// population by failing to compile rather than by being remembered.
///
/// **One store recovers on its own, and it is enumerated rather than excused** (SONNY-333, PR #194
/// review F1). `pending-server-deletions.json` is an outbox: its contents are opaque ids of tasks
/// already deleted locally, so an unreadable queue's obligations cannot be reconstructed by
/// anything, while *propagating* the failure would make every future Delete fail to record one —
/// the store's own `loadKeyed()` carries the whole argument. It sets the file aside through the
/// very mechanism this suite is about and starts fresh, so it reads again rather than throwing.
/// `theOnlySelfHealingStoreIsTheOutbox` below holds that this is exactly one store, by value, so a
/// second one cannot join the exemption by being added to a list.
///
/// **The failure is reproduced the way the founder's Mac produced it**, not with random bytes: each
/// file is written as a valid `SONNYENC1` blob under one key and read back under another. That is
/// what SONNY-240's fixtures did to `output-locations.json` and `resumable-tasks.json`, and it is
/// also what a Keychain item replaced by a restore or a migration would do to every store at once.
/// Bytes that merely fail to parse would exercise the JSON half of `decode` and say nothing about
/// the decrypt half, which is the half that actually happened.
@Suite(.serialized)
struct LocalDataQuarantineTests {
    // MARK: - The gap, enumerated

    @Test
    func everyLocalStoreIsUnreadableWhenItsFileWasWrittenUnderAnotherKey() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for store in LocalStore.allCases where !Self.selfHealingStores.contains(store) {
            let probe = Self.probe(store, at: root)
            try Self.writeUnreadableFile(at: probe.fileURL)

            #expect(throws: LocalStorageEncryptionError.self, "\(store) read a file it should not have") {
                try probe.read()
            }
        }

        // The population, so a broken enumerator cannot pass this vacuously — and so the number
        // lives in exactly one assertion rather than in a test name that goes stale.
        #expect(LocalStore.allCases.count == 15)
        #expect(Self.selfHealingStores.count == 1)
    }

    /// **The exemption above is one store and stays one store** (SONNY-333, PR #194 review F1).
    ///
    /// Held by value rather than by a `contains` check, because a set is the shape a second store
    /// joins silently — and the property that earns the exemption is narrow: the file's contents are
    /// unrecoverable by anything, so keeping it preserves nothing, while propagating the failure
    /// disables the feature it belongs to for good. Every other store holds bytes a person made or a
    /// run produced, and SONNY-253's device-bound key may hand them back.
    ///
    /// Both directions, so the exemption cannot be widened *or* quietly emptied: the outbox really
    /// does read again after a wrong-key write, and every other store really does still throw.
    @Test
    func theOnlySelfHealingStoreIsTheOutbox() throws {
        #expect(Self.selfHealingStores == [.pendingServerDeletions])

        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = Self.probe(.pendingServerDeletions, at: root)
        try Self.writeUnreadableFile(at: probe.fileURL)

        // Reads again rather than throwing…
        try probe.read()
        // …and the bytes it could not read are set aside rather than destroyed, which is what makes
        // this compatible with SONNY-253 handing a key back later.
        #expect(LocalDataQuarantine().quarantinedSiblings(of: probe.fileURL).count == 1)
    }

    /// The stores that recover from an unreadable file instead of reporting one. See the suite's
    /// header for why this is a list of exactly one and what would have to be true of a second.
    private static let selfHealingStores: Set<LocalStore> = [.pendingServerDeletions]

    /// The same walk, one step further: the mechanism clears every one of them.
    ///
    /// **This is the claim the fix rests on** — that recovery is one mechanism rather than one per store.
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
    /// only the stores' own exact filenames would report a count covering every one of them while
    /// leaving every set-aside file untouched. Sonny not being able to read them is not the same as
    /// their holding nothing.
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

    // MARK: - Settings' narrower control (SONNY-266)

    /// **The line Settings shows and the files its control removes are one listing.**
    ///
    /// Two stores, one of them set aside twice; a third set aside once and never rewritten; two live
    /// files that read; and a neighbour that merely shares a prefix. The listing is exactly the four
    /// set-aside files, in the service's store order and then name order, and the summary is their
    /// count and the sum of their sizes — sizes chosen so a dropped or doubled file changes the total.
    @Test
    func theListingCountsEverySetAsideFileAndSumsTheirBytes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try Self.setAsideLayout(at: root)
        let service = LocalDataDeletionService(fileURLs: layout.storeFileURLs)

        #expect(service.setAsideFiles() == layout.setAside)
        #expect(service.setAsideFilesSummary() == SetAsideFilesSummary(fileCount: 4, byteCount: layout.setAsideByteCount))
        #expect(!service.setAsideFilesSummary().isEmpty)
        // The row's gate is the count, never the size: a zero-byte file that would not read is set
        // aside like any other and is still a file the control removes.
        #expect(!SetAsideFilesSummary(fileCount: 1, byteCount: 0).isEmpty)

        // `fileURLs` is caller-supplied, and a store handed in twice must list its files once — the
        // property the count relies on, held rather than asserted in prose (PR #117 review, R9).
        let handedOneTwice = LocalDataDeletionService(fileURLs: [layout.outputLocations] + layout.storeFileURLs)
        #expect(handedOneTwice.setAsideFiles() == layout.setAside)
        #expect(handedOneTwice.setAsideFilesSummary() == service.setAsideFilesSummary())
    }

    /// Nothing set aside — the ordinary state — is `.none`, whether the stores have live files, no
    /// files, or no directory at all. The Data page's row is gated on exactly this.
    @Test
    func theSummaryIsEmptyWhenNothingHasBeenSetAside() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("routines.json")
        try Data("live".utf8).write(to: live, options: .atomic)
        let absent = root.appendingPathComponent("snippets.json")
        let unlistable = root.appendingPathComponent("never-made/workspaces.json")

        let service = LocalDataDeletionService(fileURLs: [live, absent, unlistable])

        #expect(service.setAsideFiles().isEmpty)
        #expect(service.setAsideFilesSummary() == .none)
        #expect(service.setAsideFilesSummary().isEmpty)
    }

    /// **The narrower door takes every set-aside file and nothing else.** Every live store file is
    /// still there with its bytes, the prefix-sharing neighbour is untouched, a store whose own file
    /// was never rewritten still has none, and `missingFileCount` is zero because this door never
    /// asks about store files. Then the listing is empty, which is what the Data page's row reads.
    @Test
    func deletingTheSetAsideFilesLeavesEveryStoreFileAndEveryNeighbourWhereItIs() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try Self.setAsideLayout(at: root)
        let service = LocalDataDeletionService(fileURLs: layout.storeFileURLs)

        let result = try service.deleteSetAsideFilesOnly()

        #expect(result == LocalDataDeletionResult(deletedFileCount: 4, missingFileCount: 0))
        for setAside in layout.setAside {
            #expect(!FileManager.default.fileExists(atPath: setAside.path), "\(setAside.lastPathComponent)")
        }
        #expect(try String(decoding: Data(contentsOf: layout.outputLocations), as: UTF8.self) == "live output locations")
        #expect(try String(decoding: Data(contentsOf: layout.taskHistory), as: UTF8.self) == "live task history")
        #expect(!FileManager.default.fileExists(atPath: layout.snippets.path), "the door created a store file")
        #expect(try String(decoding: Data(contentsOf: layout.neighbour), as: UTF8.self) == "not ours")
        #expect(service.setAsideFiles().isEmpty)
        #expect(service.setAsideFilesSummary() == .none)
    }

    /// The directory SONNY-266's two tests above share: `output-locations.json` set aside twice and
    /// live again, `task-history.json` set aside once and live again, `snippets.json` set aside once
    /// and never rewritten, and a `.backup` neighbour of the first that no door may touch.
    ///
    /// Returns the set-aside files in the order `setAsideFiles()` promises — store order, then name
    /// order within a store — and the byte total a summary over them has to report.
    private static func setAsideLayout(at root: URL) throws -> (
        storeFileURLs: [URL],
        outputLocations: URL,
        taskHistory: URL,
        snippets: URL,
        neighbour: URL,
        setAside: [URL],
        setAsideByteCount: Int64
    ) {
        let quarantine = LocalDataQuarantine()
        let outputLocations = root.appendingPathComponent("output-locations.json")
        let taskHistory = root.appendingPathComponent("task-history.json")
        let snippets = root.appendingPathComponent("snippets.json")
        let neighbour = root.appendingPathComponent("output-locations.json.backup")
        let earlier = Date(timeIntervalSince1970: 1_787_510_531)
        let later = Date(timeIntervalSince1970: 1_787_596_931)

        // Five, seven, eleven and thirteen bytes: no two the same, so every file is visible in the
        // total on its own.
        try Data("first".utf8).write(to: outputLocations, options: .atomic)
        let firstAside = try quarantine.moveAside(outputLocations, at: earlier)
        try Data("second!".utf8).write(to: outputLocations, options: .atomic)
        let secondAside = try quarantine.moveAside(outputLocations, at: later)
        try Data("live output locations".utf8).write(to: outputLocations, options: .atomic)

        try Data("task record".utf8).write(to: taskHistory, options: .atomic)
        let taskAside = try quarantine.moveAside(taskHistory, at: earlier)
        try Data("live task history".utf8).write(to: taskHistory, options: .atomic)

        try Data("snippet bytes".utf8).write(to: snippets, options: .atomic)
        let snippetAside = try quarantine.moveAside(snippets, at: earlier)

        try Data("not ours".utf8).write(to: neighbour, options: .atomic)

        return (
            storeFileURLs: [outputLocations, taskHistory, snippets],
            outputLocations: outputLocations,
            taskHistory: taskHistory,
            snippets: snippets,
            neighbour: neighbour,
            setAside: [firstAside, secondAside, taskAside, snippetAside],
            setAsideByteCount: 5 + 7 + 11 + 13
        )
    }

    // MARK: - Fixtures

    /// One store, built at `root`, plus the read door a load failure surfaces through.
    ///
    /// Exhaustive over `LocalStore` with no `default`, which is the point: a new store cannot
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
        case .pendingServerDeletions:
            let store = PendingServerDeletionStore(fileURL: root.appendingPathComponent("pending-server-deletions.json"), encryption: readerEncryption)
            return (store.fileURL, { _ = try store.loadAll() })
        case .addedSkills:
            let store = SkillSelectionStore(fileURL: root.appendingPathComponent("added-skills.json"), encryption: readerEncryption)
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
