import AppKit
import Foundation
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct ClipboardHistoryTests {
    @Test
    func monitorSkipsConcealedAndTransientTypesBeforeReadingContent() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let settings = ClipboardHistorySettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        try settings.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        let reader = FakePasteboardReader(
            changeCount: 1,
            types: [ClipboardHistoryMonitor.concealedType, NSPasteboard.PasteboardType.string.rawValue],
            string: "super secret"
        )
        let monitor = ClipboardHistoryMonitor(reader: reader, store: store, settingsStore: settings)

        #expect(try monitor.poll() == nil)
        #expect(reader.stringReadCount == 0)
        #expect(try store.loadAll().isEmpty)

        reader.changeCount = 2
        reader.types = [ClipboardHistoryMonitor.transientType, NSPasteboard.PasteboardType.string.rawValue]
        reader.string = "temporary secret"

        #expect(try monitor.poll() == nil)
        #expect(reader.stringReadCount == 0)
        #expect(try store.loadAll().isEmpty)
    }

    @Test
    func monitorRecordsPlainTextOnlyWhenEnabledAndDedupes() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let settings = ClipboardHistorySettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        try settings.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: false))
        let reader = FakePasteboardReader(
            changeCount: 1,
            types: [NSPasteboard.PasteboardType.string.rawValue],
            string: " copied text "
        )
        let monitor = ClipboardHistoryMonitor(reader: reader, store: store, settingsStore: settings)

        #expect(try monitor.poll() == nil)
        #expect(reader.stringReadCount == 0)

        try settings.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        reader.changeCount = 2
        let first = try #require(try monitor.poll())
        #expect(first.text == "copied text")
        #expect(reader.stringReadCount == 1)

        reader.changeCount = 3
        _ = try monitor.poll()
        let items = try store.loadAll()
        #expect(items.count == 1)
        #expect(items[0].text == "copied text")
    }

    @Test
    func storeAppliesRetentionItemAndTextCaps() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try store.record("old", copiedAt: now.addingTimeInterval(-ClipboardHistoryStore.maxAge - 1))
        for index in 0..<105 {
            try store.record("item \(index)", copiedAt: now.addingTimeInterval(-TimeInterval(index)))
        }

        let items = try store.loadAll(now: now)
        #expect(items.count == ClipboardHistoryStore.maxItems)
        #expect(items.first?.text == "item 0")
        #expect(items.last?.text == "item 99")
        #expect(!items.contains { $0.text == "old" })

        let long = String(repeating: "x", count: ClipboardHistoryStore.maxTextCharacters + 50)
        try store.record(long, copiedAt: now.addingTimeInterval(1))

        let capped = try #require(try store.loadAll(now: now.addingTimeInterval(1)).first)
        #expect(capped.text.count == ClipboardHistoryStore.maxTextCharacters)
    }

    @Test
    func settingsDefaultToUndismissedAndEnabledUntilSaved() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsStore = ClipboardHistorySettingsStore(fileURL: root.appendingPathComponent("settings.json"))

        #expect(try settingsStore.load() == ClipboardHistorySettings(noticeDismissed: false, isEnabled: true))

        try settingsStore.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: false))

        #expect(try settingsStore.load() == ClipboardHistorySettings(noticeDismissed: true, isEnabled: false))
    }

    @Test
    func resolverBuildsClipboardHistoryPlans() throws {
        let resolver = InstantCommandResolver()

        guard case .plan(let allPlan) = resolver.resolve(command: "clipboard history") else {
            Issue.record("Expected clipboard history command to resolve locally.")
            return
        }
        #expect(allPlan.steps.map(\.operation) == [.lookupClipboardHistory])
        #expect(allPlan.steps[0].searchQuery == nil)

        guard case .plan(let searchPlan) = resolver.resolve(command: "clip invoice") else {
            Issue.record("Expected clipboard query command to resolve locally.")
            return
        }
        #expect(searchPlan.steps.map(\.operation) == [.lookupClipboardHistory])
        #expect(searchPlan.steps[0].searchQuery == "invoice")
    }

    @Test
    func clipboardLookupUsesTierZeroRunnerPath() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.record("Invoice 123", copiedAt: now)
        try store.record("Meeting notes", copiedAt: now.addingTimeInterval(1))
        let executor = AgentActionExecutor(clipboardHistoryStore: store, now: { now.addingTimeInterval(2) })
        let runner = AgentRunner(planner: FailingPlanner(), executor: executor)
        let plan = AgentPlan(
            summary: "Search clipboard history.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clipboard",
                    operation: .lookupClipboardHistory,
                    description: "Search clipboard history.",
                    count: 5,
                    searchQuery: "invoice"
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.previews.first?.title == "Clipboard history")
        #expect(prepared.previews.first?.details.contains("Invoice 123") == true)

        let request = try runner.approvalRequest(for: prepared, scope: .unscoped)
        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(prepared, scope: .unscoped)
        #expect(result.summary == "Found 1 clipboard item.")
    }

    /// Consent must fail closed. When the settings file can't be read we cannot know the user
    /// left clipboard history enabled, so recording anything would be recording without consent.
    @Test
    func monitorFailsClosedWhenClipboardSettingsCannotBeRead() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardHistoryStore(
            fileURL: root.appendingPathComponent("history.json"),
            encryption: testEncryption(byte: 0x42)
        )
        let settingsURL = root.appendingPathComponent("settings.json")
        try ClipboardHistorySettingsStore(fileURL: settingsURL, encryption: testEncryption(byte: 0x42))
            .save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        // A different key makes the existing settings file undecryptable.
        let unreadableSettings = ClipboardHistorySettingsStore(
            fileURL: settingsURL,
            encryption: testEncryption(byte: 0x99)
        )
        let reader = FakePasteboardReader(
            changeCount: 1,
            types: [NSPasteboard.PasteboardType.string.rawValue],
            string: "private text"
        )
        let monitor = ClipboardHistoryMonitor(
            reader: reader,
            store: store,
            settingsStore: unreadableSettings
        )

        #expect(throws: ClipboardHistoryError.self) {
            _ = try monitor.poll()
        }
        #expect(try store.loadAll().isEmpty)
        #expect(reader.stringReadCount == 0)
    }

    private func testEncryption(byte: UInt8) -> LocalStorageEncryption {
        LocalStorageEncryption(
            keyManager: FixedClipboardKeyManager(bytes: Data(repeating: byte, count: 32))
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private final class FakePasteboardReader: PasteboardReading {
    var changeCount: Int
    var types: [String]
    var string: String?
    private(set) var stringReadCount = 0

    init(changeCount: Int, types: [String], string: String?) {
        self.changeCount = changeCount
        self.types = types
        self.string = string
    }

    func typeIdentifiers() -> [String] {
        types
    }

    func stringValue() -> String? {
        stringReadCount += 1
        return string
    }
}

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for clipboard instant commands.")
        throw PlannerError.missingAPIKey
    }
}

private struct FixedClipboardKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}
