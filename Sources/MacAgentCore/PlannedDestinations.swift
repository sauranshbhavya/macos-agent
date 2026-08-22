import Foundation

/// Destinations this run's already-resolved plan **names but has not written yet**, carried into a
/// nested plan's resolution (SONNY-220).
///
/// **Why this is not `RunClaims`, and why merging them would be a bug rather than a tidy-up.**
/// `RunClaims` is post-execution *fact*: it is accumulated from the `ActionPreview.writes` each unit
/// really produced, and adapters read `hasWritten` to decide real things — `FileInventory.docxFiles`
/// consults it to tell "this run wrote that PDF" apart from "that PDF predates this run", and
/// answers *skip this conversion* when it says yes. Seeding that type with paths the plan merely
/// intends would make it answer true for a file nothing has written, and the first consequence is a
/// document the user asked for being skipped because of a PDF that does not exist. This type is the
/// other half of the question — pre-execution *intent* — and it exists so the two never have to be
/// one type with two meanings. SONNY-190 made the same call for the same reason one phase earlier.
///
/// **What it is consumed by, enumerated so the boundary is checkable rather than implied.** Exactly
/// one reader: the seed of `AgentActionExecutor.resolveDefaultOutputs(in:…)`'s within-plan
/// disambiguation set. It is not a property of `CapabilityExecutionContext`, so no adapter can see
/// it, ask it a question, or mistake it for a claim; the two nested-plan closures capture it the way
/// they already capture the claims, which keeps the fact that it exists entirely inside the
/// executor.
///
/// **Folded on the way in, by this type.** The keys are `DestinationKey.folded`, the same fold
/// `RunClaims.destinations` and the executor's disambiguation set use, so seeding one from the other
/// is a union of like with like rather than a translation. Folding here rather than at the call
/// sites is SONNY-165's rule: one home for the rule, so there is no second place it could be spelled
/// differently.
struct PlannedDestinations: Equatable, Sendable {
    /// `DestinationKey.folded` keys. `private(set)` for the same reason `RunClaims`' sets are: the
    /// initialisers below are the only doors, so the fold cannot be bypassed.
    private(set) var paths: Set<String>

    static let none = PlannedDestinations()

    init(paths: Set<String> = []) {
        self.paths = Set(paths.map(DestinationKey.folded))
    }

    /// Every destination the plan's steps already carry — generated defaults the resolver filled in
    /// and paths the plan named itself alike.
    ///
    /// Both kinds belong here. A generated one is the case this type was added for: an outer
    /// `create_local_draft` resolved at `prepare` owns `draft-<title>-<stamp>.md` before the routine
    /// ahead of it in the plan has run. An explicitly named one belongs for the same reason the
    /// executor's own disambiguation set has always accumulated both — a nested routine generating
    /// the path the outer plan spelled out is the same collision, arrived at from the other side.
    ///
    /// Blank and whitespace-only paths are dropped rather than folded into the set, matching the
    /// executor's accumulation test exactly; an empty key would match nothing and claim nothing, but
    /// it would make `paths.count` lie about how many destinations the plan holds.
    init(namedBy plan: AgentPlan) {
        self.init(
            paths: Set(
                plan.steps.compactMap { step -> String? in
                    guard let path = step.outputPath,
                          !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    return path
                }
            )
        )
    }

    /// This set plus everything `other` names. Used to add a chain plan's own destinations to
    /// whatever its caller already named, so a nested plan sees both.
    func union(_ other: PlannedDestinations) -> PlannedDestinations {
        PlannedDestinations(paths: paths.union(other.paths))
    }
}
