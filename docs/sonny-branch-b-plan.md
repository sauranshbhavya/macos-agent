# Branch B — Workspace Restriction Scope: Plan

**The Plane tickets are the binding contracts. This document is the full planning rationale behind them.** Where a ticket and this doc disagree about *what to build*, the ticket wins; this doc exists so a session picking up any of those tickets can understand *why* the contract says what it says, and so the analysis that produced them is not lost when the tickets close.

Produced by SONNY-12 (planning ticket for roadmap row B), 2026-08-04. Branch: `feature/workspace-restriction-scope`. Module: **B — workspace restriction scope**. Gates roadmap row C.

Durable decisions from this plan are also recorded in `docs/sonny-founder-design-decisions.md` ("Workspace restriction scope (roadmap row B)"), which is authoritative where it and a literal reading of `docs/sonny-major-release-spec.md` conflict.

---

## 1. The problem

Sonny has one boundary and it is the same for every task. Three separate allowlists exist today and none of them knows what the user is working on:

- `PathWhitelist` — `~/Desktop` and `~/Documents`, one instance shared by every capability in every run (`AgentActionExecutor.swift:81`, `CapabilityAdapter.swift:123`).
- `MacAppCatalog` — 12 hardcoded apps (`MacAppService.swift:37-50`).
- `SafeURL` — an anti-SSRF filter, not a domain policy. Any public `http(s)` host passes (`SafeURL.swift:24-43`).

A `StoredWorkspace` is `name`, `apps`, `urls`, `teamType` — a launch bundle, nothing more (`AutomationStores.swift:64-84`). Nothing anywhere compares an in-flight action's target against a workspace's contents. Two consequences:

1. A task run "in my Client Alpha workspace" can write anywhere in Documents and open any domain, with no signal that it left the workspace.
2. Because there is no boundary, every tier-2 action has to prompt equally. That is exactly why **row C is gated on this row** — relaxation has nothing to be justified by until a scope exists.

### Founder decisions already taken (user + co-founder, 2026-08-04, recorded on SONNY-12)

- Scope constrains **apps + web domains + file locations**. The file-scoping planning cost was accepted knowingly.
- Scope is **on by default** for all workspaces, not opt-in.
- An out-of-scope action **escalates and prompts** — never hard-blocks.
- A task belongs to a workspace when **started from its card OR named in the command**.

---

## 2. The model: a scope verdict has four values

A workspace declares three resource sets. For any resource a plan touches, the verdict against the bound workspace is one of:

| Verdict | When | Effect in row B | Eligible for row C relaxation |
|---|---|---|---|
| `.inScope` | The resource matches an entry in the workspace's list for its kind | Nothing | **Yes** — the only verdict that qualifies |
| `.outOfScope` | That kind *is* configured on this workspace, and the resource matches nothing in it | Escalate to tier 3 with a reason naming the resource and the workspace | No |
| `.unconstrained` | That kind is *not* configured on this workspace (empty list) | Nothing | No |
| `.opaque` | The resource is not knowable from the plan — a Shortcut's internals, a search-driven fetch's real URLs | Nothing | No — and it poisons the whole plan's roll-up |

### Why the empty-list case gets its own value

The four-value split has two independent motivations. `.unconstrained` exists because an unconfigured resource kind is neither permission nor prohibition — argued immediately below. `.opaque` exists because some resources are not knowable at gate time at all — argued two subsections down, under "The guarantee is static and pre-execution." Neither reduces to the other, and dropping either one reintroduces a specific failure.

Both two-valued readings fail, in opposite directions, and the failure is not theoretical — it is what every workspace on disk today would hit.

**"Empty means deny all."** No workspace on disk has file locations; the field does not exist yet. Default-on scope would escalate *every file action in every workspace* on the day this ships. Unusable.

**"Empty means allow all."** A workspace with apps but no file locations would blanket-bless every path on the machine. Row C would then relax tier-3 file work the user never scoped. **This is precisely the hazard SONNY-12's interaction flag names.**

`.unconstrained` is the load-bearing case: it means "this workspace has said nothing about this kind of thing," which is neither permission nor prohibition. It produces zero new prompts and zero new relaxation. Every existing workspace behaves exactly as it does today until its owner configures something.

An adversarial pass over the four founder decisions confirmed the model is load-bearing rather than fussy: `CreateWorkspaceCapabilityAdapter` requires **at least one** of apps or URLs — `guard !apps.isEmpty || !urls.isEmpty` throws only when *both* are empty (`:81-85`) — so **apps-only, URLs-only, and both-populated workspaces are all normal, already-valid persisted states today.** Under a two-valued reading, every apps-only workspace would classify every web URL as out of scope by construction, and every URLs-only workspace would do the same to every app. Under this model both are simply `.unconstrained` on the kind they never declared.

### Derived clarification

**Scope is default-on per workspace, not per task.** A one-off command that names no workspace and was not started from a card is `.unscoped` — no scope, no escalation, no relaxation. That is not a loophole in "on by default for all workspaces"; a task that is not in a workspace has no workspace scope to be inside.

### The guarantee is static and pre-execution, and says so

Some resources are not knowable from the plan at assessment time. Three real cases, all verified:

- **Shortcuts are black boxes.** Sonny shells to `/usr/bin/shortcuts run <name>` and has no visibility into what the Shortcut touches (`ShortcutsBridgeService.swift:169-204`).
- **Search-driven web research resolves its real URLs at execution time** via `webSearchProvider.search(query:limit:)`; no plan field carries them (`WebResearchMarkdownCapabilityAdapter.swift:322-343`).
- Any future capability that discovers targets at runtime will have the same shape.

These get `.opaque`: they never escalate on scope grounds (there is nothing to compare), and they are **never eligible for relaxation.** The plan-level roll-up is `.inScope` only if every resource was statically knowable, at least one matched, none is out of scope, and no step is opaque.

That composition is what makes it safe rather than a loophole: *a plan containing a Shortcut can never be relaxed*, because Sonny never saw what it touches. The alternative — silently treating an unseeable resource as in-scope — is how a scope feature grants exactly the permissions it cannot verify.

---

## 3. Timing: "escalates and prompts" fits the existing gate exactly

Worth confirming before anyone designs around it, because the wrong reading is expensive.

`AgentRunner.execute` gates **once, entirely up front**: `assessRisk` runs and the requirement is checked *before* `executor.execute(plan:)` is ever invoked (`AgentRunner.swift:111-129`). `executeChain` then runs every segment with no re-gating between them, and `.claude/rules/macagentcore-conventions.md` forbids adding one. The only existing "resume after approval" path re-invokes `runner.execute` on the same prepared plan — a full restart from the top, which is harmless precisely because nothing had run yet when the gate fired.

So the founder's *"this isn't part of X workspace — allow anyway?"* lands as a **pre-execution, whole-plan prompt**, identical in shape and timing to every risk escalation that exists today. Nothing pauses mid-plan, nothing resumes from a failed step, and **no pause/resume/checkpoint infrastructure is needed.** That is the single largest thing this planning phase de-risked: the founder decision is implementable inside the architecture as it stands.

It is also the reason the `.opaque` verdict is necessary rather than optional. A resource discovered only at execution time has no gate left to escalate at — the one gate already closed. Marking it unseeable is the honest answer; the dishonest one is calling it in-scope.

---

## 4. Resolving the recorded interaction flag

The flag, verbatim from SONNY-12's comment (its closing "(see SONNY-13)" pointer retained):

> default-on scoping combined with branch C's decided in-scope tier-3 downgrade (see SONNY-13) means users who never configured scope get relaxed tier-3 gating implicitly. Decide whether tier-3 relaxation requires explicit per-workspace opt-in even though scoping itself defaults on.

**Decided (user, 2026-08-04): no separate opt-in toggle. Three structural gates, each independently sufficient.**

### Gate 1 — Relaxation is earned per resource kind, not granted per workspace

Listing `~/Documents/ClientAlpha` on the workspace *is* the explicit act. A user who never configured scope is `.unconstrained` on every kind, and `.unconstrained` never qualifies for relaxation. The flag's scenario — "users who never configured scope get relaxed gating implicitly" — is structurally impossible, not merely discouraged.

A separate per-workspace toggle would add a second consent surface for the same consent the user already gave by naming the resource. Two switches for one decision is how a security control gets left in the wrong position.

### Gate 2 — Relaxation is a *requirement* override, never a tier change

Row C must map `(tier, verdict) -> RiskApprovalRequirement` directly. It must never lower `effectiveTier`. Four things depend on that field staying honest:

| Depends on `effectiveTier` | What breaks if scope lowers it |
|---|---|
| Unattended gate — `approvedTier >= effectiveTier` against a fixed `.approved(.tier2)` (`AgentRunner.swift:115-116`, `AgentViewModel.swift:1611`) | In-scope tier-3 work would execute on a schedule with nobody present. A "lightweight confirmation" requires a human; an unattended run has none. |
| Stale-approval re-check — `execute` re-assesses fresh every call (`AgentRunner.swift:110-119`) | The guard would compare against a softened tier and stop catching genuine escalation between approval and execution. |
| `risk.assessed` / `risk.escalated` trace (`AgentRunner.swift:158-171`) | The audit trail would record a tier the engine did not actually assess. |
| `UnattendedTrustAdvisory`, which reads `effectiveTier` only (`UnattendedTrustAdvisory.swift:28-45`) | The opt-in warning would stop firing for routines that genuinely need it. |

**And the composition trap.** Row C decided two things: in-scope tier 2 auto-runs, and in-scope tier 3 drops to lightweight confirmation. If the tier-3 rule were implemented as a tier change (3 -> 2), the tier-2 rule would fire next on the result and in-scope tier-3 actions would **silently auto-run**. One function of `(tier, verdict)`, never two chained rules. This is a hard constraint row B hands to row C, and it is the single most likely way this feature ships as a security regression.

Precedent worth naming honestly: `InvokeShortcutCapabilityAdapter` *does* lower `effectiveTier` (tier 2 -> tier 1 on clean observed history, `InvokeShortcutCapabilityAdapter.swift:68-72`). That trust signal is earned by observed successful runs. "The user typed this folder into a list once" is a weaker signal and should not buy the same structural power.

### Gate 3 — Scope answers "right place," never "right severity"

A file inside your own workspace folder is still destroyed forever if deleted. Which tier-3 *causes* stay at explicit approval regardless of verdict is row C's call, not row B's — but row B records the finding that makes that call answerable: **no capability in v1 has a default tier of 3.** Every tier 3 that exists today is reached by escalation, and all six escalation sites say some form of "X already exists and would be replaced" (`LargestFilesZip`, `SaveRoutine`, `SnippetSave`, `WebResearchMarkdown`, `CreateLocalDraft`, `CreateWorkspace`). So row C's tier-3 clause is *entirely* about escalated tier 3 today. The spec's real tier-3 capabilities — send, upload, delete, submit, purchase, share (§11.1) — do not exist yet, and the non-relaxable floor is written for them.

### What row B ships toward this

Row B computes the verdict and puts it on the assessment as `CapabilityRiskAssessment.scopeVerdict`, and **uses it only to escalate — never to relax anything.** No relaxation ships in row B. Row C inherits a typed input instead of re-deriving scope, plus the two constraints above.

---

## 5. Architecture: one centralized evaluator, not twenty-four adapter edits

```
command ──▶ resolveDefaultOutputs ──┬──▶ adapter.assessRisk × N ──┬──▶ CapabilityRiskAssessment ──▶ AgentRunner gates
                                    │                             │                                  (unchanged)
                                    └──▶ WorkspaceScopeEvaluator ─┘
                                         (new — one walk over the resolved plan)
```

The scope check is a **second walk over the same resolved plan**, running alongside the adapters inside `AgentActionExecutor.assessRisk`, and its escalations join theirs before the assessment is built. Four reasons that is the right seam and not a per-adapter concern:

- **Complete by construction.** A new capability cannot forget to check scope, because scope is not the capability's job. Twenty-four `assessRisk` overrides is twenty-four chances to miss one.
- **It runs after `resolveDefaultOutputs`,** so output paths are already resolved and Finder-selection folders are already pinned by `FinderSelectionResolver.pinningSelectedDirectoryInput`. The evaluator sees the same paths the user is about to approve.
- **It is read-only,** matching the existing rule that `AgentRunner` is the only thing that gates and `AgentActionExecutor.execute` never re-gates.
- **Instant-dispatch commands are covered for free.** `InstantCommandResolver`'s quick-dispatch path bypasses the planner but still produces a plain `AgentPlan` that flows through the identical `prepare -> assessRisk -> execute` gate (`AgentRunner.swift:72-87`).

### New types in MacAgentCore

| Type | Responsibility |
|---|---|
| `ScopeVerdict` | `.inScope` / `.outOfScope` / `.unconstrained` / `.opaque` |
| `ScopedResource` | `.app(String)` / `.webDomain(String)` / `.fileLocation(String)` |
| `WorkspaceScope` | Built from a `StoredWorkspace`: canonicalized bundle IDs, derived hosts, resolved file roots. Owns `verdict(for:)`. |
| `TaskWorkspaceScope` | `{ case unscoped, scoped(WorkspaceScope) }` — **non-optional, never defaulted**. Every call site writes `.unscoped` on purpose. |
| `PlanScopedResources` | `AgentStep -> [ScopedResource]` via an **exhaustive switch over `AgentOperation` with no `default:`**. |
| `WorkspaceScopeEvaluator` | Walks the resolved plan, returns findings. Knows nothing about tiers. |

**Why the switch has no default clause.** A `default: return []` is a silent hole for every capability added after this row — the exact failure `.claude/rules/macagentcore-conventions.md` already documents for the three nested-plan closures, which it requires as "all three, not a subset, or nested risk silently doesn't get assessed." With no default, adding an `AgentOperation` case fails the build until someone classifies its resources. That compile error *is* the completeness guarantee.

### Threading the scope through

`TaskOrigin` lives only in `AgentViewModel` and has zero occurrences anywhere in `MacAgentCore`; `OpenAIPlanner` has no knowledge of `WorkspaceStore` (its request body is built only from command text, prior-task context, and static tool descriptions). So the workspace binding is new plumbing, and scope enforcement is structurally forced to be a post-plan check — it can never be a planner-side constraint.

The scope flows `AgentViewModel -> AgentRunner -> AgentActionExecutor.assessRisk(plan:scope:)`, and `capabilityContext(scope:)` forwards the same value into `assessNestedPlan`. That last part is not optional: without it, `run_routine` is a scope-laundering hole where a routine's steps escape the boundary its caller is bound by.

The app runs one task at a time (`isRunning` is a single `Bool`, `activeTaskOrigin` a single saved/restored `var`), so a single-slot binding is structurally sufficient. No per-task-ID keying needed.

---

## 6. Binding: which workspace a task belongs to, and for how long

**Named in the command.** Reuse `WorkspaceTaskTagging.resolvedWorkspaceName` **unchanged**. It already matches `in [the|my] workspace X` against real saved names with the same case/diacritic folding the stores use, plus a documented leftmost-then-longest tie-break and deliberate non-`\b` boundary checks. Writing a second matcher would guarantee two behaviours for one concept.

**Started from its card.** Does not exist today. `openWorkspaceWidget` only synthesizes the literal `"Open my X workspace"` and auto-executes (`AgentViewModel.swift:959-962`), so the card can start exactly one kind of task — and that is not even a distinct signal from the free-text path, since the synthesized string funnels through the same `start()`/`InstantCommandResolver`/planner pipeline as anything typed by hand.

### The rejection that still stands

The persistent active-workspace concept was **explicitly considered and rejected** (changelog, task-to-workspace-association entry): it silently mis-tags unrelated one-off tasks, and it leaks state across surfaces — a voice command in the widget inheriting whatever workspace was last active in Command Center. The wireframes' evidence for it (the Home screen's "Personal" scope pill, the Workspaces screen's green "Active" badge and Open-vs-Switch branching) remains deliberately unbuilt, and `CommandCenterView.swift:381-384` records that in code.

The binding this row adds is **per-task**: set at dispatch, cleared the moment the task reaches a terminal state, never inherited by the next command, never rendered as a global mode. That distinction is the whole reason the earlier rejection is not being reversed, and it is the thing a reviewer should check hardest.

### Scheduled runs pass `.unscoped`

A stored routine cannot contain `create_workspace` or `open_workspace` — `SaveRoutineCapabilityAdapter.validateRoutineSteps` rejects both — so a scheduled routine has no workspace binding available today. Worth stating rather than leaving implicit, because it removes the one genuinely dangerous interaction: an out-of-scope escalation to tier 3 inside a scheduled routine would otherwise skip that run, and (per SONNY-10) usually every future run too.

---

## 7. Matching: what "the same app / domain / folder" means

| Kind | Stored as | Matched by | Must not |
|---|---|---|---|
| App | Raw user string — `"Chrome"` and `"Google Chrome"` both persist as typed (`CreateWorkspaceCapabilityAdapter.swift:87-94`) | Both sides resolved through `MacAppCatalog.resolve` to `bundleIdentifier`, then equality | Compare raw strings — the same app would match in one workspace and not another |
| Web domain | Full URLs in `urls`, not domains | `SafeURL.validateWebURL(...).host`, lowercased, leading `www.` stripped; then `host == d \|\| host.hasSuffix("." + d)` | Substring matching — `notgithub.com` contains `github.com` |
| File location | New `fileLocations: [String]?` | `PathWhitelist`'s own containment: expand, standardize, resolve symlinks both sides, then `== root \|\| hasPrefix(root + "/")` | A second path-comparison routine — divergence on `..` or symlinks is a security bug, not a style one |

**Inert configuration.** A workspace file location outside `~/Desktop`/`~/Documents` can never match, because `PathWhitelist` rejects the path before scope is ever consulted. **Workspace scope narrows the global whitelist; it never widens it.** Validate at save time and say so, or the user configures a boundary that quietly does nothing.

### Per-operation resource classification

Classification is **per operation, never per field** — and it must include resources the operation touches *implicitly*, with no plan field naming them at all. Three findings from the adversarial pass make this non-negotiable:

- `open_app_search_url` carries `appName`, but that field holds a search-target name like "GitHub" or "YouTube"; the real resource is the host baked into the template's `buildURL` closure.
- `convert_docx_to_pdf` AppleScript-controls **Microsoft Word** directly (`DocumentConverter.swift:71-100`, hardcoded `/Applications/Microsoft Word.app`) with *no* `MacAppCatalog` resolution and *no* `appName` field. A field-driven classifier misses it entirely.
- `play_media`'s `NativeMediaOpener` opens `music://` / `spotify:` URIs through its own private prefix check, bypassing both `MacAppCatalog` and `SafeURL` (`MediaPlaybackService.swift:985-1035`) — a third open-checkpoint neither existing allowlist knows about.

| Operation | Resources | Read from |
|---|---|---|
| `open_app` | app | `appName` -> `MacAppCatalog` |
| `switch_running_app` | app | `appName ?? searchQuery` -> running apps, not the 12-app catalog |
| `open_url` | domain | `targetURL` |
| `open_app_search_url` | domain | the template's hardcoded host — *not* `appName` |
| `open_hacker_news` / `fetch_hn_headlines` | domain | fixed `news.ycombinator.com` |
| `web_to_markdown` | domain, file, **opaque** | `targetURL`, `sourceURLs`, resolved `outputPath`. **Search-query form is `.opaque`** — its real URLs come back from `webSearchProvider` only at execution time. |
| `write_markdown` | file, domain | `outputPath`; **plus** the HN preset it can route into — see SONNY-32 |
| `play_media` | app, domain | `mediaProvider` -> Spotify / Music, *and* the provider host `NativeMediaOpener` opens directly |
| `scan_select_largest_files` / `create_zip` | file | `inputPath` (Finder-pinned), `outputPath` |
| `scan_docx` | file | `inputPath`, `outputPath` |
| `convert_docx_to_pdf` | file, **app (implicit)** | `inputPath`, `outputPath`, **plus Microsoft Word** — AppleScript-controlled with no field naming it |
| `create_local_draft` | file | resolved `outputPath` |
| `reveal_in_finder` / `open_generated_artifact` | file, app (implicit) | `outputPath ?? inputPath`, plus Finder / the resolving app |
| `get_finder_selection` | file, app (implicit) | pinned into `inputPath` by `resolveDefaultOutputs` before assessment runs; AppleScript-controls Finder |
| `open_workspace` | app, domain | the *stored* workspace record, not the step's fields. In-scope by construction when it names the bound workspace. |
| `create_workspace` | none | `workspaceApps`/`workspaceURLs` are contents being *declared*, not resources being touched |
| `run_routine` | nested | the stored routine's own steps, via `assessNestedPlan` carrying the same scope |
| `save_routine` | none | see the decision below |
| `invoke_shortcut` | **opaque** | Sonny shells to `shortcuts run <name>` and cannot see inside. Never escalates on scope grounds, **never eligible for relaxation**, and poisons its plan's roll-up. |
| `calculate` / `clipboard` / snippets / recent artifacts / permissions / `clarify` | none | local stores and pure computation only |
| `unsupported` | none | Never reaches a resource: `AgentActionExecutor`'s `validateSupported` throws before execution. Classify it as none anyway — the switch has no `default:`, so it must be written explicitly, and "it can't run" is the reason, not an oversight. |

That table covers all 30 `AgentOperation` cases (`AgentPlan.swift:94-124`, `CaseIterable`). If it ever covers fewer, the classifier will not compile — which is the point.

**Open question inherited rather than invented.** `save_routine` folds its nested plan's escalations onto the save itself, even though saving writes only the routine file (SONNY-10's largest recorded finding; SONNY-33 reframes the copy). Scope asks the identical question: does a routine that *references* an out-of-workspace path put the *save* out of scope, or only the run? **Decided: only the run.** Saving a routine touches one file inside Sonny's own store. Row B classifies `save_routine`'s own resources as none, and lets the routine's steps be scoped when it actually runs. This keeps row B consistent with SONNY-33's decided direction instead of quietly contradicting it.

---

## 8. Sequencing: this row cannot start before SONNY-29 merges

`SONNY-29` is rewriting `AgentActionExecutor.assessRisk` into a segment-walking shape, and `SONNY-29 -> SONNY-31 -> SONNY-24` is a declared serial sequence over that same executor surface ("nothing in this sequence runs in parallel with anything else in that area"). Ticket B2 edits the same function.

This is not only a merge-conflict concern. `assessRisk` today hands each deduplicated adapter the *entire unsegmented plan once* (`AgentActionExecutor.swift:269-285`), so a plan with two steps of the same operation only ever has the first assessed. A scope check built on that shape would scope-check the first URL in a two-URL plan and silently ignore the second. **Row B inherits the blind spot unless it lands after SONNY-29.**

B1 (pure model and evaluator) touches none of those files and can start immediately. B2 onward waits. Tickets B1–B7 are otherwise **serial on one branch** — B5 adds an `AgentOperation` case, which by design breaks B1's exhaustive switch until classified, so no pair here is disjoint enough to parallelize.

---

## 9. Pitfalls found while planning

| # | Pitfall | Evidence |
|---|---|---|
| 1 | **`WorkspaceStore.save` fully replaces the record**, unlike `RoutineStore.save` which merge-preserves `schedule`/`recentRunDates`. Re-creating a workspace by natural language would silently delete its boundary — and that path escalates to tier 3 *for replacing the workspace*, so the user consents to replacing contents, not to dropping a security boundary. Needs the same merge-preserve treatment. | `AutomationStores.swift:296-300` vs `:161-172` |
| 2 | **New persisted fields must be `Optional`.** Synthesized `Decodable` calls `decode(_:forKey:)` for a non-Optional property even with a Swift-side default, and throws `keyNotFound` on every existing `workspaces.json`. | documented twice already: `AutomationStores.swift:11-14`, `:77-80` |
| 3 | **`AgentPlan.requiresConfirmation` gates nothing** — 22 construction sites in `Sources/` (16 of them in `InstantCommandResolver` alone), and nothing anywhere branches on the value. It *is* read once outside its own initializer: `segmentPlan` copies it into every chain segment. That makes the trap worse, not better — a scope flag wired through it would visibly propagate into segments while still gating nothing, so it would look wired up. Do not use it. | `AgentPlan.swift:10` (init), `AgentActionExecutor.swift:990-996` (`segmentPlan`) |
| 4 | **Power Mode is spec-only** — zero implementation anywhere in `Sources/`. §13.3's per-app "Allowed domains if browser" is not code this row can extend or collide with. | no match for `PowerMode` in `Sources/` or `Tests/` |
| 5 | **Case sensitivity.** `PathWhitelist`'s containment is a case-sensitive prefix compare on a case-insensitive filesystem. Pre-existing, inherited rather than introduced — but scope matching multiplies its exposure, so it needs a decision and a test rather than silence. | `PathWhitelist.swift:154-158` |
| 6 | **`CapabilityPermissionEnforcement` has exactly one case**, `.descriptiveOnly`. There is no existing "enforcement level" concept to extend — closing off a line of design an implementer might otherwise chase. | `CapabilityAdapter.swift:19-21` |
| 7 | **Three app/URL touches bypass every existing allowlist.** `NativeMediaOpener` opens provider URIs through its own prefix check; `MicrosoftWordDocumentConverter` AppleScript-controls Word from a hardcoded path; `AppleScriptFinderContextReader` controls Finder. None resolves through `MacAppCatalog` or `SafeURL`. A field-driven classifier would report these plans as touching nothing. | `MediaPlaybackService.swift:985-1035`, `DocumentConverter.swift:31-100`, `FinderContextService.swift:38-77` |
| 8 | **Apps-only and URLs-only workspaces are valid, normal states** — creation requires *at least one* of apps or URLs (`guard !apps.isEmpty \|\| !urls.isEmpty` throws only when both are empty), so all three combinations are reachable. Any design that treats an empty list as "deny everything of this kind" breaks the two single-dimension cases on day one. | `CreateWorkspaceCapabilityAdapter.swift:81-85` |

---

## 10. Spec conflict, and how it resolves

§10.1 puts an "App/folder/domain scope" field on every capability declaration, and §10.4 lists "Scope validation" among seven validation layers with: *"If any layer rejects, the action must not execute."* That is a **hard block**. The founder decision is escalate-and-prompt, never hard-block.

**Resolution: these are two different layers, and both are correct.** §10.1/§10.4's scope is the *capability's own* declared operating bounds — an app-opener can only open allowlisted apps, a file capability can only touch the whitelist — and that stays a hard block, because it describes what the capability is physically able to do. Workspace scope is a new, *user-declared* layer sitting above it that escalates. A workspace scope can never widen a capability's own bounds or `PathWhitelist`; it only narrows, and it narrows by asking rather than refusing.

Sections needing amendment, all in ticket B7: **§6.9** (a workspace's contents are also its restriction scope; default-on; escalate-not-block — today the only restriction sentence there is enterprise-admin-scoped), **§10.4** (distinguish the two layers explicitly), **§11.2** (scope verdict becomes an input to the approval rules, with row C's two constraints recorded), **§11.3** (approval copy gains the out-of-scope reason), **§9.2** (agent state gains the workspace binding — it has no workspace field today), **§9.3** (scope escalation is logged, following §11.1A's own "not a silent internal decision" precedent).

---

## 11. Configuration: without an edit path, the file third of the decision is inert

Spec §6.9 requires "Edit workspace." It does not exist. The only UI mutations on a workspace are *mark as team* and *delete*; apps and URLs can only be set by natural-language creation, and a code comment records that a detail view was previously rejected as "inventing a surface to solve a placement problem" for a delete button (`CommandCenterView.swift:2093-2097`).

So: if row B ships no edit path, `fileLocations` can never be set, every file resource stays `.unconstrained` forever, and one of the three founder-specified dimensions does nothing. An edit path is not polish here — it is what makes the feature exist.

**Decided (user, 2026-08-04): both, sequenced.** An `edit_workspace` capability (B5) is the functional prerequisite and matches how workspaces are already created; a workspace detail sheet (B6) is what makes the boundary visible. A boundary the user cannot see is a boundary they cannot trust — and "show workspace contents" is a §6.9 requirement in its own right.

**Stated wireframe exception.** `13-MainAppWorkspaces.svg` is a card grid only; no wireframe exists for a workspace detail surface. B6 is net-new UI in **System A** — flat, opaque, Inter, zero shadows. Liquid glass was tried for workspace cards and explicitly reverted as too distracting, so B6 does not inherit the routine-detail view's System-B-inside-System-A treatment. Recorded as a reasoned exception, per CLAUDE.md's rule, not silent drift.

### Scope reuses the workspace's existing lists

`apps` and `urls` serve as both "what opens when I open this workspace" and "what is in scope," with `fileLocations` added alongside. The alternative — separate `scopeApps`/`scopeDomains` lists — means users maintain two lists that are 95% identical, which is a DRY violation at the product level and a guaranteed source of "why did it prompt, it's right there in my workspace." If an in-scope-but-not-launched app is ever genuinely needed, that is an additive field later, not a reason to split the model now.

**Non-goal:** file locations do not auto-open when a workspace opens. Changing `open_workspace`'s behavior is not part of a restriction-scope ask.

### Editing escalates on removal, not on widening

`edit_workspace` is tier 2 (§11.1 lists "Change routine/workspace" as tier 2, and `CreateWorkspace` already is), escalating to tier 3 when an edit **removes** entries. The nearest existing precedent is the replacement-escalation family, though the copy is less uniform than it looks: of the six existing escalation sites, only `CreateWorkspace`, `SaveRoutine` and `SnippetSave` say "already exists and would be replaced"; `CreateLocalDraft`, `LargestFilesZip` and `WebResearchMarkdown` say only "… output already exists at `<path>`". So there is no single phrase to copy — the requirement is that the reason names what is actually lost, not that it matches a template.

**Rejected alternative, recorded:** escalating on *widening* instead. Widening does weaken the boundary, but the user typed the command asking for it, and putting explicit approval in front of normal setup taxes exactly the action the feature depends on.

**Forward flag for branch C, not a closed decision.** That rejection rests on a *row-B* cost argument, and row B is the phase where being in scope buys nothing. Row C changes the trade: Gate 1 says relaxation is earned by listing a resource, so once relaxation is live, an ungated tier-2 edit that adds `~/Documents` to a workspace converts a large share of the filesystem into relaxation-eligible territory in one un-escalated step — the same hazard class the interaction flag was raised about, arriving through the edit path instead of the default path. **Branch C must revisit whether adding to scope deserves more than a lightweight confirmation once relaxation exists.** Gate 1 does not already cover this: it answers *which verdicts qualify* for relaxation, not whether the act of *creating* a qualifying verdict should itself be gated.

### Removing the last entry of a kind is a different event from removing one of several

This is the sharpest edge in the whole model, and the generic removal rule above does not catch it.

Removing one of several entries leaves the kind configured: non-matching resources still resolve `.outOfScope` and still escalate. **Removing the last entry empties the list, and an empty list is `.unconstrained` — so that entire dimension silently stops escalating on anything.** The user consents to losing one folder and actually loses file-scope enforcement for the workspace.

A test that removes one entry from a two-entry list satisfies a generic "removal escalates" criterion completely while never touching this case. So the flip needs its own requirement, its own acceptance criterion, and its own reason copy: **when a removal empties a kind, the prompt must say the dimension is no longer restricted, not name the entry being removed.** "Removed ~/Documents/ClientAlpha" and "this workspace will no longer restrict file locations at all" are different consents. SONNY-40 carries both halves.

---

## 12. The ticket set

Seven tickets, serial, all on `feature/workspace-restriction-scope`, module **B — workspace restriction scope**. The tickets themselves carry the binding contracts (Branch line, expected touched areas, never-touch list, non-goals, acceptance criteria, required verification, manual-test items). Summarized here only so this document is a complete picture:

| Ticket | Outcome | Depends on |
|---|---|---|
| **SONNY-36** (B1) | Workspace scope model and evaluator (pure core) — `fileLocations`, merge-preserving save, the four-valued verdict, the exhaustive-switch classifier, the evaluator. No wiring, no UI, no behavior change. | none — can start now |
| **SONNY-37** (B2) | Wire scope into risk assessment — `assessRisk(plan:scope:)`, nested forwarding, out-of-scope escalations, `scopeVerdict` on the assessment. | SONNY-36 **and SONNY-29 merged** |
| **SONNY-38** (B3) | Bind the running task to a workspace — resolution before approval, per-task lifetime, same scope at approval and execution. | SONNY-37 |
| **SONNY-39** (B4) | "New task in this workspace" from the workspace card — the "started from its card" half, with a visible, clearable binding. | SONNY-38 |
| **SONNY-40** (B5) | `edit_workspace` capability — natural-language configuration of apps, URLs, and file locations. | SONNY-39 |
| **SONNY-41** (B6) | Workspace detail sheet — see and edit the boundary, System A. | SONNY-40 |
| **SONNY-42** (B7) | Spec amendment — §6.9, §10.4, §11.2, §11.3, §9.2, §9.3. | SONNY-41 |

References to "B1"–"B7" elsewhere in this document map to the SONNY numbers above.

---

## 13. How this plan was produced

Nine parallel research agents over the codebase, spec, changelog, and Plane tickets, followed by two adversarial passes: a completeness critic that spot-checked 13 cited claims by opening the files itself, and a feasibility probe that hunted for the specific mechanisms making each founder decision hard to implement as stated. Findings that changed the plan rather than confirming it: the four-valued verdict (the feasibility probe's apps-only/URLs-only finding), the `.opaque` class and the implicit-app-touch bypasses (Word, media URIs, Finder), the confirmation that the single up-front gate needs no new pause/resume machinery, and the SONNY-29 sequencing dependency.
