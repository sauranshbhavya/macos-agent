import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// SONNY-99. After row C, a tier-2 file write that ran unprompted under a relaxation grant and a
/// tier-0 step that was always silent look exactly the same on screen. The ran-without-asking
/// trace is the differential signal, and this suite pins the pure function that owns every rule of
/// it — the repo has no SwiftUI view-inspection harness, so `WidgetResultPanel`'s rendering of the
/// line is the founder's manual item, and the sentence itself is pinned here on the literal
/// string, the same division `WidgetApprovalExplainerTests` set.
@Suite
struct RelaxationTraceTests {
    @Test
    func theWorkspaceGrantTraceNamesTheWorkspace() {
        #expect(
            AgentActivityPresentation.relaxationTraceLine(
                grant: .inScopeWorkspace,
                effectiveTier: .tier2,
                workspaceName: "Client Alpha"
            ) == "Ran without asking — inside the Client Alpha workspace's boundary."
        )
    }

    /// The two grants are different facts a user can act on, so their sentences must differ — and
    /// the screen-built one must not mention a workspace, because the workspace boundary is not
    /// what allowed it.
    @Test
    func theScreenBuiltTraceReadsAsBuiltOnScreenAndDiffersFromTheWorkspaceOne() {
        let screenBuilt = AgentActivityPresentation.relaxationTraceLine(
            grant: .directUserAuthored,
            effectiveTier: .tier2,
            workspaceName: "Client Alpha"
        )

        #expect(screenBuilt == "Ran without asking — you built this action on screen.")
        #expect(screenBuilt != AgentActivityPresentation.relaxationTraceLine(
            grant: .inScopeWorkspace,
            effectiveTier: .tier2,
            workspaceName: "Client Alpha"
        ))
        // The distinct fixture value proves the field routing: a workspace name is provided, and
        // the screen-built sentence must not render it.
        #expect(screenBuilt?.contains("Client Alpha") == false)
    }

    @Test
    func noGrantMeansNoTraceWhateverTheTier() {
        for tier in CapabilityRiskTier.allCases {
            #expect(
                AgentActivityPresentation.relaxationTraceLine(
                    grant: .none,
                    effectiveTier: tier,
                    workspaceName: "Client Alpha"
                ) == nil
            )
        }
    }

    /// **The test that keeps the signal meaningful.** Tiers 0 and 1 auto-run in every grant column,
    /// so a grant reported there changed nothing — a trace on a step that was always silent would
    /// train the user to ignore the one on a step that was not.
    @Test
    func aTierThatAutoRunsOnItsOwnNeverTraces() {
        for tier in [CapabilityRiskTier.tier0, .tier1] {
            for grant in [RelaxationGrant.inScopeWorkspace, .directUserAuthored] {
                #expect(
                    AgentActivityPresentation.relaxationTraceLine(
                        grant: grant,
                        effectiveTier: tier,
                        workspaceName: "Client Alpha"
                    ) == nil
                )
            }
        }
    }

    /// The function is total: an `.inScope` verdict cannot arise without a bound workspace, but a
    /// missing name must still produce a sentence rather than a crash or a lie.
    @Test
    func aMissingWorkspaceNameStillProducesATotalSentence() {
        for name in [nil, "", "   "] {
            #expect(
                AgentActivityPresentation.relaxationTraceLine(
                    grant: .inScopeWorkspace,
                    effectiveTier: .tier3,
                    workspaceName: name
                ) == "Ran without asking — inside this workspace's boundary."
            )
        }
    }
}
