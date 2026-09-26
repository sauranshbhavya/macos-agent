import CoreGraphics
import Foundation

/// Whether someone is at the Mac to see what Sonny does in their apps (V2 plan section 8 keeps V1's
/// attention monitor). Working in an app moves another person's windows and types into them; that
/// is allowed because they are there to watch, so screen work stops when the screen is locked, the
/// display sleeps, or nobody has touched the Mac for three minutes.
public enum SessionAttention: Equatable, Sendable {
    case attended
    case screenLocked
    case displayAsleep
    case userIdle

    /// What the person is told when screen work stops, or nil while someone is there.
    public var stopReason: String? {
        switch self {
        case .attended: nil
        case .screenLocked: "Sonny stopped working in apps because your Mac is locked."
        case .displayAsleep: "Sonny stopped working in apps because your display is asleep."
        case .userIdle: "Sonny stopped working in apps because nobody has used this Mac for a few minutes."
        }
    }
}

public protocol SessionAttentionMonitoring: Sendable {
    func attention() async -> SessionAttention
}

/// Asks the system, in order of how completely each one means nobody is watching.
public struct SystemSessionAttentionMonitor: SessionAttentionMonitoring {
    public static let idleTimeout: TimeInterval = 180

    public struct Environment: Sendable {
        public var isScreenLocked: @Sendable () -> Bool
        public var isDisplayAsleep: @Sendable () -> Bool
        public var secondsSinceLastInput: @Sendable () -> TimeInterval

        public init(
            isScreenLocked: @escaping @Sendable () -> Bool,
            isDisplayAsleep: @escaping @Sendable () -> Bool,
            secondsSinceLastInput: @escaping @Sendable () -> TimeInterval
        ) {
            self.isScreenLocked = isScreenLocked
            self.isDisplayAsleep = isDisplayAsleep
            self.secondsSinceLastInput = secondsSinceLastInput
        }

        public static let live = Environment(
            isScreenLocked: {
                SystemSessionAttentionMonitor.isScreenLocked(sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any])
            },
            isDisplayAsleep: { CGDisplayIsAsleep(CGMainDisplayID()) != 0 },
            // Any input event resets it: "someone did something", not "an app did something".
            secondsSinceLastInput: {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            }
        )
    }

    /// No session dictionary at all counts as locked: an answer that can't be read isn't a yes.
    static func isScreenLocked(sessionDictionary: [String: Any]?) -> Bool {
        guard let sessionDictionary else { return true }
        return (sessionDictionary["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    private let environment: Environment
    private let idleTimeout: TimeInterval

    public init(environment: Environment = .live, idleTimeout: TimeInterval = Self.idleTimeout) {
        self.environment = environment
        self.idleTimeout = idleTimeout
    }

    public func attention() async -> SessionAttention {
        if environment.isScreenLocked() { return .screenLocked }
        if environment.isDisplayAsleep() { return .displayAsleep }
        if environment.secondsSinceLastInput() >= idleTimeout { return .userIdle }
        return .attended
    }
}
