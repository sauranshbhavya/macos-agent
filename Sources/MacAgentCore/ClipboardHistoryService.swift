import AppKit
import Foundation

public struct ClipboardHistoryItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var copiedAt: Date
    public var text: String

    public init(id: UUID = UUID(), copiedAt: Date, text: String) {
        self.id = id
        self.copiedAt = copiedAt
        self.text = text
    }
}

public struct ClipboardHistorySettings: Codable, Equatable, Sendable {
    public var noticeDismissed: Bool
    public var isEnabled: Bool

    public init(noticeDismissed: Bool = false, isEnabled: Bool = true) {
        self.noticeDismissed = noticeDismissed
        self.isEnabled = isEnabled
    }
}

public enum ClipboardHistoryError: Error, Equatable, LocalizedError {
    case emptyClipboardText
    case settingsUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyClipboardText:
            return "Clipboard history needs copied text."
        case .settingsUnavailable(let detail):
            return "Sonny stopped recording clipboard history because your clipboard settings could not be read: \(detail)"
        }
    }
}

public struct ClipboardHistoryStore: @unchecked Sendable {
    public static let maxItems = 100
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let maxTextCharacters = 10_000

    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
    }

    /// Where the shipping app keeps this store.
    ///
    /// The rule that makes this a named call rather than an initializer default is on
    /// `ClipboardHistoryStore.defaultDirectory` (SONNY-350).
    public static func realFileURL(fileManager: FileManager = .default) -> URL {
        Self.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("clipboard-history.json")
    }

    @discardableResult
    public func record(_ rawText: String, copiedAt: Date = Date()) throws -> ClipboardHistoryItem {
        let cleaned = trimmedAndCapped(rawText)
        guard !cleaned.isEmpty else {
            throw ClipboardHistoryError.emptyClipboardText
        }

        let item = ClipboardHistoryItem(copiedAt: copiedAt, text: cleaned)
        var items = try loadAll(now: copiedAt)
        items.removeAll { $0.text == cleaned }
        items.insert(item, at: 0)
        items = capped(items.sorted { $0.copiedAt > $1.copiedAt }, now: copiedAt)
        try write(items)
        return item
    }

    /// Forgets one copied item.
    ///
    /// Added for Command Center's Memory section (SONNY-208), through the same `loadAll`/`write`
    /// pair `record` uses. A missing id is a no-op, not an error.
    ///
    /// `now` is threaded for the same reason `record` threads `copiedAt` — see
    /// `RecentArtifactStore.delete(id:now:)`, which has the identical shape and the identical cap.
    public func delete(id: UUID, now: Date = Date()) throws {
        let items = try loadAll(now: now)
        let remaining = items.filter { $0.id != id }
        guard remaining.count != items.count else {
            return
        }
        try write(remaining)
    }

    public func loadAll(now: Date = Date()) throws -> [ClipboardHistoryItem] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [ClipboardHistoryItem].self,
            from: data,
            decoder: .clipboardISO8601
        )
        let items = decoded.migratingLegacyPlaintext(store: "clipboard history", write: write)
        return capped(items.sorted { $0.copiedAt > $1.copiedAt }, now: now)
    }

    public func recent(matching rawQuery: String? = nil, limit: Int = 10, now: Date = Date()) throws -> [ClipboardHistoryItem] {
        let query = rawQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let items = try loadAll(now: now)
        let filtered: [ClipboardHistoryItem]
        if let query, !query.isEmpty {
            filtered = items.filter { item in
                item.text
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .lowercased()
                    .contains(query)
            }
        } else {
            filtered = items
        }
        return Array(filtered.prefix(max(0, limit)))
    }

    private func trimmedAndCapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.maxTextCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(Self.maxTextCharacters))
    }

    private func capped(_ items: [ClipboardHistoryItem], now: Date) -> [ClipboardHistoryItem] {
        Array(
            items
                .filter { now.timeIntervalSince($0.copiedAt) <= Self.maxAge }
                .prefix(Self.maxItems)
        )
    }

    private func write(_ items: [ClipboardHistoryItem]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(items, encoder: .clipboardPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct ClipboardHistorySettingsStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
    }

    /// Where the shipping app keeps this store.
    ///
    /// The rule that makes this a named call rather than an initializer default is on
    /// `ClipboardHistoryStore.defaultDirectory` (SONNY-350).
    public static func realFileURL(fileManager: FileManager = .default) -> URL {
        ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("clipboard-history-settings.json")
    }

    public func load() throws -> ClipboardHistorySettings {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ClipboardHistorySettings()
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            ClipboardHistorySettings.self,
            from: data,
            decoder: .clipboardISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "clipboard history settings", write: save)
    }

    public func save(_ settings: ClipboardHistorySettings) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(settings, encoder: .clipboardPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
public protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    func typeIdentifiers() -> [String]
    func stringValue() -> String?
}

@MainActor
public final class SystemPasteboardReader: PasteboardReading {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    public func typeIdentifiers() -> [String] {
        if let items = pasteboard.pasteboardItems, !items.isEmpty {
            return items.flatMap { item in
                item.types.map(\.rawValue)
            }
        }
        return pasteboard.types?.map(\.rawValue) ?? []
    }

    public func stringValue() -> String? {
        pasteboard.string(forType: .string)
    }
}

@MainActor
public final class ClipboardHistoryMonitor {
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let transientType = "org.nspasteboard.TransientType"

    private let reader: any PasteboardReading
    private let store: ClipboardHistoryStore
    private let settingsStore: ClipboardHistorySettingsStore
    private let now: () -> Date
    private var lastChangeCount: Int?

    public init(
        reader: any PasteboardReading = SystemPasteboardReader(),
        store: ClipboardHistoryStore,
        settingsStore: ClipboardHistorySettingsStore,
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.store = store
        self.settingsStore = settingsStore
        self.now = now
    }

    /// The store this monitor records into.
    ///
    /// **Exposed rather than injected a second time, and the difference is hermeticity** (SONNY-208).
    /// Command Center's Memory section has to read and delete clipboard entries, and `AgentViewModel`
    /// holds the monitor but not the store. Giving the view model its own `ClipboardHistoryStore`
    /// init parameter would mean a *defaulted* one resolving to the real
    /// `~/Library/Application Support/Sonny/clipboard-history.json`, which every existing test
    /// fixture would silently pick up — the exact trap the fixture's own comments record for the
    /// vision journal. Reading it back off the already-injected monitor cannot diverge from what
    /// recording writes.
    public var historyStore: ClipboardHistoryStore { store }

    /// Probes the backing history file so the UI can report a corrupt store once. `poll()` only
    /// touches the store when the clipboard actually changes, so corruption would otherwise stay
    /// invisible until the user's next copy — and then only as a silently dropped record.
    public func verifyHistoryReadable() throws {
        _ = try store.loadAll(now: now())
    }

    /// Forgets what the pasteboard looked like, **without recording it**.
    ///
    /// Exists because pausing the poll timer is not enough to suppress clipboard history, and the
    /// difference is a real leak rather than a nicety (SONNY-120). `poll()` records whenever
    /// `reader.changeCount` differs from the last one it saw, and that counter survives a pause —
    /// so a run that stops the timer, lets the user copy something, and then restarts it records
    /// exactly the text the pause existed to withhold, on the very first poll. Measured before this
    /// method existed: the copied string landed in the store.
    ///
    /// Resynchronising on resume closes it. The cost is stated rather than hidden: a copy made
    /// during the pause is not recorded *later* either — it is gone, which is the point.
    public func resynchronize() {
        lastChangeCount = reader.changeCount
    }

    @discardableResult
    public func poll() throws -> ClipboardHistoryItem? {
        // Fail closed. If the consent setting can't be read, recording clipboard contents is the
        // one thing we must not default to — the user may well have turned it off.
        let isEnabled: Bool
        do {
            isEnabled = try settingsStore.load().isEnabled
        } catch {
            throw ClipboardHistoryError.settingsUnavailable(error.localizedDescription)
        }
        guard isEnabled else {
            return nil
        }

        let currentChangeCount = reader.changeCount
        guard currentChangeCount != lastChangeCount else {
            return nil
        }
        lastChangeCount = currentChangeCount

        let types = Set(reader.typeIdentifiers())
        guard !types.contains(Self.concealedType),
              !types.contains(Self.transientType) else {
            return nil
        }

        guard let text = reader.stringValue() else {
            return nil
        }
        return try store.record(text, copiedAt: now())
    }
}

extension ClipboardHistoryStore {
    /// `~/Library/Application Support/Sonny/`, the one directory every local store lives in — and
    /// the root of every `realFileURL` in this module.
    ///
    /// **No local store initializer resolves this on its own any more, and that is the whole of
    /// SONNY-350.** Each of the thirteen took `fileURL: URL? = nil` and fell back to this directory
    /// when the argument was absent, so `RoutineStore()` compiled and wrote to the developer's own
    /// data. A test process writes there under the deterministic key `LocalStorageEncryption`
    /// substitutes for tests, so the file it leaves is one the packaged app cannot decrypt, and per
    /// SONNY-239 cannot recover from either — every path into these stores loads before it writes.
    /// It reached the founder's Mac twice: a storage banner on his first manual item, with 50 test
    /// temp directories inside his real `output-locations.json` (SONNY-209).
    ///
    /// SONNY-240 removed the same shape one level up, from `AgentViewModel.init`'s store
    /// parameters, which is why a fixture that *omits* a store no longer builds. This is the level
    /// below: `fileURL` is required on every store, so a fixture that omits a *location* no longer
    /// builds either, and the real path is reachable only by writing the words `realFileURL`.
    ///
    /// **Why the type system rather than a scan.** `LocalStoreInjectionScanTests` watched this door
    /// by reading source text, and was evaded five times by reviewers looking for one afternoon
    /// each — a typealias wrapper, `routineStore: .init()`, a backticked label, a block comment
    /// between label and colon, and a store vendor that never constructs an `AgentViewModel` at all.
    /// The last two are not fixable by a better pattern: contextual member lookup means `.init()`
    /// genuinely has no type name to match, and a vendor with no `AgentViewModel` call has no
    /// argument label to name. `RoutineStore()` and `.init()` are sugar that omit a name; a required
    /// parameter and a named static member have none to omit, so the evasions stop being
    /// expressible rather than being caught.
    ///
    /// **What this still does not prevent**, stated rather than left to be found: a call site can
    /// write `RoutineStore(fileURL: RoutineStore.realFileURL())` and reach the real path anyway.
    /// That is the point rather than a gap — the real path stays reachable, in words, and
    /// `LocalStoreInjectionScanTests.onlyTheShippedConstantsTestsNameAStoresRealLocation` holds the
    /// population of tests that write them. **That guard matches four spellings, not one** (PR #162
    /// review F4): `realFileURL` is what this ticket added, but `LocalStore.<case>.fileURL()`,
    /// `defaultDirectory(…)` and `LocalDataDeletionService.defaultStoreFileURLs()` all compile and
    /// all resolve the same path, so a needle matching only the new one would read as complete while
    /// three older doors stood open. Nothing holds the equivalent population in `Sources/`, where
    /// `realFileURL` is public because `MacAgent` calls it.
    public static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sonny", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var clipboardPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var clipboardISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
