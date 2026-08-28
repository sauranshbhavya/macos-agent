import Foundation
import Testing
import MacAgentTestSupport
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

    /// The twelfth store's own pattern conformance (SONNY-209): the folder paths a person's work
    /// goes into never sit on disk in the clear.
    ///
    /// Its whitelist points at a directory of this test's own, because the store only records a
    /// folder it is allowed to write to — a default whitelist here would resolve to the developer's
    /// real Desktop and Documents.
    @Test
    func outputLocationStoreEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive-folder-\(UUID().uuidString)"
        let folder = root.appendingPathComponent(marker, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            encryption: testEncryption(),
            whitelist: PathWhitelist(roots: [root])
        )

        try store.recordOutputs(
            atPaths: [folder.appendingPathComponent("report.md").path],
            recordedAt: .fixture
        )

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.loadAll(now: .fixture).first?.name == marker)
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
        try assertOutputLocationMigration(root: root, encryption: encryption)
    }

    /// **The strip runs before the legacy-plaintext rewrite, and that ordering is the point of this
    /// test** (PR #83, F2). `RoutineStore.loadAll` re-encrypts a plaintext file as it reads it, so a
    /// strip applied *after* that rewrite would persist the very pins it had just removed: the
    /// returned value would be clean while the file on disk kept them, and every later load would
    /// strip them again from bytes nobody ever fixed.
    ///
    /// The ordering was a named decision with nothing holding it — the review moved the strip after
    /// the migration and the entire suite stayed green. What makes this test bite is that it reads
    /// the **file** afterwards rather than the return value.
    @Test
    func aLegacyPlaintextRoutineIsRewrittenWithoutThePinsItArrivedWith() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("routines.json")
        let encryption = testEncryption()

        var pinned = AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
        pinned.resolvedAppName = "Safari"
        pinned.resolvedBundleIdentifier = "com.attacker.lookalike"
        // Written as plaintext JSON with no `SONNYENC1` header — the legacy shape every store still
        // migrates on read.
        try JSONEncoder.prettySortedForTest
            .encode([normalized("Legacy"): StoredRoutine(name: "Legacy", steps: [pinned])])
            .write(to: url, options: .atomic)

        let store = RoutineStore(fileURL: url, encryption: encryption)
        _ = try store.loadAll()

        // The rewrite happened...
        #expect(try Data(contentsOf: url).starts(with: LocalStorageEncryption.fileHeader))

        // ...and what it persisted is the stripped form. **Decoded straight out of the file, not
        // re-read through a `RoutineStore`** — a second store would strip on load too, so it answers
        // "no pins" whichever order the first one used, and a test written that way passes with the
        // strip moved after the migration. This branch's own battery caught exactly that: the first
        // version of this test re-read through a store and the mutant survived it.
        let persisted = try encryption
            .decode([String: StoredRoutine].self, from: Data(contentsOf: url))
            .value
        let step = try #require(persisted[normalized("Legacy")]?.steps.first)
        #expect(step.resolvedAppName == nil)
        #expect(step.resolvedBundleIdentifier == nil)
        #expect(step.appName == "Safari")
    }

    /// A failed re-encryption during legacy migration is not a load failure: the decode already
    /// succeeded and the write is atomic, so the original file is intact and the data is usable.
    /// Letting that write error escape `loadAll()` made callers blank the data and show the
    /// "could not be decrypted or decoded" banner for data that decoded perfectly.
    @Test(.requiresUnprivilegedProcess)
    func failedLegacyMigrationRewriteStillReturnsTheDecodedData() throws {
        let root = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let plaintextURL = root.appendingPathComponent("routines.json")
        let legacy = [
            "morning": StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "open", operation: .openApp, description: "Open Safari.", appName: "Safari")
                ]
            )
        ]
        try JSONEncoder().encode(legacy).write(to: plaintextURL)
        // Read-only directory: the file still reads, but the migration rewrite cannot land.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let store = RoutineStore(fileURL: plaintextURL, encryption: testEncryption())
        let loaded = try store.loadAll()

        #expect(loaded["morning"]?.name == "Morning")
        // The plaintext original is untouched, so the migration retries on the next load.
        let raw = try Data(contentsOf: plaintextURL)
        #expect(!raw.starts(with: LocalStorageEncryption.fileHeader))
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

        // Ten since row E (SONNY-147): `task-plan-details.json` holds what each finished task
        // planned. Eleven since row J (SONNY-140): `approved-apps.json` holds which apps the user
        // let Sonny control. Twelve since row 13 (SONNY-209): `output-locations.json` holds which
        // folders their work comes out into. Nine, not eight, was SONNY-154's correction — the vision session
        // journal was the store this test did not create, so the only place the wipe's behaviour is
        // actually exercised covered every store except the most sensitive one.
        //
        // **What the count assertion is for, corrected** (PR #83, F7). It is *not* drift protection
        // between the fixture's files and its returned URLs — the two deletion counts below already
        // provide that, since a fixture returning a URL it did not create reports a missing file and
        // fails. What this adds is a tripwire on the fixture's own size: the count is stated in a
        // third place, so extending the fixture cannot pass by adjusting one number, and whoever
        // changes it has to come here and ask whether `LocalDataDeletionService`'s real list moved
        // too. That question going unasked is how the journal stayed uncovered. The number is
        // deliberately not spelled in this sentence, since a sentence that names it is a fourth
        // place to update and this one already went stale once (PR #89 cycle 2, F3).
        #expect(fileURLs.count == 13)
        #expect(result == LocalDataDeletionResult(deletedFileCount: 13, missingFileCount: 0))
        for fileURL in fileURLs {
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }

        let secondResult = try service.deleteAllLocalData()
        #expect(secondResult == LocalDataDeletionResult(deletedFileCount: 0, missingFileCount: 13))
    }

    @Test(.requiresUnprivilegedProcess)
    func localDataDeletionAttemptsEveryFileEvenWhenOneFails() throws {
        let root = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: root)
        }

        let first = root.appendingPathComponent("first.json")
        let lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        let blocked = lockedDirectory.appendingPathComponent("blocked.json")
        let last = root.appendingPathComponent("last.json")
        for url in [first, blocked, last] {
            try Data("{}".utf8).write(to: url)
        }
        // A read-only parent directory makes removeItem fail for `blocked` only.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDirectory.path)

        let service = LocalDataDeletionService(fileURLs: [first, blocked, last])

        do {
            _ = try service.deleteAllLocalData()
            Issue.record("Expected deletion to report the file it could not remove.")
        } catch let error as LocalDataDeletionError {
            #expect(error.result.deletedFileCount == 2)
            #expect(error.result.failedFilePaths == [blocked.path])
            #expect(error.errorDescription?.contains("blocked.json") == true)
        }

        // The failure must not stop the files after it from being deleted.
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: last.path))
        #expect(FileManager.default.fileExists(atPath: blocked.path))
    }

    /// The wipe's reach, pinned by count and by name. Relocated here from the deleted ledger
    /// suite (PR #49 N4): the ninth store's own `urls.count == 9` pin died with it, and without
    /// a successor a store added to the app but forgotten from this list would vanish from the
    /// wipe silently. Thirteen stores is the current whole population, since row 13's unfinished
    /// runs.
    ///
    /// **The count moved four times and no longer lives in this test's name** (SONNY-209). Row E's
    /// plan details landed first, at `ebd6c1d`, taking it to ten; row J's approved apps rebased on
    /// top of that and took it to eleven; row 13's output locations took it to twelve, and row 13's
    /// unfinished runs (SONNY-210) to thirteen. Each of the first three moves renamed this test, and
    /// each rename left the doc comments elsewhere that name it pointing at a symbol that no longer
    /// existed. So the name is count-free now and the number lives only in the assertion below,
    /// where the suite is what complains — which is what let the fourth move cost nothing but two
    /// numerals. A fourteenth store raises this number and the one in
    /// `everyLocalStoreFileIsClassifiedExactlyOnce`, and renames nothing.
    @Test
    func theWipeReachesEveryLocalStore() {
        let urls = LocalDataDeletionService.defaultStoreFileURLs()
        #expect(urls.count == 13)
        let fileNames = Set(urls.map(\.lastPathComponent))
        // Nine since row I: `vision-sessions.json` is the action journal (SONNY-96). A wipe that
        // left a record of every click Sonny made inside the user's apps would be the loudest
        // possible failure of a privacy wipe. Ten since row E: `task-plan-details.json` holds what
        // each finished task planned, and a wipe that left the plan of every task Sonny ever ran
        // fails in exactly the same way.
        //
        // Eleven since row J: `approved-apps.json` holds which apps the user let Sonny control
        // (SONNY-140). It is the one store here that is not a record of what Sonny did — it is what
        // the user decided — and it is erased with the rest, because "delete my local data" is a
        // promise about the whole directory rather than about the parts a reader thinks of first.
        //
        // Twelve since row 13: `output-locations.json` holds which folders this person's work comes
        // out into (SONNY-209). A short list of paths, which sounds harmless and is not — where
        // somebody's work goes is a map of what they work on.
        #expect(fileNames == [
            "routines.json",
            "workspaces.json",
            "clipboard-history.json",
            "clipboard-history-settings.json",
            "snippets.json",
            "recent-artifacts.json",
            "shortcuts-run-history.json",
            "task-history.json",
            "vision-sessions.json",
            "task-plan-details.json",
            "approved-apps.json",
            "output-locations.json",
            // Thirteen since row 13's second store: `resumable-tasks.json` holds the whole plan of a
            // task the user started and did not finish — its steps, the paths they name, the draft
            // text they carry. A wipe that left it behind would leave the plan of every abandoned
            // task on disk, which is the same failure as leaving the plans of the finished ones.
            "resumable-tasks.json"
        ])
    }

    /// The mechanism that stops "Don't save this task" from quietly becoming untrue. The founder's
    /// decision of 2026-08-16 is that its reach is a rule, not a list — so a store that reaches the
    /// wipe without a `LocalStore` case has to fail here rather than default to "recorded".
    ///
    /// Row E's `task-plan-details.json`, row J's `approved-apps.json` and row 13's
    /// `output-locations.json` and `resumable-tasks.json` are the tenth through thirteenth, and all
    /// four arrived exactly the way this test was built to make them arrive: the new file had no
    /// case, so it matched nothing and the suite failed until it was classified. Classifying is the
    /// fix; deleting the assertion is not.
    @Test
    func everyLocalStoreFileIsClassifiedExactlyOnce() {
        let wipedURLs = LocalDataDeletionService.defaultStoreFileURLs()

        for url in wipedURLs {
            let matches = LocalStore.allCases.filter { $0.fileURL() == url }
            #expect(matches.count == 1, "\(url.lastPathComponent) has \(matches.count) classifications, expected 1")
        }

        // And the other direction: no case describes a file the wipe never reaches.
        let classifiedURLs = LocalStore.allCases.map { $0.fileURL() }
        #expect(Set(classifiedURLs) == Set(wipedURLs))
        #expect(Set(classifiedURLs).count == LocalStore.allCases.count)
        #expect(LocalStore.allCases.count == 13)
    }

    /// **The words Settings uses to describe the wipe name every store the wipe reaches**
    /// (SONNY-233).
    ///
    /// The two surfaces that describe this button used to hold hand-written lists, and both were
    /// false by omission: the Data page's detail line named ten of thirteen and the confirmation
    /// dialog named nine — the dialog being the last thing a user reads before an irreversible
    /// press. Nothing connected either sentence to the file list, so each new store went unnamed
    /// silently. The sentence is derived now, and this is the assertion that it is complete.
    ///
    /// **The other half of the chain is the two tests above.** They pin that `LocalStore.allCases`
    /// and `LocalDataDeletionService.defaultStoreFileURLs()` describe one population; this pins that
    /// the sentence names all of `allCases`. Together: every file the wipe deletes is named in the
    /// words that describe it.
    @Test
    func theWipesOwnSentenceNamesEveryStoreItDeletes() {
        // Split back into items rather than searching for substrings: "clipboard history" is a
        // prefix of nothing here today and would be of "clipboard history settings" tomorrow, and a
        // containment check cannot tell a named store from an accidental substring of a neighbour.
        let items = LocalDataDeletionCopy.everythingItTakes
            .replacingOccurrences(of: ", and ", with: ", ")
            .components(separatedBy: ", ")

        #expect(items == LocalStore.allCases.map(\.deletionCopyName))
        #expect(items.count == LocalStore.allCases.count)
        #expect(Set(items).count == items.count, "two stores share a name and one of them is invisible")
        #expect(!items.contains(""), "a store is named by nothing at all")

        // The three that were missing when this was filed, by value — so the ticket's own finding is
        // readable here rather than only in its history.
        #expect(items.contains("what past tasks planned"))
        #expect(items.contains("allowed apps"))
        #expect(items.contains("unfinished tasks"))
        // And the one the dialog alone had lost.
        #expect(items.contains("common output locations"))
    }

    /// The join, at the sizes the product cannot reach today and a successor might.
    ///
    /// One store would otherwise render as a list of one with a stray "and" in front of it, and two
    /// take no comma at all. Written out rather than left to `joined(separator:)` for exactly that,
    /// so the branches are asserted rather than assumed unreachable.
    @Test
    func theListJoinsWithAnOxfordCommaAtEverySize() {
        #expect(LocalDataDeletionCopy.list([]) == "")
        #expect(LocalDataDeletionCopy.list(["snippets"]) == "snippets")
        #expect(LocalDataDeletionCopy.list(["snippets", "routines"]) == "snippets and routines")
        #expect(
            LocalDataDeletionCopy.list(["snippets", "routines", "workspaces"])
                == "snippets, routines, and workspaces"
        )
    }

    /// Pins *which* kind each store is, not merely that it has one. Exhaustiveness alone would let
    /// task history be silently reclassified `.artifact` and stop being suppressed, which is the
    /// same failure by a different route.
    @Test
    func theTraceArtifactSplitMatchesTheFounderDecision() {
        func stores(_ kind: LocalStoreKind) -> Set<LocalStore> {
            Set(LocalStore.allCases.filter { $0.kind == kind })
        }

        // Suppressed by "Don't save this task": incidental records of what happened.
        #expect(stores(.trace) == [
            .clipboardHistory,
            .recentArtifacts,
            // Row 13's unfinished runs (SONNY-210). A record *of* a run that nobody asked for, and
            // classifying it here is what makes "Don't save this task" cover the offer as well as
            // the history row — a suppressed run leaves no record, so Sonny never raises "you were
            // partway through X" for a task the user asked it not to remember.
            .resumableTasks,
            .shortcutRunHistory,
            .taskHistory,
            .taskPlanDetails,
            .visionSessionJournal,
            // Row 13's output locations (SONNY-209). Nobody asked Sonny to remember which folder a
            // file went into; it is derived from where the run's own output landed, which is the
            // founder's ground for `.trace` exactly. Suppressing it costs the user nothing they
            // asked for — the file is still written, and still where they put it.
            .outputLocations
        ])
        // Never suppressed: the thing the user actually asked for. `approvedApps` is here on that
        // same ground and not on a weaker one (SONNY-140): a grant is the user's own answer to a
        // question Sonny asked them, so withholding it would discard a consent decision and leave
        // Sonny asking the identical question on the next run with no way to say why.
        #expect(stores(.artifact) == [.routines, .workspaces, .snippets, .approvedApps])
        // The one store the founder's own enumeration did not reach: no task writes it.
        #expect(stores(.notWrittenByTasks) == [.clipboardHistorySettings])

        // Every kind is used, so none is a case nothing ever means.
        #expect(LocalStoreKind.allCases.allSatisfy { !stores($0).isEmpty })
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
    // The ninth store, and the one the wipe most has to reach: the journal holds `observationAfter`,
    // the model's description of what was on the user's screen. It was missing from this helper
    // (SONNY-154) — it arrived with row I and nobody extended the fixture — so the only test that
    // actually runs `deleteAllLocalData()` over real files exercised eight of nine, and the journal's
    // place in the wipe was pinned by the URL list alone.
    let visionSessionJournalStore = VisionSessionJournalStore(
        fileURL: root.appendingPathComponent("vision-sessions.json"),
        encryption: encryption
    )
    // The tenth store (row E, SONNY-147): what each finished task planned. Created here rather than
    // only listed, for the reason the journal's own line above records — a store the fixture lists
    // but never writes is a store whose deletion this test never actually runs.
    let taskPlanDetailStore = TaskPlanDetailStore(
        fileURL: root.appendingPathComponent("task-plan-details.json"),
        encryption: encryption
    )
    // The eleventh (row J, SONNY-140), created here for the identical reason.
    let approvedAppStore = ApprovedAppStore(
        fileURL: root.appendingPathComponent("approved-apps.json"),
        encryption: encryption
    )
    // The twelfth (row 13, SONNY-209), created here for the identical reason. Its whitelist is this
    // fixture's own directory, because the store records only a folder it is allowed to write to and
    // the default whitelist is the developer's real Desktop and Documents.
    let outputLocationStore = OutputLocationStore(
        fileURL: root.appendingPathComponent("output-locations.json"),
        encryption: encryption,
        whitelist: PathWhitelist(roots: [root])
    )
    // The thirteenth (row 13, SONNY-210): what a task was partway through. Created *and written to*
    // here, which is the whole point of this helper — the journal's own line above records what it
    // cost to list a store the fixture never wrote, and the only test that runs
    // `deleteAllLocalData()` over real files would otherwise exercise twelve of thirteen.
    let resumableTaskStore = ResumableTaskStore(
        fileURL: root.appendingPathComponent("resumable-tasks.json"),
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
    try visionSessionJournalStore.save(
        VisionSessionRecord(
            id: "delete-session",
            goal: "delete vision session",
            appDisplayName: "Safari",
            startedAt: .fixture
        )
    )
    try taskPlanDetailStore.save(
        StoredTaskPlanDetail(
            taskID: "delete-plan-detail",
            completedAt: .fixture,
            planSummary: "delete plan summary",
            steps: []
        )
    )
    try approvedAppStore.approve(
        bundleIdentifier: "com.apple.Notes",
        displayName: "Notes",
        approvedAt: .fixture
    )
    let outputFolder = root.appendingPathComponent("delete-output-folder", isDirectory: true)
    try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
    try outputLocationStore.recordOutputs(
        atPaths: [outputFolder.appendingPathComponent("delete-output.md").path],
        recordedAt: .fixture
    )
    try resumableTaskStore.save(
        ResumableTask(
            command: "delete unfinished task",
            plan: AgentPlan(
                summary: "delete unfinished plan",
                requiresConfirmation: false,
                steps: [
                    AgentStep(id: "calc", operation: .calculateUtility, description: "delete unfinished step")
                ]
            ),
            startedAt: .fixture,
            updatedAt: .fixture
        ),
        // The store drops a record past its idle period on read, and `.fixture` is a fixed instant
        // in the past — so a `now` of `Date()` would make `save`'s own reload discard what it just
        // wrote and leave an empty array on disk. Anchored to the record's own clock instead, which
        // is the same fixed-clock discipline `TaskRecordingPolicyTests` uses for the seven-day
        // clipboard age-out.
        now: .fixture
    )

    return [
        routineStore.fileURL,
        workspaceStore.fileURL,
        clipboardStore.fileURL,
        clipboardSettingsStore.fileURL,
        snippetStore.fileURL,
        recentArtifactStore.fileURL,
        shortcutRunHistoryStore.fileURL,
        taskHistoryStore.fileURL,
        visionSessionJournalStore.fileURL,
        taskPlanDetailStore.fileURL,
        approvedAppStore.fileURL,
        outputLocationStore.fileURL,
        resumableTaskStore.fileURL
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

private func assertOutputLocationMigration(root: URL, encryption: LocalStorageEncryption) throws {
    let marker = "legacy-output-folder-\(UUID().uuidString)"
    let folder = root.appendingPathComponent(marker, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let resolved = PathWhitelist.canonicalURL(folder.path).path
    let url = root.appendingPathComponent("legacy-output-locations.json")
    // Keyed the way the store keys it, by hand: a fixture that asked the store for its key would be
    // asserting the migration against whatever the store currently does rather than against the file
    // a previous version really left on disk.
    let legacy = [
        resolved.folding(options: [.caseInsensitive], locale: nil): OutputLocation(
            path: resolved,
            useCount: 2,
            firstUsedAt: .fixture,
            lastUsedAt: .fixture
        )
    ]
    try JSONEncoder.iso8601PrettySortedForTest.encode(legacy).write(to: url, options: .atomic)
    let store = OutputLocationStore(
        fileURL: url,
        encryption: encryption,
        whitelist: PathWhitelist(roots: [root])
    )

    #expect(try store.loadAll(now: .fixture).first?.path == resolved)
    #expect(try store.location(for: folder.path)?.useCount == 2)
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

/// Internal rather than file-private since row I: `VisionSessionJournalTests` pins the ninth
/// store's pattern conformance and needs the same two helpers. Sharing them is the point — a second
/// copy would be a second definition of "encrypted on disk" that could drift from this one.
func testEncryption() -> LocalStorageEncryption {
    LocalStorageEncryption(
        keyManager: FixedLocalStorageKeyManager(bytes: Data(repeating: 0x42, count: 32))
    )
}

func expectEncryptedFile(_ url: URL, hiding plaintext: String) throws {
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
