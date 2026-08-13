# Row C — approval relaxation: the branch plan

Produced by SONNY-13 (planning ticket for roadmap row C), 2026-08-13. Branches:
`feature/approval-relaxation-structural` and `feature/approval-relaxation-surface`, plus
`feature/sonny-62-approval-rearm` landing ahead of both. Module: **C — approval relaxation
(structural)**. Gated on row B, which shipped the boundary this row finally spends.

**The Plane tickets are the binding contracts; this document is the reasoning behind them.**
`docs/sonny-founder-design-decisions.md` is the durable decision record and should be read first.
This file is a frozen artifact in the shape of `docs/sonny-branch-b-plan.md` — it is not updated as
the branches proceed, except for the status line at the end.

**Every measurement in this document was taken at `0fdac1ca1177b67be33f30d9e563f7e2c0c6ecfe`** (the
PR #43 merge). Two prerequisite branches land before row C's own implementation begins, so a session
arriving later must re-measure rather than reuse these figures.

---

## 0. What row C is for

Row B made a workspace's contents its restriction scope and used the resulting verdict **only to
escalate**. That is the whole of the boundary's cost with none of its payoff: being inside a
workspace bought the user nothing, and every tier-2 action prompted exactly as it had before.

Row C is the payoff. Being inside a workspace's scope now **reduces** prompting. The founder charter
(Sauransh + co-founder, 2026-08-04, recorded on SONNY-13 before row B was even planned) is
deliberately beyond the conservative recommendation, which was offered and declined:

- **in-scope tier 2 auto-runs**, and
- **in-scope tier 3 drops to a lightweight confirmation.**

Everything below is either the machinery that makes those two sentences safe, or the answer to a
question they turned out to raise.

---

## 1. Three findings that changed the shape of the row

These were found by this planning session's own grounding sweep and adversarial pass. Each one
changed a decision, and each is the reason a later section reads the way it does.

### 1.1 The founder's own friction complaint is unreachable by the ratified charter

On 2026-08-07, during SONNY-41's manual pass, the founder reacted to the workspace detail sheet: an
Add or Remove clicked *on the workspace's own sheet* re-prompting every time reads as unnecessary
friction. That observation is what put dispatch origin on row C's table.

It turns out the verdict half of the charter **structurally cannot** address it.
`PlanScopedResources` classifies `edit_workspace` and `create_workspace` as `.none` scoped resources
(`PlanScopedResources.swift:249-259`), and says why in its own comment: the workspace's apps, URLs
and file locations in an edit are *contents being declared*, not resources being touched — adding
`~/Documents/ClientAlpha` writes a string into a list, it does not visit the folder. So a plan whose
only step is a workspace edit produces **zero** scope findings; `WorkspaceScopeEvaluator.planVerdict`
falls through to `.unconstrained` (`WorkspaceScope.swift:435-446`); and
`AgentActionExecutor.scopeVerdict` returns `.unconstrained` for a bound workspace or `nil` for an
unscoped task (`AgentActionExecutor.swift:476-495`). **It is never `.inScope`.**

That settles what was framed on SONNY-13 as an optional extra ("row C should *consider* dispatch
origin"). The origin term is not an enhancement on top of the charter — it is the only thing in the
design that can reach the case the founder actually complained about.

### 1.2 The tier-3 half of the charter is invisible to the user

`.lightweightConfirmation` and `.explicitApproval` render **identically** today, on every surface.
The single `switch request.requirement` anywhere in the `MacAgent` target merges them into one case
(`AgentViewModel.swift:810-838`, merged at `:813`); `WidgetPermissionPanel` takes a
`RiskApprovalRequest` and never reads `.requirement` at all, rendering the same row and the same two
icon buttons regardless (`FloatingWidgetView.swift:532-630`); Command Center's `permissionContent(_:)`
shows a fixed "Approval needed" header (`CommandCenterView.swift:750-790`).

SONNY-10's audit reached the same conclusion from the other direction on 2026-08-03 and recorded it
in the changelog as its single most reusable finding: *"a tier-2 → tier-3 escalation therefore adds
no prompt a user would not already have seen."*

So half the ratified charter has no observable effect until new UI exists. That is the entire reason
row C is two branches (§6), and it is why branch 1's records are required to say so rather than
describing a friction win it did not deliver.

### 1.3 "effectiveTier stays honest" is not sufficient

Row B handed row C the constraint that relaxation must never lower `effectiveTier`, and named four
things that depend on that field. Two corrections:

**The list of four is incomplete.** `effectiveTier` is read or referenced 151 times across 24 files.
There is a **fifth structural decision gate** nobody listed: SONNY-54's manual-routine-trust check at
`AgentViewModel.swift:822-823`, whose own comment says it "mirrors `AgentRunner.execute`'s own gate."
Also unlisted: the approved tier written back at `:2004-2005`, `RiskApprovalError.errorDescription`
(`RiskApproval.swift:169,173`), and the tier handed to `approvalCopy(for:metadata:tier:)`
(`AgentActionExecutor.swift:336`). This is exactly the class `CLAUDE.md`'s *enumerate before you
subtract* rule exists for, and the correction is more useful than the original list — the fifth gate
is a UI-layer comparison a reader trusting "the four listed sites" would miss.

**And `effectiveTier` is the wrong field to guard alone.** The `escalations` array's *contents* are
independently rendered on three surfaces: the widget's first-run explainer
(`FloatingWidgetView.swift:546-550`), Command Center's approval panel (`CommandCenterView.swift:777`),
and the scheduled-run pause notice (`AgentViewModel.swift:2404-2422`). A relaxation that keeps the
tier arithmetically honest while changing what is in that array would still change what the user
reads. Hence **I2** (§4), the ratified upgrade to the inherited constraint.

---

## 2. The model

### 2.1 Two grants

```
grant = .inScopeWorkspace    if eligibility.contains(.byWorkspaceScope)
                                && scopeVerdict == .inScope     (founder charter, 2026-08-04)
      = .directUserAuthored  if eligibility.contains(.byDirectUserOrigin)
                                && origin == .directUserAction  (founder observation, 2026-08-07)
      = .none                otherwise
```

`eligibility` is the plan-level `relaxationEligibility` roll-up (§3.3).

`.inScopeWorkspace` is tested first so that anything surfacing a reason names the stronger,
boundary-earned grant when both apply.

**Eligibility is tested per grant, never once ahead of both.** This is PR #45's review finding F2,
fixed 2026-08-13; the founder confirmed per-grant as the ratified intent rather than a design change,
and the same block is the contract on SONNY-97, corrected there in the same round.
`relaxationEligibility` is a **two-bit** `OptionSet` (§3.3) and each bit gates exactly one line above,
so a single un-parameterised *"eligibility forbids it"* ahead of both branches cannot express what §6
actually does. Hand-traced against §6's own central case: `EditWorkspaceCapabilityAdapter` narrows a
boundary-changing edit by dropping `byDirectUserOrigin` **only**, leaving `byWorkspaceScope` set — so
against the un-parameterised form the set is non-empty and the guard never fires; `scopeVerdict` is
never `.inScope` for an `edit_workspace` plan (§1.1), so the first line misses; and the plan falls
through to the origin line and takes `.directUserAuthored` anyway, the dropped bit notwithstanding.
That is precisely the auto-run §6 exists to prevent.

They are kept as separate cases even though they map identically today, because they have different
revocation stories and different user-facing explanations: *"because this is inside Client Alpha"*
and *"because you built this on screen"* are different facts, and a user can act on the difference.

### 2.2 The table

| `effectiveTier` | `.none` | `.inScopeWorkspace` | `.directUserAuthored` |
|---|---|---|---|
| 0 | autoRun | autoRun | autoRun |
| 1 | policy | policy | policy |
| 2 | policy (lightweightConfirmation) | **autoRun**\* | **autoRun**\* |
| 3 | explicitApproval | **lightweightConfirmation** | **lightweightConfirmation** |
| 4 | refuse | refuse | refuse |

\* stays `.previewOnly` when `tier2Mode == .previewOnly`. **Relaxation never overrides the user's own
tightening preference.** That policy value is unreachable in the shipped app today —
`RiskApprovalPolicy` is constructed with explicit arguments exactly once in the whole repo and that
is a unit test (`RiskApprovalTests.swift:36`); everything in `Sources/` uses `.default` — but the rule
is ratified and carries its own test, because a dead configuration surface that comes alive later
should not silently defeat the preference it exists to express.

One precision, because the first draft overclaimed it: the switch is a function of `(tier, grant)`
**on a given policy**. `self` *is* the policy and two cells read `tier2Mode`, exactly as
`RiskApprovalPolicy.requirement(for:)` already does for tiers 1 and 2 today. That is not a chained
rule — no intermediate tier is produced and nothing re-fires — but it should be stated rather than
left for a reader to discover in a case body.

### 2.3 Why tier 3 is entirely about *escalated* tier 3, today

Row B recorded the finding that makes Gate 3 answerable: **no capability has a static
`defaultRiskTier` of `.tier3`.** Re-verified here across all 55 `defaultRiskTier` lines at
`0fdac1c` — every static declaration is tier 0, 1 or 2, and `.tier3` appears attached to that
concept only as an escalation's `toTier`.

There are **exactly 8** `CapabilityRiskEscalation` construction sites in `Sources/`, and **all 8 have
`toTier == .tier3`**. Their families are less uniform than a quick read suggests, which matters
because copy is what a relaxed prompt still has to carry:

- **3** use the literal *"already exists and would be replaced"* phrasing —
  `SaveRoutineCapabilityAdapter.swift:71`, `SnippetSaveCapabilityAdapter.swift:70`,
  `CreateWorkspaceCapabilityAdapter.swift:79`.
- **3** are output-path collisions — *"… already exists at `<path>`"* —
  `LargestFilesZipCapabilityAdapter.swift:92`, `WebResearchMarkdownCapabilityAdapter.swift:122`,
  `CreateLocalDraftCapabilityAdapter.swift:70`.
- **1** is row B's out-of-scope escalation (`AgentActionExecutor.swift:455`), whose `fromTier` is
  **not** a constant — it is the plan's own rolled-up `defaultTier`, passed in at `:329`.
- **1** is `edit_workspace`'s removal escalation (`EditWorkspaceCapabilityAdapter.swift:226-233`),
  with two distinct reason variants depending on whether the removal empties the dimension.

So the spec's genuinely irreversible tier-3 capabilities — send, upload, delete, submit, purchase,
share (§11.1) — do not exist yet, and row C's tier-3 clause today governs collisions and boundary
edits only. §3.2's per-operation classification is where the non-relaxable floor for those future
capabilities will live when they arrive, and it is fail-closed, so they cannot arrive unclassified.

### 2.4 What relaxation must not copy

`InvokeShortcutCapabilityAdapter` really does lower the assessed tier on clean observed run history —
but it does it by **overriding `defaultTier` directly** inside its own `assessRisk`
(`InvokeShortcutCapabilityAdapter.swift:69-72`), never through an escalation. Worth knowing precisely,
because it means an escalation object structurally *cannot* lower anything:
`CapabilityRiskAssessment.highestTier` is a max-fold over `defaultTier` and every escalation's
`toTier` (`RiskApproval.swift:226-234`). The only lever that lowers an assessed tier is changing what
`defaultTier` is computed as.

Row C is forbidden from reusing that lever. Row B's reason stands: that trust is earned by observed
successful runs, and *"the user typed this folder into a list once"* is a weaker signal that must not
buy the same structural power.

---

## 3. The one function

### 3.1 Shape

```swift
public struct ApprovalContext: Equatable, Sendable {
    public var origin: PreparedPlanSource
    public var safeMode: Bool                 // row H / SONNY-90 supplies the real value
    // row I / SONNY-91 adds `appControlConsent` HERE, as a field — never as a rule
    // applied to this function's return value.
    public init(origin: PreparedPlanSource, safeMode: Bool)
}

public extension RiskApprovalPolicy {
    func requirement(for assessment: CapabilityRiskAssessment,
                     context: ApprovalContext) -> RiskApprovalRequirement
}
```

The explicit `public init` is not decoration: Swift's synthesized memberwise initializer for a public
struct is *internal*, `MacAgent` is a separate SwiftPM target, and every other public struct in
`RiskApproval.swift` already writes one.

Body order **is** the composition rule:

```swift
if context.safeMode { return safeModeRequirement(for: assessment.effectiveTier) }
switch (assessment.effectiveTier, grant(for: assessment, context: context)) { /* 15 cases, no default: */ }
```

Safe mode returns before the grant is computed, so *"Safe mode wins — relaxation never applies inside
it"* is structural rather than remembered. And SONNY-90 receives a **formula**, not a bare signature:
`safeModeRequirement(for: tier) = stricter(of: baseline(for: tier), safeModeFloor)` on the
permissiveness rank `refuse < previewOnly < explicitApproval < lightweightConfirmation < autoRun`
("how much happens without further gating" — `previewOnly` sits below `explicitApproval` because
nothing ever runs under it). A free-standing function returning whatever seemed right per tier could
define a Safe mode that is *looser* than the baseline somewhere; the formula cannot.

### 3.2 Exactly one public path — and there were three, not two

This is the correction the adversarial pass produced that mattered most, because the first draft
would have shipped believing the rule was satisfied.

| Function | At | Disposition |
|---|---|---|
| `CapabilityRiskAssessment.approvalRequirement(policy:)` | `RiskApproval.swift:222` | removed |
| `CapabilityRiskTier.approvalRequirement(policy:)` | `:268` | removed — zero call sites anywhere |
| `RiskApprovalPolicy.requirement(for tier:)` | `:77` | **demoted to non-public** |

The third one is the point. It is public, tier-only and context-free — row B's *"never two chained
rules"* violation in miniature — and it survives untouched if you only remove the two thin wrappers
that call it. It becomes the sanctioned internal sub-call the new function delegates to for its
baseline, and nothing outside `RiskApproval.swift` may name it.

Conversion cost, enumerated: `approvalRequirement(` has **10 external call-site lines** — 1 in
`Sources/` (`AgentRunner.swift:150`) and 9 in `Tests/`, all through the assessment receiver.
`RiskApprovalPolicy.requirement(for:)` has **8 external call-site lines**, all in
`RiskApprovalTests.swift` across 2 functions.

**I8 in its strengthened form:** no public function may take a `RiskApprovalRequirement` and return a
different one either. A post-hoc clamp is the natural low-diff shortcut a future row-I session would
reach for, and it is exactly the chained rule the whole discipline forbids.

### 3.3 Where eligibility lives

The verdict grant is protected by the verdict machinery itself: `.opaque` poisons the plan roll-up,
`.unconstrained` and `nil` never qualify, and nested verdicts are folded in specifically so a routine
cannot launder an out-of-scope touch into an `.inScope` roll-up.

**The origin grant has none of that protection** — it bypasses scope entirely — so it gets its own
fail-closed containment:

```swift
struct OperationRelaxation: OptionSet {
    static let byWorkspaceScope     // may take .inScopeWorkspace
    static let byDirectUserOrigin   // may take .directUserAuthored
}
static func relaxation(for operation: AgentOperation) -> OperationRelaxation   // exhaustive, no `default:`
```

- `byWorkspaceScope` is a **denylist**: everything except `.runRoutine` and `.invokeShortcut`.
- `byDirectUserOrigin` is an **allowlist**: only `.editWorkspace`.
- No `default:` clause, for the reason `PlanScopedResources` already refuses one — a new operation
  must not be able to land unclassified.

`.runRoutine` loses `byWorkspaceScope` deliberately. SONNY-54's founder decision (2026-08-06) made the
per-routine trust toggle the single door for skipping a routine's tier-2 prompt, scheduled *or*
manual. Without this exclusion an **untrusted** routine running inside a workspace would auto-run
through a second door the founder never opened — on its first run, with its arbitrary steps
unreviewed. This is **Gate 3 extended: scope answers "right place," never "right severity" — and
never "right thing."** The cost is recorded and accepted: a user may ask why their routine still
confirms inside a workspace where typing the same command does not.

`.invokeShortcut` loses it too. That is belt-and-braces for the verdict grant (a Shortcut is already
`.opaque` when scoped) but **load-bearing for the origin grant**, which never consults the verdict.

**The roll-up needs a home, and the first draft did not give it one.** `requirement(for:context:)`
receives only the assessment and the context — no `AgentPlan`, no per-step operation list — so it
cannot compute an intersection over steps. As written, its own fail-closed containment was
uncomputable, and an implementer following it literally would have had two choices, both bad: drop
the check (letting the origin grant apply to any operation) or substitute a coarser proxy.

So: **`CapabilityRiskAssessment` gains a `relaxationEligibility` field, computed and folded inside
`AgentActionExecutor.assessRisk` exactly where `scopeVerdict` is folded today**
(`AgentActionExecutor.swift:340-344`), **including the nested fold** that `RunRoutineCapabilityAdapter`
already performs for `scopeVerdict` (`:78`). Plan roll-up is **intersection across every step** — the
same poison shape `.opaque` already has. An adapter may **narrow** its own eligibility dynamically and
may never widen it, the same static-default / dynamic-override idiom `defaultRiskTier` and escalations
already use. SONNY-98 is its first user.

`Optional`-with-default here is for **call-site compatibility across the 16 real construction sites**
(11 in `Sources/`, 5 in `Tests/`), **not** for on-disk backward compatibility. `CapabilityRiskAssessment`
is `Codable` but is embedded in none of the 8 local stores — enumerated directly — and lives only in
memory as `RiskApprovalRequest.assessment` behind `@Published var approvalRequest`
(`AgentViewModel.swift:33`). So `AutomationStores.swift`'s `keyNotFound` rule does not apply, and an
implementer should not reach for migration handling this type never needs. SONNY-97 re-verifies that
in-branch rather than trusting this paragraph.

### 3.4 Threading, and why nothing gets a default

`ApprovalContext` is threaded into `AgentRunner.approvalRequest(...)` and `AgentRunner.execute(...)`
with **no default value at any call site**, for the same reason `scope:` has none. `execute` calls
`approvalRequest` again internally, so a context threaded at one site and defaulted at the other
produces a run that prompts under one requirement and executes under another — green tests, lying
log. `AgentRunner.swift`'s own comment on `scope:` spells that failure out; it ends *"A default is
what makes that failure silent, so there isn't one."*

The origin comes from `PreparedAgentRun.source`, which `approvalRequest` already receives.
**`assessRisk` must not learn the origin.** It stays origin-blind so `effectiveTier` remains a pure
function of the plan, and `AgentRunner.swift:113-116`'s *"everything after this line never learns how
the plan was authored"* stays true of the **assessment** even as it stops being true of the
**requirement**. That distinction is the whole reason the seam sits where it does.

### 3.5 Re-arm on drift — which row C breaks and must therefore fix

The gate in `AgentRunner.execute` (`:166-181`) merges `.lightweightConfirmation` and
`.explicitApproval` into one case and authorizes solely on `approvedTier >= effectiveTier`;
`AgentViewModel.swift:2004` writes back the approved **tier**, never the requirement the user saw.

That was sound before row C **only because requirement was a pure function of tier**, so "same tier at
approval and execution" implied "same requirement." Row C ends that implication, and the concrete
failure is: *a user answers a lightweight confirmation for a tier-3 action, the grant disappears
before execution, and the engine treats that light consent as an explicit approval at equal tier.*
That is SONNY-62's masking class, arriving through a second door — newly minted by row C rather than
inherited.

Two fixes, both on SONNY-97:

1. The approval decision carries **the requirement the user actually answered** alongside the tier,
   and the gate re-arms when the freshly re-derived requirement is *stricter*, including at equal tier.
2. **An auto-run that drifts must re-arm, not hard-fail.** The only branch turning a drifted
   `RiskApprovalError.approvalRequired` into a graceful pending approval is gated
   `where routineTrustApproval != .notRequested` (`AgentViewModel.swift:905-926`) — a SONNY-54
   condition. A plan reaching `.autoRun` through a row-C grant always carries `.notRequested`, so
   today's code would surface a hard failure instead of a second prompt.

SONNY-62 itself stays scoped to the **reason-set** drift, which is all that is reachable before row C.

---

## 4. The invariants

| | Invariant | Why it is here |
|---|---|---|
| **I1** | Relaxation never writes `effectiveTier`. | Row B's constraint. Five gates depend on it (§1.3), including the unattended ceiling. |
| **I2** | Relaxation never writes `escalations` **and never changes `approvalCopy`**. | **New, ratified 2026-08-13.** §1.3: escalation reason strings render independently on three surfaces, so tier honesty alone does not mean "nothing user-visible changed." Relaxation changes the *weight* of the ask, never the sentence. |
| **I3** | `.outOfScope`, `.unconstrained`, `.opaque` and `nil` never grant. Only `.inScope` does. | Row B's constraint. Note the three-state trap the type's own comment warns about: `nil` ("no workspace bound") and `.unconstrained` ("bound, and says nothing about this kind") must never be collapsed. |
| **I4** | Escalate-never-block preserved. | Row B's founder decision; row C adds no path that refuses. |
| **I5** | Safe mode is evaluated first; the grant is not computed inside it. | The composition rule SONNY-81's amendment required, made structural. |
| **I6** | The unattended path reaches neither grant. | True today by **two independent call-site choices** — `source: .instantResolver` and `scope: .unscoped` (`AgentViewModel.swift:2283-2315`) — not by any type-level guarantee. Which is exactly why it is pinned by a test named for the hazard. |
| **I7** | Re-arm on drift preserved, in §3.5's strengthened form. | Row C breaks the old implication; row C fixes it. |
| **I8** | Exactly one public function produces a `RiskApprovalRequirement`, and none takes one and returns a different one. | §3.2. The second clause exists because the wrapper shape is the natural shortcut, not a hypothetical one. |
| **I9** | Relaxation never exceeds the user's own policy. | §2.2's asterisk. |
| **I10** | `.inScope` reached through the **name-fallback** key never grants. | §5. |

**Testing.** The full cross-product is asserted **against a written table, not sampled**: 5 tiers × 5
verdict states (4 cases + `nil`) × 3 `PreparedPlanSource` values × 2 `safeMode` values × the
eligibility combinations. Plus two monotonicity properties on the §3.1 rank — **P1**: for identical
inputs, `safeMode == true` is never more permissive than `safeMode == false`; **P2**: a grant is never
less permissive than `.none`.

I1 and I2 are pinned in the shape row B already established: a test asserting the **whole** assessment
— tier, escalations and copy — is byte-identical with and without each grant, the way
`neitherUnscopedNorAnUnconstrainedKindChangesTheAssessment` pins its own claim rather than checking
only the tier.

**Counting note for whoever writes these.** The suite is **828 `@Test` functions across 53 files** at
`0fdac1c`, all swift-testing, zero XCTest. `grep -c "func test"` returns **4**, and all four are
private helpers — counting that way undercounts the regression surface by roughly 200×.

---

## 5. The imposter gap, and why SONNY-84 is a prerequisite

`WorkspaceScope.verdict(for: .resolvedApp(...))` matches by bundle identifier first and falls back to
a normalized display-name key for entries `MacAppCatalog` cannot resolve (`WorkspaceScope.swift:224-236`,
`:301-310`). So an app that merely *calls itself* "Figma" can earn `.inScope` against a workspace
listing the real Figma.

Before row C the consequence of that was "no escalation." **After row C it becomes silent execution.**

How far it actually reaches, stated honestly rather than inflated: `RunningAppSwitchCapabilityAdapter`
is the only producer of a `.resolvedApp` scoped resource (`PlanScopedResources.swift:220-233`) and its
`defaultRiskTier` is `.tier1` (`:33`) — a tier no grant column touches, since tier 1 already auto-runs
under the default policy. So today the two compose safely **by coincidence of tier placement**, not
because anything protects them. The reachable exposure is narrower than "an imposter runs anything":
it is an imposter's presence flipping a plan's roll-up from `.unconstrained`/`.outOfScope` to
`.inScope`, thereby relaxing the plan's *other* steps.

**SONNY-84 (row F) is therefore a merge prerequisite for SONNY-97**, and it is the structural
discharge: once every *installed* app earns a real `bundle:` key, a name-fallback match survives only
for genuinely uninstalled entries, which cannot be running and so cannot produce a `.resolvedApp`
match at all. Row C still writes **I10** into the code, so that a future tier bump on any
name-fallback-matched operation is a conscious decision against a stated rule rather than a silent
reopening of the gap.

Row C does not touch `WorkspaceScope.swift` — it is SONNY-84's file, and row B's evaluator semantics
are not to be re-derived. That is what keeps the prerequisite a sequencing constraint rather than a
merge conflict.

---

## 6. Answering the row-B forward flag

Row B rejected escalating on *widening* on a row-B cost argument — the user typed the command asking
for it, and taxing setup taxes the feature — and recorded the rejection as **not closed**: *"branch C
must revisit this."* Gate 1 does not already cover it, because Gate 1 answers *which verdicts qualify*
for relaxation, never whether the act of *creating* a qualifying verdict should itself be gated.

Row C's own design made the question sharper than row B could have known. Under the origin grant,
`edit_workspace` is the single allowlisted operation; its `defaultRiskTier` is `.tier2`
(`EditWorkspaceCapabilityAdapter.swift:77`); and its `assessRisk` escalates only when
`list.effectivelyRemoved` is non-empty (`:222-238`). So a pure *addition* produces `escalations: []`,
stays tier 2, and the grant maps it to `.autoRun`. **Left alone, row C would have turned the one edit
the flag warned about into the one edit nobody sees.**

**The ratified rule, one sentence:**

> The origin grant covers edits that move entries **within** a boundary. It never covers an edit that
> changes **whether a dimension is a boundary at all**.

Concretely, `EditWorkspaceCapabilityAdapter` narrows its own eligibility to drop `byDirectUserOrigin`
when the edit adds the first entry to an empty dimension, empties a dimension by removal, or adds a
file location that subsumes an existing entry. Everything else — adding an app, adding a URL, adding
a non-subsuming folder, removing one of several entries — keeps the grant and auto-runs from the
sheet. That is the founder's friction complaint solved without reopening the hazard.

**And one escalation on top:** adding a `PathWhitelist` root — `~/Desktop` or `~/Documents` themselves
— as a file location escalates to tier 3, with a reason naming the *consequence* rather than the entry.

**Scoped to `.fileLocation` deliberately, recorded as a stated decision rather than an omission.**
File locations are the only kind matched by *containment*, so one entry can convert a large territory.
`.app` has no hierarchy at all — `WorkspaceScope.appKey` resolves to a bundle identifier and there is
no "root app." `.webDomain` does have suffix matching (`host == d || host.hasSuffix("." + d)`), so a
shorter host is broader — but it is bounded by `SafeURL` validation and by the user having typed a
specific host, and it has no equivalent of the whitelist root. Recording the asymmetry matters
because otherwise the next reader finds a rule that silently does nothing for two of three dimensions
and reasonably assumes it is a bug.

**The dimension-emptying removal keeps explicit approval**, as a direct consequence of the same rule.
The case for relaxing it is real — the user is looking at the sheet, at that row, and clicked it, which
is the maximal intent evidence the origin grant exists to honour. The case against wins: row B calls it
*"the sharpest edge in the model"* (the user consents to losing one folder and actually loses scope
enforcement for that dimension), it is now also the single edit that changes what the whole relaxation
system will and will not do for that workspace, and it is rare — so the friction cost of excluding it
is close to zero.

**One trap this work sits squarely inside.** Row B's most valuable recorded lesson is the
**two-notions-of-empty class** — three appearances on one branch, each a locally-obvious second
definition of "empty" that agreed with the evaluator's in the common case and diverged exactly where
an inert entry exists. *"The dimension was empty before"* and *"the dimension is empty after"* are
precisely those predicates. **Ask the evaluator; never re-derive its answer** — and the fixture that
separates the two notions is a workspace whose lists are all non-empty and one of which is entirely
inert, because a suite whose every unrestricted dimension is also a literally-empty one cannot tell
them apart.

**A second row-B item row C makes more expensive — and deliberately does not answer.** Row B's own
changelog entry parks an open question alongside the widening flag: *"Should a scheduled run's
unattended pre-check assess with the run's real scope?"* (`feature/workspace-restriction-scope`,
open questions). It was flagged by SONNY-37 and left open because answering *yes* would make
`UnattendedTrustAdvisory`'s pre-check disagree with its own docstring. Row C adds a second, much
larger consequence that was not on the table when the question was parked: **answering yes would make
in-scope tier-2 steps auto-run unattended, without the per-routine trust opt-in.** The mechanism is
**I6** (§4). The unattended path reaches neither grant today only because the scheduled dispatch makes
*two* independent call-site choices — `source: .instantResolver` and `scope: .unscoped`
(`AgentViewModel.swift:2283-2315`, whose own comment says the second is *"on purpose, not by
omission"*). Assessing a scheduled run with its real scope removes one of the two, and the column it
opens is the tier-2 auto-run one. **The question stays open; only its cost is corrected** — amended
in place as **SONNY-100's** deliverable (C4), founder-ratified 2026-08-13 as part of that ticket
rather than as a new decision.

---

## 7. Default-on, and the two options declined

Row B ratified no separate per-workspace toggle, on Gate 1: *listing `~/Documents/ClientAlpha` on the
workspace **is** the explicit act*, and a second switch for one consent is how a security control ends
up left in the wrong position. That position is re-ratified for row C. The alternatives, recorded so
they are not re-litigated from scratch:

- **Opt-in per workspace.** Costs a new persisted field on `StoredWorkspace` (a closed 5-field struct)
  plus explicit handling in `WorkspaceStore.save`'s merge logic, plus a Settings surface that does not
  exist — **no Settings page in the app today is workspace-scoped**. Real cost, and it re-adds the
  second switch Gate 1 rejected.
- **Trust-graduated** (relaxation earned after N clean in-scope runs). Has a genuine precedent in
  `InvokeShortcutCapabilityAdapter`'s observed-history trust. But it contradicts Gate 1 directly, adds
  a store and a counter, and produces a *"why did it stop asking?"* mystery with no surface to explain
  it. §6's targeted widening gate is the better answer to the hazard that would otherwise argue for it.

---

## 8. The origin signal

`PreparedPlanSource` already exists and already names row C as its consumer
(`AgentRunner.swift:1-44`). Its trustworthiness is structural rather than promised: `AgentPlan` and
`AgentStep` carry no source field, the value is stamped by `AgentRunner.prepare` *after* decoding, and
`prepare(command:)` hardcodes `.planner` with no parameter — so the one entry point a model's text can
reach cannot claim a stronger origin.

| Value | Grants | Why |
|---|---|---|
| `.planner` | nothing | a model interpreted the sentence |
| `.instantResolver` | nothing | deterministic, but still parsed from free text; the friction it would remove is near-zero (instant utilities are tier 0/1). Fail-closed — adding it later is one table row and one test |
| `.directUserAction` | `.directUserAuthored`, allowlisted per operation | the user built the plan field by field, with nothing interpreted on the way |
| a future vision origin | nothing | **row I adds its own case** rather than overloading `.directUserAction` — the enum's own recorded rule. Vision is tier-3 `.opaque` and never relaxation-eligible |

That last row is not merely a convention. Overloading `.directUserAction` would hand a vision session
an origin that sits on a relaxation allowlist, which is the one thing SONNY-81's amendment forbids
outright. §3.3's per-operation classification is the structural backstop: when row I adds its
operation, the compiler requires it to be classified, and classifying it as granting neither is the
answer.

---

## 9. Branches, tickets, sequencing

**Ahead of everything: `feature/sonny-62-approval-rearm` — SONNY-62.** Standalone and first. It is a
pre-existing security bug that should not wait on row C's own prerequisite, and it unblocks row I
independently. **Parallel-eligible with row F**, recorded on the ticket: row F's tickets put
`AgentRunner.swift` and `RiskApproval.swift` on their never-touch lists explicitly, and SONNY-62
touches none of row F's surfaces. **Serial before row C's branch 1**, since both edit the same guard.

**Branch 1 — `feature/approval-relaxation-structural`** (sequential; starts after SONNY-84 and
SONNY-62 merge):

| Ticket | Outcome |
|---|---|
| **SONNY-97** | The relaxation function: `ApprovalContext`, the grants, `relaxationEligibility` folded in `assessRisk`, the 15-case mapping, the three prior entry points removed or demoted, non-defaulted threading, the Safe-mode input and formula, §3.5's re-arm work, and the full table + P1/P2 + I1–I10 tests. No UI. |
| **SONNY-98** | `edit_workspace`: boundary-changing edits lose the origin grant; root-level file-location widening escalates. §6's answer to the forward flag. |
| **SONNY-99** | The ran-without-asking trace, plus the stale comment at `AgentViewModel.swift:876-879` that this branch falsifies. |
| **SONNY-100** | Spec §11.2/§11.3, the founder-decisions record, the forward-flag closure in all four places, **the scheduled-pre-check open question's forward-hazard amendment (§6)**, §1.3's `effectiveTier` count correction, and the changelog entry. |

**Branch 2 — `feature/approval-relaxation-surface`** (after branch 1 merges):

| Ticket | Outcome |
|---|---|
| **SONNY-101** | `.lightweightConfirmation` reads differently from `.explicitApproval` on every approval surface — what makes §1.2's tier-3 clause real. |
| **SONNY-50** | Compress benign metadata to chips, reserve text weight for real risk. Designed alongside SONNY-101 as one panel language. |

**Why two branches.** Branch 2 carries a **founder-wireframe dependency** — the approval panel is the
widget's, System B, and the standing rule is a wireframe before a widget-surface implementation
session or a stated exception. Splitting lets branch 1 unblock SONNY-90 (Safe mode) and row I without
waiting on it. The cost is stated rather than hidden: **branch 1's tier-3 mapping has no user-visible
effect until branch 2 ships**, and branch 1's records are required to say so rather than claiming a
friction win it did not deliver. The friction branch 1 really delivers is in-scope tier-2 auto-run.

SONNY-99 is the one UI item on branch 1, deliberately: **we do not ship silent execution without a
trace.** Its wireframe exception was approved at ratification and is bounded to one line of text on an
existing surface, in the class of SONNY-10's first-run explainer.

**Disjointness.** Row F: file-disjoint from row C, but SONNY-84 is a merge prerequisite for SONNY-97
on the *assumption* axis (§5) — recorded on both tickets. Row G: disjoint, its never-touch list names
the risk/approval engine. Row H: SONNY-87/88/89 disjoint; **SONNY-90 is not** — same file, same
function, already sequenced after row C, and its seam is recorded on it. Row I: SONNY-91 and SONNY-92
consume row C's function, and both carry comments naming the real types so they extend rather than
chain.

---

## 10. What the 100% directive does and does not touch here

Relaxation is **authority mechanics, not vision accuracy**. The directive's permissive half — no
capability hedges, no accuracy-contingent fallbacks, no benchmark-gated sequencing, no degraded modes
designed around model unreliability — has **no application to row C**, because nothing in row C is
designed around a model working or not working. Its counterweight applies in full: *constraints that
exist because actions carry authority — consent, privacy, data egress — do not dissolve.* Row C
removes friction on the strength of a boundary **the user declared**, never on the strength of a model
performing.

Three §F rulings constrain row C directly, and the design answers each:

- **C2** — per-app control consent maps to a requirement override in one function with row C's
  mapping. Binding on the signature; hence `ApprovalContext` as an extensible struct and I8's second
  clause forbidding a wrapper (§3.1, §3.2).
- **C7** — Safe mode is a user-authority dial that survives perfect accuracy, not a model-distrust
  mode. Row C must not design it away; hence I5 and the formula handed to SONNY-90 (§3.1).
- **C10** — containment invariants are engine-owned and zero reliability UX is built around them. Row
  C adds no retry budgets and no degraded modes.

**Nothing in row C is a supersession of anything**, so no ratification of that class was requested or
given.

---

## Status

Planning complete and founder-ratified 2026-08-13 (SONNY-13, all ten questions as recommended, no
modifications). Tickets SONNY-97 through SONNY-101 created and attached to module
"C — approval relaxation (structural)", alongside the pre-existing SONNY-62 and SONNY-50. No
implementation has started. This document is frozen; the branches record their own outcomes in
`docs/sonny-v1-implementation-changelog.md`.

Corrected once before merge, in PR #45's records-only fix round (2026-08-13, cycle 1's three
findings): §2.1's grant formula now tests eligibility **per grant** (F2), and §6 carries the
scheduled-pre-check forward-hazard amendment — carried in the same 2026-08-13 ratification as the ten
decisions rather than being one of them, and omitted from this document until now (F1). Both are corrections to this artifact, not changes to the ratified design; F3 was
the branch's own changelog entry, which lives in the changelog. Frozen from here.

**Status update, 2026-08-13 (SONNY-100 — the one line this frozen artifact takes per its own header):**
branch 1 (`feature/approval-relaxation-structural`, SONNY-97/98/99/100) is complete and in review.
Implementation followed this plan with four small, named additions rather than divergences, each
recorded on the tickets: `RiskApprovalRequest` carries the applied grant as a reporting-only field
(the seam SONNY-99's never-touch list required SONNY-97 to leave), the consent's answered
requirement is a sibling Optional field rather than a `Coverage` payload, `safeModeFloor` is
`.explicitApproval` (SONNY-90 owns the floor, never the formula), and the ran-without-asking trace
additionally gates on tier ≥ 2 so a grant that changed nothing (tiers 0/1 auto-run in every column)
never traces. Branch 2 is not started.
