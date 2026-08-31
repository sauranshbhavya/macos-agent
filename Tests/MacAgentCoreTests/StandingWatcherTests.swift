import Foundation
import Testing
@testable import MacAgentCore

/// The standing watcher's own mechanism (row 13, SONNY-236): what it keeps, what "changed" means,
/// and the cap that ends it.
///
/// **The two halves are asserted apart on purpose.** The store half is about two collections sharing
/// one file without either one losing the other's records; the evaluator half is a pure state
/// machine with no clock, no network and no disk, so every awkward case in it — the ad slot, the
/// unreachable page, the expiry that lands between checks — is reachable by calling a function.
@MainActor
struct StandingWatcherTests {
    // MARK: - The file's two collections

    /// The migration: files written before watchers existed are a bare JSON array, and they still
    /// read.
    ///
    /// **The control is the second half.** A decode returning zero tasks looks identical to a decode
    /// of an empty file, so the assertion that matters is that the legacy tasks came back *with their
    /// content*, not that nothing threw.
    @Test
    func aLegacyBareArrayFileReadsAsTasksWithNoWatchers() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("resumable-tasks.json")
        let encryption = testEncryption()
        // Written as the shape the store used to write: the array itself, not a container.
        let legacy = try encryption.encode([sampleTask(id: "old", command: "Zip my three largest files")], encoder: prettySorted)
        try legacy.write(to: url)
        let store = makeStore(root: root)

        let tasks = try store.loadAll(now: .fixture)
        let watchers = try store.loadWatchers()

        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task.command == "Zip my three largest files")
        #expect(task.id == "old")
        #expect(watchers.isEmpty)
    }

    /// The other direction, and the reason the decode asks about *shape* rather than catching a
    /// failure: a container whose watcher list is corrupt must fail as itself, not be re-read as a
    /// legacy array and fail with a message about the wrong format.
    ///
    /// Driven at the decoder rather than through the store, because what is under test is
    /// `ResumableTaskFile.init(from:)`'s branch and nothing about encryption or files.
    @Test
    func aContainerWithACorruptWatcherFailsRatherThanReadingAsALegacyArray() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corrupt = Data(#"{"tasks":[],"watchers":[{"id":"w1"}]}"#.utf8)

        #expect(throws: (any Error).self) {
            _ = try decoder.decode(ResumableTaskFile.self, from: corrupt)
        }

        // The control: the same container shape with a well-formed watcher decodes, so the throw
        // above is about the corrupt record rather than about the container never decoding at all.
        let sound = Data(#"""
        {"tasks":[],"watchers":[{"id":"w1","subject":"the pricing page","url":"https://example.com/watched","createdAt":"2023-11-14T22:13:20Z","baselineDigest":"base","unstableReadings":0,"consecutiveFailures":0}]}
        """#.utf8)
        let file = try decoder.decode(ResumableTaskFile.self, from: sound)
        #expect(file.watchers.map(\.id) == ["w1"])
        #expect(file.tasks.isEmpty)
    }

    /// A container written before watchers existed — `{"tasks":[...]}` with no `watchers` key — reads
    /// as no watchers rather than failing, which would take every unfinished task in the file with it.
    @Test
    func aContainerWithNoWatchersKeyReadsAsNoWatchers() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(ResumableTaskFile.self, from: Data(#"{"tasks":[]}"#.utf8))
        #expect(file.watchers.isEmpty)
    }

    /// Both collections survive a round trip through one file.
    @Test
    func tasksAndWatchersRoundTripTogether() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        try store.save(sampleTask(id: "t1", command: "Zip my three largest files"), now: .fixture)
        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page"))

        #expect(try store.loadAll(now: .fixture).map(\.id) == ["t1"])
        #expect(try store.loadWatchers().map(\.id) == ["w1"])
        #expect(try store.loadWatchers().map(\.subject) == ["the pricing page"])
    }

    /// **The invariant the shared file exists to be at risk of.** A task write happens on every unit
    /// boundary of every run; if it dropped the watchers beside it, every standing watcher would end
    /// the first time the user ran anything — and end silently, because nothing fails and the user is
    /// simply never told again.
    @Test
    func aTaskWriteKeepsTheWatchersBesideIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page"))

        try store.save(sampleTask(id: "t1", command: "Zip my three largest files"), now: .fixture)
        try store.save(sampleTask(id: "t2", command: "Convert the report"), now: .fixture)
        try store.delete(id: "t1", now: .fixture)

        #expect(try store.loadWatchers().map(\.id) == ["w1"])
    }

    /// And the mirror: a watcher write must not drop the unfinished tasks beside it.
    @Test
    func aWatcherWriteKeepsTheTasksBesideIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.save(sampleTask(id: "t1", command: "Zip my three largest files"), now: .fixture)

        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page"))
        try store.saveWatcher(sampleWatcher(id: "w2", subject: "the invoice folder page"))
        try store.deleteWatcher(id: "w2")

        #expect(try store.loadAll(now: .fixture).map(\.id) == ["t1"])
    }

    /// The Memory row's door (SONNY-236, founder decision 2026-08-31): a row labelled *Unfinished
    /// tasks* removes unfinished tasks and leaves everything else in the file alone.
    ///
    /// **The control is `deleteAll()` in the same test**, because "the watchers survived" is only
    /// meaningful beside a door that takes them: without it the assertion is equally satisfied by a
    /// delete that does nothing at all.
    @Test
    func deletingEveryTaskKeepsTheWatchersAndTheWholeFileDoorTakesBoth() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.save(sampleTask(id: "t1", command: "Zip my three largest files"), now: .fixture)
        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page"))

        try store.deleteAllTasks()
        #expect(try store.loadAll(now: .fixture).isEmpty)
        #expect(try store.loadWatchers().map(\.id) == ["w1"])

        try store.deleteAll()
        #expect(try store.loadAll(now: .fixture).isEmpty)
        #expect(try store.loadWatchers().isEmpty)
    }

    /// The cap refuses rather than evicting — the opposite of what `capped(_:)` does to tasks, and
    /// deliberately so: the user said the sentence that created each of these.
    @Test
    func theCapRefusesASixthWatcherAndKeepsTheFiveThatExist() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, limits: limits(maxActive: 3))
        for index in 0..<3 {
            try store.saveWatcher(sampleWatcher(id: "w\(index)", subject: "page \(index)"))
        }

        #expect(throws: StandingWatcherStoreError.tooManyWatchers(limit: 3)) {
            try store.saveWatcher(sampleWatcher(id: "w3", subject: "one too many"))
        }
        // Nothing was evicted to make room, and the refusal did not corrupt the file.
        #expect(try store.loadWatchers().map(\.id) == ["w0", "w1", "w2"])
    }

    /// **An update is not an insert, and the cap must not refuse one.** A check records its own
    /// result by saving the watcher back, so a cap that refused updates would freeze every watcher's
    /// state the moment the last slot filled — and the save that then failed is the one carrying the
    /// reading that would have fired.
    @Test
    func theCapDoesNotRefuseAnUpdateToAWatcherThatAlreadyExists() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, limits: limits(maxActive: 2))
        try store.saveWatcher(sampleWatcher(id: "w0", subject: "page 0"))
        try store.saveWatcher(sampleWatcher(id: "w1", subject: "page 1"))

        var updated = sampleWatcher(id: "w1", subject: "page 1")
        updated.lastCheckedAt = Date.fixture.addingTimeInterval(900)
        updated.candidateDigest = "abc"
        try store.saveWatcher(updated)

        let loaded = try store.loadWatchers()
        #expect(loaded.count == 2)
        let reloaded = try #require(loaded.first { $0.id == "w1" })
        #expect(reloaded.candidateDigest == "abc")
        #expect(reloaded.lastCheckedAt == Date.fixture.addingTimeInterval(900))
    }

    /// Watchers come back oldest first, which is check order.
    @Test
    func watchersLoadOldestFirst() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.saveWatcher(sampleWatcher(id: "new", subject: "newer", createdAt: .fixture.addingTimeInterval(500)))
        try store.saveWatcher(sampleWatcher(id: "old", subject: "older", createdAt: .fixture))

        #expect(try store.loadWatchers().map(\.id) == ["old", "new"])
    }

    /// **`loadWatchers` filters nothing, and `loadAll` filtering is the control.** An idle task is
    /// dropped on read because nobody is waiting to hear about it; an expired watcher owes the user a
    /// sentence, so it has to survive the read that would otherwise have hidden it.
    @Test
    func anExpiredWatcherStillLoadsWhileAnIdleTaskDoesNot() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root, idleExpiry: 60)
        try store.save(sampleTask(id: "t1", command: "Zip my three largest files"), now: .fixture)
        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page"))

        let wellPast = Date.fixture.addingTimeInterval(60 * 60 * 24 * 365)
        #expect(try store.loadAll(now: wellPast).isEmpty)
        #expect(try store.loadWatchers().map(\.id) == ["w1"])
    }

    /// Deleting a watcher that is not there changes nothing and does not rewrite the file — the
    /// no-op rule every delete in this store follows.
    @Test
    func deletingAnUnknownWatcherRewritesNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page"))
        let url = store.fileURL
        let before = try Data(contentsOf: url)

        try store.deleteWatcher(id: "not-a-watcher")

        #expect(try Data(contentsOf: url) == before)
        #expect(try store.loadWatchers().map(\.id) == ["w1"])
    }

    /// The shared pattern's own promise: nothing a watcher holds is readable on disk.
    @Test
    func aWatcherIsEncryptedOnDisk() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let marker = "the pricing page \(UUID().uuidString)"

        try store.saveWatcher(sampleWatcher(id: "w1", subject: marker))

        let raw = try Data(contentsOf: store.fileURL)
        #expect(raw.starts(with: LocalStorageEncryption.fileHeader))
        #expect(String(decoding: raw, as: UTF8.self).contains(marker) == false)
        // The control: the marker really is in the record, so the absence above is about encryption
        // rather than about the subject never having been stored.
        #expect(try store.loadWatchers().first?.subject == marker)
    }

    /// A subject longer than the cap is trimmed on the way in **and on the way back out of a
    /// decode**, the rule `ResumableTask` states for its own command.
    @Test
    func anOverlongSubjectIsCappedThroughBothDoors() throws {
        let long = String(repeating: "a", count: StandingWatcher.maxSubjectCharacters + 50)
        let watcher = sampleWatcher(id: "w1", subject: long)
        #expect(watcher.subject.count == StandingWatcher.maxSubjectCharacters)

        let encoded = try JSONEncoder().encode(watcher)
        let decoded = try JSONDecoder().decode(StandingWatcher.self, from: encoded)
        #expect(decoded.subject.count == StandingWatcher.maxSubjectCharacters)
    }

    // MARK: - What "changed" means

    /// Reflowed whitespace is not a change; a letter is.
    ///
    /// The second half is the control, and it is the direction that costs something if it is wrong:
    /// a digest that absorbed too much would make the whole feature silently never fire.
    @Test
    func theDigestIgnoresReflowAndNoticesAWord() {
        let a = StandingWatcherEvaluator.digest(of: "Price:   £40\n\nIn stock")
        let b = StandingWatcherEvaluator.digest(of: "Price: £40\nIn stock\n")
        let c = StandingWatcherEvaluator.digest(of: "Price: £45\nIn stock")
        #expect(a == b)
        #expect(a != c)
    }

    /// Case is deliberately kept: "Pending" becoming "PENDING" is a real edit on the pages people
    /// watch, and this is the one place in the feature where hiding a difference is the expensive
    /// direction.
    @Test
    func theDigestNoticesACaseChange() {
        #expect(
            StandingWatcherEvaluator.digest(of: "Status: Pending")
                != StandingWatcherEvaluator.digest(of: "Status: PENDING")
        )
    }

    /// **The ad-slot answer, in one test.** A first difference is never a notification; the second
    /// identical reading is.
    @Test
    func aChangeIsNotifiedOnlyOnTheSecondIdenticalReading() {
        let watcher = sampleWatcher(id: "w1", subject: "the pricing page", baselineDigest: "base")

        let first = StandingWatcherEvaluator.apply(reading: "moved", to: watcher, now: .fixture)
        guard case .pending(let afterFirst) = first else {
            Issue.record("a first difference must not notify, got \(first)")
            return
        }
        #expect(afterFirst.candidateDigest == "moved")
        #expect(afterFirst.unstableReadings == 1)

        let second = StandingWatcherEvaluator.apply(
            reading: "moved",
            to: afterFirst,
            now: .fixture.addingTimeInterval(900)
        )
        guard case .stopped(let settled, let reason) = second else {
            Issue.record("a confirmed change must stop the watcher, got \(second)")
            return
        }
        #expect(reason == .changed)
        // The baseline moved to the confirmed reading, so a notifier handed this record does not
        // still describe the page as it was.
        #expect(settled.baselineDigest == "moved")
        #expect(settled.candidateDigest == nil)
    }

    /// A page that never reads the same way twice is called unwatchable rather than polled to the end
    /// of its lifetime and then reported as unchanged — which would be a false statement about a page
    /// that had in fact been moving the whole time.
    @Test
    func aPageThatNeverReadsTheSameTwiceIsCalledUnwatchable() {
        let bounded = limits(maxUnstableReadings: 3)
        var watcher = sampleWatcher(id: "w1", subject: "a churning page", baselineDigest: "base")

        for (index, reading) in ["one", "two"].enumerated() {
            let decision = StandingWatcherEvaluator.apply(
                reading: reading,
                to: watcher,
                now: .fixture.addingTimeInterval(Double(index) * 900),
                limits: bounded
            )
            guard case .pending(let next) = decision else {
                Issue.record("reading \(index) should still be pending, got \(decision)")
                return
            }
            watcher = next
        }

        let decision = StandingWatcherEvaluator.apply(
            reading: "three",
            to: watcher,
            now: .fixture.addingTimeInterval(1800),
            limits: bounded
        )
        guard case .stopped(_, let reason) = decision else {
            Issue.record("the third distinct reading should stop the watcher, got \(decision)")
            return
        }
        #expect(reason == .unwatchable)
    }

    /// A reading that comes back to the baseline drops the candidate and resets the instability
    /// count. Without the reset, a page that wobbled twice a day would reach `maxUnstableReadings`
    /// across an unrelated week and be declared unwatchable.
    @Test
    func aReadingEqualToTheBaselineClearsTheCandidateAndTheInstabilityCount() {
        var watcher = sampleWatcher(id: "w1", subject: "the pricing page", baselineDigest: "base")
        watcher.candidateDigest = "moved"
        watcher.unstableReadings = 2

        let decision = StandingWatcherEvaluator.apply(reading: "base", to: watcher, now: .fixture)

        guard case .unchanged(let settled) = decision else {
            Issue.record("a reading equal to the baseline is not a change, got \(decision)")
            return
        }
        #expect(settled.candidateDigest == nil)
        #expect(settled.unstableReadings == 0)
        #expect(settled.lastCheckedAt == .fixture)
    }

    /// Failures are tolerated and then are not, and a success in between clears the count. The
    /// tolerance is the point: ending a week-long watcher on one flaky fetch would be absurd, and
    /// retrying a dead URL to the end of its lifetime would finish by telling the user nothing had
    /// changed on a page Sonny never read.
    @Test
    func failuresAreToleratedUpToTheLimitAndASuccessResetsTheCount() {
        let bounded = limits(maxConsecutiveFailures: 3)
        var watcher = sampleWatcher(id: "w1", subject: "the pricing page", baselineDigest: "base")

        for index in 0..<2 {
            let decision = StandingWatcherEvaluator.applyFailure(
                to: watcher,
                now: .fixture.addingTimeInterval(Double(index) * 900),
                limits: bounded
            )
            guard case .pending(let next) = decision else {
                Issue.record("failure \(index) should be tolerated, got \(decision)")
                return
            }
            watcher = next
        }
        #expect(watcher.consecutiveFailures == 2)

        // A success in between clears it — the control for the stop below.
        let recovered = StandingWatcherEvaluator.apply(
            reading: "base",
            to: watcher,
            now: .fixture.addingTimeInterval(1800),
            limits: bounded
        )
        guard case .unchanged(let healthy) = recovered else {
            Issue.record("a successful read should clear the failure run, got \(recovered)")
            return
        }
        #expect(healthy.consecutiveFailures == 0)

        // And from the un-recovered record, the next failure is the last one.
        let third = StandingWatcherEvaluator.applyFailure(
            to: watcher,
            now: .fixture.addingTimeInterval(2700),
            limits: bounded
        )
        guard case .stopped(_, let reason) = third else {
            Issue.record("the third consecutive failure should stop the watcher, got \(third)")
            return
        }
        #expect(reason == .unreachable)
    }

    /// A failed check advances `lastCheckedAt`, so a page that is refusing connections is retried at
    /// the check interval rather than on every 30-second pulse.
    @Test
    func aFailedCheckStillAdvancesTheClock() {
        let watcher = sampleWatcher(id: "w1", subject: "the pricing page", baselineDigest: "base")
        let decision = StandingWatcherEvaluator.applyFailure(to: watcher, now: .fixture)
        guard case .pending(let updated) = decision else {
            Issue.record("expected a tolerated failure, got \(decision)")
            return
        }
        #expect(updated.lastCheckedAt == .fixture)
    }

    /// **F4's cheap half: `.expired` may not assert "It did not change" when a difference was ever
    /// seen** (founder decision, PR #184).
    ///
    /// The case it is about is a page alternating between its baseline and one other reading: never
    /// `.changed`, because the two never land consecutively, and never `.unwatchable`, because any
    /// return to the baseline resets the instability count. It runs its whole life and used to end by
    /// asserting the one thing certainly false about it.
    ///
    /// **The control is the unchanged page in the same test**, which still gets the stronger
    /// sentence — otherwise "does not say it did not change" is satisfied by never saying it.
    @Test
    func expiryOnlyClaimsNothingChangedWhenNothingEverDid() {
        let steady = sampleWatcher(id: "steady", subject: "a quiet page", baselineDigest: "base")
        #expect(
            StandingWatcherNoticeCopy.message(for: .expired, watcher: steady)
                == "Sonny stopped watching “a quiet page” after 7 days. It did not change."
        )

        // One difference, then back to the baseline — the alternating page, at the moment its last
        // reading matched, which is where `candidateDigest` and `unstableReadings` are both clear.
        var flickered = sampleWatcher(id: "flickers", subject: "a flickering page", baselineDigest: "base")
        guard case .pending(let sawDifference) = StandingWatcherEvaluator.apply(
            reading: "other", to: flickered, now: .fixture
        ) else {
            Issue.record("a first difference should be pending")
            return
        }
        guard case .unchanged(let backToBaseline) = StandingWatcherEvaluator.apply(
            reading: "base", to: sawDifference, now: .fixture.addingTimeInterval(900)
        ) else {
            Issue.record("a reading equal to the baseline is unchanged")
            return
        }
        flickered = backToBaseline
        #expect(flickered.candidateDigest == nil, "precondition: the reset really happened")
        #expect(flickered.unstableReadings == 0, "precondition: the reset really happened")
        #expect(flickered.firstDifferenceAt != nil, "the record must outlive the reset, or the sentence cannot")

        #expect(
            StandingWatcherNoticeCopy.message(for: .expired, watcher: flickered)
                == "Sonny stopped watching “a flickering page” after 7 days. Nothing settled."
        )
    }

    /// And the first difference is stamped once and never moved, so a later one does not restart it.
    @Test
    func theFirstDifferenceIsStampedOnceAndNeverCleared() {
        let watcher = sampleWatcher(id: "w1", subject: "a page", baselineDigest: "base")
        guard case .pending(let first) = StandingWatcherEvaluator.apply(reading: "a", to: watcher, now: .fixture) else {
            Issue.record("expected pending")
            return
        }
        #expect(first.firstDifferenceAt == .fixture)

        guard case .pending(let second) = StandingWatcherEvaluator.apply(
            reading: "b", to: first, now: .fixture.addingTimeInterval(900)
        ) else {
            Issue.record("expected pending")
            return
        }
        #expect(second.firstDifferenceAt == .fixture, "a later difference moved the first one")
    }

    // MARK: - Due-ness and expiry

    /// A watcher that has never been checked is due at once, so the record written at creation gets
    /// its first comparison on the next pulse rather than a check interval later.
    @Test
    func aWatcherThatHasNeverBeenCheckedIsDue() {
        let watcher = sampleWatcher(id: "w1", subject: "the pricing page")
        #expect(StandingWatcherEvaluator.isDue(watcher, now: .fixture))
    }

    /// And one checked a moment ago is not — with the interval's far side as the control, so this
    /// asserts a boundary rather than a constant.
    @Test
    func dueNessFollowsTheCheckInterval() {
        var watcher = sampleWatcher(id: "w1", subject: "the pricing page")
        watcher.lastCheckedAt = .fixture
        let bounded = limits(checkInterval: 900)

        #expect(StandingWatcherEvaluator.isDue(watcher, now: .fixture.addingTimeInterval(899), limits: bounded) == false)
        #expect(StandingWatcherEvaluator.isDue(watcher, now: .fixture.addingTimeInterval(900), limits: bounded))
    }

    /// **Expiry beats due-ness, and the ordering is the assertion.** A watcher that expires three
    /// minutes after its last check would otherwise sit for the rest of a check interval past the end
    /// of a lifetime that had already run out.
    @Test
    func anExpiredWatcherIsRetiredEvenWhenItIsNotDueForACheck() {
        var watcher = sampleWatcher(id: "w1", subject: "the pricing page")
        watcher.lastCheckedAt = .fixture.addingTimeInterval(3540)
        let bounded = limits(checkInterval: 900, maxLifetime: 3600)
        let now = Date.fixture.addingTimeInterval(3600)

        // The control: on this record, at this instant, due-ness alone says do nothing.
        #expect(StandingWatcherEvaluator.isDue(watcher, now: now, limits: bounded) == false)

        let decision = StandingWatcherEvaluator.decideBeforeObserving(watcher, now: now, limits: bounded)
        guard case .stopped(_, let reason) = decision else {
            Issue.record("an expired watcher should be retired, got \(decision)")
            return
        }
        #expect(reason == .expired)
    }

    /// And a live watcher that is simply not due yet reports `.notDue`, which is what keeps a
    /// not-due watcher from costing a request.
    @Test
    func aLiveWatcherThatIsNotDueReportsNotDue() {
        var watcher = sampleWatcher(id: "w1", subject: "the pricing page")
        watcher.lastCheckedAt = .fixture
        let decision = StandingWatcherEvaluator.decideBeforeObserving(
            watcher,
            now: .fixture.addingTimeInterval(60),
            limits: limits(checkInterval: 900, maxLifetime: 3600)
        )
        #expect(decision == .notDue)
    }

    // MARK: - The cap's own floors

    /// Every field floored, for the reason the store floors its own two: a zero here is not a small
    /// limit, it is a broken watcher.
    @Test
    func theLimitsAreFlooredAboveZero() {
        let zeroed = StandingWatcherLimits(
            maxActive: 0,
            checkInterval: 0,
            maxLifetime: -1,
            maxUnstableReadings: 0,
            maxConsecutiveFailures: -5,
            checkTimeout: 0
        )
        #expect(zeroed.maxActive == 1)
        #expect(zeroed.checkInterval == 1)
        #expect(zeroed.maxLifetime == 1)
        #expect(zeroed.maxUnstableReadings == 1)
        #expect(zeroed.maxConsecutiveFailures == 1)
        #expect(zeroed.checkTimeout == 1)
    }

    /// The shipped numbers, pinned by value.
    ///
    /// **A value table rather than a completeness check**, the shape `theWipesOwnSentenceNamesEveryStoreItDeletes`
    /// uses: these are release-time inputs the founders set, so the test that matters is the one that
    /// fails when one of them moves, not one that agrees with whatever the code says today.
    @Test
    func theShippedCapIsTheOneRecordedOnTheTicket() {
        #expect(StandingWatcherLimits.standard.maxActive == 5)
        #expect(StandingWatcherLimits.standard.checkInterval == 15 * 60)
        #expect(StandingWatcherLimits.standard.maxLifetime == 7 * 24 * 60 * 60)
        #expect(StandingWatcherLimits.standard.maxUnstableReadings == 4)
        #expect(StandingWatcherLimits.standard.maxConsecutiveFailures == 8)
        #expect(StandingWatcherLimits.standard.checkTimeout == 60)
    }

    /// And nothing in `Sources/` builds a `StandingWatcherLimits` of its own — the shipped cap is
    /// `.standard` and the initializer exists for tests.
    ///
    /// A separate arm from `noProductionPathPassesAnIdleExpiryOrCapToTheResumableStore`, which asks
    /// about arguments at this store's construction sites: this asks about a *different* needle over
    /// a different population — any construction of the limits value anywhere — and the two would
    /// each miss what the other catches.
    @Test
    func noProductionPathBuildsItsOwnStandingWatcherLimits() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        var filesRead = 0

        for target in ["MacAgentCore", "MacAgent"] {
            let directory = sources.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                Issue.record("Could not read \(directory.path)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                filesRead += 1
                let lines = TestSourceTree.codeLines(of: try String(contentsOf: url, encoding: .utf8))
                for line in lines where line.text.contains("StandingWatcherLimits(") {
                    // The one legitimate construction is `.standard`'s own, in the type's file.
                    guard url.lastPathComponent == "StandingWatcher.swift" else {
                        offenders.append("\(url.lastPathComponent):\(line.number)")
                        continue
                    }
                }
            }
        }

        #expect(offenders.isEmpty, "these build their own watcher cap: \(offenders)")
        // The control: the walk really read the shipped tree, so an empty `offenders` is a finding
        // rather than a search that reached no files.
        #expect(filesRead > 100, "the walk found \(filesRead) files, which is not the shipped tree")
    }

    // MARK: - Fixtures

    private func sampleTask(id: String, command: String) -> ResumableTask {
        ResumableTask(
            id: id,
            command: command,
            plan: AgentPlan(
                summary: "Work out a number.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(id: "calc", operation: .calculateUtility, description: "Add them up.", searchQuery: "2 + 2")
                ]
            ),
            startedAt: .fixture,
            updatedAt: .fixture
        )
    }

    private func sampleWatcher(
        id: String,
        subject: String,
        createdAt: Date = .fixture,
        baselineDigest: String = "baseline"
    ) -> StandingWatcher {
        StandingWatcher(
            id: id,
            subject: subject,
            url: URL(string: "https://example.com/watched")!,
            createdAt: createdAt,
            baselineDigest: baselineDigest
        )
    }

    private func limits(
        maxActive: Int = 5,
        checkInterval: TimeInterval = 900,
        maxLifetime: TimeInterval = 7 * 24 * 60 * 60,
        maxUnstableReadings: Int = 4,
        maxConsecutiveFailures: Int = 8,
        checkTimeout: TimeInterval = 60
    ) -> StandingWatcherLimits {
        StandingWatcherLimits(
            maxActive: maxActive,
            checkInterval: checkInterval,
            maxLifetime: maxLifetime,
            maxUnstableReadings: maxUnstableReadings,
            maxConsecutiveFailures: maxConsecutiveFailures,
            checkTimeout: checkTimeout
        )
    }

    private func makeStore(
        root: URL,
        idleExpiry: TimeInterval = ResumableTaskStore.defaultIdleExpiry,
        limits: StandingWatcherLimits = .standard
    ) -> ResumableTaskStore {
        ResumableTaskStore(
            fileURL: root.appendingPathComponent("resumable-tasks.json"),
            encryption: testEncryption(),
            idleExpiry: idleExpiry,
            limits: limits
        )
    }

    private var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
