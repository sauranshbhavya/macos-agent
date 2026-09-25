import Foundation

/// What an action does to the world (V2 plan section 7.1). The model declares one for every action,
/// and the Mac may only raise it.
///
/// The cases are ordered by consequence, so raising is `max`. `unknown` sits above every effect the
/// Mac can run without asking and below the named consequential ones, so a local rule that
/// recognises a send or a delete replaces "unknown" with the specific effect the confirmation should
/// show.
public enum Effect: String, Codable, Sendable, CaseIterable, Comparable {
    case observe
    case navigate
    case editLocal = "edit_local"
    case create
    case unknown
    case destructive
    case external
    case financial
    case credential

    private var rank: Int {
        switch self {
        case .observe: 0
        case .navigate: 1
        case .editLocal: 2
        case .create: 3
        case .unknown: 4
        case .destructive: 5
        case .external: 6
        case .financial: 7
        case .credential: 8
        }
    }

    public static func < (lhs: Effect, rhs: Effect) -> Bool { lhs.rank < rhs.rank }

    /// The higher of the two. A raise rule never lowers an effect.
    public func raised(to floor: Effect) -> Effect { max(self, floor) }
}
