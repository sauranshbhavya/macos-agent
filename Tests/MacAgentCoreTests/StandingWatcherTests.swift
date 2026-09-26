import Foundation
import Testing
@testable import MacAgentCore

/// The standing watcher's own mechanism (row 13, SONNY-236): what it keeps, what "changed" means,
/// and the cap that ends it.
///
/// **The two halves are asserted apart on purpose.** The store half is about keeping and capping
/// the records; the evaluator half is a pure state
/// machine with no clock, no network and no disk, so every awkward case in it — the ad slot, the
/// unreachable page, the expiry that lands between checks — is reachable by calling a function.
@MainActor
struct StandingWatcherTests {
    // MARK: - The store

    /// A file whose watcher list is corrupt fails as itself rather than reading as empty.
    ///
    /// Driven at the decoder rather than through the store, because what is under test is the
    /// file's shape and nothing about encryption or files.
    @Test
    func aFileWithACorruptWatcherFailsToDecode() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let corrupt = Data(#"{"watchers":[{"id":"w1"}]}"#.utf8)

        #expect(throws: (any Error).self) {
            _ = try decoder.decode(StandingWatcherFile.self, from: corrupt)
        }

        // The control: the same shape with a well-formed watcher decodes, so the throw above is
        // about the corrupt record rather than about the file never decoding at all.
        let sound = Data(#"""
        {"watchers":[{"id":"w1","subject":"the pricing page","url":"https://example.com/watched","createdAt":"2023-11-14T22:13:20Z","baselineDigest":"base","unstableReadings":0,"consecutiveFailures":0}]}
        """#.utf8)
        let file = try decoder.decode(StandingWatcherFile.self, from: sound)
        #expect(file.watchers.map(\.id) == ["w1"])
    }

    /// A watcher round trips through the file.
    @Test
    func aWatcherRoundTrips() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page"))
        try store.saveWatcher(sampleWatcher(id: "w2", subject: "the invoice folder page"))
        try store.deleteWatcher(id: "w2")

        #expect(try store.loadWatchers().map(\.id) == ["w1"])
        #expect(try store.loadWatchers().map(\.subject) == ["the pricing page"])
    }

    /// The cap refuses rather than evicting, deliberately: the user said the sentence that created
    /// each of these.
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

    /// **`loadWatchers` filters nothing.** An expired watcher owes the user a sentence, so it has to
    /// survive the read that would otherwise have hidden it.
    @Test
    func anExpiredWatcherStillLoads() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let longAgo = Date.fixture.addingTimeInterval(-StandingWatcherLimits.standard.maxLifetime * 2)
        try store.saveWatcher(sampleWatcher(id: "w1", subject: "the pricing page", createdAt: longAgo))

        #expect(try store.loadWatchers().map(\.id) == ["w1"])
    }

    /// Deleting a watcher that is not there changes nothing and does not rewrite the file — the
    /// no-op rule.
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
    /// decode**.
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

    /// A reading that comes back to the baseline drops the candidate — and **counts toward the
    /// instability rather than clearing it**, because a page that moved back is a page that moved
    /// (SONNY-390).
    ///
    /// **The reset is a check later, and the test asserts both halves**, because "does not reset" on
    /// its own is the rule that declared a page wobbling once a day unwatchable on check 146. What
    /// forgives an ordinary wobble is the *next* reading agreeing with this one.
    @Test
    func aReadingEqualToTheBaselineCountsTowardInstabilityAndTheNextAgreementClearsIt() {
        var watcher = sampleWatcher(id: "w1", subject: "the pricing page", baselineDigest: "base")
        watcher.candidateDigest = "moved"
        watcher.unstableReadings = 2

        let decision = StandingWatcherEvaluator.apply(reading: "base", to: watcher, now: .fixture)

        guard case .unchanged(let returned) = decision else {
            Issue.record("a reading equal to the baseline is not a change, got \(decision)")
            return
        }
        #expect(returned.candidateDigest == nil)
        #expect(returned.unstableReadings == 3, "the return to the baseline is itself a movement")
        #expect(returned.lastCheckedAt == .fixture)

        let settled = StandingWatcherEvaluator.apply(
            reading: "base",
            to: returned,
            now: .fixture.addingTimeInterval(900)
        )
        guard case .unchanged(let quiet) = settled else {
            Issue.record("a second baseline reading is not a change either, got \(settled)")
            return
        }
        #expect(quiet.unstableReadings == 0, "two consecutive readings that agree are what forgives")
        #expect(quiet.candidateDigest == nil)
    }

    /// **SONNY-390, the bug itself.** A page alternating between its baseline and one other reading
    /// is `.unwatchable` on the fourth check, where it used to be told nothing for seven days.
    ///
    /// The shipped `maxUnstableReadings` is used deliberately rather than a bounded fixture: the
    /// founders' requirement is four checks at the shipped limits, and a fixture that lowered the
    /// limit would assert a different sentence.
    @Test
    func anAlternatingPageIsUnwatchableOnTheFourthCheck() {
        var watcher = sampleWatcher(id: "w1", subject: "an alternating page", baselineDigest: "base")
        let readings = ["other", "base", "other", "base"]
        var stoppedOn: Int?
        var reason: StandingWatcherStopReason?

        for (index, reading) in readings.enumerated() {
            let decision = StandingWatcherEvaluator.apply(
                reading: reading,
                to: watcher,
                now: .fixture.addingTimeInterval(Double(index) * 900)
            )
            switch decision {
            case .pending(let next), .unchanged(let next):
                watcher = next
            case .stopped(_, let stopReason):
                stoppedOn = index + 1
                reason = stopReason
            case .notDue:
                Issue.record("apply never returns notDue")
            }
            if stoppedOn != nil { break }
        }

        #expect(stoppedOn == 4, "the four checks the ticket asks for, at the shipped limits")
        #expect(reason == .unwatchable)
    }

    /// **The forgiveness, at every rate the corpus measured.** A page that shows one different
    /// reading and then settles never accumulates: the counter is back at zero two checks after each
    /// wobble, so a watcher sees the same verdict — nothing — whether the page wobbles once a
    /// fortnight or once an hour.
    ///
    /// **This is the arm that fails on the rule the ticket proposed literally.** That rule reset only
    /// on a confirmed pair, and the corpus on SONNY-390 measured it declaring the once-a-day page
    /// unwatchable on check 146 and the hourly one on check 8.
    ///
    /// **The wobbles are placed by count and spread evenly, never by a modulus on the check index.**
    /// A watcher life is 672 checks at the shipped limits and a fortnight is 1344 of them, so
    /// `check % 1344` fires never and an archetype written that way is silently the steady page —
    /// which is what the corpus's first shape did, and this test is what caught it. The counts are
    /// wobbles per watcher life, and a life is 672 checks at fifteen minutes, which is **seven
    /// days**: so 1 is weekly, 2 twice a week, 7 daily, 168 hourly. (This said "1 is roughly
    /// fortnightly" — PR #209 review, F14. One per life is the conservative stand-in for a
    /// fortnightly page, since half of those lives carry no wobble at all and the informative case
    /// is the one that does, but the label was arithmetic and the arithmetic was wrong.)
    @Test(arguments: [1, 2, 7, 28, 84, 168])
    func aPageThatWobblesAndSettlesIsNeverCalledUnwatchable(wobblesPerLife: Int) {
        var watcher = sampleWatcher(id: "w1", subject: "a wobbling page", baselineDigest: "base")
        let life = 672
        let wobbleChecks = Set((0..<wobblesPerLife).map { (2 * $0 + 1) * life / (2 * wobblesPerLife) })

        for check in 0..<life {
            let reading = wobbleChecks.contains(check) ? "wobble\(check)" : "base"
            let decision = StandingWatcherEvaluator.apply(
                reading: reading,
                to: watcher,
                now: .fixture.addingTimeInterval(Double(check) * 900)
            )
            switch decision {
            case .pending(let next), .unchanged(let next):
                watcher = next
            case .stopped(_, let stopReason):
                Issue.record("\(wobblesPerLife) wobbles in a life stopped the watcher on check \(check + 1) as \(stopReason)")
                return
            case .notDue:
                Issue.record("apply never returns notDue")
                return
            }
        }

        #expect(watcher.unstableReadings < StandingWatcherLimits.standard.maxUnstableReadings)
        #expect(watcher.firstDifferenceAt != nil, "the wobbles really happened")
    }

    /// **Where the rule fails, pinned so it is a decision rather than a surprise.** The counter is a
    /// run length of consecutive differing readings, so **any four in a row end the watcher**,
    /// whatever produced them — and `main` carried every one of these sequences to expiry.
    ///
    /// **This test was named `onlyWobblesOneStableReadingApartEndTheWatcher`, and the "only" was
    /// false** (PR #209 review, F8). Three further shapes end a watcher and are asserted below; the
    /// `w, base, w, base` alternation is merely the one the ticket's own example reaches. A page
    /// that shows three different readings and then settles is arguably the more ordinary of the
    /// two, and a name promising it was safe is worse than no name at all.
    ///
    /// What is genuinely forgiven is a run that never reaches four: two wobbles two or more stable
    /// readings apart, and two adjacent wobbles that then settle. Both are asserted, because the
    /// finding is the boundary rather than "clustered wobbles are fatal".
    @Test
    func fourConsecutiveDifferingReadingsEndTheWatcherHoweverTheyArrive() {
        func verdict(_ readings: [String]) -> StandingWatcherStopReason? {
            var watcher = sampleWatcher(id: "w", subject: "a page", baselineDigest: "base")
            for (index, reading) in readings.enumerated() {
                let decision = StandingWatcherEvaluator.apply(
                    reading: reading,
                    to: watcher,
                    now: .fixture.addingTimeInterval(Double(index) * 900)
                )
                switch decision {
                case .pending(let next), .unchanged(let next):
                    watcher = next
                case .stopped(_, let reason):
                    return reason
                case .notDue:
                    return nil
                }
            }
            return nil
        }

        // Four in a row, four ways in. Every one of these reads `nothing` under the rule on `main`.
        #expect(verdict(["w1", "base", "w2", "base", "base"]) == .unwatchable, "one stable reading apart")
        #expect(verdict(["w1", "w2", "w3", "base", "base"]) == .unwatchable, "three adjacent, then settles")
        #expect(verdict(["w1", "w2", "base", "w3", "base", "base"]) == .unwatchable, "two adjacent, one apart")
        #expect(verdict(["w1", "base", "w2", "w3", "base", "base"]) == .unwatchable, "one apart, two adjacent")
        // And the runs that stop at three.
        #expect(verdict(["w1", "base", "base", "w2", "base", "base"]) == nil, "two apart is forgiven")
        #expect(verdict(["w1", "w2", "base", "base"]) == nil, "two adjacent, then settles, is forgiven")
    }

    /// **The two-reading rule is untouched, which the ticket puts out of scope.** A real change is
    /// still notified on the second identical reading, and a wobble earlier in the watcher's life
    /// does not delay or prevent it.
    @Test
    func aRealChangeIsStillConfirmedOnTheSecondIdenticalReadingAfterAWobble() {
        var watcher = sampleWatcher(id: "w1", subject: "the pricing page", baselineDigest: "base")

        for (index, reading) in ["wobble", "base", "base", "moved"].enumerated() {
            let decision = StandingWatcherEvaluator.apply(
                reading: reading,
                to: watcher,
                now: .fixture.addingTimeInterval(Double(index) * 900)
            )
            switch decision {
            case .pending(let next), .unchanged(let next):
                watcher = next
            default:
                Issue.record("check \(index + 1) should not have stopped the watcher, got \(decision)")
                return
            }
        }

        let confirmed = StandingWatcherEvaluator.apply(
            reading: "moved",
            to: watcher,
            now: .fixture.addingTimeInterval(3600)
        )
        guard case .stopped(let settled, let reason) = confirmed else {
            Issue.record("the second identical reading confirms the change, got \(confirmed)")
            return
        }
        #expect(reason == .changed)
        #expect(settled.baselineDigest == "moved")
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
    /// The case it is about is a page that saw one difference and settled back. Since SONNY-390 the
    /// page that alternates *forever* stops as `.unwatchable` instead of reaching expiry, so the
    /// population reaching `.expired` with a difference behind it is the wobbler — which is exactly
    /// the record built below, and the sentence is owed to it for the same reason.
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

        // One difference, then back to the baseline twice — the wobbler, run to the point where the
        // counter has been forgiven and `candidateDigest` cleared, which is where every field that
        // could answer "did anything ever move" reads as it did at creation.
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
        guard case .unchanged(let settledAgain) = StandingWatcherEvaluator.apply(
            reading: "base", to: backToBaseline, now: .fixture.addingTimeInterval(1800)
        ) else {
            Issue.record("a second baseline reading is unchanged")
            return
        }
        flickered = settledAgain
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

    private func makeStore(root: URL, limits: StandingWatcherLimits = .standard) -> ResumableTaskStore {
        ResumableTaskStore(
            fileURL: root.appendingPathComponent("watchers.json"),
            encryption: testEncryption(),
            limits: limits
        )
    }
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
