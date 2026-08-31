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
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            memoryRecording: memoryRecording,
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            webPageLoader: PublicWebPageLoader(
                fetcher: OneWatchedPageFetcher(text: page, failing: failing),
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
    @Test
    func aVeryLongSubjectIsCappedByTheRecordRatherThanStoredWhole() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(store: store)
        let long = String(repeating: "a", count: StandingWatcher.maxSubjectCharacters + 50)

        _ = try await executor.execute(plan: watchPlan(subject: long), log: { _, _ in })

        let watcher = try #require(try store.loadWatchers().first)
        #expect(watcher.subject.count == StandingWatcher.maxSubjectCharacters)
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
