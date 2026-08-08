# SONNY-69 → v1: Cerebras Planner + Vision Action Loop — Integration Plan

**Status: planning only. Nothing here is implemented, no roadmap row is edited, no ticket is
amended.** This document is the WORKFLOW.md steps 1–2 output for turning the SONNY-69 experiment
from a throwaway spike into v1-integration input, per the founder mandate recorded on SONNY-69
(2026-08-08). Its deliverable is a design + a numbered decision list for the founder to answer point
by point (§D). Implementation tickets exist only after those answers land.

Planning ticket: **SONNY-71** (module "X — experiments"). Branch: `feature/sonny-69-integration-plan`
(docs-only, from `main` at `99f2fd2`). Modeled on `docs/sonny-branch-b-plan.md` in structure and in
honesty: every load-bearing claim carries file:line at a SHA, or a ticket/doc citation, per
`CLAUDE.md`'s claims-and-evidence rules. Where the experiment's own ticket comments make a claim, the
claim was checked against the code and any discrepancy is called out.

---

## 0. The mandate and the two hard constraints

The founder's directive (SONNY-69 comment, 2026-08-08, coordinator-recorded): the experiment — an
open-weights planner served by Cerebras (`gpt-oss-120b`) and a vision action loop (screenshot →
Gemma 4 31B → synthesized clicks/typing in **any** app) — graduates from throwaway spike to
v1-integration input. Reshaping the roadmap in its service is *intended*, not incidental.

Two constraints the founder has **not** relaxed:

1. **The spike code never merges.** `experiment/cerebras-gpt-oss-vision` (`85fa63d`…`58e8cf5`, draft
   PR #36 titled DO NOT MERGE) is a reference, not a source. Findings seed real tickets; the code
   itself is not the implementation.
2. **Any product integration routes vision actions THROUGH the risk/approval engine, not around it.**
   The spike deliberately bypasses the engine (§2.3); the product cannot.

A third item the founder flagged as design scope, not a footnote: **the data-egress transparency
implications** of screenshots leaving the device (§B6).

Two success axes to map every recommendation to: **architecture quality** and **user friction**.

---

## 1. What the experiment actually is (grounded in code)

The complete experiment diff is **8 files, 1231 insertions(+), 6 deletions(-)** — measured at the
branch's real merge-base, not against current `main`. This matters: the experiment forked from
`6af453c` (Merge PR #32, workspace-restriction-scope), *before* SONNY-54, SONNY-58 and the
SONNY-60/61/63 docs batch merged. A naive `git diff 99f2fd2..58e8cf5` shows ~16 extra files and
935 deletions that are pure stale-main noise — every one of those 16 files is byte-identical between
`6af453c` and `58e8cf5`. The experiment removed no routine-trust or scope logic. **Read the diff as
`git diff 6af453c..58e8cf5`.**

The eight files:

| File | What it adds |
|---|---|
| `CerebrasPlanner.swift` (new, 176 lines) | A `Planning` conformance speaking Chat Completions to `api.cerebras.ai`, `gpt-oss-120b`, selected by `SONNY_PLANNER=cerebras`. |
| `VisionActionLoop.swift` (new, 826 lines) | The spike's core: screenshot → Gemma → CGEvent click/type, 10-iteration cap. |
| `PlannerComparison.swift` (new, 58 lines) | Headless `SONNY_PLANNER_COMPARE` harness printing side-by-side plans. |
| `AgentViewModel.swift` (+150/−6) | Vision-debug intercept, planner selection, unsupported-remainder split. |
| `main.swift` (+12) | The compare-harness entry hook. |
| `OpenAIPlanner.swift` (+12) | The experiment-gated decomposition prompt suffix. |
| `MacAppService.swift` (+1) | Discord added to `MacAppCatalog`. |
| `PlannerBoundaryTests.swift` (±) | The golden updated for the Discord catalog drift. |

Verified against the experiment branch at `58e8cf5`:

- **The planner (`CerebrasPlanner.swift:53-89`)** reuses the *exact* OpenAI system prompt
  (`OpenAIPlanner.systemPrompt(toolRegistry:)`), the shared `AgentPlanDecoder.decodeStrict`, and the
  shared usage parser. The Chat Completions codec is the only genuinely new surface. **The
  schema-in-prompt discovery is real (`CerebrasPlanner.swift:91-128`):** Cerebras's structured-output
  schema cap is 5,000 characters; the plan schema serializes to ~9.3 KB, so native `response_format`
  is rejected. The default mode appends the schema to the prompt and enforces it *only* client-side
  via `decodeStrict` — the same decoder OpenAI uses, but without OpenAI's *additional* server-side
  structured-output guarantee. `SONNY_CEREBRAS_STRUCTURED=1` opts into native mode to measure the
  rejection live.

- **The vision loop (`VisionActionLoop.swift`)** captures the target app's frontmost layer-0 window
  via ScreenCaptureKit, sends PNG + goal + action-history to Gemma, parses a lenient JSON decision
  (`click`/`type`/`wait`/`done`/`stuck`), and synthesizes real `CGEvent`s. It runs **entirely
  outside `AgentRunner`** — its only safety net is a stdout log before each action, a 10-iteration
  cap, an own-widget-click suppression check, and a fresh-window-frame re-fetch. It has **zero
  automated test coverage** across ~1,177 new lines. Sound patterns worth carrying forward:
  fresh-frame click mapping (`VisionActionLoop.swift:261-273`), own-window suppression (`:278-284`),
  and the pixel-identical no-change detector that compares *unmarked* bytes so its own red marker
  can't fool it (`:175-186`). Spike-shortcuts a product must **not** inherit: no engine gating, no
  tests, hardcoded magic-number timings, no retry/backoff, and it trusts the model's self-reported
  keyboard focus before synthesizing real (Return-triggering) keystrokes.

- **The consent bypass is total.** `runVisionExperiment` and the unsupported-remainder split
  (`AgentViewModel.swift`, `runVisionFallback`) call `VisionActionLoop.run` directly. With
  `SONNY_VISION_DEBUG=1`, a plan whose planner returned any unsupported step **auto-runs** the vision
  loop after the supported steps complete — no per-session opt-in. The iTerm2 incident recorded on
  SONNY-69 is exactly this: the planner returned one unsupported step, the fallback targeted the
  frontmost app (iTerm2), and Gemma typed shell commands into a live terminal. `VisionFallbackAppHint`
  has `.frontmost` as its last resort (`VisionActionLoop.swift:57-61`, `:331-337`).

- **Two findings not in the ticket's claim list**, verified in the diff: (1) a separate
  Google/Gemini vision backend (`SONNY_VISION_HOST=google`) with its own `thought:true`-part
  filtering — a *second* data-egress destination with a materially worse privacy posture (§B6); (2)
  the decomposition prompt suffix is gated on `SONNY_VISION_DEBUG`, **not** `SONNY_PLANNER=cerebras`,
  and lives inside the shared `OpenAIPlanner.systemPrompt()` — so enabling vision-debug alone also
  mutates the *default OpenAI* planner's prompt (`OpenAIPlanner.swift` suffix).

The experiment's own acceptance criteria were **never formally satisfied**: the side-by-side planner
comparison is blocked on API keys and was never run; the supervised vision run reached Discord's DM
list but click accuracy was the blocker; the formal findings comment (plan quality, latency, click
hit-rate) is still owed on SONNY-69. **The numbers that should gate the real decisions do not exist
yet.** This plan says which numbers gate which decisions rather than pretending they do (§A5, §D11).

---

## A. Planner strategy

### A1. What the current planner is, and where a second one plugs in

`Planning` is a one-method protocol (`OpenAIPlanner.swift:4-6`); the production conformance is
`OpenAIPlanner`, constructed at exactly one site — `AgentViewModel.performStart`, gated behind the
instant resolver returning `nil` (`AgentViewModel.swift:654`). `AgentOperation` has 30 cases;
`plannerVisibleCases` filters out 6 (`calculateUtility`, `lookupClipboardHistory`, `expandSnippet`,
`saveSnippet`, `switchRunningApp`, `lookupRecentArtifacts` — `AgentPlan.swift:162-175`), and that
filtered set is the literal JSON-schema `enum` the planner may emit (`AgentPlan.swift:408`). The
schema serializes to ~9.3 KB with 25 nullable-union properties — corroborating the experiment's
~9.2 KB / 25-union figure.

A second planner behind the same seam must independently: handle usage recording (opt-in via
`TaskUsageRecording`, not automatic), surface cancellation as `CancellationError`/`URLError(.cancelled)`
(a UX distinction the current code depends on), and carry its own `LocalizedError` conformance (there
is no generic translation layer above `Planning`). The experiment's `CerebrasPlanner` does all three.

### A2. The provider-architecture question is where this decision really lives

The spike adds Cerebras as a *second hardcoded client-side branch* in `performStart`
(`AgentViewModel.swift:654`, `SONNY_PLANNER=cerebras`). The spec already has an opinion about exactly
this shape. §16.5 (Model Provider Proxy) and §11.1's provider decision resolve v1 to "OpenAI ships
first, Anthropic added second, **both behind a provider-agnostic router interface designed in from
day one so the backend never hardcodes one vendor's request/response shape the way the current
prototype's `OpenAIPlanner` hardcodes OpenAI's Responses API shape**" (spec §16.5:2141, §11.1:1404).
BYOK is explicitly skipped (§7.9).

Two things follow, and they pull in different directions:

- **Adding a Cerebras-served open-weights planner is not, in itself, a spec violation.** §16.5
  excludes *BYOK* (user-supplied keys), not a third first-party provider. A provider-agnostic router
  whose point is to not hardcode a vendor shape is *more* justified, not less, once there are three
  wire formats (OpenAI Responses, Anthropic Messages, Cerebras Chat Completions) to abstract.
- **But the spike is the anti-pattern §16.5 names by name.** A second hardcoded branch in
  `performStart`, encoding Cerebras's Chat Completions shape inline, is precisely "the backend
  hardcodes one vendor's request/response shape" — done twice now instead of routed. And §16.5 places
  the router in the **hosted-backend milestone (row 12)**, not the client.

So the planner-strategy decision is really: **do we formalize the provider-agnostic router now (or a
client-side stand-in for it) and land the open-weights planner behind it, or defer any second planner
until row 12's router exists?** This is a founder decision (§D2).

### A3. The three postures, with tradeoffs

**Option A — Cerebras as the default planner (replace OpenAI).**
- *Architecture:* worst fit. Ties the default path to a single third-party inference host with a
  documented ~2.5 incidents/month and multi-hour median resolution (external-facts report,
  isdown.app, retrieved 2026-08-08) and to a preview-tier vision model with short-notice-deprecation
  risk. Sub-frontier planning quality (gpt-oss-120b ≈ o4-mini/o3-mini class — external-facts §5).
- *Friction:* best *latency* on paper (~1,800 t/s independent vs. gpt-5.5), but reliability incidents
  become user-facing planner outages with no fallback.
- *Verdict:* **not recommended.** No measurement supports it, and it makes a reliability-fragile
  third party load-bearing for the core loop.

**Option B — Cerebras as an option (OpenAI default, opt-in switch) — the spike's current shape.**
- *Architecture:* the router tension of §A2 stands; two hardcoded branches.
- *Friction:* zero for default users; power users/devs can opt in.
- *Verdict:* acceptable as a *measurement* posture, weak as a shipped one — an unmeasured, unrouted
  second planner is dead weight in the default build.

**Option C — Formalize the seam; OpenAI (gpt-5.5) default; open-weights planner as a measured,
fallback-capable alternative behind a provider-agnostic router. (Recommended.)**
- *Architecture:* best fit. Lands the second planner the way §16.5 already mandates — behind a router
  that abstracts the wire shape — turning "add Cerebras" into "add a provider," which is reusable for
  Anthropic (already planned) and for any of the ~15 other hosts that serve `gpt-oss-120b` (it is
  Apache-2.0 open-weight; Groq/Fireworks/Baseten/Vertex/self-host all serve it — external-facts §5).
  **The open-weights choice is the durable win, not Cerebras specifically:** the planner is not
  locked to one vendor, so the reliability and deprecation risks of any single host become a
  configuration change, not a rebuild.
- *Friction:* default users unaffected; the ~14×-input / ~40×-output cost delta (gpt-oss-120b
  $0.35/$0.75 per M vs. gpt-5.5 $5/$30 per M — external-facts §1a/§6) becomes available as a
  cost-optimization or fallback lane once quality is proven.
- *Verdict:* **recommended.** It satisfies the founder's "make the architecture better" goal directly
  and defers the risky "make it the default" question to measurement (§A5).

### A4. A new planner is a chance to fix the vocabulary architecture, not port its holes

The planner's emit-vocabulary is `CapabilityRegistry.plannerDescription` =
`adapters.flatMap(\.metadata.plannerTools)`, interpolated into the shared system prompt both planners
use. Three vocabulary defects are live in the queue, and all three are **planner-agnostic** — a
Cerebras swap inherits every one unless the architecture is fixed:

- **SONNY-48:** snippet operations declare `plannerTools: []` (`SnippetSaveCapabilityAdapter.swift:15`),
  so no snippet-step routine is authorable through the planner, even though the routine validator
  permits one (`SaveRoutineCapabilityAdapter.swift:107-119`). The core's permission and the planner's
  range silently disagree.
- **SONNY-68:** `switch_running_app` is `plannerVisibleCases`-excluded (verified,
  `AgentPlan.swift:169`), so "switch to X in workspace Y" — which the instant resolver rejects because
  its ≤3-post-verb-word guard trips on the workspace clause (root cause verified at code level in
  SONNY-68's comments, `InstantCommandResolver.swift:357-378`) — falls to the planner, which has no
  app-switch operation and routes it to the *nearest-sounding* one: `edit_workspace`, a **destructive
  boundary edit**. The tier-3 removal consent is the only thing that caught it.
- The general shape: the vocabulary is defined implicitly by per-adapter `plannerTools`, with no test
  pinning the agreement between the exclusion set, the empty-tool adapters, and instant-resolver
  coverage (planner-seam report: that agreement is "incidental, not pinned").

**Recommendation:** treat the vocabulary architecture as its own work item, sequenced *before* or
*with* any planner swap (because both planners share the vocabulary and both inherit its holes), and
make the SONNY-48 / SONNY-68 decisions part of it (§C, §D12). Do not bundle it *inside* the Cerebras
decision — it is independent of provider — but do use the swap as the forcing function to formalize
the seam and add the missing pin (a test asserting exclusion-set / empty-tool / resolver agreement).

### A5. What must be MEASURED before any commitment (the gate numbers)

The experiment's acceptance criteria are the right measurements and were never recorded. Before any
posture above is chosen, the owed SONNY-69 findings comment must produce, on a fixed representative
command set (not an ad-hoc 3):

1. **Plan-quality parity** — for each command, does Cerebras produce a valid, correct `AgentPlan`
   equal in quality to OpenAI's? Report agreement rate and the disagreement transcripts. *Gates
   whether Cerebras can be default (Option A) at all.*
2. **Structured-output rejection / malformed-plan rate** in schema-in-prompt mode — how often does
   `decodeStrict` reject the model's output, given there is no server-side structured guarantee?
   Re-verify the current Cerebras nullable-union support live: the docs now claim `anyOf`/null-type
   *is* supported, contradicting the experiment's "no nullable-union" finding (external-facts §1c) —
   but the 5,000-char cap still rejects the 9.3 KB schema regardless, so schema-in-prompt stays the
   safe default. *Gates whether native structured mode is ever usable, and how much retry logic the
   planner needs.*
3. **End-to-end plan latency** — Cerebras vs. OpenAI, wall-clock, including retries. (Blocked on keys;
   never run.) *Gates the "latency is the reason to switch" premise.*
4. **Reliability envelope** — treat Cerebras's ~2.5 incidents/month as a design input: any posture
   that makes it load-bearing needs a fallback to OpenAI, which Option C provides by construction.

Recommendation: **no default-planner change ships until #1 shows parity and #2 shows an acceptable
rejection rate.** Until then, Option C's "OpenAI default, open-weights alternative behind the router"
is the honest state.

---

## B. The vision loop as a product capability (the core of this plan)

The spike proves the mechanism works and bypasses consent to do it. The product must invert that:
consent first, mechanism second. This section designs the containment.

### B1. How synthetic clicks/typing enter the tier model

The engine's containment primitives all exist and are exercised daily, but none has ever been
exercised by a perception-action loop (risk-engine report, §"what does NOT exist"). The tiers are 0–4
(`CapabilityAdapter.swift:3-13`); tier 3 is "External or destructive," tier 4 "Prohibited"
(`RiskApproval.swift:237-251`); the spec's own tier-4 examples include "Whole-Mac unrestricted
control" and "Generated shell execution" (spec §11.1). The single gate is `AgentRunner.execute`
(`AgentRunner.swift:121-152`) — verified structurally the only path to `AgentActionExecutor.execute`
(§2.2 of the risk report), and `execute()` itself contains zero approval references (it must never
re-gate — `.claude/rules/macagentcore-conventions.md`).

The architectural tension: **the engine's "static pre-execution guarantee" assumes a fully
materialized plan** — `assessRisk` folds one `effectiveTier` over every segment before the first side
effect (risk report §2.3). A vision loop picks action N+1 from the screenshot after action N, so it
*cannot* submit its full step list up front. Three shapes resolve this:

**Option (a) — loop as one opaque capability.** One `AgentOperation` (e.g. `vision_session`),
assessed once at a high tier, `.opaque` for scope (it can never name its resources up front — exactly
the `.invokeShortcut` / `.getFinderSelection` shape, `WorkspaceScope.swift:23-27`). Individual clicks
run *inside* the capability's `execute()`, not through the per-action gate.
- *Pro:* cheap; matches an existing pattern.
- *Con:* **weakens the founder's constraint the most.** The engine sees one coarse gate for the whole
  session; a destructive click mid-loop (a "Send", a "Delete") has no engine-level pause. `.opaque`
  buys documentation and non-relaxation-eligibility but **zero runtime containment** — scope verdicts
  are never read during `execute()` (risk report §4.2).

**Option (b) — loop as repeated single-step plans.** Each atomic action is its own single-step
`AgentPlan` through the real `prepare → assessRisk → execute` cycle per iteration; a new
`AgentOperation` per primitive (click/type/scroll/key), each classified in `PlanScopedResources`
(whose `switch` has no `default:` — a new op *must* be classified or the build fails).
- *Pro:* per-action gating is literal — the founder's constraint satisfied per click.
- *Con:* per-action *human* approval is absurd friction (a prompt per click); and it is a lot of new
  vocabulary and classification surface. Only workable if most actions auto-run at a low tier and
  only a high-consequence subset prompts — which is really Option (c).

**Option (c) — per-envelope consent + an engine-owned in-loop containment layer. (Recommended.)**
This is the model the mandate itself sketches, and it maps directly onto the spec's Power Mode design
(§13.3 App Approval Model, §13.1 risk-gated/session-bound). One new capability whose consent is an
**envelope approved once up front**, preserving the static-pre-execution guarantee:

> `{ target app (bundle-id-pinned, §B2), goal, iteration cap, allowed action-type set
> (click / type / scroll / key), workspace boundary }`

- The envelope is assessed as a unit at a tier reflecting the *worst* action it permits — typing and
  clicking in an arbitrary app is **tier 3** (external/destructive) by default, so it always requires
  explicit approval, and is `.opaque` for scope (never relaxation-eligible).
- The user approves the whole envelope before any action fires — exactly as they approve a full plan
  today. This *is* the static pre-execution guarantee, at envelope granularity.
- **Within** the loop, a new, first-class, tested containment layer in `MacAgentCore` (part of the
  engine, not a bypass of it) enforces the envelope on every action: an action outside the pinned
  app, the allowed action-type set, or the iteration cap is refused without re-prompting; and a
  designated **high-consequence action class** (a detected "Send" / "Delete" / "Purchase" / submit /
  credential field, per the spec's §6.5 / §13 high-risk list) escalates to a **live per-action pause**
  reusing the exact stale-approval re-arm mechanism the engine already has (`AgentRunner.execute`'s
  tier re-comparison, risk report §1.4/§2.4).

Why (c): (a) is too coarse for "route through the engine" (a destructive click has no gate); (b) is
too high-friction (human prompt per click). The envelope is the friction/safety sweet spot *and* it
is honest about the static guarantee. It reuses `.opaque`, the resolve-phase pin discipline (§B2),
the re-arm mechanism, and SONNY-64's pre-built-plan dispatch (§C). It adds a new consent payload to
`RiskApprovalCopy`/`RiskApprovalRequest` — additive, defaulted, does **not** touch the gate logic
(the gate never reads `approvalCopy` — risk report §7.3).

**The founder decision hiding here (§D4):** what does "route vision actions through the risk/approval
engine" *mean* — a fresh `AgentRunner.execute` gate per click (Option b, literal), or a per-envelope
gate plus an engine-owned in-loop containment layer that pauses on the high-consequence class (Option
c)? The recommendation is (c), with the in-loop layer being a first-class, unit-tested part of
`MacAgentCore` — the engine *extended*, never *bypassed*. The spike's zero-test, stdout-only loop is
the negative example this exists to replace.

### B2. Workspace scope as the cage — the iTerm2 incident is the canonical hazard

The iTerm2 incident (spike typed shell commands into a live terminal because the fallback targeted
the frontmost app) is the exact failure the product must make impossible. Three containment layers,
all reusing machinery that already exists:

1. **Never frontmost.** The product must remove or hard-gate `VisionFallbackAppHint.frontmost`
   (`VisionActionLoop.swift:57-61`). The target app is resolved and **bundle-id-pinned once** in the
   shared resolve phase, using SONNY-58's exact discipline: pin `resolvedBundleIdentifier`, match
   bundle-id-first, and *never* re-catalog-resolve the display name (the anti-imposter rule that stops
   an app calling itself "Chrome" from inheriting Chrome's membership —
   `RunningAppSwitchCapabilityAdapter.swift:37-52`, `WorkspaceScope.swift:224-236`). **Any new pinned
   field a vision step introduces inherits SONNY-58's store-tamper class (SONNY-67) unless it gets the
   same single-sourcing guarantee** (schema-excluded, decoder-excluded, resolver-only) — this is a
   hard requirement, not a nicety.

2. **An explicit vision-control allowlist, separate from the launch catalog.** `MacAppCatalog`'s 12
   apps are a *launch* catalog (what `open_app` may start); it is not a *control* allowlist. The spec
   answers "don't act on whatever's frontmost" with the Power Mode App Approval Model (§13.3): a
   per-app allowlist the user explicitly approves (bundle-id + display name + approved control level +
   allowed/denied actions), each gated behind a per-app eval bar (§13.7). The confirmed §13.7 v1 app
   list is Safari/Chrome/Finder/Notes/Calendar/Mail/Slack/VS Code — **iTerm2 is deliberately not on
   it.** Terminals must never be default vision-controllable: a terminal is arbitrary shell execution,
   which the spec's §7.4 skips as a hard trust-boundary violation. This collides directly with SONNY-66
   (§C).

3. **The workspace boundary.** If a workspace is bound, the vision session's target app must be
   `.inScope` of it (or escalate), reusing `WorkspaceScope`'s app matching. Because the loop is
   `.opaque`, it can never be *relaxed* by association — the correct, conservative default.

### B3. The coordinator↔vision split as real architecture

The spike's split — supported steps run the normal gated path, then the vision loop takes the
remainder in the app the last opening step surfaced — is a genuinely good pattern, and it is the spec
principle "generalize current app/URL opening without pretending to support arbitrary app automation"
(spec line 463) done right: use precise, previewable, gated adapters where they exist; fall to vision
only for what they can't express. As product architecture it needs two changes from the spike:

- **The split is consented as one surface, not silently auto-run.** The spike sets
  `pendingVisionFallback` and auto-runs the vision phase after the supported steps' `execute` succeeds
  (`AgentViewModel.swift`, two consumption sites verified). The product must present "Sonny will do
  [supported steps] with its tools, then attempt [remainder] by controlling [app]" as **one** consent
  envelope up front, so the user approves the vision phase *before* the supported steps run, not
  discovers it after.
- **The coordinator decides the split; the planner vocabulary must support it.** The spike's
  decomposition suffix (`OpenAIPlanner.swift` experiment suffix) teaches the planner to emit supported
  steps + one unsupported remainder instead of rejecting wholesale. That belongs in the vocabulary
  architecture work (§A4), and it interacts with SONNY-68: a "switch to X in workspace Y" that falls
  to the planner could now trigger a vision fallback instead of `edit_workspace` — changing the
  failure mode, for better or worse. Fix the routing first (§D12).

### B4. Fallback-on-unsupported default, and the unattended story

**Fallback default (§D5).** Three choices: (a) silent auto-fallback whenever a plan has an unsupported
remainder (the spike's behavior — categorically wrong for product; it is how the iTerm2 incident
happened); (b) explicit per-session opt-in — the user is asked "Sonny can't do X with its tools;
attempt it by controlling [app]?" and consents to the envelope (§B1); (c) no fallback at all — vision
is only ever an explicit, separately-invoked mode. **Recommendation: (b).** It keeps the good
coordinator↔vision architecture (§B3) while making the vision phase a consented choice, never a silent
consequence of a planner shortfall.

**Unattended (§D7): never.** A scheduled run hardcodes an `.approved(.tier2)` ceiling
(`AgentViewModel.swift:2147`); a vision session defaults to tier 3, so it *structurally cannot* run
unattended — the existing machinery does the right thing for free. Recommendation: add a **belt-and-
suspenders explicit refusal** in the scheduled path too (don't rely only on the tier ceiling), and
adopt the spec's §13.1 session-bound rule: auto-pause on screen lock / display sleep / user idle,
never continue unattended, and require the Mac unlocked + a visible HUD for any tier-3 action.

### B5. TCC onboarding

Screen Recording and Accessibility are **System-Settings-only grants** and today are **preflight-only,
never requested** (`PermissionReadinessService.swift:73-88`): the readiness rows literally say "Not
required yet; future tools would need this." No prompting call
(`CGRequestScreenCaptureAccess`/`AXIsProcessTrustedWithOptions`) and no screen-capture/AX-control API
exists anywhere in `Sources/` (capabilities report, exhaustive grep). What vision needs:

- New `CapabilityPermissionRequirement` cases — `.screenRecording` and (if it drives UI via
  Accessibility rather than pixels-only) `.accessibilityControl` — plus their `displayName`/`description`
  arms (`CapabilityAdapter.swift:23-68`). The enum has 7 cases today; neither exists.
- `Packaging/Info.plist`: a Screen Recording usage-description key (Accessibility uses no Info.plist
  key — its prompt is driven purely by the System Settings toggle). This is the same class of
  requirement that already made the mic and Apple-Events keys necessary (`CLAUDE.md` Commands note).
- **A first-run onboarding flow — which does not exist today** (the only "first-run" concept is the
  one-sentence first-approval explainer). Screen Recording's grant only takes effect after relaunch,
  so the flow must handle the request → relaunch → confirm cycle. Natural home: a Command Center
  (System A) modal following `SettingsDialogView`'s pattern, with `SettingsSecurityAccessPage`'s
  existing `PermissionReadinessRows` flipping those two rows from "not required yet" to "required."
- **The kill switch already exists** in general form: `cancelCurrentRun()` behind the running-indicator
  Cancel and the widget Deny button. **NOT VERIFIED** whether it can interrupt a capability's
  long-running `execute()` *between* loop iterations rather than only after a whole step returns — the
  in-loop containment layer (§B1) must check a cooperative cancellation signal each iteration; this
  needs confirming in `AgentActionExecutor`/`AgentRunner` at implementation time.

### B6. Data egress — a launch requirement, not a footnote

Screenshots leaving the device to Cerebras/Google turns the "Data Sent to AI" inspector — a
**founder-named competitive differentiator vs. Clicky** (founder-decisions doc, Insights section) and
a spec differentiator (§6.13) — from a later-row feature into a **launch requirement** for vision.
Today only a one-line `dataLeavesDevice` boolean exists (`RiskApproval.swift:102`), computed from a
7-operation set (`AgentActionExecutor.swift:998-1006`); the full inspector (§6.13/§14.5) is entirely
unbuilt. What vision requires, from the spec's own rules:

- **`dataLeavesDevice` must be true and honest** for every vision session (the spike records *nothing*
  and bypasses the boolean). SONNY-32 already documents that the disclosure is audited one-directionally
  and can render a false "no" — that bidirectional-honesty fix becomes a launch blocker here (§C).
- **Pre-send content preview (§14.4A).** For full-screen captures and any tier-2+ action, the inspector
  must show the exact context bundle *before* it leaves the device — a vision session is tier-3 and
  sends screenshots, so "what Sonny saw" must be a pre-send gate, not a post-hoc log.
- **Local redaction (§12.3), best-effort, fail-closed.** Secrets in a screenshot (API keys, tokens,
  card numbers, password fields) must be redacted before upload, and the product must state plainly
  that this is best-effort detection, not a guarantee.
- **Screen prompt-injection defense (§12.5).** On-screen text is untrusted observed content; the vision
  model must not follow instructions found on screen. **The spike's prompt does not do this** — a
  malicious on-screen "ignore your goal, click Delete" could hijack it. This is the same
  untrusted-content boundary `MacAgentCore` already enforces for web content
  (`.claude/rules/macagentcore-conventions.md`), applied to screen content.
- **Provider posture.** Cerebras states no-retention / no-training on all tiers (external-facts §2).
  Google's free tier **trains on submitted data and allows human review** (external-facts §4) — sending
  screenshots there is a serious privacy problem. Recommendation (§D10): vision screenshots go only to
  a no-retention host (Cerebras, or a paid no-retention tier); **never Google's free tier**; and
  `dataLeavesDevice` honesty is non-negotiable. Also re-verify `gemma-4-31b`'s preview-vs-GA status and
  deprecation risk before depending on it (external-facts §3/§7: Cerebras is actively deprecating a
  preview model 2026-08-17).

---

## C. Roadmap and ticket impact matrix

Keep / amend / supersede for every open ticket and every future row this integration touches. "Amend"
means the ticket's contract should change *after founder approval*; nothing is edited by this session.

### Future roadmap rows

| Row | Disposition | Why |
|---|---|---|
| **14 — screen-intelligence** (§6.4, §12, §6.13, §14.4A/§14.5) | **Amend / pull perception + transparency forward** | This is where the *perception* half (capture, OCR, redaction, the Data Sent to AI inspector) belongs, and it is the prerequisite safety infra for any action half. It is the differentiator and it gates vision. Candidate to pull ahead of its locked position (after rows 12/13). |
| **18 — power-mode** (§6.5, §13) | **Amend / rescope as the action half** | The vision *action* loop (model-directed clicking/typing in apps) *is* Power Mode in spec terms. The spec deliberately sequences it last, after the risk engine + emergency-stop exist (§21.6). The experiment doesn't change that the action half is high-risk and late — but it should be rescoped around the coordinator↔vision architecture (§B3). |
| **12 — hosted backend / 13 — billing** | **Keep; flag router tension** | No hard dependency (both planners are client-called today), but §16.5's provider-agnostic router is a row-12 concern; landing the open-weights planner cleanly (§A2/§A3-C) either formalizes a client-side router stand-in now or waits for row 12. Founder decision §D2. |

**The central roadmap decision (§D8):** does row 14 pull forward and *absorb* the whole vision loop,
does the loop become its own new row gating others, or does it **split** — perception + transparency
infra pulled forward (row 14), action half staying as rescoped Power Mode (row 18)? Recommendation:
**split.** The perception/transparency infra is both the differentiator and the safety prerequisite
and should come forward; the action half stays gated behind it and behind the risk-engine maturity the
spec already requires.

### Open tickets

| Ticket | Disposition | Why |
|---|---|---|
| **SONNY-13** (row-C relaxation planning) | **Amend** | Row C's `(tier, verdict, origin)` model must include vision actions from day one: a vision session is tier-3 `.opaque`, so never relaxation-eligible (consistent), and the origin-signal work should include a vision-consent origin. Transitively blocked (below). |
| **SONNY-59** (Finder implicit control on scan/zip; touches `PlanScopedResources`) | **Keep; unhold** | Held only pending this report. It is a narrow, orthogonal classifier tighten — independent of vision. It should land; its landing unblocks SONNY-13. But it touches `PlanScopedResources.swift`, the same file a vision-action classification extends (no `default:` case), so coordinate sequencing to avoid conflicts. |
| **SONNY-66** (app-catalog expansion mechanism) | **Amend / absorb** | Now must decide **two** lists: the launch catalog (`open_app`) and the vision-control allowlist (Power Mode §13.3). "Launching vs. acting-in are now different questions." Per-app-consent is the best fit for both; terminals must be excluded from the control list (§B2). A row-C / vision input. |
| **SONNY-68** (switch-in-workspace misroutes to `edit_workspace`) | **Amend / prerequisite** | Vocabulary/routing bug independent of provider, but a planner swap inherits it and a vision fallback changes its failure mode (§B3). Fix as a prerequisite to planner + vision work (§A4). |
| **SONNY-48** (planner has no snippet vocabulary) | **Keep; fold into vocabulary work** | Same vocabulary-architecture class as SONNY-68. A planner swap is the chance to fix the registration mechanism, not port the hole (§A4). |
| **SONNY-64** (pre-built-plan dispatch, no composer round-trip) | **Keep; elevate — shared prerequisite** | Its "dispatch a pre-built `AgentPlan` into the same `prepare→assessRisk→approval` gate, no planner" is exactly the mechanism vision-envelope consent needs (§B1). Now load-bearing for both the workspace-sheet UX and vision consent. |
| **SONNY-62** (tier-equal re-arm masks a different tier-3 reason) | **Keep; more urgent** | A vision loop's per-iteration escalation *reason* can change while its tier stays 3; the current guard compares tiers only. The reason-set-comparison fix is a prerequisite for the in-loop re-check (§B1). |
| **SONNY-67** (routine store admits pre-set app pins) | **Keep; more urgent** | Any new pinned vision field (resolved app bundle-id, resolved AX element) inherits SONNY-58's store-tamper class; the single-sourcing guarantee must be replicated (§B2). |
| **SONNY-32** (dataLeavesDevice one-directional; false "no") | **Keep; launch blocker for vision** | Screenshots leaving the device must never disclose "no." The bidirectional-honesty rule must hold before vision ships (§B6). A planner swap can also reopen this (its guarantee is planner-prompt-dependent). |
| **SONNY-55** (ActionPreview built, rendered nowhere) | **Keep; relevant** | A vision session needs a preview surface more than today's plans (higher uncertainty). The "where does a preview belong" design question should be decided as part of vision consent UI. |
| **SONNY-56** (Command-Center success summary renders nowhere) | **Keep; relevant** | A vision session's outcome must render on the originating surface; this gap affects it. Fold into vision UI. |
| **SONNY-14 / SONNY-15** (rows D/E: task history controls; task detail rehydration) | **Amend scope** | If vision sessions record transcripts (screenshots + actions), row D's hide/delete/incognito must cover them and row E's rehydration must handle them. `CompletedTaskRecord` has no transcript field — extending it (optional field vs. a new store) is a decision rows D/E inherit (capabilities report). |
| **SONNY-28 / 30 / 34 / 35** (bug cluster: docx overwrite, `try?`-suppressed escalation, repeated-step drop, default-output-path) | **Keep unchanged** | Execution-correctness bugs orthogonal to vision. 34/35 sit in module C and are row-C-adjacent but survive unchanged. Sequencing vs. vision is a decision (§D12). |
| **SONNY-33** (save-time escalation fold → forward advisory) | **Keep unchanged** | Module C; orthogonal to vision. |
| **SONNY-51** (routine browser binding misses `playMedia`) | **Keep unchanged** | Orthogonal seam bug. |
| **SONNY-65** (workspace sheet app icons) | **Keep unchanged** | UI polish; pairs with SONNY-64's picker but independent of vision. |
| Discord catalog addition (ratified for the experiment) | **Re-decide via SONNY-66, do not port** | The spike added `com.hnc.Discord` to `MacAppCatalog`. Per "the spike never merges," it should be re-decided through SONNY-66's mechanism; if that mechanism is per-app-consent, no hardcoded entry is needed at all. |

### Dependency chain to surface

SONNY-13 is blocked on SONNY-59 landing (SONNY-13 comments); SONNY-59 was held pending this report;
therefore SONNY-13 is transitively held. **Unholding SONNY-59** (it is orthogonal — §C) unblocks the
chain. Row C's planning also carries SONNY-66, SONNY-62, SONNY-64, SONNY-68 and the edit-path-widening
flag as inputs — several of which this integration now also depends on, so row C and the vision work
share a prerequisite set and should be sequenced together, not in ignorance of each other.

---

## D. The decision list

Numbered for point-by-point answers. Each carries options and a recommendation mapped to the two
goals (architecture quality, user friction). **These are the founder's to decide; the plan does not
decide them.** Implementation tickets follow the answers.

**D1. Default planner posture.** (a) OpenAI default, open-weights planner as a measured,
fallback-capable *option* behind a formalized router **[recommended]**; (b) switch default to
Cerebras; (c) run a production A/B. — *Rec (a): the open-weights option is the architecture win;
making it default is unjustified until §A5 numbers exist and is reliability-fragile without a
fallback.*

**D2. The provider-architecture tension.** §16.5 mandates a provider-agnostic router so the app never
hardcodes a vendor's wire shape; the spike adds a second hardcoded client-side branch. Do we (a)
formalize the router (or a client-side stand-in) now and land the open-weights planner behind it
**[recommended]**; (b) defer any second planner until row 12's backend router exists; (c) accept a
second hardcoded branch as tech debt? — *Rec (a): three wire formats make the router more justified,
not less; the spike is the exact anti-pattern §16.5 names.*

**D3. Vision consent model.** (a) single opaque capability, coarse gate; (b) per-action gate, literal;
(c) per-envelope consent + engine-owned in-loop containment layer **[recommended]**. — *Rec (c): the
friction/safety sweet spot that keeps the static-pre-execution guarantee honest (§B1).*

**D4. What "route through the risk/approval engine" means for vision.** A fresh `AgentRunner.execute`
gate per synthetic click (literal), or a per-envelope gate plus an engine-owned, unit-tested in-loop
containment layer that pauses on a high-consequence action class (Send/Delete/Purchase/credential)?
**[recommended: the latter]** — the engine *extended*, never bypassed; the spike's stdout-only loop is
the negative example. (Ties to D3.)

**D5. Fallback-on-unsupported default.** (a) silent auto-fallback (spike behavior); (b) explicit
per-session opt-in **[recommended]**; (c) no fallback — vision is only an explicit mode. — *Rec (b):
keeps the coordinator↔vision architecture while making the vision phase consented, never a silent
consequence of a planner shortfall (this is how the iTerm2 incident happened).*

**D6. Vision-control app allowlist.** (a) reuse the 12-app launch catalog; (b) a new, separate
control allowlist; (c) per-app user consent **[recommended]**. And: are terminals (iTerm2/Terminal)
ever vision-controllable? **[recommended: never by default]** (arbitrary shell = spec §7.4 boundary).
Resolve jointly with SONNY-66.

**D7. Unattended vision.** Never **[recommended]** — bar it with an explicit refusal in the scheduled
path, not only via the tier-2 ceiling, and adopt the spec's §13.1 session-bound auto-pause rules.

**D8. Row 14 pull-forward vs. new row vs. split.** (a) split — pull perception + transparency infra
forward (row 14), keep the action half as rescoped Power Mode (row 18) **[recommended]**; (b) one new
combined vision row gating others; (c) leave the locked sequence and defer entirely. — *Rec (a): the
perception/transparency infra is both differentiator and safety prerequisite; the action half stays
gated behind it and behind the risk-engine maturity the spec already requires.*

**D9. Data-egress as a launch requirement.** Confirm that, for vision, all of these are
launch-blocking: honest `dataLeavesDevice` (SONNY-32 bidirectional fix); the Data Sent to AI inspector
with pre-send preview for full-screen/tier-2+ (§14.4A); best-effort fail-closed local redaction
(§12.3); and screen prompt-injection defense (§12.5). **[recommended: yes, all four.]**

**D10. Provider for vision (screenshots).** (a) Cerebras (no-retention) only, never Google's free
tier **[recommended]**; (b) allow Google free tier as a fallback; (c) require a paid no-retention tier
before any screenshot egress. And: re-verify `gemma-4-31b` preview-vs-GA + deprecation risk live
before depending on it. — *Rec (a): Google's free tier trains on data and allows human review
(external-facts §4); screenshots are the most sensitive payload Sonny would ever send.*

**D11. Measurement gates and who runs them.** Confirm the owed SONNY-69 findings comment must record,
on a fixed representative command set: plan-quality parity, structured-output rejection rate (with a
live nullable-union re-check), and end-to-end latency (§A5) — and that **no default-planner change
ships until parity + rejection-rate pass.** Who runs it, and against which command set?

**D12. Sequencing.** Confirm: (i) unhold and land **SONNY-59** (unblocks SONNY-13); (ii) fix the
vocabulary/routing (**SONNY-68 + SONNY-48**) as a planner prerequisite; (iii) elevate **SONNY-64** as
a shared vision/sheet prerequisite; (iv) the **bug cluster** (SONNY-28/30/34/35) — does it land before
vision planning proceeds, or in parallel? (v) sequence row C and the vision work together, given their
shared prerequisite set (§C).

**D13. Spike disposition.** Confirm draft PR #36 stays draft/reference and never merges; confirm that
findings-seeded implementation tickets are created only after D1–D12 are answered (per "the spike is a
reference, not a source").

---

## Appendix — how this plan was produced

Seven parallel research agents (model sonnet, effort high, per `CLAUDE.md`) over: the experiment
branch code at `58e8cf5`; the `Planning` seam and vocabulary; the risk/approval + scope engine; the
capability/store/UI surface; the four governing docs; the full open Plane queue (20 tickets pulled +
comments); and external provider facts (verified via web search, retrieved 2026-08-08). The coordinator
read the experiment's core files (`VisionActionLoop.swift`, `CerebrasPlanner.swift`, the wiring diff),
`AgentRunner.swift`, `RiskApproval.swift`, `WorkspaceScope.swift`, and the risk-engine report in full,
and adversarially re-verified the four load-bearing claims (planner exclusion set, `dataLeavesDevice`
membership, the scheduled `.approved(.tier2)` ceiling, spec §16.5's router language) against source
before writing. Evidence is cited inline as file:line at a SHA, or ticket/doc reference. Measurements
the experiment never recorded are named as owed, not invented.
