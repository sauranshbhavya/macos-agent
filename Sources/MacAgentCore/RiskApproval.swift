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

    /// The permissiveness rank every relaxation property is stated on (SONNY-97): how much happens
    /// without further gating. `previewOnly` sits *below* `explicitApproval` because nothing ever
    /// runs under it — an explicit approval can still end in execution; a preview cannot.
    var permissivenessRank: Int {
        switch self {
        case .refuse:
            return 0
        case .previewOnly:
            return 1
        case .explicitApproval:
            return 2
        case .lightweightConfirmation:
            return 3
        case .autoRun:
            return 4
        }
    }

    static func stricter(of first: Self, _ second: Self) -> Self {
        first.permissivenessRank <= second.permissivenessRank ? first : second
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

    /// The tier-only baseline — the sanctioned internal sub-call `requirement(for:context:)`
    /// delegates to, and nothing else.
    ///
    /// **Demoted from `public` on SONNY-97, deliberately.** Tier-only and context-free, this is
    /// row B's "never two chained rules" violation in miniature: any caller outside this file that
    /// could reach it would be a second public path to a requirement, bypassing Safe mode, both
    /// grants, and every future `ApprovalContext` field (per-app consent lands there on row I).
    /// `private` scopes it to this file, so the compiler — not a convention — is what enforces
    /// "exactly one public function produces a `RiskApprovalRequirement`" (I8).
    private func requirement(for tier: CapabilityRiskTier) -> RiskApprovalRequirement {
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

    /// Safe mode's requirement for a tier: the *stricter* of the ordinary baseline and
    /// `safeModeFloor`, on `RiskApprovalRequirement.permissivenessRank`.
    ///
    /// A formula rather than a free-standing per-tier table on purpose, and the formula is the
    /// contract handed to row H's SONNY-90 (which supplies the real `safeMode` value): a function
    /// returning whatever seemed right per tier could define a Safe mode that is *looser* than the
    /// baseline somewhere — this shape cannot, which is what property P1 pins over the whole
    /// cross-product. Note the baseline keeps the user's own tightening through the formula:
    /// a `previewOnly` tier-2 policy stays `previewOnly`, because it is stricter than the floor.
    private func safeModeRequirement(for tier: CapabilityRiskTier) -> RiskApprovalRequirement {
        .stricter(of: requirement(for: tier), Self.safeModeFloor)
    }

    /// Everything Safe mode allows still asks first. `explicitApproval` rather than `previewOnly`
    /// because Safe mode is a user-authority dial, not a lockout: the user can always allow
    /// (escalate-never-block, I4), they are just always asked. Tier 4 still refuses through the
    /// formula — `refuse` is stricter than the floor. SONNY-90 owns revisiting this constant when
    /// the Settings surface lands; it revises the *floor*, never the formula.
    static let safeModeFloor: RiskApprovalRequirement = .explicitApproval
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
    /// The relaxation grant `requirement` was derived under (SONNY-97) — the carrier SONNY-99's
    /// ran-without-asking trace reads, populated at the one deriving site
    /// (`AgentRunner.approvalRequest`) from the same assessment and context that produced
    /// `requirement`, so the two cannot disagree on one request. `.none` under Safe mode, because
    /// no grant applied there (I5). **Reporting only, never an authorization input** — nothing may
    /// read this to gate anything; the requirement already *is* the grant's whole effect (I8).
    ///
    /// Defaulted `.none` for the construction sites that never derive one (tests building a request
    /// around a hand-made assessment) — the honest value for a request no grant was computed for.
    public var relaxationGrant: RelaxationGrant

    public init(
        assessment: CapabilityRiskAssessment,
        requirement: RiskApprovalRequirement,
        approvalCopy: RiskApprovalCopy? = nil,
        relaxationGrant: RelaxationGrant = .none
    ) {
        self.assessment = assessment
        self.requirement = requirement
        self.relaxationGrant = relaxationGrant
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
    /// The *requirement* the user actually answered — the third axis (SONNY-97), recorded because
    /// row C ended the implication "same tier means same requirement": a tier-3 ask can now be a
    /// lightweight confirmation under a relaxation grant, and a light consent must not be spent as
    /// an explicit approval at equal tier the moment the grant disappears.
    ///
    /// `nil` for a standing grant, which never answered a prompt — its consent is a pure tier
    /// ceiling by decision (see `Coverage.standingGrant`), and the requirement axis is simply not
    /// one it is expressed on, exactly like the reason axis. The only site that may record a
    /// non-nil value is `init(answering:)`, the same rule SONNY-62 set for acknowledged reasons: a
    /// consent assembled from mismatched parts is a consent nobody gave.
    public var answeredRequirement: RiskApprovalRequirement?

    public init(
        tier: CapabilityRiskTier,
        coverage: Coverage,
        answeredRequirement: RiskApprovalRequirement? = nil
    ) {
        self.tier = tier
        self.coverage = coverage
        self.answeredRequirement = answeredRequirement
    }

    /// The consent a human gives by answering `request`.
    ///
    /// Tier, reasons and the answered requirement are read from the same request in one place on
    /// purpose: a call site free to pass a tier from one assessment and reasons or a requirement
    /// from another could record a consent nobody ever gave, and that mismatch is exactly the
    /// failure this type exists to make impossible.
    public init(answering request: RiskApprovalRequest) {
        self.init(
            tier: request.assessment.effectiveTier,
            coverage: .acknowledgedReasons(Set(request.assessment.escalations.map(\.reason))),
            answeredRequirement: request.requirement
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
    /// **The rule, exactly.** Authorized when *all three* hold:
    ///
    /// 1. `request`'s effective tier is at or below this consent's tier. Unchanged from before
    ///    SONNY-62, and still evaluated first: a tier that rose re-arms regardless of reasons.
    /// 2. Every escalation reason in `request` is one this consent already acknowledged.
    /// 3. `request`'s freshly derived requirement is not *stricter* than the one this consent
    ///    answered — including at equal tier, which is the case the first two checks cannot see
    ///    (SONNY-97). Before row C the requirement was a pure function of the tier, so "same tier"
    ///    implied "same requirement" and this axis had nothing to compare; a relaxation grant ends
    ///    that implication, and the concrete failure is a lightweight confirmation answered for a
    ///    tier-3 action being spent as an explicit approval after the grant disappears. Skipped for
    ///    a standing grant, whose consent is a pure tier ceiling on both other axes too.
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
    /// Takes the whole `RiskApprovalRequest` rather than its assessment because the third check
    /// reads `request.requirement` — the fresh requirement the engine just derived under the run's
    /// real context. SONNY-62 anticipated exactly this: the requirement axis is the same masking
    /// class arriving through a second door, and it belongs in this function, next to the other two.
    public func authorizes(_ request: RiskApprovalRequest) -> Bool {
        guard request.assessment.effectiveTier.rawValue <= tier.rawValue else {
            return false
        }
        guard unacknowledgedReasons(in: request).isEmpty else {
            return false
        }
        if let answeredRequirement {
            return request.requirement.permissivenessRank >= answeredRequirement.permissivenessRank
        }
        return true
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

/// The authority context an approval requirement is derived under (SONNY-97, row C): how the plan
/// came to exist, and whether the user's Safe mode is engaged.
///
/// This is an input to `RiskApprovalPolicy.requirement(for:context:)` and nothing else — it never
/// reaches `assessRisk`, which stays origin-blind so `effectiveTier` remains a pure function of the
/// plan. Threaded non-defaulted into `AgentRunner.approvalRequest` and `AgentRunner.execute` for the
/// same reason `scope:` is: `execute` re-derives the requirement internally, so a context threaded
/// at one site and defaulted at the other would prompt under one requirement and execute under
/// another, with green tests and a lying log.
public struct ApprovalContext: Equatable, Sendable {
    public var origin: PreparedPlanSource
    /// Row H's SONNY-90 supplies the real, Settings-backed value; until then row C's only caller
    /// writes `false` at one named site (`AgentViewModel.approvalContext(for:)`). When true, the
    /// requirement is `safeModeRequirement(for:)`'s formula and no grant is ever computed (I5).
    public var safeMode: Bool
    // Row I's SONNY-91 adds `appControlConsent` HERE, as a field this function maps — never as a
    // rule applied to the function's return value, which is the post-hoc clamp I8 forbids.

    // Explicit rather than synthesized: the memberwise initializer of a public struct is internal,
    // and `MacAgent` is a separate target.
    public init(origin: PreparedPlanSource, safeMode: Bool) {
        self.origin = origin
        self.safeMode = safeMode
    }
}

/// Which relaxation applied to a requirement — the *why* behind a prompt that got lighter, kept as
/// two cases even though they map identically today, because they have different revocation stories
/// and different user-facing explanations: "because this is inside Client Alpha" and "because you
/// built this on screen" are different facts, and a user can act on the difference.
public enum RelaxationGrant: String, Codable, Equatable, Sendable {
    case none
    /// The plan-level scope roll-up is `.inScope` — the boundary-earned grant of the founder
    /// charter (2026-08-04): in-scope tier 2 auto-runs, in-scope tier 3 drops to a lightweight
    /// confirmation.
    case inScopeWorkspace = "in_scope_workspace"
    /// The plan came from `PreparedPlanSource.directUserAction`: the user built it field by field
    /// on a UI surface, with no natural language interpreted on the way (founder observation,
    /// 2026-08-07). This grant exists because the verdict grant structurally cannot reach the
    /// workspace-sheet edit: `edit_workspace` classifies as `.none` scoped resources, so a sheet
    /// edit's roll-up is never `.inScope`.
    case directUserAuthored = "direct_user_authored"

    /// The §2.1 grant formula, per-grant eligibility and all (PR #45 review, F2: eligibility is
    /// tested *per grant*, never once ahead of both — SONNY-98 drops `byDirectUserOrigin` alone on
    /// a boundary-changing edit, and a single "eligibility forbids it" guard ahead of both branches
    /// cannot express that).
    ///
    /// `.inScopeWorkspace` is tested first so anything surfacing a reason names the stronger,
    /// boundary-earned grant when both apply.
    ///
    /// Only `.inScope` ever grants (I3). The other three verdicts and `nil` fail the equality test
    /// structurally, and the three-state trap the verdict's own doc comment warns about — `nil`
    /// ("no workspace bound") versus `.unconstrained` ("bound, and says nothing about this kind") —
    /// stays uncollapsed because neither compares equal to `.inScope`. A `nil` eligibility (an
    /// assessment that never went through the executor's fold) grants nothing: fail closed, never
    /// invented.
    ///
    /// **I10, stated as a rule even though SONNY-84 discharges it structurally:** an `.inScope`
    /// verdict reached through `WorkspaceScope`'s *name-fallback* key must never grant. Since
    /// SONNY-84, every installed app earns a real `bundle:` key, so a name-fallback match survives
    /// only for genuinely uninstalled entries — which cannot be running and so cannot produce a
    /// `.resolvedApp` match at all. Today the sole `.resolvedApp` producer
    /// (`RunningAppSwitchCapabilityAdapter`) is also tier 1, a tier no grant column touches. A
    /// future tier bump on any name-fallback-matched operation is a conscious decision against this
    /// stated rule, not a silent reopening of the imposter gap.
    static func grant(for assessment: CapabilityRiskAssessment, context: ApprovalContext) -> RelaxationGrant {
        let eligibility = assessment.relaxationEligibility ?? []
        if eligibility.contains(.byWorkspaceScope), assessment.scopeVerdict == .inScope {
            return .inScopeWorkspace
        }
        if eligibility.contains(.byDirectUserOrigin), context.origin == .directUserAction {
            return .directUserAuthored
        }
        return .none
    }

    /// The grant `requirement(for:context:)` actually applied — `.none` under Safe mode, mirroring
    /// I5's composition rule (the requirement function returns before the grant is computed, so a
    /// Safe-mode run relaxed nothing and must not report that it did). This is the reporting seam
    /// `RiskApprovalRequest.relaxationGrant` is filled from; it is never an authorization input.
    static func applied(for assessment: CapabilityRiskAssessment, context: ApprovalContext) -> RelaxationGrant {
        context.safeMode ? .none : grant(for: assessment, context: context)
    }
}

public extension RiskApprovalPolicy {
    /// The one public path from an assessment to an approval requirement (SONNY-97, row C — I8:
    /// exactly one public function produces a `RiskApprovalRequirement`, and no public function
    /// takes one and returns a different one; per-app consent and every future authority axis lands
    /// *here*, as an `ApprovalContext` field this mapping reads, never as a rule chained after it).
    ///
    /// Body order is the composition rule: Safe mode returns before the grant is computed, so
    /// "Safe mode wins — relaxation never applies inside it" is structural rather than remembered
    /// (I5). The switch below is a function of `(effectiveTier, grant)` *on a given policy* —
    /// `self` is the policy, and two cells read `tier2Mode` exactly as the tier-only baseline
    /// always has for tiers 1 and 2. That is not a chained rule: no intermediate requirement is
    /// produced and nothing re-fires.
    ///
    /// Relaxation is a requirement override and nothing else: it never writes `effectiveTier` (I1),
    /// never writes `escalations` and never changes `approvalCopy` (I2) — the assessment passes
    /// through this function untouched, so relaxation changes the *weight* of the ask, never the
    /// sentence. No cell refuses that would not have refused before (I4), and no grant cell is ever
    /// less permissive than its `.none` column (P2).
    func requirement(
        for assessment: CapabilityRiskAssessment,
        context: ApprovalContext
    ) -> RiskApprovalRequirement {
        if context.safeMode {
            return safeModeRequirement(for: assessment.effectiveTier)
        }
        switch (assessment.effectiveTier, RelaxationGrant.grant(for: assessment, context: context)) {
        case (.tier0, .none), (.tier0, .inScopeWorkspace), (.tier0, .directUserAuthored):
            return .autoRun
        case (.tier1, .none), (.tier1, .inScopeWorkspace), (.tier1, .directUserAuthored):
            return requirement(for: .tier1)
        case (.tier2, .none):
            return requirement(for: .tier2)
        case (.tier2, .inScopeWorkspace), (.tier2, .directUserAuthored):
            // Relaxation never exceeds the user's own policy (I9): a `previewOnly` tier-2 mode is
            // the user's own tightening, and a grant must not override it. Unreachable in the
            // shipped app today — nothing constructs a non-default policy outside tests — but a
            // dead configuration surface that comes alive later should not silently defeat the
            // preference it exists to express.
            return tier2Mode == .previewOnly ? .previewOnly : .autoRun
        case (.tier3, .none):
            return requirement(for: .tier3)
        case (.tier3, .inScopeWorkspace), (.tier3, .directUserAuthored):
            return .lightweightConfirmation
        case (.tier4, .none), (.tier4, .inScopeWorkspace), (.tier4, .directUserAuthored):
            return .refuse
        }
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
}
