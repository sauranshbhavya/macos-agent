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

    public static func clipboardHistorySettings() -> ClipboardHistorySettingsStore {
        ClipboardHistorySettingsStore(fileURL: fileURL("clipboard-history-settings.json"))
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
