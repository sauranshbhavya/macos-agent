import Foundation

public struct CompletedTaskRecord: Codable, Equatable, Sendable {
    public var command: String
    public var startedAt: Date
    public var completedAt: Date
    public var outcomeStatus: PriorTaskOutcomeStatus

    public init(
        command: String,
        startedAt: Date,
        completedAt: Date,
        outcomeStatus: PriorTaskOutcomeStatus
    ) {
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcomeStatus = outcomeStatus
    }
}

public struct TaskHistoryStore: @unchecked Sendable {
    // Bounded by record count (eviction drops oldest-first via completedAt), not by a fixed
    // duration — this is still a recency-based cutoff, just parameterized by count rather than
    // age. Today every TaskHistoryInsights stat (current streak, hasCompletedToday, this-week/
    // previous-week) only reads a recent window, so eviction never touches data those stats need.
    // Any future all-time/lifetime stat (total tasks ever, longest streak on record) would need
    // to revisit this cap before shipping.
    public static let maxItems = 10_000

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
                .appendingPathComponent("task-history.json")
        }
    }

    public func record(_ record: CompletedTaskRecord) throws {
        var records = try loadAll()
        records.append(record)
        try write(capped(records))
    }

    public func loadAll() throws -> [CompletedTaskRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [CompletedTaskRecord].self,
            from: data,
            decoder: .taskHistoryISO8601
        )
        if decoded.wasLegacyPlaintext {
            try write(decoded.value)
        }
        return decoded.value
    }

    private func capped(_ records: [CompletedTaskRecord]) -> [CompletedTaskRecord] {
        guard records.count > Self.maxItems else {
            return records
        }
        return Array(
            records
                .sorted { $0.completedAt < $1.completedAt }
                .suffix(Self.maxItems)
        )
    }

    private func write(_ records: [CompletedTaskRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(records, encoder: .taskHistoryPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var taskHistoryPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var taskHistoryISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
