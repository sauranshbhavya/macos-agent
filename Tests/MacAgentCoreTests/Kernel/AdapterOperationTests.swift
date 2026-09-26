import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// A Shortcuts list and runner a test controls.
private final class FakeShortcuts: ShortcutCatalogProviding, ShortcutInvoking, @unchecked Sendable {
    let names: [String]
    private let lock = NSLock()
    private var runs: [(String, String?)] = []

    init(_ names: [String]) {
        self.names = names
    }

    var ran: [(String, String?)] { lock.withLock { runs } }

    func shortcutNames() throws -> [String] { names }

    func invokeShortcut(name: String, input: String?) async throws -> ProcessResult {
        lock.withLock { runs.append((name, input)) }
        return ProcessResult(terminationStatus: 0, output: "done")
    }
}

/// Running apps a test lists, and the activations it saw.
private final class FakeSwitcher: RunningAppSwitching {
    let apps: [RunningApp]
    var activated: [String] = []

    init(_ apps: [RunningApp]) {
        self.apps = apps
    }

    func runningApps() -> [RunningApp] { apps }

    func activate(bundleIdentifier: String) async throws {
        activated.append(bundleIdentifier)
    }
}

/// The typed operations that run V1 adapter bodies, through the capability the kernel dispatches:
/// what each prepares (its effect and preview) and what running it does.
@Suite(.serialized)
@MainActor
struct AdapterOperationTests {
    private func capabilities(_ context: CapabilityExecutionContext) -> KernelCapabilities {
        KernelCapabilities(
            StandardCapabilities.all(context: { context }, finderRevealer: { _ in }, routines: RoutineGoalStore(fileURL: nil)).all
                + InstantPath.localCapabilities(context: { context })
        )
    }

    private func run(_ capability: any Capability, _ args: [String: JSONValue]) async throws -> (PreparedAction, CapabilityOutcome) {
        let prepared = try await capability.prepare(actionID: ActionID(), args: args)
        return (prepared, await capability.execute(prepared))
    }

    @Test
    func savingASnippetEditsLocallyAndReplacingADifferentOneIsDestructive() async throws {
        let stores = CapabilityTestStores()
        let all = capabilities(CapabilityTestContext.make(installed: [], stores: stores))
        let save = try #require(all.capability(name: "save_snippet", version: 1))

        let (first, outcome) = try await run(save, ["trigger": .string(";sig"), "text": .string("Best, Sam")])
        #expect(first.effect == .editLocal)
        #expect(outcome.status == .done)
        #expect(try stores.snippets.findExactTrigger(";sig")?.expansion == "Best, Sam")

        let same = try await save.prepare(actionID: ActionID(), args: ["trigger": .string(";sig"), "text": .string("Best, Sam")])
        #expect(same.effect == .editLocal)
        let different = try await save.prepare(actionID: ActionID(), args: ["trigger": .string(";sig"), "text": .string("Cheers, Sam")])
        #expect(different.effect == .destructive)
    }

    @Test
    func aSavedSnippetExpandsOnTheInstantPath() async throws {
        let stores = CapabilityTestStores()
        try stores.snippets.save(StoredSnippet(trigger: ";addr", expansion: "1 Main St", updatedAt: Date()))
        let expand = try #require(capabilities(CapabilityTestContext.make(installed: [], stores: stores)).capability(name: "expand_snippet", version: 1))
        let (prepared, outcome) = try await run(expand, ["query": .string(";addr")])
        #expect(prepared.effect == .observe)
        #expect(outcome.status == .done)
        #expect(outcome.evidence?.contains("1 Main St") == true)
    }

    @Test
    func aShortcutRunsByItsOwnNameWithItsInputAndAnUnknownOneAsks() async throws {
        let shortcuts = FakeShortcuts(["Log Water"])
        let context = CapabilityTestContext.make(installed: [], shortcutCatalog: shortcuts, shortcutInvoker: shortcuts)
        let run = try #require(capabilities(context).capability(name: "run_shortcut", version: 1))

        let (prepared, outcome) = try await self.run(run, ["name": .string("log water"), "input": .string("250ml")])
        #expect(prepared.effect == .unknown)
        #expect(outcome.status == .done)
        #expect(shortcuts.ran.map(\.0) == ["Log Water"])
        #expect(shortcuts.ran.map(\.1) == ["250ml"])

        await #expect(throws: CapabilityPrepareError.self) {
            _ = try await run.prepare(actionID: ActionID(), args: ["name": .string("Book Flights")])
        }
        #expect(shortcuts.ran.count == 1)
    }

    @Test
    func switchingBringsTheRunningAppForwardAndAnAppThatIsNotRunningIsRefused() async throws {
        let switcher = FakeSwitcher([RunningApp(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", processIdentifier: 42)])
        let context = CapabilityTestContext.make(installed: [], runningAppSwitcher: switcher)
        let switchApp = try #require(capabilities(context).capability(name: "switch_app", version: 1))

        let (prepared, outcome) = try await run(switchApp, ["app": .string("slack")])
        #expect(prepared.effect == .navigate)
        #expect(outcome.status == .done)
        #expect(switcher.activated == ["com.tinyspeck.slackmacgap"])

        await #expect(throws: CapabilityPrepareError.self) {
            _ = try await switchApp.prepare(actionID: ActionID(), args: ["app": .string("Figma")])
        }
    }

    @Test
    func recentFilesListsWhatSonnyMadeNewestFirst() async throws {
        let stores = CapabilityTestStores()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, name) in ["older.pdf", "newer.pdf"].enumerated() {
            let file = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            _ = try stores.recentFiles.record(path: file.path, recordedAt: Date(timeIntervalSinceNow: Double(index - 10)))
        }
        let recent = try #require(capabilities(CapabilityTestContext.make(installed: [], stores: stores)).capability(name: "recent_files", version: 1))
        let (prepared, outcome) = try await run(recent, [:])
        #expect(prepared.effect == .observe)
        let evidence = try #require(outcome.evidence)
        let newer = try #require(evidence.range(of: "newer.pdf"))
        let older = try #require(evidence.range(of: "older.pdf"))
        #expect(newer.lowerBound < older.lowerBound)
    }

    @Test
    func aFileSonnyWritesIsListedInRecentFilesAndALookupAddsNothing() async throws {
        let stores = CapabilityTestStores()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("made-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CapabilityTestContext.make(installed: [], whitelist: PathWhitelist(roots: [folder]), stores: stores)
        let all = capabilities(context)

        try Data(count: 4000).write(to: folder.appendingPathComponent("big.bin"))
        let find = try #require(all.capability(name: "find_largest_files", version: 1))
        _ = try await run(find, ["folder": .string(folder.path)])
        #expect(try stores.recentFiles.recent().isEmpty)

        let path = folder.appendingPathComponent("plan.md").path
        let write = try #require(all.capability(name: "write_file", version: 1))
        let (_, written) = try await run(write, ["content": .string("buy milk"), "path": .string(path)])
        #expect(written.status == .done)

        let recent = try #require(all.capability(name: "recent_files", version: 1))
        let (_, listed) = try await run(recent, [:])
        #expect(listed.evidence?.contains("plan.md") == true)
        #expect(try stores.recentFiles.recent().map(\.path) == [path])
    }

    @Test
    func aZipWithADefaultNameKeepsItsPathWhenItIsPreparedAgainBeforeRunning() async throws {
        let clock = Shared(Date(timeIntervalSince1970: 1_800_000_000))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 4000).write(to: folder.appendingPathComponent("big.bin"))
        let context = CapabilityTestContext.make(installed: [], whitelist: PathWhitelist(roots: [folder]), now: { clock.value })
        let zip = try #require(capabilities(context).capability(name: "zip_largest_files", version: 1))

        // No name at all, and a folder to put it in: both make a name from the time.
        for args: [String: JSONValue] in [
            ["folder": .string(folder.path)],
            ["folder": .string(folder.path), "output_path": .string(folder.path)],
        ] {
            let action = ActionID()
            let first = try await zip.prepare(actionID: action, args: args)
            // The approval sits open for a while; the kernel prepares the action again to run it.
            clock.value = clock.value.addingTimeInterval(5)
            let again = try await zip.prepare(actionID: action, args: args)
            #expect(again.contentDigest == first.contentDigest)
            #expect(again.targetIdentity == first.targetIdentity)

            // A new action is named fresh, and the name is a file inside the folder.
            let later = try await zip.prepare(actionID: ActionID(), args: args)
            #expect(later.targetIdentity != first.targetIdentity)
            #expect(first.targetIdentity.hasSuffix(".zip"))
        }

        // The same action id with different arguments is a different request: nothing pinned
        // carries over to it.
        let reused = ActionID()
        let other = folder.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(count: 4000).write(to: other.appendingPathComponent("big.bin"))
        let pinnedHere = try await zip.prepare(actionID: reused, args: ["folder": .string(folder.path)])
        clock.value = clock.value.addingTimeInterval(5)
        let elsewhere = try await zip.prepare(actionID: reused, args: ["folder": .string(other.path)])
        #expect(elsewhere.targetIdentity != pinnedHere.targetIdentity)
        #expect(elsewhere.targetIdentity.contains("/other/"))
    }

    @Test
    func aZipGivenAFolderWritesAnArchiveInsideIt() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-into-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let archives = folder.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 4000).write(to: folder.appendingPathComponent("big.bin"))
        let context = CapabilityTestContext.make(installed: [], whitelist: PathWhitelist(roots: [folder]))
        let zip = try #require(capabilities(context).capability(name: "zip_largest_files", version: 1))

        let (_, outcome) = try await run(zip, ["folder": .string(folder.path), "output_path": .string(archives.path)])
        #expect(outcome.status == .done)
        let made = try FileManager.default.contentsOfDirectory(atPath: archives.path)
        #expect(made.count == 1)
        #expect(made.first?.hasPrefix("largest-files-") == true)
        #expect(made.first?.hasSuffix(".zip") == true)
    }

    @Test
    func aReminderInFiveMinutesKeepsItsTimeWhenItIsPreparedAgainBeforeRunning() async throws {
        let clock = Shared(Date(timeIntervalSince1970: 1_800_000_000))
        let context = CapabilityTestContext.make(installed: [], now: { clock.value })
        let reminder = try #require(capabilities(context).capability(name: "create_reminder", version: 1))
        let args: [String: JSONValue] = ["title": .string("call the bank"), "minutes_from_now": .number(5)]
        let action = ActionID()

        let first = try await reminder.prepare(actionID: action, args: args)
        // The approval sits open for four minutes; the kernel prepares the action again to run it.
        clock.value = clock.value.addingTimeInterval(4 * 60)
        let again = try await reminder.prepare(actionID: action, args: args)
        #expect(again.contentDigest == first.contentDigest)
        #expect(again.preview == first.preview)

        // A new action is read fresh.
        let later = try await reminder.prepare(actionID: ActionID(), args: args)
        #expect(later.contentDigest != first.contentDigest)
    }
}
