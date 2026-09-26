import Foundation

/// One finished task as the Tasks page and a follow-up remember it.
public struct FinishedTask: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case completed
        case failed
        case cancelled
    }

    public struct Step: Codable, Sendable, Equatable {
        public var title: String
        public var effect: Effect
        public var status: OutcomeStatus?
        public var evidence: String?
    }

    public var id: TaskID
    public var goal: String
    public var origin: TaskOrigin
    public var outcome: Outcome
    public var summary: String
    public var steps: [Step]
    public var finishedAt: Date

    public init(snapshot: TaskSnapshot, finishedAt: Date) {
        id = snapshot.id
        goal = snapshot.goal
        origin = snapshot.origin
        switch snapshot.phase {
        case .completed(let summary):
            outcome = .completed
            self.summary = summary
        case .failed(let failure):
            outcome = .failed
            summary = failure.message
        default:
            outcome = .cancelled
            summary = "Stopped."
        }
        steps = snapshot.actions.map { Step(title: $0.title, effect: $0.effect, status: $0.status, evidence: $0.evidence) }
        self.finishedAt = finishedAt
    }
}

/// Finished tasks, newest first, in V2's own encrypted store. A private task is never written here
/// (V2 plan decision 10): the caller doesn't pass one, and `record` refuses one if it does.
public actor FinishedTaskStore {
    /// History is for finding and following up recent work, not an archive.
    public static let limit = 500

    private let file: EncryptedListFile<FinishedTask>
    private var cached: [FinishedTask]?

    /// `fileURL` nil keeps history in memory, for tests.
    public init(fileURL: URL?, encryption: LocalStorageEncryption = .shared) {
        file = EncryptedListFile(url: fileURL, encryption: encryption, name: "task history")
    }

    /// Every finished task, newest first. Throws when the file is there but can't be read; then
    /// `record` and `delete` refuse too, and the next call reads the file again.
    public func all() throws -> [FinishedTask] {
        if let cached { return cached }
        let loaded = try file.read()
        cached = loaded
        return loaded
    }

    public func record(_ snapshot: TaskSnapshot, finishedAt: Date) throws {
        guard !snapshot.isPrivate, snapshot.phase.isTerminal else { return }
        var records = try all().filter { $0.id != snapshot.id }
        records.insert(FinishedTask(snapshot: snapshot, finishedAt: finishedAt), at: 0)
        try write(Array(records.prefix(Self.limit)))
    }

    public func delete(_ id: TaskID) throws {
        try write(all().filter { $0.id != id })
    }

    /// The person deleting all of it, so this replaces even a file that couldn't be read.
    public func deleteAll() throws {
        try write([])
    }

    private func write(_ records: [FinishedTask]) throws {
        try file.write(records)
        cached = records
    }
}
