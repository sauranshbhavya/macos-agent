import Foundation

/// The product's one posture dial — Safe | Normal | Power, the founder's three-segment control
/// (wireframe `docs/wireframes/15-SegmentedControl.svg`, 2026-08-14), replacing the boolean
/// Safe-mode toggle.
///
/// - `safe` asks before every attended action, asks before controlling any app it has not been
///   allowed to control, and is the only mode that renders the "Data leaves device: yes/no"
///   approval line (E9's ratified §11.3 deviation).
/// - `normal` is the default: the consequence rule — ask only when an action is destructive or
///   affects someone other than the user — plus row J's per-app gate, which asks about any app
///   outside the built-in starter list that the user has not already allowed.
/// - `power` **stopped being identical to Normal on 2026-08-20** (row J, SONNY-143). It is the one
///   mode that skips the per-app gate: it asks about no app at all. Everything else is unchanged,
///   including the consequence rule, which asks in Power exactly as it asks in Normal.
///
/// **Screen control is not gated on Power — but *which apps* it may drive now differs by mode, and
/// that is new.** Two supersessions in order, because reading either alone gives the wrong answer:
///
/// 1. Until row I this comment read "row I's screen-control features gate on it when they arrive",
///    and the Power segment's own description told the user screen control would "unlock here" —
///    recorded that way on SONNY-23 and SONNY-91/92 before the founder decided otherwise on
///    2026-08-14. Screen control works in **all three modes**, and no mode gates the capability.
///    That is still true.
/// 2. On **2026-08-16** the founder revived per-app control consent, mode-dependent, superseding his
///    own 2026-08-14 decision that had deleted it. Which apps Sonny may control *without asking* now
///    depends on the mode: Safe starts from nothing, Normal starts from a built-in starter list, and
///    Power asks about no app at all. Approvals are remembered in one user list; the modes differ
///    only in what they start from. So **Power is no longer Normal-identical**, and the sentence
///    "Power buys the user nothing here" that stood here until row J is false.
///
/// What still asks in every mode, Power included, is the standing consequence rule: a destructive or
/// affects-others action asks, mid-loop included. Safe additionally asks before every action and
/// shows each capture before it is sent.
///
/// The approval engine's input is `ApprovalContext.mode` — the whole enum, since SONNY-142 replaced
/// the `safeMode: Bool` this used to fold into via `asksBeforeEveryAction`. The fold survives for
/// the two sites that really are asking "does this posture ask before every action"; it is no longer
/// what reaches the engine, because two booleans cannot express three modes and row J needs Normal
/// and Power told apart.
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
    ///
    /// **Not the engine's input, since SONNY-142.** `ApprovalContext` carries the whole mode now.
    /// This survives for the two mid-loop sites that genuinely ask this question — Safe's capture
    /// review and Safe's delegation question — and reading it as "the mode, as the engine sees it"
    /// is what made Normal and Power indistinguishable for as long as it was.
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
            return "Sonny asks before every action, asks before controlling any app, and shows whether data leaves your device."
        case .normal:
            // "asks only when an action is destructive" became false the day row J's per-app gate
            // shipped: Normal also asks about an app outside the starter list that you have not
            // allowed. Corrected rather than left, because "only" is the word a user acts on.
            return "Sonny asks before controlling an app it has not been allowed to control, and when an action is destructive or affects someone other than you."
        case .power:
            // "Runs exactly like Normal today" was true from 2026-08-14 until row J and is false
            // now: Power is the one mode that skips the per-app gate. It still promises nothing it
            // does not do — the consequence rule is named in the same breath precisely so that
            // "asks about no app" cannot be read as "asks about nothing".
            return "Sonny never asks which apps it may control. It still asks before anything destructive or anything affecting someone else."
        }
    }
}
