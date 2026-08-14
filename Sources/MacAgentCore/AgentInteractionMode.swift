import Foundation

/// The product's one posture dial — Safe | Normal | Power, the founder's three-segment control
/// (wireframe `docs/wireframes/15-SegmentedControl.svg`, 2026-08-14), replacing the boolean
/// Safe-mode toggle.
///
/// - `safe` asks before every attended action and is the only mode that renders the
///   "Data leaves device: yes/no" approval line (E9's ratified §11.3 deviation).
/// - `normal` is the default: the consequence rule — ask only when an action is destructive or
///   affects someone other than the user.
/// - `power` is **identical to Normal today, by design**: roadmap row 18's mode landing as a
///   setting first. Row I's screen-control features gate on it when they arrive (recorded on
///   SONNY-23 and SONNY-91/92); until then selecting it changes nothing, and
///   `settingsDescription` says so rather than implying otherwise.
///
/// The approval engine's input stays `ApprovalContext.safeMode: Bool` — row C's seam, which this
/// enum maps onto via `asksBeforeEveryAction` at the one deriving site. The engine distinguishes
/// exactly two postures today; the third exists at the product layer, where row I will read it.
public enum AgentInteractionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case safe
    case normal
    case power

    public var displayName: String {
        switch self {
        case .safe: return "Safe"
        case .normal: return "Normal"
        case .power: return "Power"
        }
    }

    /// Whether this mode opts back into being asked about everything attended. Exhaustive with
    /// no `default:` on purpose — a new mode must decide, or the build fails.
    public var asksBeforeEveryAction: Bool {
        switch self {
        case .safe:
            return true
        case .normal, .power:
            return false
        }
    }

    /// The one-line explanation the Settings surface shows under the selected segment.
    public var settingsDescription: String {
        switch self {
        case .safe:
            return "Sonny asks before every action, and shows whether data leaves your device."
        case .normal:
            return "Sonny asks only when an action is destructive or affects someone other than you."
        case .power:
            return "Runs exactly like Normal today — screen-control features will unlock here when they arrive."
        }
    }
}
