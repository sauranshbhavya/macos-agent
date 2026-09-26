import Foundation

/// What the watcher file holds.
struct StandingWatcherFile: Codable, Equatable, Sendable {
    var watchers: [StandingWatcher]
}

/// Where standing watchers are kept: one encrypted file of `StandingWatcher` records.
///
/// The name is V1's, from when the same file also held unfinished runs; only the watchers remain.
public struct ResumableTaskStore: @unchecked Sendable {
    public let fileURL: URL
    /// The standing-watcher cap. Injectable for tests, because reaching `maxActive` otherwise means
    /// creating the shipped number of real watchers. `noProductionPathBuildsItsOwnStandingWatcherLimits`
    /// pins that nothing in `Sources/` passes anything but `.standard`.
    public let limits: StandingWatcherLimits
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared,
        limits: StandingWatcherLimits = .standard
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
        // Already floored by `StandingWatcherLimits.init`, so nothing is re-floored here.
        self.limits = limits
    }

    /// Every standing watcher, oldest first.
    ///
    /// **Nothing is filtered out here.** A watcher whose lifetime has run out is a thing the user is
    /// owed a sentence about (`StandingWatcherStopReason.expired`), so it has to reach the checker
    /// rather than vanish on the read that would have found it. Retiring an expired watcher is the
    /// checker's job and it notifies while doing it.
    ///
    /// Oldest first, which is check order: the watcher that has been waiting longest is looked at
    /// first when a pulse can only get through some of them.
    public func loadWatchers() throws -> [StandingWatcher] {
        try loadFile().watchers.sorted { $0.createdAt < $1.createdAt }
    }

    /// Inserts or replaces one standing watcher.
    ///
    /// **The cap is enforced here, and it refuses rather than evicts** (`StandingWatcherLimits.maxActive`).
    /// Other caps in this repository's stores drop the oldest record, which is right for a record
    /// nobody asked for. A watcher is the opposite: the user said the sentence that created it, so
    /// silently ending one to make room for another is losing something they asked for, with no
    /// notification and no trace. Refusing is a sentence Sonny can say instead.
    ///
    /// **Only an insert is capped.** An update is how a check records its own result, so refusing one
    /// at the cap would freeze every watcher's state the moment the fifth was created — and the
    /// record that then failed to save is the one carrying the reading that would have fired.
    public func saveWatcher(_ watcher: StandingWatcher) throws {
        let file = try loadFile()
        var watchers = file.watchers
        if let index = watchers.firstIndex(where: { $0.id == watcher.id }) {
            watchers[index] = watcher
        } else {
            guard watchers.count < limits.maxActive else {
                throw StandingWatcherStoreError.tooManyWatchers(limit: limits.maxActive)
            }
            watchers.append(watcher)
        }
        try write(StandingWatcherFile(watchers: watchers))
    }

    /// Forgets one standing watcher — what the user's Stop press does, and what the checker does to a
    /// watcher that has finished.
    ///
    /// Deleting something already gone is a silent no-op that does not rewrite the file.
    public func deleteWatcher(id: String) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        let file = try loadFile()
        let remaining = file.watchers.filter { $0.id != id }
        guard remaining.count != file.watchers.count else {
            return
        }
        try write(StandingWatcherFile(watchers: remaining))
    }

    private func loadFile() throws -> StandingWatcherFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return StandingWatcherFile(watchers: [])
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            StandingWatcherFile.self,
            from: data,
            decoder: .resumableTaskISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "watchers", write: write)
    }

    private func write(_ file: StandingWatcherFile) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(file, encoder: .resumableTaskPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// The one failure this store has that is not a file-system or encryption failure.
public enum StandingWatcherStoreError: Error, Equatable, LocalizedError {
    case tooManyWatchers(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyWatchers(let limit):
            // Says what to do, because there is something to do. The cap is deliberately small
            // enough that a person can name what their five watchers are for, so "stop one" is a
            // real instruction rather than the product refusing and leaving them there.
            return "Sonny is already watching \(limit) things, which is the most it will watch at once. Stop one of them and ask again."
        }
    }
}

private extension JSONEncoder {
    static var resumableTaskPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var resumableTaskISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
