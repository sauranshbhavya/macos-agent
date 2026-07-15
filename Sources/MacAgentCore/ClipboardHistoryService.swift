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

    public var errorDescription: String? {
        switch self {
        case .emptyClipboardText:
            return "Clipboard history needs copied text."
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
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("clipboard-history.json")
        }
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
        if decoded.wasLegacyPlaintext {
            try write(decoded.value)
        }
        return capped(decoded.value.sorted { $0.copiedAt > $1.copiedAt }, now: now)
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
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("clipboard-history-settings.json")
        }
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
        if decoded.wasLegacyPlaintext {
            try save(decoded.value)
        }
        return decoded.value
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
        store: ClipboardHistoryStore = ClipboardHistoryStore(),
        settingsStore: ClipboardHistorySettingsStore = ClipboardHistorySettingsStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.store = store
        self.settingsStore = settingsStore
        self.now = now
    }

    @discardableResult
    public func poll() throws -> ClipboardHistoryItem? {
        guard (try? settingsStore.load().isEnabled) ?? true else {
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
