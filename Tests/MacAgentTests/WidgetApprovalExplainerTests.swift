import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// SONNY-10. The floating widget's permission panel is the surface most users meet their first
/// approval on, and until this change its first-run copy explained Sonny's *policy* ("we always
/// ask") without ever saying why *this* action was flagged. `riskReason` — the sentence the risk
/// engine already computes and Command Center already renders — now joins it.
///
/// Tested through `AgentActivityPresentation.firstRunApprovalExplainerLines` rather than the view,
/// because this repo has no SwiftUI view-inspection harness; `WidgetPermissionPanel` does nothing
/// with these lines but render them in order, so the pure function is where the behavior lives.
@Suite
struct WidgetApprovalExplainerTests {
    /// The steady-state guarantee, and the reason this is safe against the wireframe: after the
    /// first approval the panel is once again exactly the "Allow access to [resource]" row plus
    /// two buttons that `docs/sonny-design-system-reference.md:145` specifies — nothing above it.
    @Test
    func noExplainerLinesOnceTheFirstApprovalHasBeenResolved() {
        let lines = AgentActivityPresentation.firstRunApprovalExplainerLines(
            for: makeRequest(),
            isFirstApproval: false
        )

        #expect(lines.isEmpty)
    }

    @Test
    func firstApprovalShowsTheReassuranceSentenceThenThisActionsOwnRiskReason() {
        let request = makeRequest(riskReason: "This can create or change local files.")

        let lines = AgentActivityPresentation.firstRunApprovalExplainerLines(
            for: request,
            isFirstApproval: true
        )

        #expect(lines == [
            "Sonny always asks first for actions like this — you decide, every time.",
            "This can create or change local files."
        ])
    }

    /// Pins *which* field is read. The fixture gives every `RiskApprovalCopy` field a distinct
    /// value, so rendering `undoDescription`, `actionDescription`, or `involvedResource` by mistake
    /// fails here instead of shipping a plausible-looking wrong sentence.
    @Test
    func theSecondLineIsRiskReasonAndNotAnyOtherApprovalCopyField() throws {
        let request = makeRequest(
            actionDescription: "ACTION",
            riskReason: "REASON",
            involvedResource: "RESOURCE",
            undoDescription: "UNDO"
        )

        let lines = AgentActivityPresentation.firstRunApprovalExplainerLines(
            for: request,
            isFirstApproval: true
        )

        // `try #require`, not `#expect`: `#expect` is non-fatal, so a regression that returns one
        // line would record the count failure and then run straight into `lines[1]` and trap on
        // "Index out of range", taking the rest of the suite's diagnostics down with it. The
        // precondition has to actually stop this test for the index access below to be safe.
        try #require(lines.count == 2)
        #expect(lines[1] == "REASON")
        #expect(!lines.contains("ACTION"))
        #expect(!lines.contains("RESOURCE"))
        #expect(!lines.contains("UNDO"))
    }

    /// A blank reason must collapse to one line, not render an empty row that pushes the panel's
    /// spacing out for no visible text.
    @Test
    func blankRiskReasonLeavesOnlyTheReassuranceSentence() {
        let lines = AgentActivityPresentation.firstRunApprovalExplainerLines(
            for: makeRequest(riskReason: "   "),
            isFirstApproval: true
        )

        #expect(lines == ["Sonny always asks first for actions like this — you decide, every time."])
    }

    /// The escalation reasons stay out of this list — they render on every approval in their own
    /// warning-colored line, and duplicating them here would show the same sentence twice on a
    /// first run that also escalated.
    @Test
    func escalationReasonsAreNotFoldedIntoTheFirstRunLines() {
        let assessment = CapabilityRiskAssessment(
            defaultTier: .tier2,
            effectiveTier: .tier3,
            approvalCopy: makeCopy(riskReason: "REASON"),
            escalations: [
                CapabilityRiskEscalation(
                    fromTier: .tier2,
                    toTier: .tier3,
                    reason: "Zip output already exists at /tmp/a.zip."
                )
            ]
        )
        let request = RiskApprovalRequest(assessment: assessment, requirement: .explicitApproval)

        let lines = AgentActivityPresentation.firstRunApprovalExplainerLines(
            for: request,
            isFirstApproval: true
        )

        #expect(lines.count == 2)
        #expect(!lines.contains { $0.contains("already exists") })
    }
}

private func makeCopy(
    actionDescription: String = "Run the prepared plan",
    riskReason: String = "This can create or change local files, routines, or workspaces.",
    involvedResource: String = "Prepared Sonny action",
    undoDescription: String = "Delete generated local files manually if needed."
) -> RiskApprovalCopy {
    RiskApprovalCopy(
        actionDescription: actionDescription,
        riskReason: riskReason,
        involvedResource: involvedResource,
        dataLeavesDevice: false,
        undoDescription: undoDescription
    )
}

private func makeRequest(
    actionDescription: String = "Run the prepared plan",
    riskReason: String = "This can create or change local files, routines, or workspaces.",
    involvedResource: String = "Prepared Sonny action",
    undoDescription: String = "Delete generated local files manually if needed."
) -> RiskApprovalRequest {
    RiskApprovalRequest(
        assessment: CapabilityRiskAssessment(
            defaultTier: .tier2,
            approvalCopy: makeCopy(
                actionDescription: actionDescription,
                riskReason: riskReason,
                involvedResource: involvedResource,
                undoDescription: undoDescription
            )
        ),
        requirement: .lightweightConfirmation
    )
}
