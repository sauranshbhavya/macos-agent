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

/// What an approval actually authorized — which is not the same thing as how risky the action
/// happened to be at the moment the question was asked.
///
/// **Why a tier alone was never enough.** `AgentRunner.execute` re-assesses the plan fresh on every
/// call, because the world drifts between the moment a prompt is answered and the moment the run
/// executes. The guard comparing the two used to compare bare tiers, so two *different* tier-3
/// causes compared equal: an approval given for "example.com is not part of the Research workspace"
/// silently covered a "draft output already exists" escalation that appeared while the prompt sat
/// open, and the run replaced a file the user was never asked about. (SONNY-62, reproduced from a
/// real observed run.) The tier bounds how much a run may cost; it never described what the user
/// agreed to.
public struct RiskApprovalConsent: Codable, Equatable, Sendable {
    /// What this consent covers *beyond* its tier ceiling.
    public enum Coverage: Codable, Equatable, Sendable {
        /// A standing grant: a *class* of runs pre-authorized ahead of time rather than one prompt
        /// answered in front of a human. Nobody was shown a reason, so there is no reason set to
        /// compare a fresh assessment against, and the tier ceiling is the whole of the consent.
        ///
        /// This is what a routine's trust toggle and the unattended scheduled path grant, and
        /// keeping them on a pure tier ceiling is deliberate rather than an omission. Their ceiling
        /// is tier 2 — no external or destructive action can pass it at all — and re-arming an
        /// unattended run on a reason nobody is present to read would convert a grant the user
        /// explicitly gave into a paused schedule. (Today the two rules coincide exactly: every
        /// escalation any adapter or the scope evaluator produces targets tier 3, so an assessment
        /// at or below tier 2 carries no escalations for either rule to compare. They diverge only
        /// if a tier-2 escalation is ever added, and this case records which answer that day gets.)
        case standingGrant

        /// One prompt, answered by a human who was shown exactly these escalation reasons.
        ///
        /// **The empty set is the ordinary shape, not an edge case** — a tier-2 confirmation raises
        /// no escalations at all, so its prompt names no reasons. It is still a different statement
        /// from `standingGrant`: this one says a human answered a prompt that named nothing, that
        /// one says no prompt was answered. **But as of SONNY-62 the difference cannot change an
        /// authorize/deny outcome, and claiming it could was this file's own first mistake.** For
        /// the two to disagree on an outcome, a consent would need a tier-3 ceiling with an empty
        /// acknowledged set. No adapter can produce that assessment: no `defaultTier` anywhere can
        /// reach tier 3, while all eight `CapabilityRiskEscalation` construction sites target tier
        /// 3 and each assessment forwards the escalations of any plan nested inside it — so a
        /// tier-3 assessment always carries at least one reason, and a non-empty reason set always
        /// means tier 3.
        ///
        /// **Why no `defaultTier` reaches tier 3.** Swept at `04ce7e4` — and first at `042f74e`,
        /// before this branch rebased onto row F, which edited several of the files counted here and
        /// so required the whole sweep re-run rather than carried — over every `defaultRiskTier`
        /// occurrence and every `CapabilityRiskAssessment` construction site in `Sources/`, rather
        /// than over the adapters that looked relevant; every figure here is the re-measured one.
        /// All 25 literals are tier 2 or below (7/8/10 across tiers 0/1/2), and the six
        /// `descriptor.defaultRiskTier` forwards each resolve to a `static let` in
        /// `AppWebsiteActionDescriptors` — one of those same literals. **Three**
        /// sites compute the value at assessment time instead of forwarding a literal, not one:
        /// `InvokeShortcut` picks `.tier1` on a clean run history and its own literal otherwise, so
        /// it only lowers — but `RunRoutine` and `SaveRoutine` each take the *maximum* of their own
        /// literal and the nested plan's `defaultTier`, and `AgentActionExecutor` maximizes across
        /// a plan's adapters. A maximum is free to move a default *upward*, which is why "only
        /// lowers" was the wrong argument and this paragraph's second mistake. What actually bounds
        /// it: a maximum over values that are all tier 2 or below is itself tier 2 or below, and a
        /// nested `defaultTier` is another such maximum one level down, so the bound holds at every
        /// nesting depth.
        ///
        /// The two cases do differ in the *trace* today — only this one can emit `risk.rearmed` —
        /// and they will differ in outcome the day an adapter defaults to tier 3 or an escalation
        /// targets tier 2.
        case acknowledgedReasons(Set<String>)
    }

    /// The ceiling. A fresh assessment above it is never authorized, whatever its reasons.
    public var tier: CapabilityRiskTier
    public var coverage: Coverage

    public init(tier: CapabilityRiskTier, coverage: Coverage) {
        self.tier = tier
        self.coverage = coverage
    }

    /// The consent a human gives by answering `request`.
    ///
    /// Tier and reasons are read from the same request in one place on purpose: a call site free to
    /// pass a tier from one assessment and reasons from another could record a consent nobody ever
    /// gave, and that mismatch is exactly the failure this type exists to make impossible.
    public init(answering request: RiskApprovalRequest) {
        self.init(
            tier: request.assessment.effectiveTier,
            coverage: .acknowledgedReasons(Set(request.assessment.escalations.map(\.reason)))
        )
    }

    /// The escalation reasons in `request` this consent never covered, in the assessment's own
    /// order, deduplicated.
    ///
    /// Empty for a standing grant — not because such a grant covers everything, but because reasons
    /// are not the axis it is expressed on; its tier ceiling is checked separately by
    /// ``authorizes(_:)``.
    public func unacknowledgedReasons(in request: RiskApprovalRequest) -> [String] {
        guard case .acknowledgedReasons(let acknowledged) = coverage else {
            return []
        }
        var seen: Set<String> = []
        return request.assessment.escalations
            .map(\.reason)
            .filter { !acknowledged.contains($0) && seen.insert($0).inserted }
    }

    /// Whether this consent still authorizes `request` — the stale-approval question, asked fresh at
    /// execution time.
    ///
    /// **The rule, exactly.** Authorized when *both* hold:
    ///
    /// 1. `request`'s effective tier is at or below this consent's tier. Unchanged from before
    ///    SONNY-62, and still evaluated first: a tier that rose re-arms regardless of reasons.
    /// 2. Every escalation reason in `request` is one this consent already acknowledged.
    ///
    /// **Subset, not equality.** A reason that *disappeared* between the prompt and the execution
    /// means the world got less risky along that axis — the user consented to strictly more than is
    /// now about to happen, so re-asking would be a prompt with nothing new in it. A reason that
    /// *appeared* is one they were never shown, and re-arms.
    ///
    /// **Unordered, and multiplicity-insensitive.** Reasons are compared as a set. Assessment order
    /// is an artifact of segment iteration, and a reason repeated across two steps says nothing the
    /// first occurrence did not.
    ///
    /// **Compared as exact strings, so a reworded reason re-arms.** This is fail-closed on purpose.
    /// A reason string is literally the sentence the approval panel showed the user, and nothing
    /// here can tell a cosmetic rewording from "already exists at /a.md" becoming
    /// "already exists at /b.md" — the two are the same shape and only one of them is harmless.
    /// The cost of being wrong in this direction is one extra prompt; in the other, it is the bug
    /// this type was added to fix.
    ///
    /// **A re-arm cannot loop.** The re-arm carries the *fresh* request to the user, so the consent
    /// recorded when they answer it acknowledges the new reasons, and the next execution's
    /// assessment — deterministic for a fixed plan and a fixed world — is covered.
    ///
    /// Takes the whole `RiskApprovalRequest` rather than its assessment because the requirement is
    /// the next axis to land here: row C (SONNY-97) records which requirement the user actually
    /// answered and re-arms when a stricter one appears at equal tier, which is this same masking
    /// class arriving through a second door. That check belongs in this function, next to these two.
    public func authorizes(_ request: RiskApprovalRequest) -> Bool {
        guard request.assessment.effectiveTier.rawValue <= tier.rawValue else {
            return false
        }
        return unacknowledgedReasons(in: request).isEmpty
    }
}

public enum RiskApprovalDecision: Codable, Equatable, Sendable {
    case notRequested
    case approved(RiskApprovalConsent)

    /// A standing grant, expressed as the bare tier ceiling it is.
    ///
    /// Overloads the case's own constructor so that every pre-SONNY-62 `.approved(tier)` call site
    /// keeps meaning exactly what it meant. In `Sources/` those sites are exactly the two standing
    /// grants — the unattended scheduled run and a routine's trust toggle — and neither ever answered
    /// a prompt; the rest of the callers are tests, which use it to exercise a bare tier ceiling
    /// deliberately. A prompt a human answered must use `approved(answering:)` instead, or the
    /// consent it records will cover reasons nobody was shown.
    public static func approved(_ tier: CapabilityRiskTier) -> RiskApprovalDecision {
        .approved(RiskApprovalConsent(tier: tier, coverage: .standingGrant))
    }

    /// The decision a human makes by answering `request`.
    public static func approved(answering request: RiskApprovalRequest) -> RiskApprovalDecision {
        .approved(RiskApprovalConsent(answering: request))
    }

    /// Whether this decision authorizes `request` at execution time. `.notRequested` never does.
    public func authorizes(_ request: RiskApprovalRequest) -> Bool {
        guard case .approved(let consent) = self else {
            return false
        }
        return consent.authorizes(request)
    }
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

/// Which relaxation grants an operation may ever take (SONNY-97, row C).
///
/// The verdict grant is protected by the verdict machinery itself — `.opaque` poisons the plan
/// roll-up, `.unconstrained` and `nil` never qualify. The origin grant has none of that protection,
/// because it bypasses scope entirely; this set is its fail-closed containment, and the verdict
/// grant takes the same gate for uniformity. Each bit gates exactly one grant, and they are
/// independent on purpose: SONNY-98 narrows a boundary-changing workspace edit by dropping
/// `byDirectUserOrigin` *alone*, leaving `byWorkspaceScope` set, so nothing here may collapse the
/// two into one "eligible at all" answer (PR #45 review, F2).
public struct OperationRelaxation: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The operation may take `.inScopeWorkspace` — the founder charter's verdict grant.
    public static let byWorkspaceScope = OperationRelaxation(rawValue: 1 << 0)
    /// The operation may take `.directUserAuthored` — the screen-built-plan origin grant.
    public static let byDirectUserOrigin = OperationRelaxation(rawValue: 1 << 1)

    public static let all: OperationRelaxation = [.byWorkspaceScope, .byDirectUserOrigin]

    /// The static classification: what each operation may ever take, before any adapter narrows it.
    ///
    /// `byWorkspaceScope` is a **denylist** — every operation except `.runRoutine` and
    /// `.invokeShortcut`. `.runRoutine` loses it deliberately: SONNY-54's founder decision
    /// (2026-08-06) made the per-routine trust toggle the single door for skipping a routine's
    /// tier-2 prompt, scheduled *or* manual, and without this exclusion an untrusted routine running
    /// inside a workspace would auto-run through a second door the founder never opened — on its
    /// first run, with its arbitrary steps unreviewed. Scope answers "right place", never "right
    /// severity" — and never "right thing". The cost is recorded and accepted: a user may ask why
    /// their routine still confirms inside a workspace where typing the same command does not.
    /// `.invokeShortcut` loses it too — belt-and-braces for the verdict grant (a scoped Shortcut is
    /// already `.opaque`) but load-bearing for the origin grant, which never consults the verdict.
    ///
    /// `byDirectUserOrigin` is an **allowlist** — only `.editWorkspace`, the one operation a screen
    /// builds field by field today. A future surface's operation joins by conscious classification
    /// here, never by falling into a wider bucket.
    ///
    /// **No `default:` clause, for the reason `PlanScopedResources` already refuses one**: a new
    /// operation must not be able to land unclassified. When row I adds its vision operation, the
    /// compiler forces a decision, and classifying it as granting neither is the answer recorded on
    /// SONNY-92.
    public static func relaxation(for operation: AgentOperation) -> OperationRelaxation {
        switch operation {
        case .editWorkspace:
            return [.byWorkspaceScope, .byDirectUserOrigin]
        case .runRoutine, .invokeShortcut:
            return []
        case .scanSelectLargestFiles, .createZip, .scanDocx, .convertDocxToPDF, .openHackerNews,
             .fetchHNHeadlines, .writeMarkdown, .webToMarkdown, .openApp, .openAppSearchURL,
             .openURL, .playMedia, .getFinderSelection, .revealInFinder, .showPermissionReadiness,
             .saveRoutine, .createWorkspace, .openWorkspace, .openGeneratedArtifact,
             .createLocalDraft, .calculateUtility, .lookupClipboardHistory, .expandSnippet,
             .saveSnippet, .switchRunningApp, .lookupRecentArtifacts, .clarify, .unsupported:
            return [.byWorkspaceScope]
        }
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
    /// The plan-level relaxation-eligibility roll-up (SONNY-97): the intersection, across every
    /// step, of each operation's static `OperationRelaxation.relaxation(for:)` classification and
    /// any narrowing the step's own adapter declared. Any step that forbids a grant forbids it for
    /// the whole plan — the same poison shape `.opaque` already has on the verdict axis.
    ///
    /// Optional with the same meaning as `scopeVerdict`'s optionality, and it is call-site
    /// compatibility, not disk migration (this type is embedded in none of the local stores —
    /// re-verified on SONNY-97): `nil` from an adapter means "no narrowing declared", which the
    /// executor's fold treats as identity. An adapter that *does* set it may only narrow what the
    /// static classification allows — the fold intersects, so widening is structurally
    /// inexpressible. On an assessment that never went through the executor's fold, `nil` grants
    /// nothing: the grant computation fails closed rather than inventing an eligibility.
    public var relaxationEligibility: OperationRelaxation?

    public init(
        defaultTier: CapabilityRiskTier,
        effectiveTier: CapabilityRiskTier? = nil,
        approvalCopy: RiskApprovalCopy? = nil,
        escalations: [CapabilityRiskEscalation] = [],
        scopeVerdict: ScopeVerdict? = nil,
        relaxationEligibility: OperationRelaxation? = nil
    ) {
        self.defaultTier = defaultTier
        self.effectiveTier = effectiveTier ?? Self.highestTier(defaultTier: defaultTier, escalations: escalations)
        self.approvalCopy = approvalCopy
        self.escalations = escalations
        self.scopeVerdict = scopeVerdict
        self.relaxationEligibility = relaxationEligibility
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
