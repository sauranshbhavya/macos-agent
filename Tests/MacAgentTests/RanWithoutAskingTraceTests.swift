import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// SONNY-99's trace, reshaped by the consequence rule (2026-08-13). Under the rule a tier-2 file
/// write and an advisory-only tier-3 both run unprompted, and on screen they would look exactly
/// like a tier-0 step that was always silent. The ran-without-asking trace is the differential
/// signal, and this suite pins the pure function that owns every rule of it — the repo has no
/// SwiftUI view-inspection harness, so `WidgetResultPanel`'s rendering of the line is the
/// founder's manual item, and the sentence itself is pinned here on the literal string, the same
/// division `WidgetApprovalExplainerTests` set.
@Suite
struct RanWithoutAskingTraceTests {
    /// A silent tier-2 run with nothing advisory states the rule — the sentence that tells a user
    /// *why* Sonny stopped asking, in the founder's own terms.
    @Test
    func aSilentTierTwoStatesTheRule() {
        #expect(
            AgentActivityPresentation.ranWithoutAskingLine(
                requirement: .autoRun,
                effectiveTier: .tier2,
                advisoryReasons: []
            ) == "Ran without asking — nothing here is destructive, and it affects no one else."
        )
    }

    /// An advisory-only silent run names the advisory facts verbatim — the sentences the approval
    /// panel used to carry are still read by the user, on this line. Multiple reasons join in
    /// assessment order.
    @Test
    func anAdvisorySilentRunNamesTheAdvisoryFactsVerbatim() {
        let line = AgentActivityPresentation.ranWithoutAskingLine(
            requirement: .autoRun,
            effectiveTier: .tier3,
            advisoryReasons: [
                "example.com is not part of the Research workspace.",
                "Removes Notes from workspace Client Alpha's apps. "
                    + "What is removed stops counting as part of this workspace."
            ]
        )

        #expect(line == "Ran without asking — worth knowing: "
            + "example.com is not part of the Research workspace. "
            + "Removes Notes from workspace Client Alpha's apps. "
            + "What is removed stops counting as part of this workspace.")
    }

    /// **The test that keeps the signal meaningful.** Tiers 0 and 1 always ran silently, so a
    /// trace there would mark a silence that was always ordinary and train the user to ignore the
    /// one that is not.
    @Test
    func aTierThatAlwaysRanSilentlyNeverTraces() {
        for tier in [CapabilityRiskTier.tier0, .tier1] {
            #expect(
                AgentActivityPresentation.ranWithoutAskingLine(
                    requirement: .autoRun,
                    effectiveTier: tier,
                    advisoryReasons: []
                ) == nil
            )
        }
    }

    /// A run that prompted was disclosed by the prompt; a trust-approved routine run was disclosed
    /// by the user's own standing toggle. Neither requirement is `.autoRun`, so neither traces —
    /// whatever the tier, and even if advisory reasons ride along on the same assessment.
    @Test
    func anythingThatWasNotAnAutoRunNeverTraces() {
        for requirement in RiskApprovalRequirement.allCases where requirement != .autoRun {
            for tier in CapabilityRiskTier.allCases {
                #expect(
                    AgentActivityPresentation.ranWithoutAskingLine(
                        requirement: requirement,
                        effectiveTier: tier,
                        advisoryReasons: ["example.com is not part of the Research workspace."]
                    ) == nil,
                    "\(requirement), \(tier)"
                )
            }
        }
    }

    /// The function is total over messy input: blank or whitespace-only reasons are dropped, and
    /// if nothing survives, the line falls back to the rule sentence rather than trailing into
    /// "worth knowing:" followed by nothing.
    @Test
    func blankAdvisoryReasonsFallBackToTheRuleSentence() {
        #expect(
            AgentActivityPresentation.ranWithoutAskingLine(
                requirement: .autoRun,
                effectiveTier: .tier3,
                advisoryReasons: ["", "   "]
            ) == "Ran without asking — nothing here is destructive, and it affects no one else."
        )
    }
}
