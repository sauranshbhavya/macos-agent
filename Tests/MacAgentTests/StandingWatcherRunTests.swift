import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// The standing watcher as the app actually runs it (SONNY-236): the checker on the shared pulse,
/// what it fetches, what it writes back, and what it says.
///
/// **Driven through `checkStandingWatchers`, the method the timer calls, rather than through the
/// evaluator.** The evaluator's own state machine is asserted in `MacAgentCoreTests` where it has no
/// clock and no disk; what this suite is for is the wiring around it — that the record is written
/// back, that a finished watcher is deleted, that the notice reaches the channel the notification
/// sinks, and that a not-due watcher costs no request.
@MainActor
struct StandingWatcherRunTests {
    /// A watcher that is due is read, and a page that has not moved leaves it running with nothing
    /// said.
    ///
    /// **The control is the observer's own call count.** "No notice was published" is satisfied just
    /// as well by a check that never happened, which is the failure this whole suite is most exposed
    /// to — every other assertion here would still pass.
    @Test
    func anUnchangedPageIsReadAndSaysNothing() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.answer(with: "Price: £40  In stock")
        // `createdAt` on the same clock the pulse is given: a fixture created at the real `Date()`
        // and checked at a fixed 2027 instant is simply expired, which is the watcher working and
        // not what this test is about.
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.store.saveWatcher(
            watcher(baselineDigest: digest(of: "Price: £40 In stock"), createdAt: checkedAt)
        )

        await fixture.check(now: checkedAt)

        #expect(observer.callCount == 1)
        #expect(fixture.viewModel.watcherNotice == nil)
        let remaining = try fixture.store.loadWatchers()
        #expect(remaining.count == 1)
        let updated = try #require(remaining.first)
        #expect(updated.candidateDigest == nil)
        // **The clock the pulse was given is the clock the record carries** (PR #184 review, R3).
        // `!= nil` was the assertion here, and it holds against the defect this branch shipped for
        // one commit — due-ness decided on the injected clock while `lastCheckedAt` was stamped from
        // `Date()`. The three tests that caught that only failed once real time had drifted past the
        // injected clock by more than a second, which is why this lane's own filtered run was green.
        // This is the deterministic version: equality, through the view model, on the value the test
        // chose.
        #expect(updated.lastCheckedAt == checkedAt)
    }

    /// **The ad-slot property, through the real path.** A first difference writes a candidate and
    /// says nothing; the second identical reading fires and the watcher is gone.
    @Test
    func aChangeFiresOnlyOnTheSecondIdenticalReadingAndThenTheWatcherIsGone() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        try fixture.store.saveWatcher(watcher(baselineDigest: digest(of: "Price: £40")))

        observer.answer(with: "Price: £45")
        await fixture.check()

        #expect(fixture.viewModel.watcherNotice == nil, "a first difference must not notify")
        let pending = try #require(try fixture.store.loadWatchers().first)
        #expect(pending.candidateDigest == digest(of: "Price: £45"))

        // Past the check interval, or the second check is simply not due.
        await fixture.check(now: Date().addingTimeInterval(StandingWatcherLimits.standard.checkInterval + 1))

        #expect(fixture.viewModel.watcherNotice == "“the pricing page” changed.")
        #expect(try fixture.store.loadWatchers().isEmpty)
        #expect(observer.callCount == 2)
    }

    /// A page that reads differently every time is given up on rather than polled for a week and
    /// then reported as unchanged, which would be false about a page that never stopped moving.
    @Test
    func aChurningPageIsGivenUpOnAndSaysWhy() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        try fixture.store.saveWatcher(watcher(baselineDigest: digest(of: "steady")))

        var clock = Date()
        for index in 0..<StandingWatcherLimits.standard.maxUnstableReadings {
            observer.answer(with: "advertisement \(index)")
            await fixture.check(now: clock)
            clock = clock.addingTimeInterval(StandingWatcherLimits.standard.checkInterval + 1)
        }

        let notice = try #require(fixture.viewModel.watcherNotice)
        #expect(notice.contains("reads differently every time"))
        #expect(notice.contains("did not change") == false, "that would be false about a page that kept moving")
        #expect(try fixture.store.loadWatchers().isEmpty)
    }

    /// A failed fetch is tolerated and says nothing; enough of them in a row stops the watcher and
    /// says the page could not be read.
    ///
    /// **The tolerance half is the assertion that matters.** A notification per flaky fetch would be
    /// worse than the silence it replaced, and nothing else in the suite would catch it.
    @Test
    func failedReadsAreSilentUntilTheyAreNotAndThenSayThePageCouldNotBeRead() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        try fixture.store.saveWatcher(watcher(baselineDigest: digest(of: "steady")))
        observer.answerByFailing()

        var clock = Date()
        for _ in 0..<(StandingWatcherLimits.standard.maxConsecutiveFailures - 1) {
            await fixture.check(now: clock)
            #expect(fixture.viewModel.watcherNotice == nil, "a tolerated failure must say nothing")
            clock = clock.addingTimeInterval(StandingWatcherLimits.standard.checkInterval + 1)
        }
        // Still running, and its failure run has been recorded rather than forgotten each time.
        let stillThere = try #require(try fixture.store.loadWatchers().first)
        #expect(stillThere.consecutiveFailures == StandingWatcherLimits.standard.maxConsecutiveFailures - 1)

        await fixture.check(now: clock)

        #expect(fixture.viewModel.watcherNotice == "Sonny stopped watching “the pricing page”. The page could not be read.")
        #expect(try fixture.store.loadWatchers().isEmpty)
    }

    /// A watcher whose lifetime ran out is retired with a sentence, and **without a fetch** — the
    /// property that keeps an expired watcher from costing a request.
    @Test
    func anExpiredWatcherIsRetiredWithoutReadingThePage() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        let created = Date().addingTimeInterval(-(StandingWatcherLimits.standard.maxLifetime + 60))
        try fixture.store.saveWatcher(watcher(baselineDigest: "base", createdAt: created))

        await fixture.check()

        #expect(observer.callCount == 0, "an expired watcher must not cost a request")
        let notice = try #require(fixture.viewModel.watcherNotice)
        #expect(notice == "Sonny stopped watching “the pricing page” after 7 days. It did not change.")
        #expect(try fixture.store.loadWatchers().isEmpty)
    }

    /// A watcher that is not due yet costs no request either — the other half of the same property,
    /// and the one that runs on every one of the 30-second pulses between checks.
    @Test
    func aWatcherThatIsNotDueCostsNoRequest() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.answer(with: "Price: £40")
        try fixture.store.saveWatcher(watcher(baselineDigest: digest(of: "Price: £40")))

        let start = Date()
        await fixture.check(now: start)
        #expect(observer.callCount == 1)

        // A minute later — a pulse, but not a check.
        await fixture.check(now: start.addingTimeInterval(60))
        #expect(observer.callCount == 1)
    }

    /// **A watcher is not blocked by a task in flight, and that is the decision rather than an
    /// oversight** (SONNY-236). `checkScheduledRoutines` refuses while `isRunning`, because it starts
    /// a task; a watcher starts none, and inheriting that guard would make every watcher blind for
    /// the length of every command the user runs.
    ///
    /// The control is `checkScheduledRoutines` in the same state, which really does refuse.
    @Test
    func aWatcherIsCheckedWhileATaskIsRunningEvenThoughARoutineWouldNotBe() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.answer(with: "Price: £40")
        try fixture.store.saveWatcher(watcher(baselineDigest: digest(of: "Price: £40")))
        fixture.viewModel.isRunning = true

        await fixture.check()

        #expect(observer.callCount == 1, "a watcher does not start a task and must not be gated on one")

        // The control: the same state, the same pulse, and the routine checker declines to act.
        try fixture.routineStore.save(scheduledRoutineDueNow())
        fixture.viewModel.checkScheduledRoutines()
        #expect(fixture.viewModel.scheduledRunNotice == nil)
    }

    /// A watcher notice never reaches `errorMessage`, because there is no task to have failed and the
    /// widget ranks a failure above a result — a notice routed there would blank the result of
    /// whatever the user actually ran.
    @Test
    func aWatcherNoticeNeverLandsOnTheTasksOwnFailureChannel() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.answerByFailing()
        try fixture.store.saveWatcher(watcher(baselineDigest: "base"))

        var clock = Date()
        for _ in 0..<StandingWatcherLimits.standard.maxConsecutiveFailures {
            await fixture.check(now: clock)
            clock = clock.addingTimeInterval(StandingWatcherLimits.standard.checkInterval + 1)
        }

        // The control: the notice really was published, so `errorMessage` being nil is about the
        // channel rather than about nothing having happened.
        #expect(fixture.viewModel.watcherNotice != nil)
        #expect(fixture.viewModel.errorMessage == nil)
    }

    /// One watcher per pulse, oldest first — five coming due together are five requests spread over
    /// five pulses rather than five at once against somebody else's server.
    @Test
    func onlyOneWatcherIsCheckedPerPulseAndTheOldestGoesFirst() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.answer(with: "unchanged")
        let start = Date()
        try fixture.store.saveWatcher(
            watcher(id: "old", subject: "the older page", baselineDigest: digest(of: "unchanged"), createdAt: start.addingTimeInterval(-100))
        )
        try fixture.store.saveWatcher(
            watcher(id: "new", subject: "the newer page", baselineDigest: digest(of: "unchanged"), createdAt: start)
        )

        await fixture.check(now: start)

        #expect(observer.callCount == 1)
        #expect(observer.urlsRead.count == 1)
        // The oldest is the one that was checked: it now has a `lastCheckedAt` and the other does not.
        let watchers = try fixture.store.loadWatchers()
        #expect(try #require(watchers.first { $0.id == "old" }).lastCheckedAt != nil)
        #expect(try #require(watchers.first { $0.id == "new" }).lastCheckedAt == nil)
    }

    // MARK: - The three findings of PR #184's review

    /// **F1 — a watcher notice reaches the user even when Sonny is the app they are in.**
    ///
    /// The four older notification channels are gated on `!isUserWorkingInSonny`, and for them the
    /// gate is free: whatever it suppresses is already on a Sonny surface. `watcherNotice` is
    /// rendered by no view, and `finishStandingWatcher` publishes the sentence and then deletes the
    /// record — so a gate here was not deduplication, it was deletion, in what is arguably the
    /// feature's most common case.
    ///
    /// Asserted by reading the wiring, because `SonnyNotificationService.init?` returns nil without
    /// bundle identity and the subscription does not exist in a test process. The **control** is the
    /// neighbouring channels in the same file: they still carry the guard, so a zero here is this
    /// channel's asymmetry rather than the sweep failing to find a guard anywhere.
    @Test
    func theWatcherChannelIsTheOneWithNoIsUserWorkingInSonnyGate() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let subscription = try MacAgentSource.region(
            of: delegate,
            from: "viewModel.$watcherNotice",
            to: ".store(in: &cancellables)"
        )
        #expect(!subscription.contains("isUserWorkingInSonny"))

        for gated in ["viewModel.$scheduledRunNotice", "viewModel.$localStorageNotice", "viewModel.$errorMessage"] {
            let other = try MacAgentSource.region(of: delegate, from: gated, to: ".store(in: &cancellables)")
            #expect(
                other.contains("!isUserWorkingInSonny"),
                "\(gated) lost its gate — the watcher channel's exemption is only meaningful beside them"
            )
        }
    }

    /// **F2 — a wipe pressed while a check is in flight is not undone by that check's write-back.**
    ///
    /// `deleteLocalData` guards on `!isRunning`, and a watcher check deliberately does not set it,
    /// so the fetch outlives the wipe. Without the fix `saveWatcher` finds a missing file, creates
    /// the directory and writes the watcher back — a user who pressed delete-all-local-data gets
    /// their watchers returned, which is a privacy failure rather than an ordering bug.
    ///
    /// The **control** is the precondition: the wipe really did unlink the file and `loadWatchers()`
    /// really was empty, so the final assertion is about the write-back and not about a delete that
    /// never happened.
    @Test
    func aWipeDuringAnInFlightCheckIsNotUndoneByIt() async throws {
        let fixture = try makeWatcherFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.holdTheAnswer()
        try fixture.store.saveWatcher(watcher(baselineDigest: digest(of: "steady")))

        await fixture.startCheck(now: Date())
        #expect(observer.callCount == 1, "the check must be in flight for this to test anything")

        fixture.viewModel.deleteLocalData()
        // The press is asynchronous since SONNY-404's fix round: it drains the deletion queue and
        // deletes the account's server-side content before it touches a local file.
        await fixture.viewModel.localDataWipeForTests?.value
        #expect(try fixture.store.loadWatchers().isEmpty, "precondition: the wipe took the file")
        #expect(FileManager.default.fileExists(atPath: fixture.store.fileURL.path) == false)

        // Now let the page answer, after the wipe. **`settle()`, not `awaitStandingWatcherCheck()`**
        // — the wipe cleared the handle that one awaits, so it would return before the late answer
        // ran and this test would pass with the generation guard deleted (W14).
        observer.releaseTheAnswer(with: "steady")
        await fixture.settle()

        #expect(try fixture.store.loadWatchers().isEmpty, "the wipe was undone by a check in flight")
        #expect(FileManager.default.fileExists(atPath: fixture.store.fileURL.path) == false)
    }

    /// **F3 — one page that never answers does not stop every other watcher.**
    ///
    /// The re-entrancy slot was cleared only by the task body finishing and nothing bounded the
    /// fetch, so a page that never answers parked it permanently: every later pulse returned at the
    /// guard, no failure was ever recorded, and `maxConsecutiveFailures` could not end the stalled
    /// watcher either — the cap written to stop a dead page occupying a watcher was unreachable.
    ///
    /// Driven entirely on the injected clock: the abandonment is decided by comparing the pulse's own
    /// `now` against the check's start, so nothing here races a timer.
    @Test
    func onePageThatNeverAnswersIsAbandonedAndDoesNotStopTheOthers() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.holdTheAnswer()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.store.saveWatcher(
            watcher(id: "stalled", subject: "a page that never answers", baselineDigest: "base", createdAt: start.addingTimeInterval(-100))
        )
        try fixture.store.saveWatcher(
            watcher(id: "healthy", subject: "a page that answers", baselineDigest: digest(of: "steady"), createdAt: start)
        )

        await fixture.startCheck(now: start)
        #expect(observer.callCount == 1)

        // A pulse inside the bound changes nothing: the slot is still legitimately held.
        fixture.viewModel.checkStandingWatchers(now: start.addingTimeInterval(30))
        #expect(observer.callCount == 1)

        // A pulse at the bound abandons it, records a failed reading against the stalled watcher,
        // and frees the slot.
        observer.releaseTheAnswer(with: "steady")
        await fixture.check(now: start.addingTimeInterval(StandingWatcherLimits.standard.checkTimeout))

        let watchers = try fixture.store.loadWatchers()
        let stalled = try #require(watchers.first { $0.id == "stalled" })
        #expect(stalled.consecutiveFailures == 1, "an abandoned check must count, or the cap cannot end it")
        #expect(observer.callCount >= 2, "the other watcher must become reachable again")
    }

    /// And the late answer from an abandoned check writes nothing — the half of F2 and F3 that
    /// cancellation alone cannot do, since a cancelled `Task` still runs its continuation and the
    /// observer may ignore cancellation entirely.
    @Test
    func aStalledCheckThatAnswersLateWritesNothing() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.holdTheAnswer()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.store.saveWatcher(watcher(baselineDigest: "base", createdAt: start))

        await fixture.startCheck(now: start)
        fixture.viewModel.checkStandingWatchers(now: start.addingTimeInterval(StandingWatcherLimits.standard.checkTimeout))
        // The abandonment recorded one failure. Whatever the stalled fetch says now must not add to
        // it, and must not promote anything.
        let afterAbandon = try #require(try fixture.store.loadWatchers().first)
        #expect(afterAbandon.consecutiveFailures == 1)

        // Same reason as the wipe test above: the abandonment cleared the handle, so the only honest
        // way to let the late answer run is to spin the actor.
        observer.releaseTheAnswer(with: "something entirely different")
        await fixture.settle()

        let settled = try #require(try fixture.store.loadWatchers().first)
        #expect(settled.consecutiveFailures == 1, "the late answer wrote back")
        #expect(settled.candidateDigest == nil, "the late answer promoted a reading")
        #expect(fixture.viewModel.watcherNotice == nil)
    }

    /// **`checkTimeout` and `checkInterval` compose in the build the founders actually run, not only
    /// in the shipped one** (PR #184 review; the same class of defect as F6).
    ///
    /// Shipped, `checkInterval` is 900s and `checkTimeout` 60s, so a check is always abandoned long
    /// before the next interval and the two never interact. The manual rows instruct
    /// `checkInterval: 30`, which **inverts** that: a check may now outlive two intervals. The
    /// inversion exists only in the founders' build, which is exactly where nobody re-derives the
    /// numbers — so it is asserted here rather than reasoned about.
    ///
    /// The three steps, on the injected clock: a pulse inside the timeout starts no second fetch; the
    /// pulse at the timeout abandons exactly once and records one failure; and the watcher's cadence
    /// is then set by the timeout rather than by the interval.
    @Test
    func theCheckTimeoutAndTheCheckIntervalComposeInTheShortenedBuild() async throws {
        let fixture = try makeWatcherFixture()
        defer { fixture.cleanUp() }
        let observer = fixture.observer
        observer.holdTheAnswer()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.store.saveWatcher(watcher(baselineDigest: "base", createdAt: start))

        await fixture.startCheck(now: start)
        #expect(observer.callCount == 1)

        // A pulse at one shortened interval: the slot is held, and nothing else is asked.
        fixture.viewModel.checkStandingWatchers(now: start.addingTimeInterval(30))
        await fixture.settle()
        #expect(observer.callCount == 1, "a second fetch started while one was in flight")
        #expect(try fixture.store.loadWatchers().first?.consecutiveFailures == 0, "abandoned too early")

        // A pulse at two shortened intervals, which is the timeout: abandoned exactly once.
        fixture.viewModel.checkStandingWatchers(now: start.addingTimeInterval(60))
        await fixture.settle()
        let afterTimeout = try #require(try fixture.store.loadWatchers().first)
        #expect(afterTimeout.consecutiveFailures == 1, "the abandonment did not record exactly one failure")

        // **The third step, which this test's own doc comment promised and its body did not assert**
        // (PR #184 cycle 3, N2). The abandonment stamps `lastCheckedAt`, and due-ness is measured
        // from that — so the next check is `checkTimeout + checkInterval` after the last one, not
        // `checkTimeout`. The missing assertion is exactly what let the manual row say "retried on
        // the timeout" for a round.
        let abandonedAt = try #require(afterTimeout.lastCheckedAt)
        #expect(abandonedAt == start.addingTimeInterval(60), "the abandonment stamps the pulse it happened on")
        let interval = StandingWatcherLimits.standard.checkInterval
        #expect(
            StandingWatcherEvaluator.isDue(afterTimeout, now: abandonedAt.addingTimeInterval(interval - 1)) == false,
            "a hanging page became due before a full interval had passed since its abandonment"
        )
        #expect(
            StandingWatcherEvaluator.isDue(afterTimeout, now: abandonedAt.addingTimeInterval(interval)),
            "a hanging page never becomes due again"
        )
    }

    /// **N1 — a watcher whose delete keeps failing says its sentence once, not once per pulse**
    /// (PR #184 cycle 3).
    ///
    /// The reviewer measured 11 notices across 11 pulses against a read-only store directory: the
    /// delete throws, the record survives, and because expiry is decided *before* due-ness the
    /// expired branch re-fires on the 30-second pulse rather than the check interval. Nothing
    /// downstream coalesces them, and F1 removed the gate that had been damping it.
    ///
    /// The **control** is the first pulse: the notice really is published once, so a count of one is
    /// the guard working rather than the notice never arriving.
    @Test
    func aWatcherWhoseDeleteKeepsFailingSaysItOnce() async throws {
        let fixture = try makeWatcherFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
            fixture.cleanUp()
        }
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        try fixture.store.saveWatcher(
            watcher(
                id: "expired",
                subject: "a page nobody came back to",
                baselineDigest: "base",
                createdAt: start.addingTimeInterval(-(StandingWatcherLimits.standard.maxLifetime + 60))
            )
        )
        // Reads still work; the rewrite the delete needs does not.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.root.path)

        var notices = 0
        for tick in stride(from: 0, through: 300, by: 30) {
            fixture.viewModel.watcherNotice = nil
            await fixture.check(now: start.addingTimeInterval(Double(tick)))
            if fixture.viewModel.watcherNotice != nil {
                notices += 1
            }
        }

        #expect(notices == 1, "the watcher notified \(notices) times across 11 pulses")
        // And the record really did survive, so this is the guard rather than a delete that worked.
        #expect(try fixture.store.loadWatchers().count == 1)
    }

    // MARK: - The notification channel

    /// **The watcher notice posts through its own actionless category, and the actionless part is a
    /// founder decision rather than a UI preference** (SONNY-236).
    ///
    /// A watcher notifies and does nothing else — it may not open, write, send, file, delete or run
    /// anything — so a button on this banner is not a nicety somebody forgot, it is the route to
    /// acting the founders declined. The `error` category's Retry would have supplied one without
    /// anybody choosing to, and it runs `retryLastCommand()`, which re-dispatches the user's own last
    /// submitted command: a task with no relationship to the watched page.
    ///
    /// Asserted by reading the wiring because it cannot be asserted by running it, the same reason
    /// `theScheduledNoticePostsThroughItsOwnActionlessCategory` gives: `SonnyNotificationService.init?`
    /// returns nil without bundle identity, so the subscription this pins does not exist in a test
    /// process at all. This is the one manual-test row a founder owes that no agent can stand in for.
    @Test
    func theWatcherNoticePostsThroughItsOwnCategoryAndThatCategoryOffersNothingToPress() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let subscription = try MacAgentSource.region(
            of: delegate,
            from: "viewModel.$watcherNotice",
            to: ".store(in: &cancellables)"
        )
        #expect(subscription.contains("postWatcherNotification"))
        #expect(!subscription.contains("postErrorNotification"))
        #expect(!subscription.contains("postScheduledRunNotification"))

        let service = try MacAgentSource.read("SonnyNotificationService.swift")
        let watcherCategory = try MacAgentSource.region(
            of: service,
            from: "identifier: SonnyNotificationCategory.watcher,",
            to: ")"
        )
        #expect(watcherCategory.contains("actions: [],"))
        #expect(!watcherCategory.contains("retryAction"))
        #expect(!watcherCategory.contains("allowAction"))

        // The click opens Command Center — a place to look, rather than a thing done on the user's
        // behalf, which is the only kind of response this notification may have.
        #expect(service.contains("case SonnyNotificationCategory.watcher:"))
        #expect(service.contains("self?.onOpenWatcherNotice()"))
        let wiring = try MacAgentSource.region(
            of: delegate,
            from: "onOpenWatcherNotice: { [weak self] in",
            to: "}"
        )
        #expect(wiring.contains("showCommandCenter()"))
    }

    // MARK: - Fixtures

    private func digest(of text: String) -> String {
        StandingWatcherEvaluator.digest(of: text)
    }

    private func watcher(
        id: String = "w1",
        subject: String = "the pricing page",
        baselineDigest: String,
        createdAt: Date = Date()
    ) -> StandingWatcher {
        StandingWatcher(
            id: id,
            subject: subject,
            url: URL(string: "https://example.com/pricing")!,
            createdAt: createdAt,
            baselineDigest: baselineDigest
        )
    }

    private func scheduledRoutineDueNow() -> StoredRoutine {
        StoredRoutine(
            name: "Morning",
            steps: [
                AgentStep(id: "calc", operation: .calculateUtility, description: "Add them up.", searchQuery: "2 + 2")
            ],
            schedule: RoutineSchedule(
                cadence: .daily,
                hour: 0,
                minute: 0,
                isEnabled: true,
                unattendedTrusted: false,
                lastRunAt: nil
            )
        )
    }
}

/// The view model, its watcher store and the observer it reads through, all at a temporary root.
///
/// **`check(now:)` is the whole reason this is a type rather than a function.** `checkStandingWatchers`
/// starts the fetch in a `Task` and returns, because the pulse that calls it must not block the main
/// actor for the length of an HTTP request — so a test that called it and asserted immediately would
/// be asserting against a check that had not happened yet. Waiting on the view model's own task
/// handle is what makes the assertions describe a finished check rather than a race the test usually
/// wins.
@MainActor
private struct WatcherFixture {
    let viewModel: AgentViewModel
    let store: ResumableTaskStore
    let routineStore: RoutineStore
    let observer: WatcherObserverStub
    let root: URL

    func check(now: Date = Date()) async {
        viewModel.checkStandingWatchers(now: now)
        await viewModel.awaitStandingWatcherCheck()
    }

    /// Spins this actor a bounded number of times so an *abandoned* check's continuation can run.
    ///
    /// **`awaitStandingWatcherCheck()` cannot be used for that, and the battery is what proved it.**
    /// It awaits `standingWatcherCheck?.value`, and abandoning a check sets that handle to `nil` — so
    /// after a wipe or a stall it returns immediately, before the late answer has been processed.
    /// A test asserting there and then passes whether or not the generation guard exists, which is
    /// exactly what W14 ("an abandoned check writes back anyway") showed: the test written for that
    /// property did not kill it, and the mutant survived that test while being caught elsewhere.
    ///
    /// Yields rather than sleeps, for the reason `startCheck` gives — there is no threshold here to
    /// lose a race against, and the assertions afterwards are what fail if the count were too small.
    func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }

    /// Starts a check and returns once the observer has actually been asked — for the tests about a
    /// check that is *in flight*, which cannot await the task because the answer is being withheld
    /// on purpose.
    ///
    /// **Bounded by yields rather than by a clock.** `checkStandingWatchers` schedules a `Task` on
    /// this actor and returns, so the body has not run when it does; a test asserting immediately
    /// reads a call count of zero. Spinning the actor a fixed number of times is deterministic —
    /// there is no wall-clock threshold to lose a race against, which is the trap
    /// `asyncProcessRunnerCancelsRunningProcess` is written down for. The count is generous and the
    /// assertion afterwards is what fails if it were ever too small.
    func startCheck(now: Date) async {
        let before = observer.callCount
        viewModel.checkStandingWatchers(now: now)
        for _ in 0..<100 where observer.callCount == before {
            await Task.yield()
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeWatcherFixture(wipesRealStoreFiles: Bool = false) throws -> WatcherFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StandingWatcherRunTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encryption = LocalStorageEncryption(keyManager: WatcherFixtureKeyManager())
    let store = ResumableTaskStore(
        fileURL: root.appendingPathComponent("resumable-tasks.json"),
        encryption: encryption
    )
    let routineStore = RoutineStore(
        fileURL: root.appendingPathComponent("routines.json"),
        encryption: encryption
    )
    let observer = WatcherObserverStub()
    let clipboardSettingsStore = ClipboardHistorySettingsStore(
        fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
        encryption: encryption
    )
    let viewModel = AgentViewModel(
        routineStore: routineStore,
        // Everything this suite does not exercise goes to an unreachable root rather than to this
        // fixture's own: a store named here is one an assertion could accidentally be about.
        workspaceStore: UnreachableLocalStores.workspaces(),
        snippetStore: UnreachableLocalStores.snippets(),
        recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
        finderRevealer: { _ in },
        shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
        taskHistoryStore: UnreachableLocalStores.taskHistory(),
        taskPlanDetailStore: UnreachableLocalStores.taskPlanDetails(),
        visionSessionJournalStore: UnreachableLocalStores.visionSessionJournal(),
        clipboardHistorySettingsStore: clipboardSettingsStore,
        approvedAppStore: UnreachableLocalStores.approvedApps(),
        outputLocationStore: UnreachableLocalStores.outputLocations(),
        resumableTaskStore: store,
        pendingServerDeletionStore: PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json")
        ),
        skillSelectionStore: SkillSelectionStore(
            fileURL: root.appendingPathComponent("added-skills.json")
        ),
        standingWatcherObserver: observer,
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            store: UnreachableLocalStores.clipboardHistory(),
            settingsStore: clipboardSettingsStore
        ),
        // Empty by default, so no test can wipe anything it did not ask to; the F2 test opts in and
        // names exactly the one file it is about.
        localDataDeletionService: LocalDataDeletionService(fileURLs: wipesRealStoreFiles ? [store.fileURL] : []),
        backendClient: makeHermeticBackendClient(),
        userDefaults: UserDefaults(suiteName: "StandingWatcherRunTests-\(UUID().uuidString)") ?? .standard
    )
    return WatcherFixture(
        viewModel: viewModel,
        store: store,
        routineStore: routineStore,
        observer: observer,
        root: root
    )
}

private struct WatcherFixtureKeyManager: LocalStorageKeyManaging {
    func keyData() throws -> Data {
        Data(repeating: 0x3C, count: 32)
    }
}

/// An observer a test drives, counting what it was asked for.
///
/// **`@MainActor`, because `StandingWatcherObserving` is.** An `actor` would have been the reflex for
/// a stub with a mutable counter read from a spawned task, and it does not compile here — an actor
/// cannot conform to a globally-isolated protocol. It is also unnecessary: the protocol's isolation
/// is `PublicWebPageLoader.load`'s own, the checker's task hops to the main actor to call it, and the
/// test reads the counter there too, so there is one actor and no race to protect against.
@MainActor
final class WatcherObserverStub: StandingWatcherObserving {
    private var reply: Result<String, any Error> = .failure(StubError.notConfigured)
    private(set) var callCount = 0
    private(set) var urlsRead: [URL] = []
    private var held = false
    private var pending: [CheckedContinuation<String, Never>] = []

    enum StubError: Error, Equatable { case notConfigured, refused }

    func answer(with text: String) {
        reply = .success(text)
    }

    func answerByFailing() {
        reply = .failure(StubError.refused)
    }

    /// The next read blocks until `releaseTheAnswer` — a page that has not answered *yet*, which is
    /// what F2 and F3 are both about and what no `Result` can express.
    ///
    /// A continuation rather than a sleep: the test decides when the page answers, so nothing here
    /// races a clock. `CheckedContinuation` also traps on a double resume, which is the failure a
    /// hand-rolled flag would make silent.
    func holdTheAnswer() {
        held = true
    }

    func releaseTheAnswer(with text: String) {
        held = false
        reply = .success(text)
        let waiting = pending
        pending = []
        for continuation in waiting {
            continuation.resume(returning: text)
        }
    }

    func readableText(at url: URL) async throws -> String {
        callCount += 1
        urlsRead.append(url)
        guard held else {
            return try reply.get()
        }
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
        }
    }
}
