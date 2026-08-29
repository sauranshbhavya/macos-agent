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
            .appendingPathComponent("recent-artifacts.json")
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

    /// Forgets one artifact. The file it points at is untouched — this store only ever held a note
    /// about it, which is the same thing `LocalStoreClassification` says of the whole store.
    ///
    /// Added for Command Center's Memory section (SONNY-208), through the same `loadAll`/`write`
    /// pair `record` uses. A missing id is a no-op, not an error.
    ///
    /// `now` is threaded for the same reason `record` threads `recordedAt`: `loadAll` applies the
    /// age cap, so reading with one instant and writing back is an eviction pass — and a caller that
    /// could not pin the instant could not tell a delete apart from an eviction.
    public func delete(id: UUID, now: Date = Date()) throws {
        let artifacts = try loadAll(now: now)
        let remaining = artifacts.filter { $0.id != id }
        guard remaining.count != artifacts.count else {
            return
        }
        try write(remaining)
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
        let artifacts = decoded.migratingLegacyPlaintext(store: "recent artifacts", write: write)
        return capped(artifacts.sorted { $0.recordedAt > $1.recordedAt }, now: now)
    }

    public func recent(matching rawQuery: String? = nil, limit: Int = 10, now: Date = Date()) throws -> [RecentArtifact] {
        let query = rawQuery.map(SearchText.normalizedQuery)

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

    /// Which fields of an artifact are searchable is this store's business; *how* the text is
    /// normalised is not, and lives in `SearchText` so task-history search folds identically
    /// (SONNY-118).
    private func normalizedSearchText(for artifact: RecentArtifact) -> String {
        SearchText.normalized("\(artifact.title) \(artifact.path)")
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
