import Foundation

public struct StoredSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        trigger: String,
        expansion: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.updatedAt = updatedAt
    }
}

public enum SnippetStoreError: Error, Equatable, LocalizedError {
    case missingTrigger
    case missingExpansion
    case missingSnippet(String)

    public var errorDescription: String? {
        switch self {
        case .missingTrigger:
            return "A snippet needs a trigger."
        case .missingExpansion:
            return "A snippet needs expansion text."
        case .missingSnippet(let trigger):
            return "No snippet is saved for \(trigger)."
        }
    }
}

public struct SnippetStore: @unchecked Sendable {
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
                .appendingPathComponent("snippets.json")
        }
    }

    public func save(_ snippet: StoredSnippet) throws {
        let normalizedSnippet = try validated(snippet)
        var snippets = try loadAll()
        snippets[normalizedSnippet.trigger] = normalizedSnippet
        try write(snippets)
    }

    public func snippet(matchingTrigger rawTrigger: String) throws -> StoredSnippet {
        let trigger = try normalizedTrigger(rawTrigger)
        guard let snippet = try loadAll()[trigger] else {
            throw SnippetStoreError.missingSnippet(rawTrigger)
        }
        return snippet
    }

    public func findExactTrigger(_ rawTrigger: String) throws -> StoredSnippet? {
        let trigger = rawTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else {
            return nil
        }
        return try loadAll()[trigger]
    }

    public func loadAll() throws -> [String: StoredSnippet] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [String: StoredSnippet].self,
            from: data,
            decoder: .snippetISO8601
        )
        if decoded.wasLegacyPlaintext {
            try write(decoded.value)
        }
        return decoded.value
    }

    private func validated(_ snippet: StoredSnippet) throws -> StoredSnippet {
        let trigger = try normalizedTrigger(snippet.trigger)
        let expansion = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expansion.isEmpty else {
            throw SnippetStoreError.missingExpansion
        }
        var result = snippet
        result.trigger = trigger
        result.expansion = expansion
        return result
    }

    private func normalizedTrigger(_ rawTrigger: String) throws -> String {
        let trigger = rawTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else {
            throw SnippetStoreError.missingTrigger
        }
        return trigger
    }

    private func write(_ snippets: [String: StoredSnippet]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(snippets, encoder: .snippetPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var snippetPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var snippetISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
