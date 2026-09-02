import Foundation
import MacAgentCore

/// Local stores at a path this test process invents and nothing else knows (SONNY-350).
///
/// **What this is for.** SONNY-350 made `fileURL` a required parameter of all thirteen local store
/// initializers, so `RoutineStore()` no longer compiles and the real
/// `~/Library/Application Support/Sonny/` location is reachable only by writing the words
/// `realFileURL`. That closed the store initializers. It also broke every fixture that reached a
/// store *without naming one* — not by constructing it, but by letting a **vendor** default it:
/// `AgentActionExecutor`, `InstantCommandResolver`, `ClipboardHistoryMonitor` and `AgentRunner` each
/// defaulted their store parameters to a real-path store, so a test about app switching that
/// named only its `runningAppSwitcher` held six stores pointed at the developer's own data.
/// Those defaults are gone too, and this is what the fixtures that never cared about a store pass
/// instead.
///
/// **A fresh directory per call, and it is deliberately never created.** Every store on the shared
/// pattern guards its reads on `fileManager.fileExists` and calls `createDirectory` before it
/// writes, so a store built here that is only read touches the file system not at all and leaves
/// nothing behind. A fixture that actually *exercises* a store wants a root it can inspect and
/// clean up — that is `makeDirectory()` plus a `defer`, in the suite that cares, and such a fixture
/// should keep passing its own store rather than one of these.
///
/// **The name says what these are rather than what they are not.** "Temporary" would be the obvious
/// word and it would be the wrong one: the point is not that the location is short-lived but that
/// nothing else in the process, and nothing in the shipping app, can name it. A test that finds one
/// of these in an assertion has found a store the test never meant to reach.
public enum UnreachableLocalStores {
    /// A URL under a directory named for this call and nothing else.
    ///
    /// `UUID()` rather than a counter: two suites run in parallel in this repository, and a counter
    /// shared across them is a lock or a race.
    public static func fileURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-unreachable-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    public static func routines() -> RoutineStore {
        RoutineStore(fileURL: fileURL("routines.json"))
    }

    public static func workspaces() -> WorkspaceStore {
        WorkspaceStore(fileURL: fileURL("workspaces.json"))
    }

    public static func clipboardHistory() -> ClipboardHistoryStore {
        ClipboardHistoryStore(fileURL: fileURL("clipboard-history.json"))
    }

    public static func snippets() -> SnippetStore {
        SnippetStore(fileURL: fileURL("snippets.json"))
    }

    public static func recentArtifacts() -> RecentArtifactStore {
        RecentArtifactStore(fileURL: fileURL("recent-artifacts.json"))
    }

    public static func shortcutRunHistory() -> ShortcutRunHistoryStore {
        ShortcutRunHistoryStore(fileURL: fileURL("shortcuts-run-history.json"))
    }
}

/// A standing-watcher observer that reaches no network, for the fixtures that have never heard of
/// watchers (SONNY-236).
///
/// **The same argument as `UnreachableLocalStores` above, one parameter along.**
/// `AgentViewModel.standingWatcherObserver` has no default, because a defaulted live observer would
/// put every fixture one 30-second pulse away from a real HTTP request — the shape SONNY-240 removed
/// from the store parameters, applied to something that fetches rather than writes. A test that
/// actually exercises watching passes its own stub and asserts against it; everything else passes
/// this.
///
/// **It throws rather than returning empty text, and that is the decision.** Empty text is a
/// *reading*: it would digest to a real value, differ from any baseline, and drive the change
/// machinery — so a fixture that accidentally ticked a watcher would exercise the promotion path
/// with fabricated content and pass. A throw is what "this fixture cannot read pages" means, and it
/// lands on the failure-tolerance path where nothing is claimed about the page at all.
public struct UnreachableStandingWatcherObserver: StandingWatcherObserving {
    public init() {}

    public func readableText(at url: URL) async throws -> String {
        throw UnreachableStandingWatcherObserverError.noNetworkInThisFixture(url)
    }
}

public enum UnreachableStandingWatcherObserverError: Error, Equatable {
    case noNetworkInThisFixture(URL)
}

public extension UnreachableLocalStores {
    /// The five stores that had no vendor here until SONNY-236 needed them.
    ///
    /// **Added rather than spelled at the call site, and the reason is a guard rather than tidiness.**
    /// `LocalStoreInjectionScanTests.onlyTheShippedConstantsTestsNameAStoresRealLocation` sweeps the
    /// test tree for every spelling that resolves a store's real `~/Library` path, and one of its
    /// needles is `.fileURL(` — which `UnreachableLocalStores.fileURL("task-history.json")` matches
    /// exactly, at a call site whose whole purpose is the opposite. A fixture written that way is
    /// flagged as naming the real location while pointing at a directory nothing can find, and the
    /// only repairs available are widening the permitted list, which would license the real thing in
    /// that file forever, or keeping the dotted spelling inside this file, where the sweep's own
    /// needle does not reach it. This is the second.
    static func taskHistory() -> TaskHistoryStore {
        TaskHistoryStore(fileURL: fileURL("task-history.json"))
    }

    static func taskPlanDetails() -> TaskPlanDetailStore {
        TaskPlanDetailStore(fileURL: fileURL("task-plan-details.json"))
    }

    static func visionSessionJournal() -> VisionSessionJournalStore {
        VisionSessionJournalStore(fileURL: fileURL("vision-sessions.json"))
    }

    static func approvedApps() -> ApprovedAppStore {
        ApprovedAppStore(fileURL: fileURL("approved-apps.json"))
    }

    static func outputLocations() -> OutputLocationStore {
        OutputLocationStore(fileURL: fileURL("output-locations.json"))
    }

    /// Unfinished runs and standing watchers (SONNY-382).
    ///
    /// Needed here the day `CapabilityExecutionContext` and `AgentActionExecutor` gained the store,
    /// for the same reason as the five above: every fixture that builds an executor now names this
    /// store whether or not it has ever heard of a watcher, and the one thing none of them may name
    /// is the real file.
    static func resumableTasks() -> ResumableTaskStore {
        ResumableTaskStore(fileURL: fileURL("resumable-tasks.json"))
    }
}
