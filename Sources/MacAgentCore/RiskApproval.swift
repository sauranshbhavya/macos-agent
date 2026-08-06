import Foundation

public enum RiskApprovalRule: String, Codable, CaseIterable, Equatable, Sendable {
    case autoRun = "auto_run"
    case autoRunUnlessPolicyRequiresApproval = "auto_run_unless_policy_requires_approval"
    case previewOrLightweightConfirmation = "preview_or_lightweight_confirmation"
    case explicitApprovalRequired = "explicit_approval_required"
    case refuseOrRequireTakeover = "refuse_or_require_takeover"

    public var displayName: String {
        switch self {
        case .autoRun:
            return "Auto-run"
        case .autoRunUnlessPolicyRequiresApproval:
            return "Auto-run unless policy requires approval"
        case .previewOrLightweightConfirmation:
            return "Preview or lightweight confirmation"
        case .explicitApprovalRequired:
            return "Explicit approval required"
        case .refuseOrRequireTakeover:
            return "Refuse or require takeover"
        }
    }
}

public enum RiskApprovalRequirement: String, Codable, CaseIterable, Equatable, Sendable {
    case autoRun = "auto_run"
    case previewOnly = "preview_only"
    case lightweightConfirmation = "lightweight_confirmation"
    case explicitApproval = "explicit_approval"
    case refuse = "refuse"

    public var displayName: String {
        switch self {
        case .autoRun:
            return "Auto-run"
        case .previewOnly:
            return "Preview only"
        case .lightweightConfirmation:
            return "Lightweight confirmation"
        case .explicitApproval:
            return "Explicit approval"
        case .refuse:
            return "Refuse"
        }
    }

    public var requiresUserApproval: Bool {
        switch self {
        case .lightweightConfirmation, .explicitApproval:
            return true
        case .autoRun, .previewOnly, .refuse:
            return false
        }
    }
}

public enum Tier2ApprovalMode: String, Codable, CaseIterable, Equatable, Sendable {
    case previewOnly = "preview_only"
    case lightweightConfirmation = "lightweight_confirmation"
}

public struct RiskApprovalPolicy: Codable, Equatable, Sendable {
    public static let `default` = RiskApprovalPolicy()

    public var requireApprovalForTier1: Bool
    public var tier2Mode: Tier2ApprovalMode

    public init(
        requireApprovalForTier1: Bool = false,
        tier2Mode: Tier2ApprovalMode = .lightweightConfirmation
    ) {
        self.requireApprovalForTier1 = requireApprovalForTier1
        self.tier2Mode = tier2Mode
    }

    public func requirement(for tier: CapabilityRiskTier) -> RiskApprovalRequirement {
        switch tier {
        case .tier0:
            return .autoRun
        case .tier1:
            return requireApprovalForTier1 ? .lightweightConfirmation : .autoRun
        case .tier2:
            switch tier2Mode {
            case .previewOnly:
                return .previewOnly
            case .lightweightConfirmation:
                return .lightweightConfirmation
            }
        case .tier3:
            return .explicitApproval
        case .tier4:
            return .refuse
        }
    }
}

public struct RiskApprovalCopy: Codable, Equatable, Sendable {
    public var actionDescription: String
    public var riskReason: String
    public var involvedResource: String
    public var dataLeavesDevice: Bool
    public var undoDescription: String

    public init(
        actionDescription: String,
        riskReason: String,
        involvedResource: String,
        dataLeavesDevice: Bool,
        undoDescription: String
    ) {
        self.actionDescription = actionDescription
        self.riskReason = riskReason
        self.involvedResource = involvedResource
        self.dataLeavesDevice = dataLeavesDevice
        self.undoDescription = undoDescription
    }

    public var lines: [String] {
        [
            "What Sonny is about to do: \(actionDescription)",
            "Why this is risky: \(riskReason)",
            "Involves: \(involvedResource)",
            "Data leaves device: \(dataLeavesDevice ? "yes" : "no")",
            "Undo: \(undoDescription)"
        ]
    }
}

public struct RiskApprovalRequest: Codable, Equatable, Sendable {
    public var assessment: CapabilityRiskAssessment
    public var requirement: RiskApprovalRequirement
    public var approvalCopy: RiskApprovalCopy

    public init(
        assessment: CapabilityRiskAssessment,
        requirement: RiskApprovalRequirement,
        approvalCopy: RiskApprovalCopy? = nil
    ) {
        self.assessment = assessment
        self.requirement = requirement
        self.approvalCopy = approvalCopy ?? assessment.approvalCopy ?? RiskApprovalCopy(
            actionDescription: "Run the prepared plan",
            riskReason: assessment.effectiveTier.semanticName,
            involvedResource: "Prepared Sonny action",
            dataLeavesDevice: false,
            undoDescription: "No automatic undo is available."
        )
    }

    public var requiresUserApproval: Bool {
        requirement.requiresUserApproval
    }
}

public enum RiskApprovalDecision: Codable, Equatable, Sendable {
    case notRequested
    case approved(CapabilityRiskTier)
}

public enum RiskApprovalError: Error, Equatable, LocalizedError {
    case approvalRequired(RiskApprovalRequest)
    case previewOnly(RiskApprovalRequest)
    case refused(RiskApprovalRequest)

    public var errorDescription: String? {
        switch self {
        case .approvalRequired(let request):
            return "Approval required before Sonny can run this \(request.assessment.effectiveTier.displayName.lowercased()) action."
        case .previewOnly:
            return "This action is limited to preview by the current approval policy."
        case .refused(let request):
            return "Sonny refused this \(request.assessment.effectiveTier.displayName.lowercased()) action."
        }
    }
}

public struct CapabilityRiskEscalation: Codable, Equatable, Sendable {
    public var fromTier: CapabilityRiskTier
    public var toTier: CapabilityRiskTier
    public var reason: String

    public init(fromTier: CapabilityRiskTier, toTier: CapabilityRiskTier, reason: String) {
        self.fromTier = fromTier
        self.toTier = toTier
        self.reason = reason
    }
}

public struct CapabilityRiskAssessment: Codable, Equatable, Sendable {
    public var defaultTier: CapabilityRiskTier
    public var effectiveTier: CapabilityRiskTier
    public var approvalCopy: RiskApprovalCopy?
    public var escalations: [CapabilityRiskEscalation]
    /// The plan-level workspace-scope roll-up, or `nil` when the task was assessed `.unscoped`.
    ///
    /// **Nothing in this branch reads it to relax anything**, and that is the point: row C needs a
    /// typed input rather than re-deriving scope from escalation strings. `nil` means "no workspace
    /// was bound", which is not the same as `.unconstrained` ("a workspace was bound and says
    /// nothing about this kind") — collapsing the two would hand row C a value it cannot act on
    /// safely, since only one of them ever describes a real boundary.
    ///
    /// Optional and defaulted so every adapter's own `CapabilityRiskAssessment(...)` compiles
    /// unchanged: an adapter assesses one segment and has no plan-level view, so `nil` there is the
    /// honest answer rather than a forgotten one. The executor is the only thing that fills it in.
    public var scopeVerdict: ScopeVerdict?

    public init(
        defaultTier: CapabilityRiskTier,
        effectiveTier: CapabilityRiskTier? = nil,
        approvalCopy: RiskApprovalCopy? = nil,
        escalations: [CapabilityRiskEscalation] = [],
        scopeVerdict: ScopeVerdict? = nil
    ) {
        self.defaultTier = defaultTier
        self.effectiveTier = effectiveTier ?? Self.highestTier(defaultTier: defaultTier, escalations: escalations)
        self.approvalCopy = approvalCopy
        self.escalations = escalations
        self.scopeVerdict = scopeVerdict
    }

    public func approvalRequirement(policy: RiskApprovalPolicy = .default) -> RiskApprovalRequirement {
        policy.requirement(for: effectiveTier)
    }

    private static func highestTier(
        defaultTier: CapabilityRiskTier,
        escalations: [CapabilityRiskEscalation]
    ) -> CapabilityRiskTier {
        let highestRaw = escalations
            .map(\.toTier.rawValue)
            .reduce(defaultTier.rawValue, max)
        return CapabilityRiskTier(rawValue: highestRaw) ?? defaultTier
    }
}

public extension CapabilityRiskTier {
    var semanticName: String {
        switch self {
        case .tier0:
            return "Informational"
        case .tier1:
            return "Low impact"
        case .tier2:
            return "Local modification"
        case .tier3:
            return "External or destructive"
        case .tier4:
            return "Prohibited or unavailable"
        }
    }

    var defaultApprovalRule: RiskApprovalRule {
        switch self {
        case .tier0:
            return .autoRun
        case .tier1:
            return .autoRunUnlessPolicyRequiresApproval
        case .tier2:
            return .previewOrLightweightConfirmation
        case .tier3:
            return .explicitApprovalRequired
        case .tier4:
            return .refuseOrRequireTakeover
        }
    }

    func approvalRequirement(policy: RiskApprovalPolicy = .default) -> RiskApprovalRequirement {
        policy.requirement(for: self)
    }
}
