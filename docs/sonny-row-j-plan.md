# Row J — per-app control consent, and the terminal screen check

Planning output for **SONNY-104**, produced 2026-08-16 on `docs/app-control-consent-planning`, cut
from `main` at `9a84e3b`. Every measurement below is stamped with the SHA it was taken at and names
the command that produced it.

This document plans **two gates**. They are planned together because both answer "which apps may
Sonny control", both touch the same policy code, and their **ordering** is the thing most likely to
go wrong — this repository has twice shipped a structural deny that sat behind something it should
have sat above (row I's execute door, and its resolver hook that nothing called).

The binding contracts are the Plane tickets. This document is the architectural record: the founder
decisions, the constraints, and the reasoning a ticket cannot carry. Where this document and a
ticket disagree, the ticket wins.

**Source decisions.** Founder (Sauransh Bhardwaj), 2026-08-16, recorded on SONNY-91 (gate one),
SONNY-102 (gate two) and SONNY-104 (both, plus the nine answers with their conditions). The
2026-08-14 decision that deleted per-app control consent is superseded, not pretended away — see
`docs/sonny-founder-design-decisions.md`.

---

## 1. The ordering, which is not a design choice

Three refusals and one prompt, in this order. Every layer above the consent gate refuses; only the
consent gate ever asks.

| Order | Gate | Outcome | Where it lives today |
|---|---|---|---|
| 1 | **Static terminal deny list** | Refusal, never a prompt | `ScreenControlPolicy.terminalBundleIdentifiers`, enforced at `VisionSessionCapabilityAdapter.swift:147` (resolve), `:189` (assess), `:248` (execute), re-checked per iteration at `VisionSessionContainment.swift:262-306` |
| 2 | **Runtime screen check** (new, gate two) | Refusal, never a prompt | New — inside the capture/redact step of `VisionSessionRunner` |
| 3 | **Per-app consent** (new, gate one) | Prompt, or silence | New — a field on `ApprovalContext`, read inside `RiskApprovalPolicy.requirement(for:context:)` |

**The static list refuses first, and the screen check never becomes a reason to trim it.** A static
bundle-identifier comparison cannot be talked out of its answer by anything rendered; a screen check
reads exactly the surface an attacker controls. That asymmetry is the whole reason the ban rests on
the list, and it does not change because a second mechanism arrived.

**Both refusals sit above the consent model. A terminal is never a prompt, in any mode, whatever the
user has approved.** The terminal check is **not** folded into the per-app gate as "an app that is
always denied" — it stays a separate, higher refusal at its own doors.

### Why that separation is structural rather than remembered

The deny list's three doors all run **before any approval requirement exists**:

- The resolve door (`:147`) throws during `resolveDefaultOutputs`, so the plan never becomes
  executable and never reaches assessment.
- The assess door (`:189`) throws inside `assessRisk`, which is what *produces* the
  `CapabilityRiskAssessment` that `requirement(for:context:)` later consumes. There is no assessment
  to compute a requirement from.
- The execute door (`:248`) throws before `context.visionSession` is even read — deliberately, and
  the comment there records why: ordered the other way for one commit, the ban became conditional on
  screen control being configured at all.

So "the deny list is above the consent model" is a consequence of where the code sits, not a rule
anyone has to remember. **Gate two must inherit that property**, and §4.3 places it accordingly.

---

## 2. Gate one — the per-app control model

### 2.1 What the user gets

Which apps Sonny may control **without asking** depends on the mode:

- **Safe** — starts from nothing. Sonny asks before controlling any app.
- **Normal** — starts from a built-in starter list. Anything outside it asks.
- **Power** — asks about no app at all.

An approval is remembered. In every mode the **consequence rule is untouched**: destructive actions
and anything affecting someone other than the user still ask, mid-loop included. This decision
governs *which apps Sonny may drive*, never *what it may do once driving them*.

### 2.2 The starter list (piece 1)

**Founder decision, 2026-08-16, with conditions.** Apps a non-technical Mac user has. **Every IDE
and code editor is off the list.** The ground, in the founder's words: the exclusion is about
embedded shells, not about the apps being dangerous. A developer who wants Sonny inside VS Code
approves it once, by hand — one click, once, ever.

**The list is derived, never `MacAppCatalog.default`.** That table (`MacAppService.swift:64-77`, 12
entries) is the only surviving hardcoded app list in `Sources/`, and it contains
`com.apple.Terminal` (`:76`) and `com.microsoft.VSCode` (`:75`). It is an alias table for name
resolution and has gated nothing since C12. Reusing it as a starter list would ship both a terminal
and an embedded-shell host on the silent side of the gate. This is the concrete reason the required
test is not a formality.

**The required test asserts two things, not one** — in the manner of `theEvidenceSplitMatchesTheList`,
driven off the production lists themselves so an entry appended without the guard failing is
impossible:

1. No starter entry appears in `ScreenControlPolicy.terminalBundleIdentifiers`.
2. No starter entry is an excluded IDE or code editor.

Both are list-driven rather than literal, with one deliberate exception following
`theTwoFounderNamedTerminalsAreOnTheList`'s precedent: a literal pin on a handful of entries, because
list-driven assertions all pass against an emptied list.

**Evidence discipline, inherited from the deny list.** The starter list carries the same
one-verified/N-unverified split the deny list carries, for the same reason: a wrong identifier on a
*deny* list fails open, and a wrong identifier on an *allow* list also fails safe (the app simply
prompts) — but a reader deciding whether to trust an entry deserves to know which kind of claim it
is. The split is recorded in the doc comment and pinned by a test, exactly as `ScreenControlPolicy`'s
is.

**The honest tension, stated rather than discovered.** This is itself a name-based list with the same
incompleteness property SONNY-102 is about — inverted, so it fails safe: an unlisted app prompts
rather than being silently driven. That is genuinely better, and it is still a curated list somebody
maintains.

### 2.3 The asking flow and the prompt (piece 2)

**Founder decision, 2026-08-16.** The prompt **reuses the ordinary approval path**. It is a
`RiskApprovalRequest` like any other, produced by the one requirement function, answered by the
existing Allow/Deny controls.

**Where it renders — and a premise that had to be corrected first.** SONNY-91's comment, SONNY-104's
description, and the root `CLAUDE.md` all state that the floating widget is the only approval
surface. **That is false at `9a84e3b` and has been since branch 10.** `CommandCenterAttentionPanel`
(`Sources/MacAgent/CommandCenterView.swift:688-890`) declares its own `AttentionState` with
`permission` / `clarification` / `failure` (`:695-712`), reads the same `viewModel.approvalRequest`,
renders the same first-run explainer, disclosure lines and escalation reasons, and wires Deny/Allow
to the identical `viewModel.cancelCurrentRun()` / `viewModel.start()` entry points (`:794-802`). It
is instantiated on all four top-level pages — `:462`, `:907`, `:2319`, `:2524`.

The consequence is the reason this matters rather than a trivium: **reusing the ordinary path puts
the prompt on both surfaces for free.** A bespoke widget panel — the shape row I used four times —
would render in the widget only, because `CommandCenterAttentionPanel` renders none of row I's four
vision states. Filed as **SONNY-112** for the `CLAUDE.md` correction, which is outside this ticket's
touched areas.

**What the prompt says.** The existing panel already renders `Allow access to `**`<app>`** from
`RiskApprovalCopy.involvedResource`, which a vision session already populates with the app's display
name (`VisionSessionCapabilityAdapter.swift:204`). What is missing is the fact that the answer is
remembered. **That fact goes in the escalation reason** — the existing channel for *why the user is
being asked*, already rendered in amber on both surfaces — and **not** in a new explanatory line. This
respects the standing rule that the product does not explain how it works; an escalation reason is
not an explanation of mechanism, it is the reason for this specific question.

**No "just this once" option in v1.** Founder decision, with three reasons recorded so it is not
re-litigated: it is a second consent shape for the same consent; the approval buttons are icon-only
circles (`FloatingWidgetView.swift:717-733`) and a third would mean redesigning them, which belongs
to the whole-product UI/UX pass (SONNY-109) and not here; and revocation (§2.6) is the escape hatch
for anyone who wants to undo a grant.

### 2.4 Remembering the answer (piece 3) — the tenth local store

A new encrypted local store of approved apps, following the shared `LocalStorageEncryption` pattern
the existing nine follow — defaulted `encryption:` constructor parameter, AES-GCM with the
`SONNYENC1\n` header, transparent legacy-plaintext migration. **Not a variant.**

**It must reach the wipe, and that is two assertions, not one.**
`LocalDataDeletionService.defaultStoreFileURLs()`
(`Sources/MacAgentCore/LocalDataDeletionService.swift:85-99`) returns nine URLs at `9a84e3b`.
`theWipeReachesExactlyTheNineLocalStores`
(`Tests/MacAgentCoreTests/LocalStorageSecurityTests.swift:346-364`) asserts **both**
`urls.count == 9` **and** an exact set of nine literal filenames. A tenth store changes the count,
the filename set, and the test's name.

**Load versus write failures are different things** and get different user-facing handling —
`recordLocalStorageLoadFailure` is load/decrypt-only wording; a write failure needs its own accurate
`errorMessage`, following `applyClipboardHistoryNoticeChoice`.

**A stored approval never outranks a refusal.** The deny doors and the screen check both run above
this store, so an entry for an app that later lands on the deny list cannot resurrect it. Two
belt-and-braces requirements, because a durable grant outlives the session that minted it: the write
path refuses to persist an app the deny list refuses, and the revocation surface (§2.6) never
displays one.

### 2.5 How the mode and the consent reach the engine — the architectural constraint

This is the part row I's changelog entry warned about in advance:

> *"No new posture was needed for 'Safe asks about vision, Normal and Power do not' — it falls out of
> the shipped engine. A future reader tempted to add a mode axis to `ApprovalContext` should read
> this first."*

That warning is an instruction about **shape**, not a prohibition. This work is exactly that future
reader's case, and the shape is fixed by row C's invariant **I8**: exactly one public function
produces a `RiskApprovalRequirement`, and no public function takes one and returns a different one.

**The named signature change:**

```swift
// Sources/MacAgentCore/RiskApproval.swift

public struct ApprovalContext: Equatable, Sendable {
    public var mode: AgentInteractionMode        // REPLACES `safeMode: Bool`
    public var appControl: AppControlStanding    // NEW
    public init(mode: AgentInteractionMode, appControl: AppControlStanding)
}

/// The resolved per-app fact, computed once per plan by one resolver and carried here.
/// Deliberately payload-free: the app's identity travels on the assessment for copy, not into
/// the policy, which needs only the answer.
public enum AppControlStanding: String, CaseIterable, Equatable, Sendable {
    case notApplicable   // this plan controls no app
    case allowed         // allowed under the current mode
    case needsApproval   // not yet allowed under the current mode
}

// signature unchanged; the switch inside it is what changes
func requirement(for assessment: CapabilityRiskAssessment,
                 context: ApprovalContext) -> RiskApprovalRequirement
```

`safeMode: Bool` is **replaced**, not supplemented. Two booleans cannot express three modes, and
carrying both would leave a derived field that can disagree with its source.

**Rules the implementation must satisfy, each checkable:**

1. **One switch, and the mode is one of its dimensions.** The scrutinee is the tuple
   `(context.mode, context.appControl, assessment.effectiveTier)`. No `default:` anywhere, and
   **`mode` is never matched with `_`** — so a fourth mode, or a fourth standing, forces every cell
   to be answered rather than inherited. That friction is the design, not something to route around.
2. **Never a rule chained after the function.** The tempting low-diff move —
   `let base = policy.requirement(...); return needsApproval ? .explicitApproval : base` — is exactly
   the post-hoc clamp I8 exists to forbid, and it is how a rule ends up firing on a result it was
   never meant to see.
3. **`appControl` is a strictness input only.** It may raise an ask; it may never remove one. This is
   the same one-directionality rule `VisionConsequenceClassifier` obeys for screen-derived signals,
   and the same shape as C2's ratified "consent maps to a requirement override, never a tier change".
4. **The function still never writes the assessment.** `effectiveTier`, `escalations` and
   `approvalCopy` are byte-identical with and without any standing. `effectiveTier` must stay honest
   because the unattended path's fixed `.approved(.tier2)` ceiling works by comparing tiers.
5. **Tier 4 refuses in every mode and every standing** — row C's escalate-never-block invariant (I4),
   pinned by the cross-product.
6. **Safe mode's floor is unchanged.** `safeModeFloor` stays `.explicitApproval` and Safe's formula
   stays `stricter(of: requirement(for: tier), safeModeFloor)`. Composing terms *inside* the one
   function is the existing ratified shape; it is not a post-hoc clamp.

**The table test widens; it does not get its own file.** Row C's exhaustive cell-by-cell table
(`Tests/MacAgentCoreTests/ConsequenceRuleTests.swift`) gains the two new axes. Properties it must
keep pinning: Safe mode never more permissive than any other mode (P1); a standing never more
permissive than `.notApplicable` (the P2 analogue); destructive always asks; advisory alone never
asks; tier 4 always refuses.

### 2.5.1 Where the standing is resolved — and the failure mode to avoid

**Row I shipped a resolver hook that nothing ever called.** `AgentActionExecutor`'s resolve dispatch
is a hand-maintained list of `if`s rather than an exhaustive switch, so the vision adapter's
`resolveDefaultOutputs` existed and was never invoked — every vision plan reached all three gates
unpinned. The same class bit twice on that branch. **This plan's single largest risk is repeating
it**, because a per-app resolver that nothing calls looks exactly like a working gate.

**One resolver, named, with its call sites named:**

- A pure function in `MacAgentCore` taking `(mode, target bundle identifier?, starter list, approved
  apps)` and returning `AppControlStanding`. Pure so it is trivially testable; the stores are inputs,
  not dependencies.

**The resolver's answer depends on the mode, and that is the rule most likely to be lost.** Founder
correction, 2026-08-16, made while reviewing the ticket set: the switch in §2.5 reads the mode and
the resolver computes the standing, and it is possible to read both of those and still build a
resolver that ignores the mode. **Built that way, the starter list would grant standing in Safe too,
which silently undoes the one thing switching to Safe is for.** The rule, stated so it cannot be
inferred wrongly:

> **The starter list contributes standing in Normal and Power, and never in Safe. The user's own
> approvals contribute in all three.**

This is the mechanism behind §2.7's table, and it is what makes founder decision 4 — Normal → Safe
keeps the user's own list and drops the starter list — a property of the resolver rather than a
description of intent. **Acceptance criterion, carried on the implementing ticket:** one app resolves
differently across modes inside a single test, so a mode-blind implementation cannot pass.
- **Production call site 1:** `AgentViewModel.approvalContext()`
  (`Sources/MacAgent/AgentViewModel.swift:2296-2298`) — the one production construction site. It
  gains a non-defaulted parameter carrying the plan's vision target, so every caller must answer.
- **Production call site 2:** `VisionSessionInteracting.visionApprovalContext()`
  (`Sources/MacAgentCore/VisionSessionEnvironment.swift:172`), called by the runner at
  `VisionSessionRunner.swift:214`, `:310` and `:382` for mid-loop approvals. Its signature carries
  the session's pinned target.
- **Non-vision plans resolve to `.notApplicable`** — and that must be an answer each call site gives,
  never a default parameter value. A default is how this becomes a hook nothing calls.

**The anti-dead-hook requirement, stated as a ticket acceptance criterion:** the gate is pinned by a
test that drives a **real** plan through `performStart` — the `ConsequenceRuleDispatchTests` pattern,
which exists because row C's mapping was pinned by 950 green tests while the product's dispatch path
into it was never exercised and the feature did not fire in the packaged app. A component-level test
on the resolver alone does not discharge this.

**Re-resolved per iteration.** A live session re-resolves the standing at each iteration start, so a
revocation made in Settings while a session runs stops it. The cost is a set membership check.

### 2.6 Revocation (piece 4)

**Ships in v1. It is not a cut candidate** — founder directive, 2026-08-16: nothing gets parked, and
every part of every roadmap row ships. It may land in a separate branch from pieces 1–3; that is a
sequencing choice, never a scope one.

Settings → Security & Access → **Screen Control** (`CommandCenterView.swift:3821-3841`) grows a list
of approved apps with a per-row remove, plus a remove-all.

**Named precedent, not a new component.** The only existing "list of stored items, each with its own
inline remove" in the codebase is `WorkspaceDetailView`'s scope-entry list — `entryRow(_:)`
(`CommandCenterView.swift:2976-3016`), built on `SettingsAdaptiveControlRow` with a danger-tone
Remove button and `CommandCenterRowActionStyle(tone: .danger)`. No Settings page contains a
`ForEach` over stored items today; this is the first. System A tokens throughout.

`SettingsAdaptiveControlRow` is `private` to `CommandCenterView.swift`, so the new rows live in that
file or the type stops being private — a decision for the implementing ticket, recorded so it is not
discovered mid-build.

### 2.7 The mode differences (piece 5), and what a mode switch does

Cheap once §2.5 exists — the modes are already three cells of the new switch.

**Founder decision, 2026-08-16, on the mode switch.** Normal → Safe **keeps the user's list and drops
the starter list**. Safe stops trusting Sonny's list and keeps trusting the user's own explicit
choices. The founder asked that the reasoning be kept verbatim:

> *auto-clearing destroys user data on a toggle, which the consequence rule says should ask first.*

So there is exactly **one** user list, per app, forever (founder decision). The modes differ only in
what they start from:

| Mode | Baseline | Effective allow set |
|---|---|---|
| Safe | nothing | the user's list |
| Normal | the starter list | starter list ∪ the user's list |
| Power | everything | everything (the gate does not run) |

Remove-all in the revocation surface is the deliberate escape hatch for a user who wants the clean
slate a mode switch does not give them.

---

## 3. Copy that this work falsifies

Not open questions — founder confirmed these are implementation. Each is a shipped promise that
becomes false the day the gate lands, and each belongs on the ticket that falsifies it:

1. **Settings → Screen Control** (`CommandCenterView.swift:3823-3826`) currently says: *"Once Screen
   Recording and Accessibility are granted, Sonny can control any app installed on this Mac."* False
   under gate one.
2. The comment above it (`:3815-3820`) records *"There is no grant list, because there are no grants;
   there is no revoke, because there is nothing to revoke."* Both halves become false.
3. **`AgentInteractionMode.power.settingsDescription`** (`AgentInteractionMode.swift:66`) says *"Runs
   exactly like Normal today."* False — Power becomes the one mode that skips the per-app gate. Its
   doc comment (`:11-13`, `:15-29`) records the Normal-identical claim in three more places.
4. **`AgentInteractionMode.safe.settingsDescription`** (`:58`) needs to reflect that Safe also asks
   about which apps Sonny may control, not only about actions.

---

## 4. Gate two — the terminal screen check

**Founder decision, 2026-08-16 (SONNY-102).** Keep the static ten-name deny list as the primary,
load-bearing refusal, and add a runtime check that looks at what is actually on screen and refuses to
control the target when it sees a shell.

**Why this one, in the founder's terms.** It is the only candidate that reaches **Power** — which
asks about no app, so a name list is otherwise the only thing standing there — and the only one that
reaches the **embedded-shell gap**, which does not narrow with more list entries at all. The three
declined alternatives (hand-maintained list only; bundle-metadata heuristics; inverting to an allow
list) are recorded on SONNY-102 and are not re-litigated here.

### 4.1 What signal it reads

**The OCR pass that already runs on every capture.** `LocalRedactionService.redactCapture`
(`Sources/MacAgentCore/LocalRedactionService.swift:146-220`) calls
`ImageTextRecognizing.recognizeText`, joins the observations into one document, and pattern-matches
it. The live recognizer is `VisionImageTextRecognizer` — `VNRecognizeTextRequest`,
**on-device, no network** (`Sources/MacAgentCore/VisionImageTextRecognizer.swift:17`).

**The verdict is produced inside the redaction service, from the observations it already has, and
only the verdict escapes.** Raw recognised screen text must never leave that type. This is row I's
most expensive lesson stated as a design rule: *a structural guarantee is only as wide as the type
that carries it* — F5's redaction fix was correct for the parameter it constrained, and the same
class of text left by two other doors that took plain `String`s. The verdict rides on
`RedactedPayload`, whose initializer is already `fileprivate` and which is already deliberately not
`Codable`, so a verdict cannot be forged by a call site that forgot to ask or handed one by a
decoder — the same structural-producer discipline `ScreenControlVerdict` uses.

**Accessibility tree, considered and not chosen as the primary signal.** It would add a second view
of the same question, at the cost of a second permission that can be revoked mid-session and a second
failure mode. The OCR pass is already on the path, already local, and already fail-closed. Recorded
as a candidate for later hardening, not as an omission.

### 4.2 What it costs

**No new OCR pass, no new network call, no new permission, no new model call.** The recognition
already happens on every capture; the marginal cost is pattern matching over strings already in
memory.

**A committed baseline for the existing pass exists.** Find it by searching for the test name, not by
line number — this citation has already moved twice in two days, once when this branch added a
roadmap row above it and once when row 12's planning branch merged 45 lines above it. **Locator: the
`feature/vision-foundations` entry of `docs/sonny-v1-implementation-changelog.md`, in the `Tests:`
paragraph, the sentence printed by `redactionLatencyIsBoundedOnARepresentativeCapture`.** It records
**374 ms** end-to-end at `4e430f0` — real Vision OCR, detect, paint and re-encode, 800×600, four
lines, two planted secrets. `4e430f0` is an ancestor of `9a84e3b`. At this branch's rebase onto
`8e22dab` it sits at line 2774; treat that as an aid, not the citation. The implementation ticket re-measures against that figure so
the added cost is a delta against a known number rather than a fresh claim.

**Per action, not per session.** A screen changes under you, so a once-per-session answer has a real
correctness cost. The check runs on every capture, which is once per loop iteration — the same
cadence the deny-list re-check already runs at (`VisionSessionContainment.checkIterationStart`).

### 4.3 When it runs

**Placement in the loop** (`Sources/MacAgentCore/VisionSessionRunner.swift`):

```
checkIterationStart          :144   cancellation, cap, Accessibility, attention,
                                    terminal re-check, frontmost boundary
captureFrontmostWindow       :196   one window of the target app
redactCapture                :202   OCR + detect + paint  ← the shell verdict is produced here
  ↳ SHELL CHECK                     refuse here, before anything below
Safe-mode capture review     :218   only in Safe
decisionPrompt / send        :244   the redacted capture leaves the device
perform(decision)            :365   input synthesis
```

Refusing at that point means a shell on screen is caught **before the capture is sent to the vision
provider and before any action is synthesized**. Nothing about a screen showing a shell ever leaves
the device.

**Ordering against the other two gates**, per §1: the deny list has already refused at three doors
before the loop is ever entered, and the consent gate is below both.

**The first capture happens before the control approval.** Founder decision, so that the user is
never asked to approve an app Sonny would refuse anyway — which closes the accidental-approval trap
SONNY-102 names, where an unlisted terminal prompts as an ordinary unknown app and a user approves
one by mistake. Three facts the founder required stated explicitly rather than left implicit:

1. **A capture happens before the control approval.**
2. **That capture never leaves the device and is never journalled.** It is taken for the local shell
   check only.
3. **The capture is scoped to the target app's own window, not the whole screen** — see §4.4.

### 4.4 The window-scoping guarantee, verified by enumeration

This is load-bearing: the founder made §4.6's "end the session" conditional on it, because if a
capture could ever include other windows, a terminal sitting behind Chrome would kill an unrelated
session. Verified at `9a84e3b` by enumerating every capture path, not by reading the one function
that looked relevant:

- `ScreenCaptureService` exposes exactly **one** capture entry point,
  `captureFrontmostWindow(ofBundleIdentifier:)` (`ScreenCaptureService.swift:211`). There is no
  whole-screen or per-display capture method on the type.
- Candidates are filtered to the target app before anything is chosen —
  `window.bundleIdentifier == bundleIdentifier` (`:214-218`) — on top of a layer-0, on-screen filter
  (`:258`).
- The capture uses `SCContentFilter(desktopIndependentWindow: scWindow)` (`:305`): ScreenCaptureKit's
  single-window filter, which captures that window's own content and excludes everything else on
  screen, occluding windows included.
- That is the **only** `SCContentFilter` construction in the repository.
  `grep -rn "SCContentFilter\|SCDisplay\|CGDisplayCreateImage\|CGWindowListCreateImage" Sources/ Tests/`
  → one hit. Zero `SCDisplay`, zero `CGDisplayCreateImage`, zero `CGWindowListCreateImage`.
- The vision loop's only capture call is `VisionSessionRunner.swift:196`, into that one entry point.
  `grep -rn "captureService\." Sources/` → three hits, two of which are preflight permission checks.
- The window is re-resolved by ID at capture time (`:290-296`), so a window that closed in between
  fails cleanly rather than capturing something stale.

**This is stronger than the condition required.** The same scoping that makes ending the session safe
is what aims the check at the gap it was chosen for: a shell **inside the target window** is in the
capture, and a shell in **any other app's window** is not.

**A standing constraint, not just a finding.** Any future change that widens the capture — a
multi-window capture, a display capture, a region grab — invalidates §4.6's "end the session" and
must revisit it. Recorded here so a later branch reads it before widening rather than after.

### 4.5 How strict — two independent signs

**Founder decision:** two independent signs of a shell, not one. A single `$` on a documentation page
must not stop Sonny driving Chrome.

**Founder condition: the signals and the threshold are recorded as testable values, not as prose.**
Named constants in production code, with tests asserting the boundary in both directions, so "two
signs" is executable rather than a description of intent. The detector follows `SecretTextDetector`'s
existing shape — pattern matching over the joined OCR document, one document rather than line by
line, which is the shape PR #49's F1 established after a per-line scan let a multi-line key block
match only its first line.

The implementation ticket carries a **fixture corpus**, appended to like
`VisionPromptInjectionTests`:

- **Must refuse:** Terminal, iTerm, VS Code's integrated terminal panel, a JetBrains run console, a
  notebook cell running shell.
- **Must not refuse:** a documentation page showing `$ npm install`; a chat message quoting a
  command; **a code editor displaying shell script source** — a `.sh` file open in an editor is not
  an interactive shell, and this is the sharpest false positive in the set.

**The direction of error is stated rather than left to taste.** The rule this defends is categorical,
so over-refusing is the correct direction — but over-refusing has a real product cost, which is why
the threshold is two signs rather than one. Tuning happens against the corpus, not against a
recollection of what a shell looks like.

### 4.6 What it does when it sees a shell, and how it fails

**Ends the session**, the way the terminal refusal does. Founder decision, conditional on §4.4, and
the condition holds. A new `VisionContainmentRefusal` case carries the user-facing sentence, matching
`.targetIneligible`'s shape — one string for the panel and the record, because a refusal the log
describes differently from the panel is a refusal nobody can audit.

Refusing the single action instead was considered: the next capture is one scroll away from the same
shell, and the containment layer's own doc comment already states the principle — *"A containment
refusal never re-prompts. Each of these is a fact about the world that a human answering a question
cannot change... Offering an 'allow anyway' here would convert a structural boundary into a dialog."*

**It fails closed, and that property is inherited structurally rather than re-implemented.**
`redactCapture` already throws when recognition fails —
`LocalRedactionError.detectionUnavailable` (`LocalRedactionService.swift:154-156`, comment: *"Fail
closed: no scan, no payload. An unscanned image must never become sendable."*) — and
`imageRedactionFailed` when regions cannot be painted. `VisionSessionRunner` propagates both
(`:202`). So **an unreadable screen already ends the session today**, and the shell verdict inherits
that: there is no third "could not tell" state that could be mistaken for permission, because the
code path that would have produced one throws first.

**This must be pinned, not assumed.** A test injects a recognizer that throws and asserts the session
ends — not that the verdict comes back "no shell". That distinction is the entire content of "an
unreadable screen is not permission", and a mutation deleting the propagation must fail it.

### 4.7 The embedded-shell gap — stated explicitly, as required

**Yes, this addresses it — and bounded.** SONNY-102 records a second, narrower gap: a shell running
*inside* an app that is not a terminal (VS Code's integrated terminal, a JetBrains run console, a
notebook cell). Nothing in bundle identity distinguishes "has a shell inside it", so that gap does
not narrow with list entries at all. A screen check is the only mechanism that reaches it, and §4.4's
window scoping is what aims it there: a shell rendered in the target window is in the capture.

**What it does not reach**, said now rather than discovered later: a shell in a background tab, a
collapsed panel, a scrolled-away region of the window, or any window other than the captured one.

### 4.8 What must not be claimed — SONNY-102 does not close

**This does not close SONNY-102, and no record of this work may say it does.** Two reasons, both
structural:

1. **A screen check reads the surface an attacker controls.** That is why it is defense in depth and
   never primary, why the deny list stays load-bearing, and why the list is not trimmed by one entry.
2. **A shell that is not rendered is not seen.** §4.7's bounds are permanent properties of the
   mechanism, not gaps a better implementation closes.

The gap narrows in all three modes — including Power, which is the reason this approach was chosen —
and does not close. **The categorical rule still outruns its implementation.** SONNY-102 stays open
and becomes the home of the screen-check implementation.

The existing test `aTerminalNobodyListedIsControllableAndThatIsTheKnownGap` asserts the gap as
behaviour so it is executable rather than prose. It stays, and it must not be weakened to accommodate
the new check.

---

## 5. Blast radius, measured with a compiler-driven method

At `9a84e3b`. The founder required this re-measured after an earlier figure was reported from a plain
grep with no method stated and no SHA — this repository has a recorded history of exactly this count
being wrong three times in a row, each correction from a wider method, and only a compiler-driven one
settling it, because grep cannot type-resolve receivers.

**Method.** `Sources/`, `Tests/` and `Package.swift` at `9a84e3b` were copied to a scratch directory
**outside the repository**. In that copy only, `ApprovalContext.init(safeMode:)` and
`ApprovalContext.safeMode` were each marked `@available(*, deprecated, message: ...)` with distinct
messages, and the copy was built with `swift build --build-tests` using `CLAUDE.md`'s exact flagged
flags — **exit 0**. Counts are unique `file:line` pairs extracted only from lines matching
`^/…\.swift:N:C: warning: …`; the raw log holds 716 lines mentioning the init probe, most of them
caret continuation lines and macro-expansion notes, and counting those is how this measurement would
have been wrong a fourth time. Nothing in the repository worktree was modified — `git status
--porcelain` empty, `HEAD` still `9a84e3b`, checked after the probe.

**Results.**

- **Construction sites, type-resolved: 55** across 17 files — **1 in `Sources/`**
  (`AgentViewModel.swift:2297`) and **54 across 16 test files**. Largest single file:
  `ConsequenceRuleTests.swift`, 25.
- **Reads of `ApprovalContext.safeMode`: 3**, all in `Sources/` — `RiskApproval.swift:645`,
  `VisionSessionRunner.swift:214`, `VisionSessionRunner.swift:310`. The declaring initializer's own
  assignment (`RiskApproval.swift:600`) is a fourth touch point the compiler does not flag, counted
  by reading it.
- **No site hidden inside a deprecated context:** zero other `@available(*, deprecated)` declarations
  exist in the tree.

**Why the plain grep gives a different number, measured rather than asserted.**
`grep -rn "safeMode" Sources/` → 26 lines; `grep -rn "safeMode" Tests/` → 77 lines across 18 files,
both reproducing exactly at `9a84e3b`. It is a wider population because the token appears in
`safeModeRequirement`, `safeModeFloor`, `safeModeLines`, doc-comment prose — and, the trap grep
cannot see past, in **unrelated `safeMode: Bool` declarations**: a stored property on
`WidgetPermissionPanel` (`FloatingWidgetView.swift:634`) and parameters on two
`AgentActivityPresentation` functions (`:173`, `:184`), with their own reads at `:175`, `:186`,
`:471`, `:696`, `:769`. None would change if `ApprovalContext`'s field changed.

**The most useful thing this measurement produced.** In `Tests/`, 18 files match the token but only
**16** construct an `ApprovalContext`. The two that do not —
`Tests/MacAgentTests/ConsequenceRuleDispatchTests.swift` and
`Tests/MacAgentTests/VisionSessionRunTests.swift` — drive Safe mode through the **real product path**
(`AgentViewModel.interactionMode` / `safeModeEnabled`) rather than by building a context by hand.
**Those two must be re-verified behaviourally** after the mode becomes a three-valued input; the
other 16 are mechanical.

**Founder instruction, recorded as a ticket requirement:** the 54 mechanical test-signature updates
get their **own commit**, separate from any behavioural change, so a reviewer can see at a glance
that nothing behavioural hid inside them.

---

## 6. Sequencing — three branches, sequential

Founder decision, 2026-08-16. All five pieces of gate one ship, plus gate two. Splitting across
branches is sequencing, never scope.

| Order | Branch | Contents |
|---|---|---|
| 1 | `feature/terminal-screen-check` | Gate two. SONNY-102's implementation home. |
| 2 | `feature/app-control-consent` | Gate one pieces 1, 2, 3, 5 — starter list, asking flow, the tenth store, mode differences. Indivisible. |
| 3 | `feature/app-control-revocation` | Gate one piece 4 — the Settings list with per-row remove. |

**Screen check first**, because it improves behaviour that already shipped, it depends on nothing in
gate one, and shipping the refusal before the prompting means the accidental-approval window — a user
approving an unlisted terminal that prompts as an ordinary unknown app — never exists in a real
build.

**Pieces 1–3 cannot be split.** A starter list with no asking behind it means every other app
dead-ends with no escape hatch — worse than today's behaviour, not better. This was offered to the
founder as a fast partial and explicitly declined.

**Disjointness — these three do not run in parallel with each other.** Recorded in the founder's own
words: *all three touch the same Settings page and the same vision adapter, so it does not pass.*
Concretely: all three touch `SettingsSecurityAccessPage` (`CommandCenterView.swift:3719-3859`); gate
two and gate one both touch `VisionSessionCapabilityAdapter` and `VisionSessionRunner`; branches 2
and 3 share the tenth store's contract. **No recorded disjointness note means serial**, and this is a
recorded note saying serial.

Each remains disjoint from the other lanes running today — SONNY-16, SONNY-14/15, SONNY-111,
SONNY-103 — which is a separate question, decided per ticket.

---

## 7. Collision with roadmap row 12, named now

**Row 12 (hosted agent runtime backend) and this work will both want Settings surfaces**, and neither
ticket set may assume it owns that page.

At `9a84e3b`, **no credential or API-key entry field exists anywhere in the UI** — verified by sweep.
Every provider key is read from the process environment, and row 12 is specced to hold credentials
server-side. What exists today is read-only *presence*: `PermissionReadinessService` reports whether
`OPENAI_API_KEY` is set, rendered in Security & Access → Permission Readiness
(`CommandCenterView.swift:3776-3789`).

- **This work claims** Security & Access → **Screen Control** (`:3821-3841`) — the approved-apps list
  and the corrected reach copy.
- **Row 12 most plausibly claims** Security & Access → **Permission Readiness** (`:3776-3789`), the
  one place already rendering a credential-presence row, or Settings → **Usage** (`:3937-3958`), an
  explicit placeholder reserved for billing.

Same page, different sections. The collision is in `SettingsSecurityAccessPage`'s structure and in
`SettingsAdaptiveControlRow` being `private` to a 4000-line file that both ticket sets will edit —
not in the sections themselves. Recorded on both ticket sets so the second one to land rebases rather
than discovers.

---

## 8. What this planning did not decide

- **Whether the Accessibility tree becomes a second screen-check signal.** Considered, not chosen;
  recorded in §4.1 as later hardening rather than as an omission.
- **The exact starter-list membership.** The grounds are decided (§2.2) and the two guard tests are
  contracted; the literal entries are the implementing ticket's, produced under those grounds and
  under the evidence-split discipline.
- **Whether `SettingsAdaptiveControlRow` stops being `private`.** Named in §2.6 as a decision the
  implementing ticket makes, so it is not discovered mid-build.
- **SONNY-101 / SONNY-50's approval-panel surface question.** Untouched here. It remains open on
  SONNY-106.
