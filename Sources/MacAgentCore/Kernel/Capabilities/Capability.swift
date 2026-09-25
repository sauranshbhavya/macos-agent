import CryptoKit
import Foundation

/// What the user is shown before a confirm-level action runs: the exact effect, never a summary
/// the model wrote.
public struct ApprovalPreview: Sendable, Equatable, Codable {
    public var title: String
    /// One line each: recipient, target, content.
    public var details: [String]

    public init(title: String, details: [String] = []) {
        self.title = title
        self.details = details
    }
}

/// Whether an action may be tried again after an uncertain end.
public enum RetryRule: Sendable, Equatable {
    /// Running it twice changes nothing (opening an app, reading a file).
    case idempotent
    /// Never replayed. An uncertain end becomes outcome_unknown and asks the user.
    case never
}

/// An action resolved against the live Mac, ready to gate and run.
///
/// `targetIdentity` and `contentDigest` are what an approval binds to. A capability prepares again
/// right before dispatch, and if either changed, the approval is void.
public struct PreparedAction: Sendable {
    public var actionID: ActionID
    /// The capability's own floor for this call, before the gate's raise rules.
    public var effect: Effect
    public var targetIdentity: String
    public var contentDigest: String
    public var preview: ApprovalPreview
    public var retry: RetryRule
    /// Local facts that can raise the effect.
    public var raiseFacts: RaiseFacts
    /// The target app's standing, for actions that control an app.
    public var standing: AppStanding?
    /// The capability's own resolved data (for example, the app's URL), read back by `execute`.
    public var payload: any Sendable

    public init(
        actionID: ActionID,
        effect: Effect,
        targetIdentity: String,
        content: String,
        preview: ApprovalPreview,
        retry: RetryRule,
        raiseFacts: RaiseFacts = .none,
        standing: AppStanding? = nil,
        payload: any Sendable
    ) {
        self.actionID = actionID
        self.effect = effect
        self.targetIdentity = targetIdentity
        self.contentDigest = Self.digest(target: targetIdentity, content: content)
        self.preview = preview
        self.retry = retry
        self.raiseFacts = raiseFacts
        self.standing = standing
        self.payload = payload
    }

    static func digest(target: String, content: String) -> String {
        let data = Data("\(target)\u{0}\(content)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// How one action ended, as its capability saw it.
public struct CapabilityOutcome: Sendable, Equatable {
    public var status: OutcomeStatus
    public var evidence: String?
    public var error: OutcomeError?

    public init(status: OutcomeStatus, evidence: String? = nil, error: OutcomeError? = nil) {
        self.status = status
        self.evidence = evidence
        self.error = error
    }

    public static func done(_ evidence: String) -> CapabilityOutcome {
        CapabilityOutcome(status: .done, evidence: evidence)
    }

    public static func failed(_ code: OutcomeErrorCode, _ message: String) -> CapabilityOutcome {
        CapabilityOutcome(status: .failed, error: OutcomeError(code: code, message: message))
    }
}

/// Why an action could not be prepared. Each maps to one outcome the gateway can act on.
public enum CapabilityPrepareError: Error, Sendable, Equatable {
    case invalidArguments(String)
    case targetNotFound(String)
    case targetRefused(String)
    case permissionDenied(String)
    case stale(String)

    var result: (status: OutcomeStatus, error: OutcomeError) {
        switch self {
        case .invalidArguments(let message): (.failed, OutcomeError(code: .invalidArguments, message: message))
        case .targetNotFound(let message): (.failed, OutcomeError(code: .targetNotFound, message: message))
        case .targetRefused(let message): (.refused, OutcomeError(code: .targetRefused, message: message))
        case .permissionDenied(let message): (.failed, OutcomeError(code: .permissionDenied, message: message))
        case .stale(let message): (.stale, OutcomeError(code: .staleReference, message: message))
        }
    }
}

/// One thing the Mac can do, as the kernel sees it. A capability never decides whether it may run;
/// the gate does.
public protocol Capability: Sendable {
    /// The operation name and version this capability answers, as the manifest declares them.
    var name: String { get }
    var version: Int { get }

    /// Resolves the call against the live Mac without changing anything.
    func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction

    /// Runs a prepared action. Must honour task cancellation where it can.
    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome
}

/// The capabilities this Mac has, keyed by operation name and version.
public struct KernelCapabilities: Sendable {
    private let capabilities: [String: any Capability]

    public init(_ capabilities: [any Capability]) {
        var byKey: [String: any Capability] = [:]
        for capability in capabilities {
            byKey[Self.key(capability.name, capability.version)] = capability
        }
        self.capabilities = byKey
    }

    public func capability(name: String, version: Int) -> (any Capability)? {
        capabilities[Self.key(name, version)]
    }

    public var manifestOperations: [Manifest.Operation] {
        capabilities.values
            .map { Manifest.Operation(name: $0.name, version: $0.version) }
            .sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    private static func key(_ name: String, _ version: Int) -> String { "\(name)@\(version)" }
}
