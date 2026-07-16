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
                .appendingPathComponent("task-history.json")
        }
    }

    public func record(_ record: CompletedTaskRecord) throws {
        var records = try loadAll()
        records.append(record)
        try write(records)
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

    private func write(_ records: [CompletedTaskRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(records, encoder: .taskHistoryPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension TaskHistoryStore {
    static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sonny", isDirectory: true)
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
