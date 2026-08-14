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

    /// The permissiveness rank every approval property is stated on (SONNY-97): how much happens
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

    /// The tier-only baseline. Since the consequence rule (2026-08-13) its sole caller is
    /// `safeModeRequirement(for:)` — the ordinary path maps tiers directly and no longer consults
    /// it, which also means `requireApprovalForTier1` has **no observable effect anywhere** (its
    /// tightening is subsumed by Safe mode's floor) and `tier2Mode == .previewOnly` shows only
    /// under Safe mode. Both dials are kept pending a founder decision on deleting them — flagged
    /// in the pivot's closing records rather than removed unilaterally.
    ///
    /// **Demoted from `public` on SONNY-97, deliberately.** Tier-only and context-free, any caller
    /// outside this file would be a second public path to a requirement, bypassing Safe mode and
    /// every future `ApprovalContext` field (per-app consent lands there on row I). `private`
    /// scopes it to this file, so the compiler — not a convention — is what enforces "exactly one
    /// public function produces a `RiskApprovalRequirement`" (I8).
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

    /// The disclosure normal approval surfaces render. "Data leaves device" is deliberately NOT
    /// among these four — spec §11.3 made it one of five mandatory lines on every approval
    /// surface, and E9 (founder-ratified 2026-08-08, kept in full by C7 on 2026-08-12) is a
    /// conscious deviation: the label leaves all normal surfaces and renders only inside Safe
    /// mode, where `safeModeLines` restores it in its original position. (E9's other half — an
    /// in-product after-the-fact egress log — was superseded by the founder on 2026-08-14; the
    /// Safe-mode label is the product's one egress disclosure.)
    public var lines: [String] {
        [
            "What Sonny is about to do: \(actionDescription)",
            "Why this is risky: \(riskReason)",
            "Involves: \(involvedResource)",
            "Undo: \(undoDescription)"
        ]
    }

    /// The Safe-mode disclosure: the same lines with "Data leaves device: yes/no" restored where
    /// §11.3 put it, sourced from the bidirectionally-honest `dataLeavesDevice` classification
    /// (SONNY-32's fix, landed with SONNY-88 and kept when the ledger was deleted — the
    /// classification cannot lie in either direction, which is what makes the surviving label
    /// worth rendering).
    public var safeModeLines: [String] {
        // Derived from `lines`, never a second copy of it (PR #49 F11): this is security-bearing
        // disclosure copy, and a wording edit that landed in one list but not the other would
        // diverge the two surfaces silently. Index 3 is the label's §11.3 position, before Undo.
        var all = lines
        all.insert(dataLeavesDeviceLine, at: 3)
        return all
    }

    public var dataLeavesDeviceLine: String {
        "Data leaves device: \(dataLeavesDevice ? "yes" : "no")"
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
        ///
        /// The consequence rule (2026-08-13) leans on the same ceiling from the other side: an
        /// advisory-only tier 3 auto-runs when a user dispatched it, but no unattended run can
        /// *reach* one — a scheduled run is `.unscoped` (no out-of-scope advisories) and
        /// `StoredRoutine.forbiddenStepOperations` rejects `edit_workspace` (no removal or
        /// widening advisories) — so every escalation an unattended run can raise is one of the
        /// destructive replace/collision family, which still asks, and which this tier-2 ceiling
        /// still refuses. Reachability, not a type-level guarantee; pinned by a named test.
        case standingGrant

        /// One prompt, answered by a human who was shown exactly these escalation reasons.
        ///
        /// **The empty set is a real shape, not an edge case** — under the consequence rule the
        /// prompts that name no reasons are Safe mode's (every tier that could run asks there,
        /// escalations or not; before the rule, every ordinary tier-2 confirmation was this shape
        /// too). It is still a different statement from `standingGrant`: this one says a human
        /// answered a prompt that named nothing, that one says no prompt was answered. **But as of
        /// SONNY-62 the difference cannot change an authorize/deny outcome, and claiming it could
        /// was this file's own first mistake.** For the two to disagree on an outcome, a consent
        /// would need a tier-3 ceiling with an empty acknowledged set. No adapter can produce that
        /// assessment: no `defaultTier` anywhere can reach tier 3, while all nine
        /// `CapabilityRiskEscalation` construction sites target tier 3 (the eight counted at
        /// `04ce7e4` plus SONNY-98's whitelist-root widening; re-swept at `972c62a`) and each
        /// assessment forwards the escalations of any plan nested inside it — so a tier-3
        /// assessment always carries at least one reason, and a non-empty reason set always means
        /// tier 3.
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
    /// the requirement stopped being a pure function of the tier: first through row C's grants
    /// (since superseded), now through `ApprovalContext` (Safe mode today, per-app consent on row
    /// I) and the escalations' consequence classes. A consent given to a lighter ask must never be
    /// spent on a stricter one at equal tier, whatever produced the difference — the axis is
    /// defense-in-depth for every context field that will ever bend the mapping.
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
    ///    (SONNY-97). The requirement stopped being a pure function of the tier — first through
    ///    row C's grants (superseded 2026-08-13), now through `ApprovalContext` and the
    ///    escalations' consequence classes — so "same tier" no longer implies "same requirement",
    ///    and a light consent must not be spent on a stricter fresh ask, whatever bent the
    ///    mapping. Skipped for a standing grant, whose consent is a pure tier ceiling on both
    ///    other axes too.
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
    /// What kind of consequence this escalation is warning about — the axis the founder's
    /// consequence rule (2026-08-13) gates on. Sonny asks permission only when an action is
    /// **destructive** (destroys or replaces existing user data or user-built artifacts) or
    /// **affects someone other than the user** (send/post/share/publish/purchase). Everything else
    /// runs without asking and is made legible by the ran-without-asking trace instead.
    public enum Consequence: String, Codable, CaseIterable, Equatable, Sendable {
        /// Destroys or replaces something the user already has: a file overwrite, a
        /// replace-on-save of a routine/workspace/snippet, a deletion. Always asks — there is no
        /// relaxing this class.
        case destructive
        /// Reaches someone other than the user: send, post, share, publish, purchase. **Armed but
        /// empty today** — no v1 capability can affect anyone but the user, so no construction
        /// site carries this class yet. It exists now so that when vision actions arrive, their
        /// escalations classify into a class that already asks, rather than needing the rule
        /// rebuilt under time pressure.
        case affectsOthers = "affects_others"
        /// A fact worth telling the user, not a consent worth interrupting them for: an
        /// out-of-scope resource, a workspace-entry removal, a whitelist-root widening. Advisory
        /// escalations still raise `effectiveTier` honestly (the tier stays a true severity
        /// signal, and the unattended tier-2 ceiling still reads it) — they just don't prompt on
        /// their own; their reason surfaces on the ran-without-asking trace instead.
        case advisory

        /// Whether this class keeps the prompt. Exhaustive with no `default:` on purpose: a new
        /// consequence class must decide whether it asks, or the build fails.
        var asksFirst: Bool {
            switch self {
            case .destructive, .affectsOthers:
                return true
            case .advisory:
                return false
            }
        }
    }

    public var fromTier: CapabilityRiskTier
    public var toTier: CapabilityRiskTier
    public var reason: String
    /// Non-defaulted in the initializer deliberately: every construction site must classify its
    /// consequence, so a new escalation cannot land unclassified — the same fail-closed shape
    /// `PlanScopedResources` and the old per-operation classification used. When genuinely unsure,
    /// classify `.destructive`/`.affectsOthers` (fail closed: ask) and flag it, never `.advisory`.
    public var consequence: Consequence

    public init(
        fromTier: CapabilityRiskTier,
        toTier: CapabilityRiskTier,
        reason: String,
        consequence: Consequence
    ) {
        self.fromTier = fromTier
        self.toTier = toTier
        self.reason = reason
        self.consequence = consequence
    }
}

public struct CapabilityRiskAssessment: Codable, Equatable, Sendable {
    public var defaultTier: CapabilityRiskTier
    public var effectiveTier: CapabilityRiskTier
    public var approvalCopy: RiskApprovalCopy?
    public var escalations: [CapabilityRiskEscalation]
    /// The plan-level workspace-scope roll-up, or `nil` when the task was assessed `.unscoped`.
    ///
    /// **Data, not a gate.** Under the consequence rule (2026-08-13) nothing reads this to decide
    /// an approval requirement in either direction — the out-of-scope fact travels as an advisory
    /// escalation whose reason surfaces on the trace, and the verdict itself stays computed and
    /// stored for the surfaces that render it (the task's binding, chips) and for the future
    /// vision cage. `nil` means "no workspace was bound", which is not the same as `.unconstrained`
    /// ("a workspace was bound and says nothing about this kind") — the distinction stays
    /// uncollapsed because both are facts a surface may need to state accurately.
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

/// The authority context an approval requirement is derived under: today, whether the user's Safe
/// mode is engaged; row I's per-app control consent lands here as a further field.
///
/// This is an input to `RiskApprovalPolicy.requirement(for:context:)` and nothing else — it never
/// reaches `assessRisk`, so `effectiveTier` remains a pure function of the plan. Threaded
/// non-defaulted into `AgentRunner.approvalRequest` and `AgentRunner.execute` for the same reason
/// `scope:` is: `execute` re-derives the requirement internally, so a context threaded at one site
/// and defaulted at the other would prompt under one requirement and execute under another, with
/// green tests and a lying log.
///
/// The `origin` field the row-C grants read is gone with them (consequence rule, 2026-08-13): the
/// rule gates on what an action *does*, never on how its plan came to exist, and a dead input left
/// on a security-relevant context is exactly the dormant policy the pivot was told to remove.
/// `PreparedPlanSource` itself survives — dispatch, logging and the pending-arm rule still read it.
public struct ApprovalContext: Equatable, Sendable {
    /// Row H's SONNY-90 supplies the real, Settings-backed value; until then the only production
    /// writer is one named site (`AgentViewModel.approvalContext()` reading
    /// `AgentViewModel.safeModeEnabled`). When true, the requirement is
    /// `safeModeRequirement(for:)`'s formula: everything that could run asks first, tier 4 still
    /// refuses. Safe mode is the cautious user's opt-back-in to being asked about everything.
    public var safeMode: Bool
    // Row I's SONNY-91 adds `appControlConsent` HERE, as a field this function maps — never as a
    // rule applied to the function's return value, which is the post-hoc clamp I8 forbids.

    // Explicit rather than synthesized: the memberwise initializer of a public struct is internal,
    // and `MacAgent` is a separate target.
    public init(safeMode: Bool) {
        self.safeMode = safeMode
    }
}

public extension RiskApprovalPolicy {
    /// The one public path from an assessment to an approval requirement (I8: exactly one public
    /// function produces a `RiskApprovalRequirement`, and no public function takes one and returns
    /// a different one; per-app consent and every future authority axis lands *here*, as an
    /// `ApprovalContext` field this mapping reads, never as a rule chained after it).
    ///
    /// **The consequence rule** (founder directive, 2026-08-13, superseding row C's ratified
    /// scope-conditional relaxation): Sonny asks permission only when an action is *destructive*
    /// or *affects someone other than the user* — the two `Consequence` classes whose `asksFirst`
    /// is true. Everything else runs without asking, made legible by the ran-without-asking trace.
    ///
    /// Body order is the composition rule: Safe mode returns first, so "Safe mode wins — the rule
    /// never runs inside it" is structural rather than remembered. The switch below is exhaustive
    /// over the tier with no `default:`, and the ask term reads only the escalations' consequence
    /// classes:
    ///
    /// - Any escalation whose class asks first (destructive, affects-others) asks, **at every
    ///   tier that can run**. On tiers 0–2 that term is unreachable through any adapter today —
    ///   all nine construction sites target tier 3, so a derived `effectiveTier` at or below 2
    ///   means no escalation fired — but the rule is "asks when destructive", not "asks when
    ///   destructive and the tier arithmetic agrees", so the term is written where the rule puts
    ///   it and pinned by a hand-built test. The day an escalation targets tier 2 (a possibility
    ///   `Coverage.standingGrant`'s comment already records), it asks without anyone remembering
    ///   to make it.
    /// - Otherwise tiers 0/1/2 auto-run unconditionally — the policy dials no longer gate them.
    /// - Advisory-only tier 3 auto-runs, with the ran-without-asking trace naming what was
    ///   advisory. A tier-3 assessment carrying **no** escalations is unreachable through any
    ///   adapter today and fails closed to `.explicitApproval`: with nothing classified there is
    ///   nothing to run silently on.
    /// - Tier 4 refuses, in every state.
    ///
    /// This function never writes the assessment: `effectiveTier` stays an honest severity signal
    /// for the gates that read it (the unattended tier-2 ceiling above all), and escalation
    /// sentences reach their surfaces — panel or trace — unedited. The rule changes what asks,
    /// never what a sentence says.
    func requirement(
        for assessment: CapabilityRiskAssessment,
        context: ApprovalContext
    ) -> RiskApprovalRequirement {
        if context.safeMode {
            return safeModeRequirement(for: assessment.effectiveTier)
        }
        let asksFirst = assessment.escalations.contains { $0.consequence.asksFirst }
        switch assessment.effectiveTier {
        case .tier0, .tier1, .tier2:
            return asksFirst ? .explicitApproval : .autoRun
        case .tier3:
            return asksFirst || assessment.escalations.isEmpty ? .explicitApproval : .autoRun
        case .tier4:
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
