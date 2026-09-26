import Foundation
import MacAgentCore

/// Local stores at a path this test process invents and nothing else knows (SONNY-350).
///
/// **What this is for.** `fileURL` is a required parameter of every local store initializer, and
/// `InstantCommandResolver` takes its stores without defaults, so a fixture that never cared about a
/// store passes one of these instead of one pointed at the developer's own data.
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

    public static func snippets() -> SnippetStore {
        SnippetStore(fileURL: fileURL("snippets.json"))
    }

    public static func recentArtifacts() -> RecentArtifactStore {
        RecentArtifactStore(fileURL: fileURL("recent-artifacts.json"))
    }
}
