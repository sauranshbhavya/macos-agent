import Foundation

/// A single-use permission to commit one exact effect (V2 plan section 6).
///
/// It names the task, the action, the effect, the target and a digest of the content. Before the
/// action runs, the capability prepares again and the broker compares: a different target or
/// content voids the approval, and so does time.
public struct PreparedCommit: Sendable, Equatable, Hashable {
    public let task: TaskID
    public let action: ActionID
    public let commitID: UUID
    public let effect: Effect
    public let targetIdentity: String
    public let contentDigest: String
    public let expiresAt: Date
    public let preview: ApprovalPreview

    public func hash(into hasher: inout Hasher) {
        hasher.combine(commitID)
    }
}

public enum CommitRefusal: Error, Sendable, Equatable {
    case unknown
    case notApproved
    case wrongAction
    case expired
    /// The target or content changed after the user approved.
    case changed
    case alreadyUsed
}

/// Holds approvals and hands each out once. Approvals are routed by task and action id, never by
/// which window has focus.
public actor ApprovalBroker {
    private enum State {
        case pending
        case approved
        case used
    }

    /// How long an approval stays good. Long enough to read a preview, short enough that a stale one
    /// can't be spent later.
    public static let lifetime: TimeInterval = 10 * 60

    private var commits: [UUID: (commit: PreparedCommit, state: State)] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func issue(task: TaskID, prepared: PreparedAction, effect: Effect) -> PreparedCommit {
        let commit = PreparedCommit(
            task: task,
            action: prepared.actionID,
            commitID: UUID(),
            effect: effect,
            targetIdentity: prepared.targetIdentity,
            contentDigest: prepared.contentDigest,
            expiresAt: now().addingTimeInterval(Self.lifetime),
            preview: prepared.preview
        )
        commits[commit.commitID] = (commit, .pending)
        return commit
    }

    /// Records the user's yes. Only the commit issued for this task and this action can be approved.
    @discardableResult
    public func approve(task: TaskID, action: ActionID, commitID: UUID) -> Bool {
        guard let entry = commits[commitID], entry.state == .pending,
              entry.commit.task == task, entry.commit.action == action
        else { return false }
        commits[commitID] = (entry.commit, .approved)
        return true
    }

    /// Spends an approval against the action as it was prepared again just before dispatch.
    public func consume(
        commitID: UUID,
        task: TaskID,
        action: ActionID,
        reprepared: PreparedAction
    ) throws(CommitRefusal) {
        guard let entry = commits[commitID] else { throw .unknown }
        let commit = entry.commit
        guard commit.task == task, commit.action == action else { throw .wrongAction }
        switch entry.state {
        case .pending: throw .notApproved
        case .used: throw .alreadyUsed
        case .approved: break
        }
        guard now() < commit.expiresAt else {
            commits[commitID] = nil
            throw .expired
        }
        guard reprepared.targetIdentity == commit.targetIdentity,
              reprepared.contentDigest == commit.contentDigest
        else {
            commits[commitID] = nil
            throw .changed
        }
        commits[commitID] = (commit, .used)
    }

    /// Voids every approval a task holds, when it ends or is cancelled.
    public func void(task: TaskID) {
        commits = commits.filter { $0.value.commit.task != task }
    }
}
