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

    /// The consequence rule on bare, escalation-free assessments, asked through the one public
    /// path: tiers 0–2 auto-run, an escalation-free tier 3 fails closed to an explicit ask
    /// (nothing classified means nothing to run silently on), and tier 4 refuses.
    @Test
    func escalationFreeTiersMapToTheConsequenceRulesDefaults() {
        let policy = RiskApprovalPolicy.default
        let context = ApprovalContext(safeMode: false)

        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier0), context: context) == .autoRun)
        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier1), context: context) == .autoRun)
        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier2), context: context) == .autoRun)
        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier3), context: context) == .explicitApproval)
        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier4), context: context) == .refuse)
    }

    /// The policy dials are inert on the ordinary path under the consequence rule — a tightened
    /// tier 1 and a preview-only tier 2 both auto-run; the stricter tier-2 dial survives only
    /// inside Safe mode, where the formula takes the stricter of baseline and floor. (Whether the
    /// dials should now be deleted outright is the founder's call, flagged in the pivot records.)
    @Test
    func thePolicyDialsAreInertOnTheOrdinaryPath() {
        let policy = RiskApprovalPolicy(
            requireApprovalForTier1: true,
            tier2Mode: .previewOnly
        )

        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier0), context: ApprovalContext(safeMode: false)) == .autoRun)
        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier1), context: ApprovalContext(safeMode: false)) == .autoRun)
        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier2), context: ApprovalContext(safeMode: false)) == .autoRun)
        #expect(policy.requirement(for: CapabilityRiskAssessment(defaultTier: .tier2), context: ApprovalContext(safeMode: true)) == .previewOnly)
    }

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
        #expect(
            RiskApprovalPolicy.default.requirement(
                for: assessment,
                context: ApprovalContext(safeMode: false)
            ) == .explicitApproval
        )
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

    // MARK: - SONNY-62: what an approval covers, reason by reason
    //
    // `RiskApprovalConsent.authorizes(_:)` is the whole rule, so these exercise it directly rather
    // than only through `AgentRunner.execute` — the runner-level tests in `AgentRunnerTests` prove
    // the wiring, and these prove the boundaries, including the ones no adapter can currently
    // produce (a reason drifting at tier 2, an escalation that is not a tier-3 one).

    @Test
    func answeringAPromptRecordsItsTierAndEveryReasonItShowed() {
        let request = makeRequest(tier: .tier3, reasons: ["Draft output already exists at /tmp/a.md.", "example.com is not part of the Research workspace."])

        let consent = RiskApprovalConsent(answering: request)

        #expect(consent.tier == .tier3)
        #expect(consent.coverage == .acknowledgedReasons([
            "Draft output already exists at /tmp/a.md.",
            "example.com is not part of the Research workspace."
        ]))
        #expect(RiskApprovalDecision.approved(answering: request) == .approved(consent))
    }

    /// The bug, at the level of the rule: two tier-3 causes are equal as tiers and different as
    /// consent.
    @Test
    func aSecondTierThreeReasonAtTheSameTierIsNotAuthorized() {
        let answered = makeRequest(tier: .tier3, reasons: ["example.com is not part of the Research workspace."])
        let consent = RiskApprovalConsent(answering: answered)
        let drifted = makeRequest(tier: .tier3, reasons: [
            "Draft output already exists at /tmp/a.md.",
            "example.com is not part of the Research workspace."
        ])

        #expect(consent.authorizes(answered))
        #expect(!consent.authorizes(drifted))
        #expect(consent.unacknowledgedReasons(in: drifted) == ["Draft output already exists at /tmp/a.md."])
    }

    /// Subset, not equality: a reason that went away is strictly less than what was consented to.
    @Test
    func aReasonThatDisappearedLeavesTheApprovalCovering() {
        let answered = makeRequest(tier: .tier3, reasons: [
            "Draft output already exists at /tmp/a.md.",
            "example.com is not part of the Research workspace."
        ])
        let consent = RiskApprovalConsent(answering: answered)
        let calmer = makeRequest(tier: .tier3, reasons: ["example.com is not part of the Research workspace."])

        #expect(consent.authorizes(calmer))
        #expect(consent.unacknowledgedReasons(in: calmer).isEmpty)
    }

    /// Fail-closed on wording, deliberately: nothing here can tell a cosmetic rewrite from a
    /// different file with the same sentence shape.
    @Test
    func aRewordedReasonIsANewReason() {
        let answered = makeRequest(tier: .tier3, reasons: ["Draft output already exists at /tmp/a.md."])
        let consent = RiskApprovalConsent(answering: answered)
        let reworded = makeRequest(tier: .tier3, reasons: ["A draft already exists at /tmp/a.md."])
        let sameShapeDifferentFile = makeRequest(tier: .tier3, reasons: ["Draft output already exists at /tmp/b.md."])

        #expect(!consent.authorizes(reworded))
        #expect(!consent.authorizes(sameShapeDifferentFile))
        // Trailing whitespace is a difference too — there is no normalization step to rely on.
        #expect(!consent.authorizes(makeRequest(tier: .tier3, reasons: ["Draft output already exists at /tmp/a.md. "])))
    }

    @Test
    func reasonsAreComparedAsAnUnorderedSet() {
        let answered = makeRequest(tier: .tier3, reasons: ["First reason.", "Second reason."])
        let consent = RiskApprovalConsent(answering: answered)
        let reordered = makeRequest(tier: .tier3, reasons: ["Second reason.", "First reason."])
        // Multiplicity is not a difference either: a reason repeated across two steps says nothing
        // the first occurrence did not.
        let repeated = makeRequest(tier: .tier3, reasons: ["Second reason.", "First reason.", "Second reason."])

        #expect(consent.authorizes(reordered))
        #expect(consent.authorizes(repeated))
    }

    /// Tiers unequal, both directions — the pre-SONNY-62 behavior, unchanged.
    @Test
    func aHigherTierIsNeverAuthorizedAndALowerOneStillIs() {
        let answered = makeRequest(tier: .tier2, reasons: ["Shared reason."])
        let consent = RiskApprovalConsent(answering: answered)
        let higher = makeRequest(tier: .tier3, reasons: ["Shared reason."])
        let lower = makeRequest(tier: .tier1, reasons: ["Shared reason."])

        #expect(!consent.authorizes(higher))
        // The tier is checked first, so a higher tier re-arms even though every reason was
        // acknowledged — this is why the rule is a conjunction and not a replacement.
        #expect(consent.unacknowledgedReasons(in: higher).isEmpty)
        #expect(consent.authorizes(lower))
    }

    /// The rule is "no reason the user never saw", not "no reason the user never saw at equal
    /// tier" — a lower-tier assessment carrying an unseen reason still re-arms.
    @Test
    func aLowerTierCarryingAnUnseenReasonStillReArms() {
        let consent = RiskApprovalConsent(answering: makeRequest(tier: .tier3, reasons: ["Shared reason."]))
        let lowerButUnseen = makeRequest(tier: .tier2, reasons: ["Something else entirely."])

        #expect(!consent.authorizes(lowerButUnseen))
    }

    /// A standing grant — the routine trust toggle and the unattended scheduled run — is a tier
    /// ceiling and nothing more, because no reason was ever shown to compare against.
    @Test
    func aStandingGrantIsATierCeilingThatIgnoresReasons() {
        let grant = RiskApprovalConsent(tier: .tier2, coverage: .standingGrant)

        #expect(grant.authorizes(makeRequest(tier: .tier2, reasons: ["A reason nobody was shown."])))
        #expect(grant.unacknowledgedReasons(in: makeRequest(tier: .tier2, reasons: ["A reason nobody was shown."])).isEmpty)
        #expect(!grant.authorizes(makeRequest(tier: .tier3, reasons: [])))
        #expect(RiskApprovalDecision.approved(.tier2) == .approved(grant))
    }

    /// The empty acknowledged set is a real state, not a spelling of `standingGrant` — a human
    /// answered a prompt that named nothing, which is what every tier-2 confirmation is.
    ///
    /// This case builds its assessment directly because the *outcome-differing* half of it is not
    /// reachable through any adapter today: it needs a tier-3 assessment carrying no escalations,
    /// and every `defaultRiskTier` in `Sources/` is tier 2 or below while every escalation targets
    /// tier 3, so tier 3 always arrives with at least one reason. The rule is pinned here anyway,
    /// because the day an adapter defaults to tier 3 is not the day to be deriving what an empty
    /// acknowledged set means.
    @Test
    func anEmptyAcknowledgedSetIsNotAStandingGrant() {
        let answered = makeRequest(tier: .tier3, reasons: [])
        let consent = RiskApprovalConsent(answering: answered)
        let drifted = makeRequest(tier: .tier3, reasons: ["Draft output already exists at /tmp/a.md."])

        #expect(consent.coverage == .acknowledgedReasons([]))
        #expect(consent.coverage != .standingGrant)
        #expect(consent.authorizes(answered))
        #expect(!consent.authorizes(drifted))
        #expect(RiskApprovalConsent(tier: .tier3, coverage: .standingGrant).authorizes(drifted))
    }

    @Test
    func aDecisionThatWasNeverRequestedAuthorizesNothing() {
        let decision = RiskApprovalDecision.notRequested

        #expect(!decision.authorizes(makeRequest(tier: .tier0, reasons: [])))
        #expect(!decision.authorizes(makeRequest(tier: .tier3, reasons: ["Any reason."])))
    }

    // MARK: - The requirement axis (SONNY-97)

    /// The third axis's concrete failure, held to exactly the case the first two axes cannot see:
    /// equal tier, identical reasons, and only the *requirement* stricter — a lightweight
    /// confirmation answered for a tier-3 action under a relaxation grant, then re-derived as an
    /// explicit approval after the grant disappeared. The light consent must not be spent as the
    /// heavy one.
    @Test
    func aLightweightAnswerDoesNotAuthorizeAnEqualTierExplicitRequirement() {
        let answered = makeRequest(
            tier: .tier3,
            reasons: ["Shared reason."],
            requirement: .lightweightConfirmation
        )
        let consent = RiskApprovalConsent(answering: answered)
        let drifted = makeRequest(
            tier: .tier3,
            reasons: ["Shared reason."],
            requirement: .explicitApproval
        )

        #expect(consent.answeredRequirement == .lightweightConfirmation)
        #expect(consent.authorizes(answered))
        #expect(!consent.authorizes(drifted))
    }

    /// The other direction stays covered: a requirement that is equal, or *looser* than the one
    /// answered, is strictly less than what the user consented to — re-asking would be a prompt
    /// with nothing new in it, the same subset logic the reason axis uses.
    @Test
    func anAnswerStillCoversAFreshRequirementThatIsEqualOrLooser() {
        let explicit = RiskApprovalConsent(
            answering: makeRequest(tier: .tier3, reasons: ["Shared reason."], requirement: .explicitApproval)
        )

        #expect(explicit.authorizes(
            makeRequest(tier: .tier3, reasons: ["Shared reason."], requirement: .explicitApproval)
        ))
        #expect(explicit.authorizes(
            makeRequest(tier: .tier3, reasons: ["Shared reason."], requirement: .lightweightConfirmation)
        ))
    }

    /// A standing grant has no requirement axis, exactly as it has no reason axis: its consent is a
    /// pure tier ceiling by decision, and a fresh requirement at or under that ceiling is covered
    /// whatever its weight. This is what keeps the routine-trust and unattended paths untouched.
    @Test
    func aStandingGrantHasNoRequirementAxisToDriftOn() {
        let grant = RiskApprovalConsent(tier: .tier2, coverage: .standingGrant)

        #expect(grant.answeredRequirement == nil)
        #expect(grant.authorizes(makeRequest(tier: .tier2, reasons: [], requirement: .lightweightConfirmation)))
        #expect(grant.authorizes(makeRequest(tier: .tier2, reasons: [], requirement: .explicitApproval)))
        #expect(!grant.authorizes(makeRequest(tier: .tier3, reasons: ["Any reason."], requirement: .lightweightConfirmation)))
    }

    /// `init(answering:)` reads the requirement from the same request as the tier and the reasons —
    /// one source, so no call site can pair a requirement from one prompt with the reasons of
    /// another.
    @Test
    func answeringARequestRecordsItsRequirementFromThatSameRequest() {
        let request = makeRequest(tier: .tier3, reasons: ["Reason A."], requirement: .lightweightConfirmation)
        let consent = RiskApprovalConsent(answering: request)

        #expect(consent.tier == .tier3)
        #expect(consent.coverage == .acknowledgedReasons(["Reason A."]))
        #expect(consent.answeredRequirement == .lightweightConfirmation)
    }

    private func makeRequest(
        tier: CapabilityRiskTier,
        reasons: [String],
        requirement: RiskApprovalRequirement? = nil
    ) -> RiskApprovalRequest {
        let assessment = CapabilityRiskAssessment(
            defaultTier: .tier2,
            // Passed explicitly rather than derived, so a case can pin a tier that its reason list
            // would not produce on its own — that combination is exactly what the guard has to
            // handle correctly.
            effectiveTier: tier,
            escalations: reasons.map {
                // `.destructive` throughout: the consent machinery is class-agnostic (it compares
                // tiers, reason strings, and answered requirements — never classes), and
                // destructive is the class whose escalations still reach a human's consent at all.
                CapabilityRiskEscalation(fromTier: .tier2, toTier: .tier3, reason: $0, consequence: .destructive)
            }
        )
        // `requirement` is likewise explicit where a case needs a weight the mapping would not
        // produce for this tier — the requirement axis is defense-in-depth for every context
        // field that bends the mapping (Safe mode today), and the cases pin how consents treat a
        // weight difference at equal tier whatever produced it.
        return RiskApprovalRequest(
            assessment: assessment,
            requirement: requirement ?? RiskApprovalPolicy.default.requirement(
                for: assessment,
                context: ApprovalContext(safeMode: false)
            )
        )
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
            "local.apps.open-app": .tier1,
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
