import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct RiskApprovalTests {
    @Test
    func tierSemanticsAndDefaultRulesMatchSpec() {
        let expectations: [(CapabilityRiskTier, String, RiskApprovalRule)] = [
            (.tier0, "Informational", .autoRun),
            (.tier1, "Low impact", .autoRunUnlessPolicyRequiresApproval),
            (.tier2, "Local modification", .previewOrLightweightConfirmation),
            (.tier3, "External or destructive", .explicitApprovalRequired),
            (.tier4, "Prohibited or unavailable", .refuseOrRequireTakeover)
        ]

        for (tier, semanticName, rule) in expectations {
            #expect(tier.semanticName == semanticName)
            #expect(tier.defaultApprovalRule == rule)
        }
    }

    @Test
    func defaultPolicyKeepsTierZeroAndOneAutonomous() {
        let policy = RiskApprovalPolicy.default

        #expect(policy.requirement(for: .tier0) == .autoRun)
        #expect(policy.requirement(for: .tier1) == .autoRun)
        #expect(policy.requirement(for: .tier2) == .lightweightConfirmation)
        #expect(policy.requirement(for: .tier3) == .explicitApproval)
        #expect(policy.requirement(for: .tier4) == .refuse)
    }

    @Test
    func policyCanTightenTierOneAndPreviewTierTwo() {
        let policy = RiskApprovalPolicy(
            requireApprovalForTier1: true,
            tier2Mode: .previewOnly
        )

        #expect(policy.requirement(for: .tier0) == .autoRun)
        #expect(policy.requirement(for: .tier1) == .lightweightConfirmation)
        #expect(policy.requirement(for: .tier2) == .previewOnly)
    }

    @Test
    func assessmentUsesHighestEscalatedTier() {
        let assessment = CapabilityRiskAssessment(
            defaultTier: .tier2,
            escalations: [
                CapabilityRiskEscalation(
                    fromTier: .tier2,
                    toTier: .tier3,
                    reason: "Output file already exists."
                )
            ]
        )

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.approvalRequirement() == .explicitApproval)
    }

    @Test
    func approvalCopyContainsRequiredUserFacingFields() {
        let copy = RiskApprovalCopy(
            actionDescription: "Create a zip archive",
            riskReason: "This writes a new file",
            involvedResource: "/Users/test/Desktop/largest.zip",
            dataLeavesDevice: false,
            undoDescription: "Delete the created zip"
        )

        #expect(copy.lines == [
            "What Sonny is about to do: Create a zip archive",
            "Why this is risky: This writes a new file",
            "Involves: /Users/test/Desktop/largest.zip",
            "Data leaves device: no",
            "Undo: Delete the created zip"
        ])
    }

    @Test
    func defaultExecutableCapabilityTiersMatchSpec() throws {
        let metadataByID = Dictionary(
            uniqueKeysWithValues: CapabilityRegistry.default.metadata.map { ($0.id, $0.defaultRiskTier) }
        )
        let expected: [String: CapabilityRiskTier] = [
            "local.permissions.readiness": .tier0,
            "local.finder.read-selection": .tier0,
            "local.instant.calculator": .tier0,
            "local.instant.clipboard-history": .tier0,
            "local.instant.snippet-expansion": .tier0,
            "local.instant.recent-artifacts": .tier0,
            "local.instant.running-app-switch": .tier1,
            "local.instant.snippet-save": .tier2,
            "local.apps.open-allowlisted-app": .tier1,
            "local.browser.open-app-search-url": .tier1,
            "local.browser.open-url": .tier1,
            "local.media.open-result": .tier1,
            "local.finder.reveal-path": .tier1,
            "local.workspaces.open": .tier1,
            "local.files.open-generated-artifact": .tier1,
            "local.files.largest-files-zip": .tier2,
            "local.files.create-local-draft": .tier2,
            "local.documents.docx-to-pdf": .tier2,
            "local.web.research-markdown": .tier2,
            "local.routines.save": .tier2,
            "local.routines.run": .tier2,
            "local.workspaces.create": .tier2,
            // Spec §11.1 lists "Change routine/workspace" as tier 2, and editing is the same class
            // of change as creating. Removal raises it to tier 3 dynamically, in the adapter.
            "local.workspaces.edit": .tier2,
            "local.shortcuts.invoke": .tier2
        ]

        for (capabilityID, tier) in expected {
            #expect(metadataByID[capabilityID] == tier)
        }
        #expect(metadataByID["local.planner.clarify"] == .tier0)
    }
}
