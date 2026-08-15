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
///   setting first. Its future meaning is deliberately open, and `settingsDescription` promises
///   nothing rather than implying a capability behind it.
///
/// **Screen control is not gated on Power, and this comment used to say it was.** Until row I it
/// read "row I's screen-control features gate on it when they arrive", and the Power segment's own
/// description told the user screen control would "unlock here" — recorded that way on SONNY-23 and
/// SONNY-91/92 before the founder decided otherwise on 2026-08-14. The ratified rule: screen
/// control works in **all three modes**. Safe is the only one that asks about it — before every
/// vision action, and showing each capture before it is sent — while Normal and Power run vision
/// actions silently. What still asks in every mode, Power included, is the standing consequence
/// rule: a destructive or affects-others action asks, mid-loop included. So Power buys the user
/// nothing here, which is why the copy no longer offers it.
///
/// The approval engine's input stays `ApprovalContext.safeMode: Bool` — row C's seam, which this
/// enum maps onto via `asksBeforeEveryAction` at the one deriving site. That mapping is unchanged
/// by the above and is what makes "Safe asks about vision, Normal and Power do not" fall out of the
/// existing engine rather than needing a fourth posture: the engine distinguishes exactly two
/// postures, and the third stays a product-layer name with no engine meaning yet.
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
            // Promises nothing. The previous sentence promised screen control would unlock here,
            // which the founder's 2026-08-14 decision made false — screen control works in every
            // mode — and a settings description that names a capability the segment does not gate
            // is the kind of copy a user reasonably acts on.
            return "Runs exactly like Normal today. Reserved for more advanced controls as Sonny grows."
        }
    }
}
