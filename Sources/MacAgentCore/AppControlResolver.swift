import Foundation

/// Whether Sonny may control one app without asking, given the user's mode and their own grants.
///
/// **A pure function, and the stores are inputs rather than dependencies.** It takes the starter
/// list and the approved apps as values, so it is trivially testable and so there is exactly one
/// place the rule lives. Row I shipped a resolver hook that nothing ever called — `resolveDefaultOutputs`
/// existed and every vision plan reached all three gates unpinned — so the two production call sites
/// are named here and pinned by a test that drives a real plan through `performStart` rather than by
/// a component test on this function alone.
///
/// ## The rule most likely to be lost
///
/// Founder correction, 2026-08-16, made while reviewing row J's ticket set. It is possible to read
/// the requirement switch's signature and this function's signature and still write a resolver that
/// ignores the mode — and built that way, **the starter list would grant standing in Safe too, which
/// silently undoes the one thing switching to Safe is for.**
///
/// > **The starter list contributes standing in Normal and Power, and never in Safe. The user's own
/// > approvals contribute in all three.**
///
/// That is the mechanism behind the founder's fourth decision — Normal → Safe keeps the user's own
/// list and drops the starter list — and it makes it a property of this function rather than a
/// description of intent. The effective allow sets:
///
/// | Mode | Baseline | Effective allow set |
/// |---|---|---|
/// | Safe | nothing | the user's list |
/// | Normal | the starter list | starter list ∪ the user's list |
/// | Power | everything | everything — the gate does not run |
///
/// ## What this deliberately does not do
///
/// **It does not check the terminal deny list, and folding that in would be a defect rather than a
/// tidy-up.** A terminal is never a prompt in any mode, whatever the user has approved, and that is
/// true because the deny list refuses at three doors *above* any requirement — `resolveDefaultOutputs`
/// throws before a plan is executable, `assessRisk` throws before there is an assessment to compute a
/// requirement from, and `execute` throws before the vision environment is even read — plus the
/// runtime screen check above this. A copy of that rule here would be a fourth comparison that can
/// drift, and it would demote a structural refusal into a cell of a consent table.
public enum AppControlResolver {
    /// - Parameters:
    ///   - mode: the user's posture dial. Matched exhaustively — a fourth mode does not compile
    ///     until somebody decides what it starts from.
    ///   - targetBundleIdentifier: the app this plan will control, or `nil` when it controls none.
    ///     `nil` is how a non-vision plan answers, and it is an answer a call site gives rather than
    ///     a default this function assumes.
    ///   - starterList: normally `AppControlStarterList.bundleIdentifiers`. Passed rather than read,
    ///     so a test can prove the mode rule with a list it controls.
    ///   - approvedApps: the user's own grants, normally `ApprovedAppStore.loadAll()`.
    public static func standing(
        mode: AgentInteractionMode,
        targetBundleIdentifier: String?,
        starterList: Set<String>,
        approvedApps: [ApprovedApp]
    ) -> AppControlStanding {
        guard let target = targetBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return .notApplicable
        }

        // Both sides fold through the one normalizer, the same rule the deny list uses. The user's
        // list is checked first in every mode because it is the only contributor Safe has, and
        // ordering it first is what stops a future edit from making the starter check the common
        // path and the user check the exception.
        let userApproved = approvedApps.contains { $0.matches(bundleIdentifier: target) }

        switch mode {
        case .safe:
            // **The starter list contributes nothing here.** This line is the founder's correction.
            return userApproved ? .allowed : .needsApproval
        case .normal:
            if userApproved || starterList.contains(ScreenControlPolicy.normalize(target)) {
                return .allowed
            }
            return .needsApproval
        case .power:
            // The gate does not run. Not "everything is on a list" — there is no list consulted at
            // all, which is why an app the user never approved still resolves `.allowed` here and
            // why switching to Power is the one mode change that adds no rows to anybody's list.
            return .allowed
        }
    }
}
