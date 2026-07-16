import Foundation

public struct RecentArtifact: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var title: String
    public var recordedAt: Date

    public init(
        id: UUID = UUID(),
        path: String,
        title: String,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.title = title
        self.recordedAt = recordedAt
    }
}

public struct RecentArtifactStore: @unchecked Sendable {
    public static let maxItems = 100
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

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
                .appendingPathComponent("recent-artifacts.json")
        }
    }

    @discardableResult
    public func record(path rawPath: String, recordedAt: Date = Date()) throws -> RecentArtifact? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, isExistingRegularFile(path) else {
            return nil
        }

        let artifact = RecentArtifact(
            path: path,
            title: URL(fileURLWithPath: path).lastPathComponent,
            recordedAt: recordedAt
        )
        var artifacts = try loadAll(now: recordedAt)
        artifacts.removeAll { $0.path == path }
        artifacts.insert(artifact, at: 0)
        artifacts = capped(artifacts.sorted { $0.recordedAt > $1.recordedAt }, now: recordedAt)
        try write(artifacts)
        return artifact
    }

    @discardableResult
    public func recordGeneratedArtifacts(
        from result: AgentRunResult,
        recordedAt: Date = Date()
    ) throws -> Int {
        var recorded = 0
        for path in generatedFilePaths(in: result) {
            if try record(path: path, recordedAt: recordedAt) != nil {
                recorded += 1
            }
        }
        return recorded
    }

    public func loadAll(now: Date = Date()) throws -> [RecentArtifact] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [RecentArtifact].self,
            from: data,
            decoder: .recentArtifactISO8601
        )
        if decoded.wasLegacyPlaintext {
            try write(decoded.value)
        }
        return capped(decoded.value.sorted { $0.recordedAt > $1.recordedAt }, now: now)
    }

    public func recent(matching rawQuery: String? = nil, limit: Int = 10, now: Date = Date()) throws -> [RecentArtifact] {
        let query = rawQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let artifacts = try loadAll(now: now)
        let filtered: [RecentArtifact]
        if let query, !query.isEmpty {
            filtered = artifacts.filter { artifact in
                normalizedSearchText(for: artifact).contains(query)
            }
        } else {
            filtered = artifacts
        }
        return Array(filtered.prefix(max(0, limit)))
    }

    private func generatedFilePaths(in result: AgentRunResult) -> [String] {
        var paths: [String] = []
        if shouldRecordPreviewWrites(for: result.plan) {
            paths.append(contentsOf: result.previews.flatMap(\.writes))
        }
        paths.append(
            contentsOf: result.suggestions
                .filter { [.openFile, .revealInFinder].contains($0.kind) }
                .map(\.value)
        )
        return unique(paths.map { ($0 as NSString).expandingTildeInPath })
    }

    private func shouldRecordPreviewWrites(for plan: AgentPlan) -> Bool {
        plan.steps.contains { step in
            [
                .createZip,
                .convertDocxToPDF,
                .writeMarkdown,
                .webToMarkdown,
                .createLocalDraft,
                .runRoutine
            ].contains(step.operation)
        }
    }

    private func isExistingRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return true
    }

    private func capped(_ artifacts: [RecentArtifact], now: Date) -> [RecentArtifact] {
        Array(
            artifacts
                .filter { now.timeIntervalSince($0.recordedAt) <= Self.maxAge }
                .prefix(Self.maxItems)
        )
    }

    private func normalizedSearchText(for artifact: RecentArtifact) -> String {
        "\(artifact.title) \(artifact.path)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func write(_ artifacts: [RecentArtifact]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(artifacts, encoder: .recentArtifactPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var recentArtifactPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var recentArtifactISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
