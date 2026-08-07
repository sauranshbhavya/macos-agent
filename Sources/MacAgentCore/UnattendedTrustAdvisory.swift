import Foundation

/// The heads-up shown when a user turns on unattended trust for a routine that, as it stands
/// today, could never actually run unattended.
///
/// Tier-3+ is never unattended-eligible regardless of the opt-in — `AgentRunner` re-assesses at
/// execute time and requires the approved tier to be at least the effective tier, so a scheduled
/// run carrying a tier-2 approval cannot execute a tier-3 plan. As of SONNY-31 that refusal pauses
/// the routine's schedule and posts one notice naming the cause, so the user does eventually find
/// out why; this advisory is what tells them *before* the schedule they just set up switches
/// itself off on its first firing.
///
/// **Deliberately a warning, not a gate.** This is not the save-time tier gating that was
/// considered and rejected for branch 10: that proposal blocked scheduling outright unless every
/// step was tier 0/1, which would have excluded the routines people actually want to schedule
/// (running any saved routine is tier 2 by default). This blocks nothing.
///
/// **Deliberately best-effort, and the copy says so.** Tiers escalate dynamically from real
/// conditions at run time — a zip whose output path already exists goes tier 2 → tier 3, a snippet
/// save that would replace an existing trigger *with different text* does the same (identical text
/// is a no-op and no longer escalates, per SONNY-31) — so a routine that reads tier 2 here can
/// still be tier 3 when it fires, and pause itself then. A clean result from this check is not a
/// promise that the routine will run.
public enum UnattendedTrustAdvisory {
    /// Returns advisory copy when the routine currently assesses at tier 3+, otherwise nil.
    ///
    /// Never throws: a routine that cannot be assessed at all (missing, unreadable store, a step
    /// whose preview fails) yields no advisory rather than blocking the opt-in. The real backstop
    /// is at execution time, not here, so a failure to pre-check costs a paused schedule and its
    /// notice later — it does not let anything unsafe through.
    @MainActor
    public static func warning(
        forRoutineNamed name: String,
        executor: AgentActionExecutor
    ) -> String? {
        let plan = RunRoutineCapabilityAdapter.plan(forRoutineNamed: name)
        // `.unscoped` is the semantically correct value here, not merely the compiling one: this
        // advisory pre-checks a routine from the routine's own settings surface, outside any task
        // and therefore outside any workspace binding. Nothing about the advisory's behavior or
        // copy changes — the assessment it reads is byte-identical to the one it read before scope
        // existed. (SONNY-37; user-ratified narrow exception to that ticket's never-touch entry,
        // which covers this file's behavior. Whether a *scheduled run's* pre-check should one day
        // assess with the run's real scope is explicitly undecided and is flagged on the ticket.)
        guard let assessment = try? executor.assessRisk(plan: plan, scope: .unscoped) else {
            return nil
        }
        guard assessment.effectiveTier.rawValue >= CapabilityRiskTier.tier3.rawValue else {
            return nil
        }
        return """
        “\(name)” currently needs your explicit approval to run, so Sonny will pause its schedule \
        and tell you why rather than run it unattended. Sonny re-checks this every time it runs, so \
        a routine that is fine today can still pause later — for example when a file it writes \
        already exists.
        """
    }
}
