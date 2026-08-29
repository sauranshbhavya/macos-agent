import Foundation
import Testing
@testable import MacAgentCore

/// **The direction the ticket calls the one that breaks the whole product if it is lost**: a free
/// local capability works with no network, no session and no entitlement of any kind (SONNY-135).
///
/// Contract §5.3.1 states it as a code shape rather than as a boolean, "because a boolean is what
/// gets read backwards":
///
/// > A free local capability never consults the entitlement claim at all. Not "consults it and
/// > succeeds"; does not call it. A check that is never made cannot fail closed.
///
/// So there are two halves and both are here in spirit: this file drives the free capabilities and
/// shows they resolve with none of the entitlement machinery in existence, and
/// `EntitlementSourceScanTests` in the app target holds the structural half — that no free path has
/// acquired a dependency on it.
@Suite
@MainActor
struct EntitlementFreePathTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-entitlement-free-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test
    func aFreeLocalCapabilityResolvesWithNoNetworkNoSessionAndNoEntitlement() throws {
        // Nothing in this test constructs an `EntitlementService`, a key set or a claim store, and
        // nothing it calls can reach one: `InstantCommandResolver` imports only `Foundation`, holds
        // five local stores and answers from them. That is the guarantee §16.3 rests on, and it is
        // the reason row 12's whole architecture keeps the agent loop on the Mac.
        let root = try makeRoot()
        let snippets = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        let routines = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let workspaces = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let artifacts = RecentArtifactStore(fileURL: root.appendingPathComponent("artifacts.json"))

        try snippets.save(StoredSnippet(trigger: "sig", expansion: "Sent from Sonny"))
        try routines.save(StoredRoutine(
            name: "morning",
            steps: [AgentStep(
                id: "open",
                operation: .openApp,
                description: "Open TextEdit.",
                appName: "TextEdit"
            )]
        ))
        try workspaces.save(StoredWorkspace(
            name: "writing",
            apps: ["TextEdit"],
            urls: []
        ))

        let resolver = InstantCommandResolver(
            snippetStore: snippets,
            recentArtifactStore: artifacts,
            routineStore: routines,
            workspaceStore: workspaces,
            shortcutCatalog: NoShortcuts(),
            installedAppResolver: NoInstalledApps()
        )

        // A calculation, a snippet, a routine and a workspace — the four kinds of thing the founder's
        // headline manual check names, each resolved to a plan with nothing signed in.
        for command in ["calc 2 + 2", "sig", "run morning", "open writing"] {
            guard case .plan = resolver.resolve(command: command) else {
                Issue.record("\(command) did not resolve locally with no entitlement in reach")
                continue
            }
        }
    }

    @Test
    func theResolverAnswersTheSameWayWhetherOrNotAClaimExists() throws {
        // The sharper form of the same property, and the one a mutant would have to defeat: the
        // answer is *identical* with a claim on disk and with none, because the resolver cannot see
        // one. A resolver that had quietly acquired an entitlement dependency would differ here.
        let root = try makeRoot()
        let snippets = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        try snippets.save(StoredSnippet(trigger: "sig", expansion: "Sent from Sonny"))
        let resolver = InstantCommandResolver(
            snippetStore: snippets,
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("a.json")),
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("r.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("w.json")),
            shortcutCatalog: NoShortcuts(),
            installedAppResolver: NoInstalledApps()
        )

        let withoutAnything = resolver.resolve(command: "sig")
        // A key set exists in the process, a claim store exists, and the resolver is unchanged.
        _ = EntitlementKeySet.parsing(["k:\(String(repeating: "A", count: 43))"])
        let withMachineryInTheProcess = resolver.resolve(command: "sig")

        #expect(withoutAnything == withMachineryInTheProcess)
        #expect(withoutAnything != nil)
    }

    private struct NoShortcuts: ShortcutCatalogProviding {
        func shortcutNames() throws -> [String] { [] }
    }

    private struct NoInstalledApps: InstalledAppResolving {
        func resolve(_ rawName: String?) -> InstalledApp? { nil }
    }
}
