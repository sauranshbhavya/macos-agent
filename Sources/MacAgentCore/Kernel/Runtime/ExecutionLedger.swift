import Foundation

/// One action as the ledger tracks it, from receipt to its end.
public struct LedgerAction: Sendable, Equatable, Codable {
    public var actionID: ActionID
    public var state: LedgerState
    public var declared: Effect
    /// The effect the gate judged, after raising. Set once the action is prepared.
    public var judged: Effect?
    /// What the receipt and a pause call this action.
    public var title: String?
    public var evidence: String?
    public var error: OutcomeError?

    public init(actionID: ActionID, state: LedgerState, declared: Effect) {
        self.actionID = actionID
        self.state = state
        self.declared = declared
    }
}

/// The proposal a task is working through, kept so an outcome can be rebuilt after a relaunch.
public struct PendingProposal: Sendable, Equatable, Codable {
    public var seq: Int
    public var agent: ProposingAgent
    public var final: Bool
    public var actions: [ActionID]

    public init(seq: Int, agent: ProposingAgent, final: Bool, actions: [ActionID]) {
        self.seq = seq
        self.agent = agent
        self.final = final
        self.actions = actions
    }
}

/// Everything the Mac must remember about an unfinished task to keep its exactly-once promise
/// across a disconnect or a relaunch (V2 plan section 4).
public struct TaskLedgerRecord: Sendable, Equatable, Codable {
    public var task: TaskID
    public var request: TaskStartBody
    public var createdAt: Date
    /// The last gateway seq accepted.
    public var lastSeqIn: Int
    /// The last seq this Mac sent.
    public var lastSeqOut: Int
    /// Messages sent but not yet known to have reached the gateway, resent after a reconnect.
    public var outbox: [ClientMessage]
    public var actions: [LedgerAction]
    public var pending: PendingProposal?
    /// A question or a screen request from the gateway this Mac hasn't answered yet. The gateway
    /// waits on the answer, so a relaunch must put the question back or look again, not wait too.
    public var awaiting: AwaitedRequest?
    /// Set when the task ended on this Mac while its last messages were still undelivered, so a
    /// relaunch restores it as ended rather than as a task still waiting on the gateway.
    public var endedLocally: LocalEnd?

    public enum LocalEnd: String, Sendable, Equatable, Codable {
        case cancelled
    }

    public enum AwaitedRequest: Sendable, Equatable, Codable {
        case ask(seq: Int, body: AskBody)
        case observe(seq: Int, body: ObserveBody)
    }

    public init(task: TaskID, request: TaskStartBody, createdAt: Date) {
        self.task = task
        self.request = request
        self.createdAt = createdAt
        self.lastSeqIn = 0
        self.lastSeqOut = 0
        self.outbox = []
        self.actions = []
        self.pending = nil
    }

    public func action(_ id: ActionID) -> LedgerAction? {
        actions.first { $0.actionID == id }
    }

    mutating func update(_ id: ActionID, _ change: (inout LedgerAction) -> Void) {
        guard let index = actions.firstIndex(where: { $0.actionID == id }) else { return }
        change(&actions[index])
    }

    /// Drops outbox messages the gateway has shown it received.
    mutating func acknowledge(through seq: Int) {
        outbox.removeAll { ($0.address?.seq ?? 0) <= seq }
    }

    var resumeEntry: HelloBody.ResumeEntry {
        HelloBody.ResumeEntry(
            task: task,
            lastSeqIn: lastSeqIn,
            lastSeqOut: lastSeqOut,
            ledger: actions.suffix(64).map { .init(actionID: $0.actionID, state: $0.state) }
        )
    }
}

/// Where unfinished tasks' ledgers are kept. Written before every dispatch.
public protocol TaskLedgerStoring: Sendable {
    func save(_ record: TaskLedgerRecord) throws
    func delete(_ task: TaskID) throws
    func unfinished() throws -> [TaskLedgerRecord]
}

/// Ledgers as encrypted files under Application Support, one per task (V2 plan section 6, "Fresh
/// stores": V2 writes under its own folder and reads nothing older).
public struct FileTaskLedgerStore: TaskLedgerStoring {
    private let directory: URL
    private let encryption: LocalStorageEncryption

    public init(directory: URL, encryption: LocalStorageEncryption = .shared) {
        self.directory = directory
        self.encryption = encryption
    }

    public func save(_ record: TaskLedgerRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encryption.encode(record)
        try data.write(to: url(for: record.task), options: [.atomic, .completeFileProtection])
    }

    public func delete(_ task: TaskID) throws {
        let url = url(for: task)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func unfinished() throws -> [TaskLedgerRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files
            .filter { $0.pathExtension == "ledger" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                switch try? encryption.decode(TaskLedgerRecord.self, from: data) {
                case .encrypted(let record)?: return record
                default: return nil
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func url(for task: TaskID) -> URL {
        directory.appendingPathComponent("\(task).ledger")
    }
}

/// Ledgers in memory, for tests. A test can hand the same store to a second runtime to model a
/// relaunch.
public final class MemoryTaskLedgerStore: TaskLedgerStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [TaskID: TaskLedgerRecord] = [:]

    public init() {}

    public func save(_ record: TaskLedgerRecord) throws {
        lock.withLock { records[record.task] = record }
    }

    public func delete(_ task: TaskID) throws {
        _ = lock.withLock { records.removeValue(forKey: task) }
    }

    public func unfinished() throws -> [TaskLedgerRecord] {
        lock.withLock { records.values.sorted { $0.createdAt < $1.createdAt } }
    }

    public func record(_ task: TaskID) -> TaskLedgerRecord? {
        lock.withLock { records[task] }
    }
}
