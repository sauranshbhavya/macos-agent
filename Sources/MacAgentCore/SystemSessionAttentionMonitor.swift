import Foundation

#if canImport(AppKit)
import AppKit
import CoreGraphics
#endif

/// Whether a human is still at the Mac, answered from the OS.
///
/// **This is an authority check, not an accuracy hedge** (E7 as ratified under C8). A vision session
/// is allowed to move the user's cursor because the user is there; when they are not, the basis for
/// that permission is gone, and no amount of model quality substitutes for it. So a session pauses
/// on any of the three conditions below, and resuming is an explicit user action — never automatic,
/// because "the screen unlocked" is not the same event as "the user asked Sonny to carry on".
///
/// Each condition is read independently rather than folded into one boolean, so the pause can say
/// which one fired: "your Mac was locked" and "you have been away for a while" are different facts,
/// and a user who is told the wrong one learns to distrust the message.
#if canImport(AppKit)
public struct SystemSessionAttentionMonitor: SessionAttentionMonitoring {
    /// How long without input counts as away.
    ///
    /// **A constant, not a setting** — the ticket's non-goal is explicit about that, and a
    /// configurable idle timeout is a dial whose only purpose is to be turned up. Three minutes is
    /// long enough to read a page of text while Sonny works and short enough that a user who walked
    /// away does not come back to a finished session they never watched.
    public static let idleTimeout: TimeInterval = 180

    /// Reads the OS. Injected so tests can drive every branch without a real display or a real lock.
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
                // `CGSessionCopyCurrentDictionary` is the documented way to ask, and its
                // `CGSSessionScreenIsLocked` key is simply absent when the screen is not locked —
                // so the absence is a real "no", not a failure to read.
                guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
                    // **Fail closed.** Unable to tell means unable to justify moving the cursor.
                    return true
                }
                return (session["CGSSessionScreenIsLocked"] as? Int) == 1
            },
            isDisplayAsleep: {
                // A sleeping display cannot be captured, and a user who cannot see the screen cannot
                // supervise what happens on it — which is the same objection as a locked screen.
                CGDisplayIsAsleep(CGMainDisplayID()) != 0
            },
            secondsSinceLastInput: {
                // Any HID event resets this, which is exactly the definition wanted: "the user did
                // something recently" rather than "an app did something recently".
                CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState,
                    eventType: .init(rawValue: ~0)!
                )
            }
        )
    }

    private let environment: Environment
    private let idleTimeout: TimeInterval

    public init(
        environment: Environment = .live,
        idleTimeout: TimeInterval = SystemSessionAttentionMonitor.idleTimeout
    ) {
        self.environment = environment
        self.idleTimeout = idleTimeout
    }

    public func attentionState() async -> SessionAttentionState {
        // Ordered by how completely each condition removes the user's ability to supervise. A locked
        // Mac is the strongest statement of "I am not here", and a user told the strongest true
        // reason is better served than one told the weakest.
        if environment.isScreenLocked() {
            return .screenLocked
        }
        if environment.isDisplayAsleep() {
            return .displayAsleep
        }
        if environment.secondsSinceLastInput() >= idleTimeout {
            return .userIdle
        }
        return .attended
    }

    /// Whether an approval may be shown at all — §13.1's tier-3 condition.
    ///
    /// **The Mac must be unlocked, and only that.** The other half of §13.1's condition — that the
    /// HUD is visible — is inherited free from the founder's 2026-07-20 decision that the widget is
    /// permanently on screen, so only this half needs asserting.
    ///
    /// Deliberately *narrower* than the protocol's default, which would refuse whenever attention is
    /// lost for any reason. An idle user can still be shown an approval and answer it — being asked
    /// is exactly how they find out Sonny is waiting — while a locked screen cannot show one to
    /// anybody. Overriding the default here is what keeps "idle pauses, locked refuses" two
    /// different outcomes instead of one.
    public func canPresentApproval() async -> Bool {
        !environment.isScreenLocked()
    }
}
#endif
