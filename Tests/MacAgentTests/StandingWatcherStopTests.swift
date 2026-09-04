import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// Stopping a watcher, and the Routines page that offers the control (SONNY-382).
///
/// **Why this suite exists at all, in the ticket's own words:** a watcher a user can start and
/// cannot stop is a background process they forgot they started, spending a cap they cannot see. So
/// the assertions here are about the row being on the page, the list being live, and the press
/// reaching the store.
@MainActor
struct StandingWatcherStopTests {
    /// The Routines page renders the Watching card and its Stop control, and the Stop goes to
    /// `stopWatching`.
    ///
    /// **A source scan, because this repository can drive no SwiftUI.** It is written to the rules
    /// `MacAgentSource`'s own doc comment sets: the region is sliced from its own anchors, and each
    /// property is asserted against a *count* rather than a bare `contains`, since a comment can add
    /// a token and can never take one away.
    @Test
    func theRoutinesPageRendersTheWatchingCardAndItsStopGoesToStopWatching() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")

        let page = try MacAgentSource.braceBlock(of: source, openedBy: "private struct RoutinesView: View {")
        #expect(MacAgentSource.count(of: "WatchingCollection(viewModel: viewModel)", inText: page) == 1)
        // Gated on there being something to watch, so the page grows a card rather than a permanent
        // explanation of a feature this user may never use.
        #expect(MacAgentSource.count(of: "if !viewModel.standingWatchers.isEmpty {", inText: page) == 1)

        let collection = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private struct WatchingCollection: View {"
        )
        #expect(MacAgentSource.count(of: "CollectionHeader(title: \"Watching\")", inText: collection) == 1)
        // Two sites: the `ForEach` over the list, and the `isLast` comparison against its count. A
        // count rather than a `contains`, so a third reader arrives at this test rather than
        // joining the population silently (SONNY-378).
        #expect(MacAgentSource.count(of: "viewModel.standingWatchers", inText: collection) == 2)
        #expect(MacAgentSource.count(of: "stop: { viewModel.stopWatching(watcher) }", inText: collection) == 1)
        // **No creation door on this page.** Command Center has no composer, and a "New watcher"
        // button that only pre-filled a sentence would say this page can start one.
        #expect(MacAgentSource.count(of: "actionTitle", inText: collection) == 0)

        let row = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private struct StandingWatcherRow: View {"
        )
        #expect(MacAgentSource.count(of: "Button(\"Stop\", action: stop)", inText: row) == 1)
        // Named for a screen reader rather than left as a list of identical "Stop" buttons — the
        // property SONNY-378 records for the approved-apps list's Remove buttons.
        #expect(
            MacAgentSource.count(
                of: ".accessibilityLabel(\"Stop watching \\(presentation.subject)\")",
                inText: row
            ) == 1
        )
    }

    /// The row says what is being watched and **when it stops on its own** — the ticket's "the Stop
    /// control must not read as the only way a watcher ends", met as row state rather than as a
    /// sentence explaining watchers.
    @Test
    func theRowNamesTheSubjectTheHostAndTheDayTheWatcherStopsByItself() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! #require(TimeZone(identifier: "UTC"))
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
        let presentation = StandingWatcherRowPresentation(
            watcher: StandingWatcher(
                subject: "the order status",
                url: URL(string: "https://shop.example.com/orders/9?ref=x")!,
                createdAt: createdAt,
                baselineDigest: "seed"
            ),
            calendar: calendar,
            locale: Locale(identifier: "en_GB")
        )

        #expect(presentation.subject == "the order status")
        // The host, not the whole URL: a full URL truncates in the middle at this row height, and
        // the subject above already says which page this is in the user's own words.
        // 15 January + the shipped seven-day lifetime = 22 January.
        #expect(presentation.detailText == "shop.example.com · until 22 Jan")
    }

    /// Pressing Stop deletes that watcher and leaves the others running — the published list is what
    /// the page renders, so it has to be the thing that changes.
    @Test
    func stoppingOneWatcherDeletesItAndLeavesTheOthers() throws {
        let fixture = try makeStopFixture()
        defer { fixture.cleanUp() }
        let kept = watcher(subject: "the other page", url: "https://example.com/b")
        try fixture.store.saveWatcher(watcher(subject: "the order status", url: "https://example.com/a"))
        try fixture.store.saveWatcher(kept)
        fixture.viewModel.refreshSavedItems()
        #expect(fixture.viewModel.standingWatchers.count == 2)

        let target = try #require(fixture.viewModel.standingWatchers.first { $0.subject == "the order status" })
        fixture.viewModel.stopWatching(target)

        #expect(fixture.viewModel.standingWatchers.map(\.subject) == ["the other page"])
        #expect(try fixture.store.loadWatchers().map(\.id) == [kept.id])
        // The user pressed the control and it worked, so neither channel says anything.
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.localStorageNotice == nil)
        // Stopping is not news to somebody holding the button down: nothing is posted through the
        // watcher channel, which is where the four endings Sonny decides are announced.
        #expect(fixture.viewModel.watcherNotice == nil)
    }

    /// A Stop that cannot be written says so on `errorMessage` — the channel for a control the user
    /// pressed — and **not** on `localStorageNotice`, which is where a task's own bookkeeping goes.
    ///
    /// Both channels are asserted, in both directions, because getting this wrong is silent: the
    /// notice channel would leave the user believing the watcher had stopped, and `errorMessage` on
    /// a *background* write would blank the result of a task that succeeded.
    /// Gated: it locks a directory to 0o500, and root bypasses permission bits — so on a
    /// root-running machine this would fail for a reason that is not a defect (SONNY-106 section D).
    @Test(.requiresUnprivilegedProcess)
    func aStopThatCannotBeWrittenReportsOnTheChannelForAPressedControl() throws {
        let fixture = try makeStopFixture()
        defer { fixture.cleanUp() }
        let stuck = watcher(subject: "the order status", url: "https://example.com/a")
        try fixture.store.saveWatcher(stuck)
        fixture.viewModel.refreshSavedItems()
        #expect(fixture.viewModel.standingWatchers.count == 1)

        // The store's directory made read-only, so the rewrite the delete needs throws while the
        // record itself is still perfectly readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path) }

        fixture.viewModel.stopWatching(stuck)

        let message = try #require(fixture.viewModel.errorMessage)
        #expect(message.hasPrefix("Could not stop watching \u{201C}the order status\u{201D}"))
        #expect(fixture.viewModel.localStorageNotice == nil, "a pressed control must not report on the notice channel")
        // The watcher is still there, which is the truth: nothing was deleted.
        #expect(fixture.viewModel.standingWatchers.count == 1)
    }

    /// A store that will not read leaves the page listing **nothing** rather than the last good
    /// answer, and says why on the storage channel.
    ///
    /// A stale row here would offer a Stop for a record nothing can read — a control that cannot do
    /// what it says. The control is the first half of the test: the list is non-empty first, so an
    /// empty list afterwards is the failure and not the fixture never having loaded.
    @Test
    func anUnreadableStoreEmptiesTheWatchingListRatherThanLeavingItStale() throws {
        let fixture = try makeStopFixture()
        defer { fixture.cleanUp() }
        try fixture.store.saveWatcher(watcher(subject: "the order status", url: "https://example.com/a"))
        fixture.viewModel.refreshSavedItems()
        #expect(fixture.viewModel.standingWatchers.count == 1)

        try Data("not encrypted, not JSON".utf8).write(to: fixture.store.fileURL)
        fixture.viewModel.refreshSavedItems()

        #expect(fixture.viewModel.standingWatchers.isEmpty)
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("unfinished tasks"))
    }

    private func watcher(subject: String, url: String) -> StandingWatcher {
        StandingWatcher(
            subject: subject,
            url: URL(string: url)!,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            baselineDigest: "seed-\(subject)"
        )
    }
}

private struct StopFixture {
    let viewModel: AgentViewModel
    let store: ResumableTaskStore
    let root: URL

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeStopFixture() throws -> StopFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("StandingWatcherStopTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encryption = LocalStorageEncryption(keyManager: StopFixtureKeyManager())
    let store = ResumableTaskStore(
        fileURL: root.appendingPathComponent("resumable-tasks.json"),
        encryption: encryption
    )
    let clipboardSettingsStore = ClipboardHistorySettingsStore(
        fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
        encryption: encryption
    )
    let viewModel = AgentViewModel(
        routineStore: UnreachableLocalStores.routines(),
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
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            store: UnreachableLocalStores.clipboardHistory(),
            settingsStore: clipboardSettingsStore
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        backendClient: makeHermeticBackendClient(),
        userDefaults: UserDefaults(suiteName: "StandingWatcherStopTests-\(UUID().uuidString)") ?? .standard
    )
    return StopFixture(viewModel: viewModel, store: store, root: root)
}

private struct StopFixtureKeyManager: LocalStorageKeyManaging {
    func keyData() throws -> Data {
        Data(repeating: 0x5E, count: 32)
    }
}
