import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct RiskApprovalTests {
    @Test
    func assessmentUsesHighestEscalatedTier() {
        let assessment = CapabilityRiskAssessment(
            defaultTier: .tier2,
            escalations: [
                CapabilityRiskEscalation(
                    fromTier: .tier2,
                    toTier: .tier3,
                    reason: "Output file already exists.",
                    consequence: .destructive
                )
            ]
        )

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
    }
}
