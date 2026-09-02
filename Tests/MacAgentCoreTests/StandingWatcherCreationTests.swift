import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Starting a watcher — the half SONNY-236 deliberately left out (SONNY-382).
///
/// **Driven through `AgentActionExecutor.execute`, the real dispatch path**, rather than by calling
/// the adapter directly. The thing that was missing before this ticket was not an adapter, it was a
/// *route*: nothing in `Sources/` constructed a `StandingWatcher`. A suite that called
/// `StandingWatcherCapabilityAdapter().execute(...)` would pass with the operation unregistered,
/// unrouted in the executor's workflow switch and invisible to the planner — which is the whole
/// defect it is supposed to be about.
@MainActor
struct StandingWatcherCreationTests {
    private static let watchedURL = "https://example.com/status"

    /// The plan a planner emits for "tell me when this page changes".
    private func watchPlan(
        url: String = watchedURL,
        subject: String? = "the order status"
    ) -> AgentPlan {
        AgentPlan(
            summary: "Watch a page.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "s1",
                    operation: .startWatching,
                    description: "Watch the status page.",
                    targetURL: url,
                    watchSubject: subject
                )
            ]
        )
    }

    private func makeStore() throws -> (ResumableTaskStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StandingWatcherCreationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")), root)
    }

    private func makeExecutor(
        store: ResumableTaskStore,
        page: String = "Status: pending",
        failing: Bool = false,
        memoryRecording: MemoryRecordingSettings = .recordEverything,
        whitelist: PathWhitelist = PathWhitelist(),
        fetcher: (any WebPageFetching)? = nil,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            memoryRecording: memoryRecording,
            whitelist: whitelist,
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            webPageLoader: PublicWebPageLoader(
                fetcher: fetcher ?? OneWatchedPageFetcher(text: page, failing: failing),
                robotsChecker: AllowEveryPage(),
                extractor: OneWatchedPageExtractor(text: page)
            ),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            resumableTaskStore: store,
            now: { now }
        )
    }

    /// The whole point of the ticket: a plan the planner can emit turns into a watcher the checker
    /// will pick up.
    ///
    /// **The baseline is asserted by value against the page's own text**, not merely for being
    /// non-empty. A watcher whose baseline is the digest of `""` differs from every real reading, so
    /// its very next check records a candidate and the one after that reports a change that never
    /// happened — the failure mode a not-nil assertion here would wave through.
    @Test
    func askingSonnyToWatchAPageStoresAWatcherWhoseBaselineIsThatPagesReading() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let executor = makeExecutor(store: store, page: "Status: pending", now: startedAt)

        let result = try await executor.execute(plan: watchPlan(), log: { _, _ in })

        let watchers = try store.loadWatchers()
        #expect(watchers.count == 1)
        let watcher = try #require(watchers.first)
        #expect(watcher.subject == "the order status")
        #expect(watcher.url.absoluteString == Self.watchedURL)
        #expect(watcher.baselineDigest == StandingWatcherEvaluator.digest(of: "Status: pending"))
        // Never checked yet, so the first pulse that sees it checks it rather than waiting out an
        // interval — `StandingWatcherEvaluator.isDue`'s nil branch.
        #expect(watcher.lastCheckedAt == nil)
        #expect(watcher.candidateDigest == nil)
        #expect(watcher.firstDifferenceAt == nil)
        #expect(watcher.createdAt == startedAt)
        #expect(result.summary == "Sonny is watching \u{201C}the order status\u{201D}.")
    }

    /// **The approval says what it will cost**, which for this operation is not the one write but
    /// the standing consequence: somebody else's server fetched on a timer for a week.
    ///
    /// Asserted against the cap rather than against literal words, so shortening `checkInterval` for
    /// a manual pass cannot leave the panel quoting the shipped number.
    @Test
    func theApprovalNamesWhatIsWatchedAndTheCadenceItWillBeCheckedOn() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(store: store)

        let prepared = try executor.prepare(plan: watchPlan())
        let preview = try #require(prepared.previews.first)

        #expect(preview.title == "Watch https://example.com/status")
        #expect(preview.details.contains("Watching for: the order status"))
        #expect(
            preview.details.contains(
                "Checks every \(StandingWatcherCapabilityAdapter.minuteCount(StandingWatcherLimits.standard.checkInterval)) "
                + "for up to \(StandingWatcherNoticeCopy.dayCount(StandingWatcherLimits.standard.maxLifetime))"
            )
        )
        #expect(preview.writes == [store.fileURL.path])
        // Tier 2 — a confirmation, not silence. Nothing is overwritten and nothing leaves the
        // machine but a GET of a page the user named, so it is not tier 3 either.
        let assessment = try executor.assessRisk(plan: watchPlan(), scope: .unscoped)
        #expect(assessment.effectiveTier == .tier2)
        #expect(assessment.escalations.isEmpty)
    }

    /// **The two numbers the founders' shortened manual build puts on screen, asserted rather than
    /// reasoned about** (SONNY-382's manual rows; the same discipline PR #184's F6 added for
    /// `checkTimeout` after two rounds of manual-row arithmetic that did not compose).
    ///
    /// The manual pass runs at `checkInterval: 30` and `maxLifetime: 600`, and both of this
    /// operation's approval numbers round: half a minute renders as "1 minute" and ten minutes as
    /// "1 day". Neither is a defect and both look like one, so the checklist says so — and this is
    /// what fails if a later edit changes either formatter and leaves that page lying.
    @Test
    func theApprovalsTwoNumbersRoundTheWayTheManualChecklistSaysTheyDo() {
        #expect(StandingWatcherCapabilityAdapter.minuteCount(30) == "1 minute")
        #expect(StandingWatcherNoticeCopy.dayCount(600) == "1 day")
        // And at the shipped values, where they are exact rather than rounded — the control, without
        // which the two assertions above would be satisfied by a formatter that always says "1".
        #expect(StandingWatcherCapabilityAdapter.minuteCount(StandingWatcherLimits.standard.checkInterval) == "15 minutes")
        #expect(StandingWatcherNoticeCopy.dayCount(StandingWatcherLimits.standard.maxLifetime) == "7 days")
    }

    /// The cap refuses rather than evicting, and it refuses **before** an approval panel is raised —
    /// a user who is at five should be told so instead of approving a watcher that is then declined
    /// underneath them.
    ///
    /// The control is the arm one below the cap: without it, an assertion that a sixth throws is
    /// equally satisfied by a path that never creates any watcher at all.
    @Test
    func aSixthWatcherIsRefusedBeforeAnApprovalIsRaisedAndTheFifthIsNot() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(store: store)
        let limit = StandingWatcherLimits.standard.maxActive

        for index in 0..<(limit - 1) {
            try store.saveWatcher(
                StandingWatcher(
                    subject: "existing \(index)",
                    url: URL(string: "https://example.com/\(index)")!,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                    baselineDigest: "seed-\(index)"
                )
            )
        }

        // Control: one below the cap still prepares and still runs.
        _ = try executor.prepare(plan: watchPlan())
        _ = try await executor.execute(plan: watchPlan(), log: { _, _ in })
        #expect(try store.loadWatchers().count == limit)

        // At the cap: the refusal arrives at `prepare`, which is before any approval exists.
        #expect(throws: StandingWatcherStoreError.tooManyWatchers(limit: limit)) {
            _ = try executor.prepare(plan: watchPlan())
        }
        #expect(try store.loadWatchers().count == limit, "a refused watcher must not have been written")
    }

    /// Memory switched off for this store refuses out loud rather than reporting a watcher that does
    /// not exist. The control is the same plan with the switch on.
    @Test
    func aWatcherIsRefusedOutLoudWhenThatMemoryIsSwitchedOff() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let off = makeExecutor(
            store: store,
            memoryRecording: MemoryRecordingSettings(categoriesDisabledByUser: [.resumableTasks])
        )

        await #expect(throws: MemoryDisabledError(category: .resumableTasks)) {
            _ = try await off.execute(plan: watchPlan(), log: { _, _ in })
        }
        #expect(try store.loadWatchers().isEmpty)

        // Control: the identical plan through an executor whose switch is on does create one, so the
        // refusal above is the switch and not the fixture.
        _ = try await makeExecutor(store: store).execute(plan: watchPlan(), log: { _, _ in })
        #expect(try store.loadWatchers().count == 1)
    }

    /// A page that cannot be read starts **no** watcher. Recording one with an empty baseline would
    /// report a change on the check after next, about a page Sonny never read.
    @Test
    func aPageThatCannotBeReadStartsNoWatcherAtAll() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(store: store, failing: true)

        await #expect(throws: WebResearchError.noReadableContent(Self.watchedURL)) {
            _ = try await executor.execute(plan: watchPlan(), log: { _, _ in })
        }
        #expect(try store.loadWatchers().isEmpty)
    }

    /// A step with no subject, and a step naming an address `SafeURL` refuses, are both rejected at
    /// `prepare` — before anything is fetched and before anything is written.
    ///
    /// The private-host arm is the one that matters: a stored watcher is fetched again by a timer,
    /// so an address that must never be fetched must never become a record.
    @Test
    func aWatchStepWithNoSubjectOrAPrivateAddressIsRefusedBeforeAnythingIsFetched() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(store: store)

        #expect(
            throws: AgentExecutionError.invalidPlan(
                "start_watching needs watchSubject: what to tell the user about."
            )
        ) {
            _ = try executor.prepare(plan: watchPlan(subject: "   "))
        }
        // By name rather than as "some error": the refusal has to be `SafeURL`'s, because that is
        // the check that keeps a loopback address out of a record a timer will fetch. A plan
        // rejected for a different reason would satisfy a bare throws assertion and prove nothing.
        #expect(throws: SafeURLError.privateHostBlocked("127.0.0.1")) {
            _ = try executor.prepare(plan: watchPlan(url: "http://127.0.0.1:8080/status"))
        }
        #expect(try store.loadWatchers().isEmpty)
    }

    /// The subject is a label and is capped like one — a model that echoes a paragraph back does not
    /// get to put a paragraph in a notification.
    ///
    /// **Every surface, and the approval is the one that was missing** (PR #187, F4). The record was
    /// capped from the start, so the row, the notification and the summary all read a capped string.
    /// The approval panel reads the *plan's* subject, one gate before a record exists — so the one
    /// surface a user is asked to read before consenting was the only uncapped one, which is exactly
    /// backwards. The record assertion below is the control: without it a cap applied only in the
    /// preview would satisfy this test.
    @Test
    func aVeryLongSubjectIsCappedOnEverySurfaceIncludingTheApproval() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(store: store)
        let long = String(repeating: "a", count: StandingWatcher.maxSubjectCharacters + 50)

        let prepared = try executor.prepare(plan: watchPlan(subject: long))
        let detail = try #require(
            prepared.previews.flatMap(\.details).first { $0.hasPrefix("Watching for: ") }
        )
        #expect(detail.count == "Watching for: ".count + StandingWatcher.maxSubjectCharacters)

        let result = try await executor.execute(plan: watchPlan(subject: long), log: { _, _ in })

        let watcher = try #require(try store.loadWatchers().first)
        #expect(watcher.subject.count == StandingWatcher.maxSubjectCharacters)
        // The three surfaces agree by value, not merely by length: one capping rule, applied once.
        #expect(detail == "Watching for: \(watcher.subject)")
        #expect(result.summary == "Sonny is watching \u{201C}\(watcher.subject)\u{201D}.")
    }

    /// **A routine may not carry one**, and the store's own write door is what enforces it — not the
    /// planner prompt, which is advice.
    @Test
    func aRoutineMayNotCarryAStartWatchingStep() {
        #expect(StoredRoutine.forbiddenStepOperations.contains(.startWatching))
        #expect(throws: AutomationStoreError.unsafeRoutineStep(AgentOperation.startWatching.rawValue)) {
            try StoredRoutine.validateStepSafety(watchPlan().steps)
        }
    }

    /// **A job over many items may not carry one either — the third repetition door** (PR #187, F1).
    ///
    /// This is the shape the reviewer ran rather than a hypothetical: an eight-file folder job whose
    /// template is `[reveal_in_finder, start_watching]` passed every existing check, because
    /// `validateTemplateReadsTheItemField` is satisfied by the *first* step alone and
    /// `PlanItemJobResolver.expanding` then copies every step once per item. What came out was five
    /// identical watchers of one page, the user's whole cap spent on duplicates, three refusals, and
    /// a run reporting "Worked through 5 of 8 files."
    ///
    /// Driven through the real `prepare` over a real folder, so what is pinned is the door and not
    /// the classification behind it — and the assertion that **nothing was written** is the half that
    /// matters, since the old behaviour wrote five before refusing.
    @Test
    func aJobOverManyItemsMayNotCarryAStartWatchingStep() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            try Data("x".utf8).write(to: root.appendingPathComponent("\(name).pdf"))
        }
        let executor = makeExecutor(store: store, whitelist: PathWhitelist(roots: [root]))

        func job(_ steps: [AgentStep]) -> AgentPlan {
            AgentPlan(
                summary: "Do this to each of these.",
                requiresConfirmation: true,
                steps: steps,
                itemJob: PlanItemJob(
                    source: .folder,
                    folderPath: root.path,
                    itemKind: .files,
                    fileExtensions: ["pdf"],
                    itemField: .inputPath
                )
            )
        }
        let reveal = AgentStep(id: "r", operation: .revealInFinder, description: "Show it.")
        let watch = AgentStep(
            id: "w",
            operation: .startWatching,
            description: "Watch the status page.",
            targetURL: Self.watchedURL,
            watchSubject: "the order status"
        )

        #expect(
            throws: PlanItemJobError.forbiddenStepOperation(
                "Sonny will not start a watcher for each item — that would spend everything it can watch on copies of one page. Ask for the watcher on its own."
            )
        ) {
            _ = try executor.prepare(plan: job([reveal, watch]))
        }
        #expect(try store.loadWatchers().isEmpty, "a refused job must not have started any watcher")

        // A template that is *only* the watch step is refused by the same door and with the same
        // sentence, rather than falling through to "nothing reads the file it would put each item in"
        // — which is true of it and tells the user nothing they can act on.
        #expect(
            throws: PlanItemJobError.forbiddenStepOperation(
                "Sonny will not start a watcher for each item — that would spend everything it can watch on copies of one page. Ask for the watcher on its own."
            )
        ) {
            _ = try executor.prepare(plan: job([watch]))
        }

        // Two controls, because a refusal is worthless if it fires on the fixture. The same job
        // without the watch step prepares into eight copies, and the same watch step outside a job
        // still starts a watcher.
        let allowed = try executor.prepare(plan: job([reveal]))
        #expect(allowed.plan.steps.count == 8)
        #expect(try executor.prepare(plan: watchPlan()).plan.steps.count == 1)
    }

    /// **The two doors, shown disagreeing** (PR #187, F5). The branch asks the cap twice and the
    /// stated reason is that neither ask is redundant — the adapter's is early so a refusal arrives
    /// instead of an approval, and `ResumableTaskStore.saveWatcher`'s is the choke point every door
    /// goes through. Nothing exercised the second half: with the store's ask deleted, every test
    /// still passed, because in a quiet fixture the two doors always agree.
    ///
    /// They can only disagree across the one suspension between them — the page fetch — so the
    /// fixture puts a watcher there. Four exist when `prepare` runs, so the early door passes on its
    /// own terms; the loader takes the fifth slot while the page is being read; and the write that
    /// follows is the only thing left standing between that and a sixth.
    @Test
    func aWatcherArrivingWhileThePageIsBeingReadIsRefusedByTheStore() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = StandingWatcherLimits.standard.maxActive
        for index in 0..<(limit - 1) {
            try store.saveWatcher(
                StandingWatcher(
                    subject: "existing \(index)",
                    url: URL(string: "https://example.com/\(index)")!,
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                    baselineDigest: "seed-\(index)"
                )
            )
        }
        let fetcher = FillsTheLastSlotWhileFetching(store: store, limit: limit)
        let executor = makeExecutor(store: store, fetcher: fetcher)

        // The early door passes: four is below the cap, so this is an approval the user really is
        // offered.
        _ = try executor.prepare(plan: watchPlan())

        await #expect(throws: StandingWatcherStoreError.tooManyWatchers(limit: limit)) {
            _ = try await executor.execute(plan: watchPlan(), log: { _, _ in })
        }
        // The fetch happened, which is what places the refusal after the early door rather than at
        // it — with four watchers that door cannot refuse, so the throw is the store's.
        #expect(fetcher.fetched)
        let watchers = try store.loadWatchers()
        #expect(watchers.count == limit)
        #expect(watchers.contains { $0.subject == "the order status" } == false)
    }
}

/// Takes the last free watcher slot while it is serving the page, so the adapter's early cap check
/// and the store's write-door check see different worlds (PR #187, F5).
///
/// A class rather than a struct because `fetched` is read back after the run: what makes the refusal
/// attributable to the store rather than to the early door is that the fetch happened at all.
@MainActor
private final class FillsTheLastSlotWhileFetching: WebPageFetching {
    let store: ResumableTaskStore
    let limit: Int
    var fetched = false

    init(store: ResumableTaskStore, limit: Int) {
        self.store = store
        self.limit = limit
    }

    func fetch(_ url: URL) async throws -> FetchedWebPage {
        fetched = true
        try store.saveWatcher(
            StandingWatcher(
                subject: "arrived mid-fetch",
                url: URL(string: "https://example.com/late")!,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                baselineDigest: "late"
            )
        )
        return FetchedWebPage(
            requestedURL: url,
            html: "Status: pending",
            retrievedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

/// Serves one page's text for any URL, or throws for every URL.
///
/// Any URL rather than a keyed table, deliberately: these tests are about the watcher record, and a
/// URL-keyed fixture that silently missed would make "no watcher was written" pass for the wrong
/// reason. A test that cares which URL was fetched asserts the record's own `url`.
@MainActor
private struct OneWatchedPageFetcher: WebPageFetching {
    let text: String
    let failing: Bool

    func fetch(_ url: URL) async throws -> FetchedWebPage {
        if failing {
            throw WebResearchError.noReadableContent(url.absoluteString)
        }
        return FetchedWebPage(requestedURL: url, html: text, retrievedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

private struct OneWatchedPageExtractor: ReadableWebExtracting {
    let text: String

    func extract(html: String, sourceURL: URL, retrievedAt: Date) throws -> ReadableWebPage {
        ReadableWebPage(
            sourceURL: sourceURL,
            retrievedAt: retrievedAt,
            title: "Status",
            author: nil,
            publishedDate: nil,
            headings: [],
            links: [],
            readableText: text
        )
    }
}

@MainActor
private struct AllowEveryPage: RobotsTXTChecking {
    func canFetch(_ url: URL, userAgent: String) async throws -> Bool { true }
}
