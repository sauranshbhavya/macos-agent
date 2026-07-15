# Sonny V1 Implementation Changelog

Canonical progress/handoff record for Sonny v1 implementation. This file is the source of truth between chats — future implementation chats should read this before trusting memory or assumptions about current state. See `docs/sonny-major-release-spec.md` §21.0A (build sequence) and §24 (future-chat operating procedure, cross-agent review protocol) for the workflow this file supports.

Branch naming: plain `feature/<name>` (no per-agent prefix). Agent identity is tracked per-entry below, not in the branch name.

## Feature Branch Checkpoint Workflow

Each roadmap row below is one feature branch, but a feature branch should be implemented as a sequence of small, reviewable checkpoints on that same branch. A checkpoint should map to one migrated capability, subfeature, or similarly coherent leg of the branch.

Checkpoint workflow:

1. Plan the full branch scope before editing.
2. Implement one checkpoint on the feature branch.
3. Run the relevant tests for that checkpoint.
4. Report the diff and test results to the user.
5. Wait for the user's manual review/testing and explicit approval before committing or pushing that checkpoint.
6. Continue on the same feature branch for the next checkpoint.
7. When all checkpoints for the branch are complete, run the full required test pass, fill this changelog entry, append the next-chat kickoff prompt, and send the branch for cross-agent review before merge to `main`.

Do not batch an entire feature branch into one large unreviewed implementation. Do not create extra branches for every checkpoint unless this roadmap is explicitly updated. Never commit, push, merge, or open/modify a PR without explicit user approval.

## Locked Branch Roadmap (2026-07-04)

Dependency-ordered. Do not start a branch before the ones above it are merged, unless a later chat explicitly re-justifies reordering here.

| # | Branch | Spec sections | Status |
|---|---|---|---|
| 1 | `feature/capability-adapter-foundation` | §4A.0 | Complete |
| 2 | `feature/local-risk-approval-engine` | §10, §11, §11.1A | Complete |
| 3 | `feature/web-research-app-foundation` | §4A.2, §4A.3 | Complete |
| 4 | `feature/provider-media-playback` | §4A.4 | Complete |
| 5 | `feature/instant-utilities-shortcuts` | §4A.6, §4A.7 | Complete |
| 6 | `feature/followup-usage-transparency` | §4A.8, §4A.9 | Complete |
| 7 | `feature/local-storage-privacy-foundation` | §15.4 | Complete |
| 8 | `feature/product-shell-shared-state` | §4A.1 (shell only), §6.2, §6.3, §17.3 | Superseded — see branch 9. Branch 8 itself is frozen, no further commits. |
| 9 | `feature/command-center-depth-and-data-model` | Founder-decisions UI-fidelity audit, task-to-workspace association; recommended (not mandatory) home for the first-run tier-2 legibility moment | Not started |
| 10 | `feature/routine-scheduling` | Real scheduler/execution-trigger (defined run time, enabled/disabled state) per `docs/sonny-founder-design-decisions.md` | Not started |
| 11 | `feature/floating-command-widget` | §17.3 (cockpit surface, visual form only); user wireframes (2026-07-08), not spec-mandated | Not started |
| 12 | `feature/hosted-agent-runtime-backend` | §6.1, §8, §9, §16, §21.2, §21.3, §6.19 | Not started |
| 13 | `feature/billing-command-center-memory` | §6.14, §16.3, §16.4, §6.3A (full), §6.10; plus a locked free-tier allowance mechanism, see note below | Not started |
| 14 | `feature/screen-intelligence` | §6.4, §12, §20.3, §21.5, §6.13, §14.4A, §14.5 | Not started |
| 15 | `feature/privacy-security-hardening` | remaining §6.12, §14, §15, §20.5, §20.6, §21.7 | Not started |
| 16 | `feature/workflow-library-polish` | §18.1, §18.2, §18.5, §18.6; web-search provider resolved (Tavily), see note below | Not started |
| 17 | `feature/mcp-client-integration` | New — not in original spec; see note below | Not started |
| 18 | `feature/power-mode` | §6.5, §13, §20.4, §21.6, §20.9 | Not started |
| 19 | `feature/enterprise-foundations` | §6.15, §15.6, §21.9 | Not started |
| 20 | `feature/release-ops-evals-hardening` | §19, remaining §20, §21.10, §22, §23, §24, §26 | Not started |

## Open Decisions Carried Forward From `feature/v1-strategy-replan`

Not resolved by the replan below — a future session must not assume these are settled just because the roadmap accounts for them structurally:

- **Positioning copy.** Not actually a pending decision for this conversation — the public tagline stays as-is, no change proposed. The in-product first-run copy (the actual words at Q1's approval moment) can only be written once that UI surface is designed, which is implementation #3/Prompt B's job as part of designing the screen, not an abstract writing exercise ahead of it. Nothing blocked here; resolves naturally when that design work happens. **Resolved 2026-07-15:** that design work happened during the UI/UX wireframe-fidelity audit (implementation #3/Prompt B) — see branch 9's note below for the first-run-moment *direction* (polish the approval panel's own first-time framing, plus a light, non-forced curated example; explicitly not a forced onboarding walkthrough). The literal copy text itself is still unwritten — that's implementation work for branch 9's checkpoint, not something this audit produced.

Resolved 2026-07-15, kept here only as a pointer so a future session doesn't go looking for them as open: web-search-provider choice (Tavily — see the branch 16 note below) and the free-tier/pricing structure (see the branch 13 note below). Neither should be reopened without a real reason.

Notes on sequencing decisions behind this table:

- Branches 1-2 are split (adapter contract alone, then risk/approval on top of it) so each proves one thing in isolation: "existing tools run through adapters without regression," then "risk/approval works on top of adapters."
- Branches 3-6 split the §4A.2-§4A.9 generalization pass into four smaller reviewable branches rather than one large one, per user decision on 2026-07-04.
- Branch 7 (local storage/Keychain hardening) is pulled out as its own branch, done before backend/auth work per §21.0A step 4.
- Branch 8 is scoped to the shared-state shell only (§4A.1) — the full Command Center UI (account/subscription/stats screens) is deferred to branch 13, once billing exists to gate it. A same-day post-completion review found branch 8's built pages fall short of the wireframes in content depth and information architecture (not token-matching, which is accurate), and a founder/designer conversation surfaced two features bigger than UI polish. Resolved in `feature/v1-strategy-replan`'s Phase 4 (2026-07-15): branch 8 is superseded, not reopened — see branches 9 and 10.
- **Branch 9 (`feature/command-center-depth-and-data-model`)** was inserted 2026-07-15 during `feature/v1-strategy-replan`'s Phase 4, replacing branch 8 as the "not started" continuation of that work. Scope: audit branch 8's built pages against `docs/sonny-founder-design-decisions.md` for the confirmed content-depth/information-architecture gaps (Insights needs an asymmetric bento grid it doesn't have; Workspaces needs an audit against the confirmed card fields — name, solo/team, task count, apps as an overlapping icon stack), plus task-to-workspace association.

  **Resolved 2026-07-15, during the UI/UX wireframe-fidelity design audit (implementation #3/Prompt B) that also produced this branch's proposed checkpoint sequence below:**

  - **Task-to-workspace association: narrow tagging, not a persistent active-workspace concept.** Only tasks explicitly dispatched via quick-workspace-dispatch, or an explicit "in workspace X" phrase, get tagged with the workspace they ran in — the broader option (a genuine persistent "active workspace" context with real session state and UI, giving every task row a tag) was considered and rejected. Reasoning: a persistent global active-workspace risks silently mis-tagging unrelated one-off tasks — a real correctness problem for a stats feature, where never being silently wrong matters more than full wireframe fidelity — and it introduces shared cross-surface state that could produce surprising behavior once branch 11's floating widget exists (a voice command from the widget silently inheriting whatever workspace was last active in the Command Center). Schema the new `CompletedTaskRecord` workspace field so this doesn't foreclose a persistent-active-workspace option later — don't hard-code narrow-tagging-only into the data model, just don't build the active-workspace UI/session-state now. Direct wireframe evidence for the *rejected* broader option, preserved for context since it's genuinely strong: the Home/Tasks screen (`9-MainAppHomeScreen.svg`) shows a "Personal" scope indicator near the top; the Workspaces screen (`13-MainAppWorkspaces.svg`) shows a green "Active" badge on one card with "Open" vs. "Switch" button semantics on the others — real signal for a Linear-style persistent-workspace-context interaction model, but `docs/sonny-founder-design-decisions.md` only ever confirmed the card *fields* (solo/team, task count, icon stack) as real Sonny intent, never this mode-switching mechanic itself, and the correctness/cross-surface risk above outweighs chasing it.
  - **First-run tier-2+ approval moment: polish the approval panel's own first-time framing, plus a light, non-forced version of curating one good example in the empty-state/onboarding — explicitly not a forced onboarding walkthrough.** Verified directly against the current code (`Sources/MacAgent/ContentView.swift:907-932` `ApprovalPanel`, `RiskApprovalCopy` in `Sources/MacAgentCore/RiskApproval.swift`): the approval panel today has zero first-time distinction — it renders identically on a user's 1st and 100th approval, five plain structured lines with no first-time explainer. That gap matters more than which specific task triggers the moment, since most real early tasks already resolve to tier 2 by default under the existing risk model (zip largest files, save routine, create workspace are all tier 2 per branch 2's entry above), so the natural-usage probability of hitting the moment early is already reasonable without engineering the triggering task. A forced onboarding demo step (§17.2) was rejected: onboarding is already dense (what Sonny does, why hosted AI, data handling, permissions, Power Mode, how to stop Sonny, English-only), and a scripted forced walkthrough risks reading as a demo rather than an organic first task — the exact thing this decision was told to avoid.
  - **Data Sent To AI Inspector (§6.13/§14.5): explicitly pulled out of this branch's scope, not given a checkpoint.** Verified directly by grepping `Sources/` for screenshot/OCR/redaction/context-capture patterns and reading `AIUsageRecord` in `Sources/MacAgentCore/TaskUsage.swift` in full: no context-bundle capture exists anywhere in the codebase today. `AIUsageRecord` (`kind`, `model`, `tokenSource`, `tokenCounts`, `audioDurationSeconds`) is pure token/usage metering for the billing meter — it does not capture or persist context sources used, screenshots sent, OCR text sent, files/excerpts sent, or redactions applied, which is what §6.13 actually requires. An earlier pass through this same audit incorrectly assumed the context-bundle capture already existed in the agent loop; it does not — corrected here before it could get treated as given. This feature needs its own real scoping/costing pass, the same rigor the first-run-moment decision above got, not a checkpoint added because it superficially looked unblocked; most of what it would depend on (§6.4/§12 screen capture, OCR, redaction) is itself unbuilt branch-14 (`feature/screen-intelligence`) territory. Revisit sequencing once branch 14 exists to build against.
  - **Routine detail view (System-B-inside-System-A liquid-glass panel, per `docs/sonny-founder-design-decisions.md`'s Routines section) moved into this branch's scope, not branch 10's.** It has no dependency on branch 10's scheduling data model — it can show the routine's existing step list today and gain schedule fields once branch 10 lands later — and it's a pure wireframe-fidelity gap, squarely this branch's actual theme; branch 10 stays focused specifically on the scheduling architecture itself. See branch 11's note below, which now points here rather than claiming branch 11 builds this view.

  **Proposed checkpoint sequence for this branch** (design audit's proposal, not yet started — small reviewable checkpoints per the workflow at the top of this file): (1) Tasks status-grouped sections (Completed/Failed/Canceled, with counts, no schema change needed — `PriorTaskOutcomeStatus` already has the values); (2) Workspaces solo/team field + real overlapping app-icon stack (via existing `MacAppService` bundle→icon resolution); (3) Insights asymmetric bento-grid restructure + section headers (layout only); (4) Settings "Display full names" toggle + "My Account" sidebar group header; (5) task-to-workspace association data model per the narrow-tagging resolution above; (6) Insights "Breakdown by Workspace" panel + Workspaces' real task count (replacing the current mislabeled saved-item count) using checkpoint 5's data; (7) routine detail view; (8) first-run moment (approval-panel first-time copy + light curated-example surfacing) per the resolution above.
- **Branch 10 (`feature/routine-scheduling`)** was split out as its own branch rather than folded into branch 9, specifically because it surfaces a real, unresolved tension with Sonny's own existing safety principles — not something found via competitive research, but via cross-referencing Sonny's own docs against each other. A scheduled routine runs unattended, but tier 2+ actions elsewhere in the product require a human present to approve, and Power Mode explicitly forbids unattended sessions.

  **Resolved 2026-07-15, during the same UI/UX wireframe-fidelity design audit (implementation #3/Prompt B):** an explicit per-routine "unattended trust" opt-in, with silent-skip-and-notify as a hard backstop for tier-3+ steps only — tier-3+ never becomes unattended-eligible regardless of the opt-in, no matter what the toggle says. Rejected: tier-gating at save time (block scheduling unless every step is tier 0/1) — too weak to ship as a real feature, since the routine-defining examples people actually want (save routine, create a workspace, the zip-files example) are tier 2 by default per branch 2's entry above; and queue-for-approval-via-notification (pause and notify at the first tier-2+ step, resume on tap) — functionally reduces to "notify me it's ready, I'll finish it myself," undercutting the actual point of scheduling given how common tier-2 steps are.

  **A finding surfaced during the same audit, confirmed directly against the code and load-bearing for why the per-routine opt-in is the right shape rather than a blanket auto-run policy:** running a saved routine is *itself* tier 2 by default, independent of its steps' tiers. `RunRoutineCapabilityAdapter.defaultRiskTier` is `.tier2` (`Sources/MacAgentCore/RunRoutineCapabilityAdapter.swift:27`), and `assessRisk(plan:context:)` combines it with the nested plan's tier via `highestTier(metadata.defaultRiskTier, nested.defaultTier)` (line 44) — a floor, not a default that nested tier-0/1 steps can lower. So even a routine composed entirely of tier-0/1 steps still hits tier-2 gating today just from the act of running it. This means the real kickoff question was never only "what happens to tier-2+ *steps*" — it's whether a scheduled trigger gets an explicit, deliberately-designed exception to the outer routine-level tier-2 gate that a manual click keeps. That exception is exactly what the per-routine opt-in is: a routine owner explicitly consents, per-routine, to let that outer gate (and any tier-2 step gates) be bypassed unattended; tier-3+ is carved out as never-bypassable regardless of the toggle.

  **Implementation-level open item, not yet resolved, for whoever actually builds this:** the opt-in needs a new concept in `RiskApprovalPolicy`/`AgentRunner` (a per-routine override), not just UI — read both closely before committing to a specific mechanism, since this audit reasoned from this changelog's own description of the tier model, not a fresh implementation-level read of the current approval-gating code.

  **A related, smaller design question surfaced by the same audit, to resolve alongside the above:** the wireframe (`11-MainAppRoutines.svg`) has no manual "Run" button on any routine row at all — the implied interaction is toggle-to-enable, with the row itself opening the detail view (now branch 9's scope, see above) on click. The current build's "Run" button is an original addition, not wireframe-sourced, and now sits in the visual slot the wireframe reserves for schedule-time + toggle. Not wrong, but should be a deliberate placement call (keep as a quick-action alongside the toggle, or move into the detail view) once this branch's UI checkpoint is scoped, rather than left to persist by default.

  **Note:** the routine detail view (System-B-inside-System-A liquid-glass panel) previously associated with this branch has moved to branch 9 — see branch 9's note above. This branch's UI checkpoint is the cadence-grouped list only (section headers, schedule-time display, enabled/disabled toggle).

  **Proposed checkpoint sequence for this branch** (design audit's proposal, not yet started): (1) schedule data model — cadence, run time, enabled bool, plus the per-routine unattended-trust opt-in field — with migration for existing routines; (2) scheduler/execution-trigger component (does not exist at all today); (3) approval-policy resolution implementing the per-routine opt-in + tier-3+ backstop above; (4) cadence-grouped Routines UI (section headers, schedule display, toggle, plus the Run-button placement decision above).
- Branch 11 (floating-command-widget) was inserted into the roadmap on 2026-07-11, during branch 8's checkpoint 2 review. It redesigns the menu-bar cockpit's visual/interaction form (Spotlight-style floating command bar + live progress/result overlay, per the user's own wireframes shared 2026-07-08) rather than the plain `NSPopover` shell every branch through 8 has built inside. No spec section mandates this specific visual form — §17.3 only requires the cockpit's *functional* surfaces (command input, voice state, timeline, approvals, etc.), which remain unchanged; this branch changes presentation, not requirements. Depends on branch 8's shared-state foundation and the `SonnyTheme`/`SonnyType` design-system tokens established during branch 8's rebrand work. Branch 18 (Power Mode) needs a new "Power Mode HUD" surface (§17.3) that should build on this cockpit shell rather than the old popover, to avoid a second rework cycle. Every branch from 5 through 8 explicitly deferred this same redesign rather than attempting it piecemeal (see branch 5's changelog entry: "do not build launcher palette UI until quick-results-list wireframes are provided"). **Before starting this branch, read `docs/sonny-design-system-reference.md` in full** — it documents the widget's complete lifecycle (idle/working/permission/success/error/failure), exact shadow/glass recipe, and a separate token set (SF Pro, not Inter; its own accent colors, not `SonnyTheme.accent`) extracted from the wireframes on 2026-07-12. Do not reuse `SonnyTheme`/`SonnyType` for this branch without reading that doc first. **Also read `docs/sonny-founder-design-decisions.md`** — its "Routines" section documents a previously-undocumented System-B-inside-System-A UI requirement (the routine detail view, styled like the floating widget's liquid-glass material but embedded in the main app window). **Resolved 2026-07-15 (see branch 9's note above): that view is built in branch 9, not here** — this branch's relevance to it is only as the source of the System B token/shadow/material recipe (`docs/sonny-design-system-reference.md` §3) the view reuses, since branch 9 will need those tokens before branch 11 itself exists. CLAUDE.md treats the founder-decisions doc as authoritative over the spec/wireframes where they conflict. Two standing notes added 2026-07-15 during `feature/v1-strategy-replan`: (1) the widget's own wireframes already spec an "Asking for permission" lifecycle state as one of six core states — it needs the same design rigor as the idle/success states, not less because it's less visually exciting; (2) when the still-missing instant-utility quick-results-list wireframe finally gets made, deprioritize design investment in quick app/window switching specifically (converged to near-parity with Spotlight/the rebuilt Siri per competitive research) in favor of clipboard history, snippet expansion, and recent-artifact lookup, which remain genuinely differentiated. Also retire "ask Sonny to run your Shortcuts" as a standalone marketing claim — Siri can now do bare invocation natively; the Shortcuts bridge's real, undiminished value is a Shortcut as one composable step inside a larger supervised, audited plan, which nothing else replicates.
- Memory (§6.10) is bundled into branch 13 rather than given its own branch, since it needs the full Command Center UI to be viewable/editable.
- **Branch 13 (`feature/billing-command-center-memory`)**'s pricing/free-tier structure was fully specified 2026-07-15 during `feature/v1-strategy-replan`, replacing the earlier draft (a permanent allowance with cap value and price both left open) entirely:
  - **Free ($0/mo):** 50 credits/month, permanent (not a trial), `gpt-5.4-mini`. Voice/dictation and instant utilities are uncapped — 0 credits, not counted against the pool, since they're already zero-cost by design and capping them would reintroduce exactly the friction that tier exists to avoid. No Power Mode.
  - **Pro ($20/mo):** 350 credits/month, `gpt-5.5` (the full model, not mini — paying unlocks quality, not just quantity). Same uncapped voice/utilities. No Power Mode. Auto top-up available.
  - **Max ($100/mo):** 2,500 credits/month, user's choice of `gpt-5.5` or Claude Sonnet 5 — 1 credit costs the same regardless of which model is picked (Claude Sonnet 5 is confirmed cheaper per equivalent work even after its ~30% tokenizer inflation, so this doesn't create a margin problem worth solving with differential weighting). **Power Mode is included only at this tier** — a decision made 2026-07-15 during this session, not something the spec itself specifies beyond "paid-only" (§6.5). Auto top-up available.
  - **Credit weighting:** 1 credit = one standard planner-routed command. Web-research tasks cost 3 credits, reflecting the real ~3-8x cost multiplier once Tavily's search cost (~$0.008/search, see branch 16 below) is added on top of the LLM cost — this replaces the earlier draft's LLM-only cost assumption, which didn't account for search cost at all.
  - **Claude Sonnet 5 is costed at its standard rate** ($3/$15 per MTok, effectively ~$3.90/$19.50 once the ~30% tokenizer inflation is applied), not its introductory rate ($2/$10) — that introductory window closes 2026-08-31 and this branch will not ship before then.
  - **Auto top-up** is framed as directly serving §16.4's existing mid-task-lapse principle (never interrupt an atomic action in progress) — a trust feature, not just a monetization lever.
  - **Honest caveat, preserved deliberately, not smoothed over:** the Max tier's $100/2,500-credit combination is directionally reasonable — it matches two independent real comparables' pricing shape — but isn't fully trustworthy until Power Mode's actual per-action cost is researched. That hasn't happened yet; Power Mode is the last branch, unbuilt, uncosted. Anthropic's own computer-use tool pricing (per-tool-definition tokens, screenshot/vision costs, session-runtime billing, from their public API pricing docs) is a real starting point for that future costing pass, not a substitute for it.
- **Branch 16 (`feature/workflow-library-polish`)**'s web-search-provider choice (§4A.2's `WebSearchProviding` seam, unconfigured since branch 3) was resolved 2026-07-15 during `feature/v1-strategy-replan`: Tavily, $0.008/search pay-as-you-go. No dependency on which paid tier a user is on — the cost is already folded into branch 13's credit-weighting above (web-research tasks cost 3 credits specifically to account for it).
- §6.16-§6.18 and §18.7-§18.8 are not separate branches — they are explicitly cross-references to §4A.6-§4A.8 ("formal v1 requirement version of...", "listed here for completeness") with no independent scope, fully covered by branches 3-6.
- **Branch 17 (`feature/mcp-client-integration`)** is new, added 2026-07-15 during `feature/v1-strategy-replan`'s Phase 4 — Raycast and other competitors now ship MCP client support, and Sonny has no equivalent. Locked now, non-negotiable: every MCP tool call is a `CapabilityAdapter` like any other capability, routing through `AgentRunner`'s existing risk-tier/approval gate with no parallel or bypassing trust path — this is the rule the whole product's trust story depends on and it must not be relitigated at implementation time. Explicitly left open for build time: which MCP servers/tools ship first, server-configuration UI, and initial risk-tier defaults for MCP tools pending real usage data — that ecosystem moves too fast to lock specifics now. Sequenced immediately before Power Mode; both the placement and its rationale are confirmed (2026-07-15): MCP is simply lower-risk and simpler than Power Mode, so it ships first to close the real competitive gap (Raycast and others already have this) sooner — not as a deliberate rehearsal for Power Mode. Do not scope additional branch-17 requirements around "stress-testing approval-flow edge cases for Power Mode's benefit" — that framing was considered and rejected, not left open. If Power Mode's own branch later finds real lessons in how MCP's approval flow held up, that's a natural look-back at that time, not a goal to design MCP around now.
- The kill switch (§20.9) is folded into branch 18 (Power Mode) rather than given its own branch, since it's tightly coupled to Power Mode's emergency-stop work (§13.5).

## Entry Template

Copy this for each completed branch. Fill every field — "none" is a valid answer, a blank field is not. Product context, constraints, and non-negotiables already live permanently in the spec (§1-§26); do not restate them here, only reference section numbers. The two fields marked **(required, no blanket claims)** exist because a vague answer there is exactly how a later chat regresses something silently.

```
### Branch: feature/<name>
Status: in progress | complete | blocked
Date: YYYY-MM-DD
Implementing agent: Claude | Codex
Reviewing agent: Claude | Codex | pending

Spec sections covered: (list; flag any left partial and why)
Files changed: (actual list — not "see diff")
Tests: (exact command run, from README) -> (pass/fail, counts)

Behavior added: (one bullet per new capability)
Behavior preserved (required, no blanket claims): (one bullet per EXISTING flow this branch touched, confirming it still works — "everything else still works" is not acceptable, name them)

Architectural decisions / pitfalls discovered (required, write "none" if true): (anything a future chat would get wrong if it only read the spec and not this entry)
Known limitations / deferred scope: 
Open questions for the next chat (required, write "none" if true): 

Next branch: feature/<name> (per roadmap above, or state the reordering and why)
```

Then append this ready-to-paste block so the next chat can start cold without re-deriving context:

```
--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/<next-name>
Implementing agent: <X>  Reviewing agent: <Y>
Primary target: §<sections>

Just completed: feature/<prev-name> — <one-line summary>
Must preserve: <the specific existing flows this branch must not break, pulled from "Behavior preserved" above>
Known pitfalls to avoid repeating: <from "Architectural decisions / pitfalls discovered" above, or "none">

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.
```

## Entries

### Branch: feature/capability-adapter-foundation
Status: complete
Date: 2026-07-04
Implementing agent: Codex
Reviewing agent: Claude

Spec sections covered: §4A.0 complete. Forward-compatible metadata placeholders for §10/§11/§11.1A are present, but no risk engine, approval gating, escalation UI, or policy logic was implemented on this branch.
Files changed:
- `Sources/MacAgentCore/AgentActionExecutor.swift`
- `Sources/MacAgentCore/CapabilityAdapter.swift`
- `Sources/MacAgentCore/CreateWorkspaceCapabilityAdapter.swift`
- `Sources/MacAgentCore/DefaultCapabilityAdapters.swift`
- `Sources/MacAgentCore/DocxConversionCapabilityAdapter.swift`
- `Sources/MacAgentCore/FinderSelectionCapabilityAdapter.swift`
- `Sources/MacAgentCore/FinderSelectionResolver.swift`
- `Sources/MacAgentCore/HackerNewsMarkdownCapabilityAdapter.swift`
- `Sources/MacAgentCore/LargestFilesZipCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenAllowlistedAppCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenMediaResultCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenSafeURLCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenWorkspaceCapabilityAdapter.swift`
- `Sources/MacAgentCore/PermissionReadinessCapabilityAdapter.swift`
- `Sources/MacAgentCore/RevealInFinderCapabilityAdapter.swift`
- `Sources/MacAgentCore/RunRoutineCapabilityAdapter.swift`
- `Sources/MacAgentCore/SaveRoutineCapabilityAdapter.swift`
- `Sources/MacAgentCore/ToolRegistry.swift`
- `Tests/MacAgentCoreTests/AgentActionExecutorTests.swift`
- `Tests/MacAgentCoreTests/CapabilityRegistryTests.swift`
- `Tests/MacAgentCoreTests/PlannerBoundaryTests.swift`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 53 tests in 8 suites.

Behavior added:
- Added `CapabilityAdapter`, `CapabilityMetadata`, `CapabilityRegistry`, and adapter-backed default tool registration for local Mac capabilities.
- Added stable capability IDs, display names/descriptions, planner tool metadata, descriptive-only required permissions metadata, default risk-tier placeholders, dry-run behavior descriptions, and local executor location metadata.
- Added registry/protocol/metadata tests, planner prompt golden tests, tool-registry golden tests, response-format shape tests, and adapter routing coverage.

Behavior preserved (required, no blanket claims):
- Largest-files zip still scans whitelisted folders, selects the largest regular files, preserves stable default zip output paths between preview and execution, dry-runs without writing, creates zips through the injected archiver, and suggests revealing the generated zip.
- DOCX conversion still scans whitelisted folders, uses the injected document converter, supports mock destination behavior, skips existing PDF outputs, dry-runs without writing, and suggests revealing the PDF folder.
- Hacker News Markdown still opens `https://news.ycombinator.com`, fetches headlines via the existing `HackerNewsFetching` service, writes Markdown to the resolved whitelisted output path, dry-runs without writing, and suggests opening/revealing the Markdown file.
- Safe URL opening still validates through `SafeURL.validateWebURL`, allows only HTTP/HTTPS, rejects unsupported schemes, previews the URL, and executes through the injected browser opener.
- Allowlisted app opening still resolves apps through `MacAppCatalog`, rejects unknown apps, preserves the bundle-ID allowlist, previews the resolved display name/bundle ID, and executes through the injected app opener.
- Media result opening still validates provider/title, builds the same `MediaPlaybackRequest`, preserves Apple Music/Spotify behavior-description preview text, executes through the injected media opener, and returns the exact summary from `mediaOpener.open()`.
- Finder selection still reads selected Finder items through the existing Finder context reader, validates every path through the Desktop/Documents whitelist, previews selected paths, and reports the whitelisted item count on execution.
- Reveal in Finder still validates paths through the whitelist, allows preview of a future not-yet-created artifact, requires the path to exist during execution, and opens Finder with `NSWorkspace.activateFileViewerSelecting`.
- Permission readiness still uses `PermissionReadinessService.currentStatus`, previews the same status source used by execution, has no side effects, does not prompt for permissions, and reports required-action items in the existing summary format.
- Save routine still validates routine names and nested steps, rejects unsafe routine/workspace/clarify/unsupported/nested-routine steps, previews nested steps through normal plan preview, writes to `routineStore.fileURL`, and preserves saved step counts in the summary.
- Run routine still loads saved routines from `RoutineStore`, previews nested routine plans, executes nested plans through normal executor dispatch, preserves suggestions, and preserves the `Ran routine <name>. ...` summary prefix.
- Create workspace still validates workspace names, allowlisted apps, safe URLs, non-empty app/URL content, previews `workspaceStore.fileURL`, saves through `WorkspaceStore`, and preserves app/URL counts in the summary.
- Open workspace still loads from `WorkspaceStore`, validates allowlisted apps and safe URLs, opens apps before URLs, uses the injected app/browser openers, previews the combined opens list, and preserves app/URL counts in the summary.
- Chained execution still segments composite workflows, resolves reveal-in-Finder steps to the previous produced artifact, preserves the zip-plus-reveal future-artifact preview behavior, and executes each segment through the top-level adapter-backed dispatch.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- `DefaultCapabilityAdapters.all()` now uses real adapters for every executable capability; only `clarify` remains `MetadataOnlyCapabilityAdapter` because clarification is intercepted by `clarificationQuestion()` / `prepare()` before executable dispatch and has no local side-effect executor.
- Routines need executor recursion because saved routine plans can contain any already-migrated capability or mixed chain. `CapabilityExecutionContext` now carries `previewNestedPlan` and `executeNestedPlan` closures back to the executor so `RunRoutineCapabilityAdapter` and `SaveRoutineCapabilityAdapter` can stay adapter-owned without leaving routine behavior in the switch.
- `FinderSelectionResolver` was extracted as the shared DRY helper for whitelisted Finder selection and selected-folder resolution; zip and DOCX adapters use it instead of duplicating Finder-selection code.
- The transitional `previews` closure in `AgentActionExecutor.execute()` was removed once all executable switch cases routed through adapters.
- Planner/schema behavior was protected with hard golden tests for `ToolRegistry.default.plannerDescription`, `OpenAIPlanner.systemPrompt(toolRegistry: .default)`, and `AgentPlanSchema.responseFormat()`.
- Required permissions metadata is descriptive-only on this branch. It does not enforce readiness, gate execution, request permissions, or implement branch #2 approval behavior.
- Chained execution is intentionally not an adapter because it is not tied to one `AgentOperation`; it remains runtime segmentation that calls top-level preview/execute, which now dispatches segment capabilities through the adapter registry.
- During checkpoint 7 review, a one-off uncaught `NSException` flake appeared in `asyncProcessRunnerCancelsRunningProcess` from an existing `AsyncProcessRunner`/`NSTask` cancellation race. It passed on rerun, `AsyncProcessRunner.swift` was not touched, and it is unrelated/non-blocking for this branch.
Known limitations / deferred scope:
- Real risk tiers, dynamic escalation, approval UI, and policy enforcement are deferred to `feature/local-risk-approval-engine`.
- `clarify` has metadata for planner/tool description purposes but remains pre-dispatch control flow rather than an executable adapter.
- The existing `AsyncProcessRunner`/`NSTask` cancellation flake described above remains unresolved and should not be treated as a new capability-adapter regression if it reappears.
Open questions for the next chat (required, write "none" if true): none.

Next branch: `feature/local-risk-approval-engine` (§10, §11, §11.1A), building real risk tiers and dynamic escalation on top of the fully migrated capability adapters.

--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/local-risk-approval-engine
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §10, §11, §11.1A

Just completed: feature/capability-adapter-foundation — existing prototype capabilities now route through protocol-based local capability adapters with registry-backed metadata while preserving planner/schema boundaries.
Must preserve: largest-files zip default output stability and dry-run behavior; DOCX injected converter/mock/skip-existing-PDF behavior; Hacker News browser/fetch/Markdown write/reveal behavior; SafeURL HTTP/HTTPS-only validation; MacAppCatalog allowlist rejection; media provider/title validation and injected opener summaries; Finder selection whitelist validation; reveal-in-Finder preview-vs-execute existence distinction; permission readiness read-only semantics; save/run routine behavior; create/open workspace behavior and app-before-URL order; zip-plus-reveal chained execution.
Known pitfalls to avoid repeating: routines require `previewNestedPlan`/`executeNestedPlan` recursion hooks because saved routines can contain mixed adapter-backed chains; Finder selection should use `FinderSelectionResolver`; do not reintroduce the removed transitional previews closure; required permissions metadata is descriptive-only until this branch defines enforcement; an existing `AsyncProcessRunner`/`NSTask` cancellation flake may appear in tests and is unrelated to adapter work unless reproduced against touched code.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.

### Branch: feature/local-risk-approval-engine
Status: complete
Date: 2026-07-08
Implementing agent: Codex
Reviewing agent: Claude

Spec sections covered: §10, §11, and §11.1A complete for the local runtime. §9.3 is covered only for the minimal local `.risk`/`risk.escalated` log marker needed by §11.1A; full hosted Agent Trace Event Types remain out of scope.
Files changed:
- `Sources/MacAgent/AgentViewModel.swift`
- `Sources/MacAgent/ContentView.swift`
- `Sources/MacAgentCore/AgentActionExecutor.swift`
- `Sources/MacAgentCore/AgentEvent.swift`
- `Sources/MacAgentCore/AgentRunner.swift`
- `Sources/MacAgentCore/CapabilityAdapter.swift`
- `Sources/MacAgentCore/CreateWorkspaceCapabilityAdapter.swift`
- `Sources/MacAgentCore/HackerNewsMarkdownCapabilityAdapter.swift`
- `Sources/MacAgentCore/LargestFilesZipCapabilityAdapter.swift`
- `Sources/MacAgentCore/RiskApproval.swift`
- `Sources/MacAgentCore/RunRoutineCapabilityAdapter.swift`
- `Sources/MacAgentCore/SaveRoutineCapabilityAdapter.swift`
- `Tests/MacAgentCoreTests/AgentRunnerTests.swift`
- `Tests/MacAgentCoreTests/RiskApprovalTests.swift`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 78 tests in 10 suites.

Behavior added:
- Added the local risk-tier and approval-rule model: tier 0 auto-run, tier 1 auto-run unless policy tightens, tier 2 preview/lightweight-confirmation policy, tier 3 explicit approval, and tier 4 refusal.
- Added `CapabilityRiskAssessment`, `CapabilityRiskEscalation`, `RiskApprovalPolicy`, `RiskApprovalRequest`, `RiskApprovalDecision`, and text-only `RiskApprovalCopy` fields covering what Sonny will do, why it is risky, the app/file/domain involved, whether data leaves the device, and undoability.
- Added adapter-owned `assessRisk(plan:context:)` hooks to the `CapabilityAdapter` contract, defaulting to static `defaultRiskTier` so simple capabilities do not need custom risk code.
- Added read-only `AgentActionExecutor.assessRisk(plan:)` to resolve default outputs, collect unique capability adapters in a plan/chain, combine default/effective tiers, collect escalations, and generate approval copy without making an approval decision or executing anything.
- Added real tier gating in `AgentRunner`: it owns auto-run, lightweight-confirmation, explicit-approval, preview-only, and refusal decisions before calling `AgentActionExecutor.execute()`.
- Preserved `AgentActionExecutor.execute(plan:log:)` as an unchanged direct-execution primitive for already-approved plans; direct executor tests remain execution tests, not approval tests.
- Added dynamic validation-time escalation from tier 2 to tier 3 when a largest-files zip output path already exists.
- Added dynamic validation-time escalation from tier 2 to tier 3 when a Hacker News Markdown output file already exists.
- Added dynamic validation-time escalation from tier 2 to tier 3 when saving a routine would replace an existing routine with the same normalized name.
- Added dynamic validation-time escalation from tier 2 to tier 3 when creating a workspace would replace an existing workspace with the same normalized name.
- Added stale-approval protection: a stored `.approved(tier)` decision only authorizes execution if a fresh risk reassessment is still at or below that approved tier.
- Added visible local risk logging through `AgentPhase.risk`, including `risk.assessed` and `risk.escalated` messages; this is deliberately not the hosted trace spine.
- Added approval-pending UI state in `AgentViewModel`/`ContentView`: tier 2+ runs pause after preview with an approval panel, the primary button becomes `Approve`, cancel clears the pending run, approval re-runs risk assessment before execution, and tier 0/1 typed/voice runs continue without added friction.
- Added synchronous `isRunning = true` before spawning start/approval tasks, closing the pre-existing fast double-click race for both normal start and approval execution.
- Added `assessNestedPlan` to `CapabilityExecutionContext`, mirroring the existing nested preview/execute hooks so routine risk assessment recurses through the same executor dispatch path routine execution uses.
- Added runner-level tests for tier 0/1 auto-run, tier 2 confirmation, tier 3 escalation, tier 4 refusal scaffolding, stale approval protection, approval UI-facing state behavior, nested routine escalation, and cross-capability zip-plus-reveal chain gating.

Behavior preserved (required, no blanket claims):
- Largest-files zip still preserves stable default output paths between preview and execution, still dry-runs without writing, still creates archives through the injected archiver, still suggests reveal behavior, and is now tier 2 gated by `AgentRunner`; if its explicit or resolved zip output already exists, it escalates to tier 3 before execution.
- DOCX conversion still scans whitelisted folders, uses the injected converter/mock behavior, skips existing PDF outputs, dry-runs without writing, and remains tier 2 gated by `AgentRunner`; an existing destination PDF is still skip-existing behavior, not an overwrite escalation.
- Hacker News Markdown still opens the fixed HN URL, fetches headlines through `HackerNewsFetching`, writes Markdown to the whitelisted output, dry-runs without writing, and is now tier 2 gated by `AgentRunner`; if the Markdown output already exists, it escalates to tier 3 before execution.
- Safe URL opening still validates through `SafeURL.validateWebURL`, allows only HTTP/HTTPS, rejects unsupported schemes, opens through the injected browser opener, and stays tier 1 auto-run for typed and voice commands with no approval friction by default.
- Allowlisted app opening still resolves apps through `MacAppCatalog`, rejects unknown apps, preserves the bundle-ID allowlist, opens through the injected app opener, and stays tier 1 auto-run for typed commands with no approval friction by default.
- Media result opening still validates provider/title, builds the same `MediaPlaybackRequest`, preserves Apple Music/Spotify result-opening preview text, executes through the injected media opener, returns the opener summary, and stays tier 1 auto-run by default.
- Finder selection still uses the shared Finder selection reader/resolver path, validates every selected item through the whitelist, reports whitelisted item count, and stays tier 0 auto-run because it is read-only context gathering.
- Reveal in Finder still validates paths through the whitelist, allows preview of a future generated artifact, requires the path to exist at execution, opens Finder with `NSWorkspace.activateFileViewerSelecting`, and stays tier 1 auto-run by default.
- Permission readiness still uses `PermissionReadinessService.currentStatus`, remains read-only/no-prompt/no-side-effect, reports required-action items in the existing summary format, and stays tier 0 auto-run.
- Save routine still validates routine names and nested steps, rejects unsafe routine/workspace/clarify/unsupported/nested-routine steps, previews nested steps through normal plan preview, writes to `RoutineStore`, and is now tier 2 gated by `AgentRunner`; replacing an existing routine name escalates to tier 3 before execution.
- Run routine still loads saved routines from `RoutineStore`, previews nested routine plans, executes nested plans through normal executor dispatch, preserves suggestions and the `Ran routine <name>. ...` summary prefix, and is now tier 2 gated by `AgentRunner`; nested routine plans now surface their own escalations in the outer approval request.
- Create workspace still validates workspace names, allowlisted apps, safe URLs, non-empty app/URL content, previews `WorkspaceStore.fileURL`, saves through `WorkspaceStore`, and is now tier 2 gated by `AgentRunner`; replacing an existing workspace name escalates to tier 3 before execution.
- Open workspace still loads from `WorkspaceStore`, validates allowlisted apps and safe URLs, opens apps before URLs, uses the injected app/browser openers, preserves app/URL count summaries, and stays tier 1 auto-run by default.
- Zip-plus-reveal chained execution still segments the zip step and reveal step through top-level dispatch, resolves the reveal step to the produced zip artifact, preserves future-artifact preview behavior, and is now risk-assessed/gated once as a tier 2 chain before either segment executes.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- `dryRun` and tier-based approval are orthogonal. Dry-run remains preview-only mode; non-dry-run execution now goes through tier-aware approval in `AgentRunner`.
- `AgentRunner` owns the approve/refuse decision. `AgentActionExecutor.assessRisk(plan:)` supplies read-only assessment because it has registry/context access, but `AgentActionExecutor.execute(plan:log:)` never gates by itself.
- Keeping `AgentActionExecutor.execute()` as the already-approved primitive meant all pre-existing direct executor execution tests stayed valid and required zero approval rewrites.
- `AgentPlan.requiresConfirmation` remains advisory. The authoritative local decision is the fresh `CapabilityRiskAssessment` plus `RiskApprovalPolicy`.
- Tier 0/1 actions must remain frictionless for typed and voice flows by default. Tests now assert this explicitly for permission readiness, Finder selection, open URL, open app, media opening, reveal in Finder, and open workspace coverage paths.
- Approval decisions carry the tier that was approved, not a Boolean. This is what lets a later reassessment reject stale tier 2 approval if the plan has escalated to tier 3.
- The approval/start double-click task race existed before this branch in `start()` and was more visible once approval was introduced. Both `start()` and `approvePendingRun()` now set `isRunning = true` synchronously before spawning their tasks.
- DOCX existing-PDF behavior is intentionally not an escalation because the adapter skips existing PDFs rather than overwriting or replacing them.
- `assessNestedPlan` mirrors `previewNestedPlan` and `executeNestedPlan`; routines need all three because saved routines can contain mixed adapter-backed chains and must not bypass risk behavior.
- Dynamic escalation belongs to the capability adapter contract, not ad hoc executor logic. The executor combines adapter assessments but does not invent capability-specific escalation rules.
- `AgentPhase.risk` was added as a minimal local marker for visible assessment/escalation logs. Full hosted trace event taxonomy remains deferred to the hosted trace workstream.
- Required-permissions metadata remains descriptive-only on this branch. The risk/approval system does not yet enforce macOS permission readiness or subscription/entitlement checks.
- Finder selection is tier 0, not tier 1, because it only reads whitelisted local context. This was re-verified at the runner gating layer during checkpoint 4.
Known limitations / deferred scope:
- No Power Mode, Accessibility action space, generated shell, generated AppleScript, hosted trace spine, hosted backend, subscription/entitlement validation, Keychain/encrypted storage, provider playback, generic web research, Shortcuts bridge, instant utilities, follow-up correction, or usage transparency was implemented on this branch.
- Tier 2 defaults to lightweight confirmation because there is still no settings UI for changing `RiskApprovalPolicy`.
- No current first-party capability has static tier 3 or tier 4 metadata; tier 3 is exercised through real dynamic escalation and tier 4 through refusal scaffolding in tests.
- Required permissions metadata remains descriptive-only until a later branch defines enforcement.
Open questions for the next chat (required, write "none" if true): none.

Next branch: `feature/web-research-app-foundation` (§4A.2, §4A.3), the first split local capability generalization branch. It is now unblocked because new web/app capabilities can plug into the real adapter risk hooks and `AgentRunner` approval gate instead of inventing their own confirmation path.

--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/web-research-app-foundation
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §4A.2, §4A.3

Just completed: feature/local-risk-approval-engine — Sonny now has a local risk-tier/approval-rule model, adapter-owned dynamic escalation hooks, `AgentRunner`-owned approval gating, visible local risk logs, approval-pending UI state, stale-approval protection, and nested routine risk assessment.
Must preserve: largest-files zip tier 2 gating plus tier 3 overwrite escalation and stable dry-run/default-output behavior; DOCX tier 2 gating plus skip-existing-PDF behavior with no overwrite escalation; Hacker News Markdown tier 2 gating plus tier 3 output-collision escalation; Safe URL tier 1 auto-run with HTTP/HTTPS-only validation; allowlisted app tier 1 auto-run with `MacAppCatalog` rejection; media result tier 1 auto-run with provider/title validation and injected opener summaries; Finder selection tier 0 auto-run with whitelist validation; reveal-in-Finder tier 1 auto-run with preview-vs-execute existence distinction; permission readiness tier 0 auto-run/read-only semantics; save routine tier 2 gating plus tier 3 replacement escalation; run routine tier 2 gating with nested risk assessment and nested dispatch; create workspace tier 2 gating plus tier 3 replacement escalation; open workspace tier 1 auto-run with app-before-URL order; zip-plus-reveal chain assessed/gated once before either segment executes.
Known pitfalls to avoid repeating: `dryRun` is preview-only and orthogonal to approval; `AgentRunner` owns gating while `AgentActionExecutor.execute()` remains direct already-approved execution; new capability-specific escalation rules belong in adapter `assessRisk(plan:context:)`; approval decisions must carry the approved tier and be checked against fresh reassessment; routines need `assessNestedPlan`/`previewNestedPlan`/`executeNestedPlan` recursion hooks; DOCX skip-existing behavior is not an overwrite escalation; required-permissions metadata is still descriptive-only; `AgentPhase.risk` is only a minimal local log marker, not the hosted trace spine.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.

### Branch: feature/web-research-app-foundation
Status: complete
Date: 2026-07-08
Implementing agent: Codex
Reviewing agent: Claude

Spec sections covered: §4A.2 complete for direct public URL web-to-Markdown, comparison notes from multiple sources, Hacker News as a provider preset, output save/open/reveal behavior, robots/login/CAPTCHA/paywall refusal, and the required untrusted-content boundary/red-team fixture. §4A.2 remains partial for production topic/search because this branch shipped the `WebSearchProviding` protocol seam and fixture-backed tests only; no real provider is configured. §4A.3 complete for the scoped local app/website action foundation: declarative descriptors, app search URLs, local draft artifacts, generated artifact opening, and existing reveal reuse. Active browser page import, logged-in/private browser content, unrestricted multi-URL user input parsing, hosted search, and UI control of apps are intentionally deferred.
Files changed:
- `Package.swift`
- `Package.resolved`
- `Sources/MacAgent/ContentView.swift`
- `Sources/MacAgentCore/AgentActionExecutor.swift`
- `Sources/MacAgentCore/AgentPlan.swift`
- `Sources/MacAgentCore/AppWebsiteActionDescriptors.swift`
- `Sources/MacAgentCore/CapabilityAdapter.swift`
- `Sources/MacAgentCore/CreateLocalDraftCapabilityAdapter.swift`
- `Sources/MacAgentCore/DefaultCapabilityAdapters.swift`
- `Sources/MacAgentCore/HackerNewsMarkdownCapabilityAdapter.swift` (deleted; behavior moved into `WebResearchMarkdownCapabilityAdapter`)
- `Sources/MacAgentCore/OpenAIPlanner.swift`
- `Sources/MacAgentCore/OpenAllowlistedAppCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenAppSearchURLCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenGeneratedArtifactCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenSafeURLCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenWorkspaceCapabilityAdapter.swift`
- `Sources/MacAgentCore/WebResearchMarkdownCapabilityAdapter.swift`
- `Sources/MacAgentCore/WebResearchService.swift`
- `Sources/MacAgentCore/WebResearchSynthesizer.swift`
- `Tests/MacAgentCoreTests/AgentActionExecutorTests.swift`
- `Tests/MacAgentCoreTests/AgentRunnerTests.swift`
- `Tests/MacAgentCoreTests/CapabilityRegistryTests.swift`
- `Tests/MacAgentCoreTests/PlannerBoundaryTests.swift`
- `Tests/MacAgentCoreTests/RiskApprovalTests.swift`
- `Tests/MacAgentCoreTests/ToolRegistryTests.swift`
- `Tests/MacAgentCoreTests/WebResearchServiceTests.swift`
- `Tests/MacAgentCoreTests/WebResearchSynthesizerTests.swift`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 100 tests in 12 suites.

Behavior added:
- Added `web_to_markdown` direct URL support: validates public `http`/`https` URLs, checks robots.txt, fetches public HTML without browser cookies or logged-in context, rejects login/CAPTCHA/paywall-like pages, extracts readable page content through SwiftSoup-backed parsing, synthesizes a structured note, and writes source-linked Markdown with retrieval/generated timestamps.
- Added `web_to_markdown` comparison-note support: multiple resolved source pages can be fetched, wrapped separately as untrusted observed content, synthesized into one comparison note, and saved to a whitelisted Markdown path.
- Added `web_to_markdown` topic/search support at the adapter seam: `AgentStep.searchQuery` routes through `WebSearchProviding` with the same tier 2 risk path, output-collision escalation, synthesis, and Markdown save flow as direct URLs; production intentionally uses `UnavailableWebSearchProvider` and fails clearly with `Web search provider not configured.`
- Added `source=hacker_news` preset behavior inside `WebResearchMarkdownCapabilityAdapter`: the existing `open_hacker_news`, `fetch_hn_headlines`, and `write_markdown` operation sequence now routes through the generic web research adapter instead of a separate HN adapter.
- Added `open_app_search_url`: tier 1 action that opens only fixed allowlisted search URL templates for Google, GitHub, YouTube, Apple Music, and Spotify; it does not click, type, scroll, or otherwise control apps.
- Added `open_generated_artifact`: tier 1 action that opens an existing whitelisted generated file through the injected file opener and supports chained null-output resolution from the previous produced artifact.
- Added `create_local_draft`: tier 2 action that creates only a local whitelisted Markdown draft artifact, suggests opening/revealing it, and escalates to tier 3 before overwriting an existing draft path.

Behavior preserved (required, no blanket claims):
- Hacker News Markdown still opens the fixed `https://news.ycombinator.com` URL, fetches headlines through `HackerNewsFetching`, writes the same `MarkdownWriter.hackerNewsMarkdown(...)` structure to the whitelisted output, dry-runs without writing, suggests opening/revealing the Markdown file, stays tier 2 by default, and escalates to tier 3 with the exact reason `Markdown output already exists at <path>.`
- The existing HN operation sequence `open_hacker_news -> fetch_hn_headlines -> write_markdown` still routes correctly; the old adapter file was removed so there is one implementation path rather than parallel HN code.
- Safe URL opening still validates through `SafeURL.validateWebURL`, permits only HTTP/HTTPS, rejects unsupported schemes, opens through the injected browser opener, and now reads its metadata from the shared app/website action descriptor.
- Allowlisted app opening still resolves apps through `MacAppCatalog`, rejects unknown apps, preserves the bundle-ID allowlist, opens through the injected app opener, and now reads its metadata from the shared app/website action descriptor.
- Open workspace still loads saved workspaces from `WorkspaceStore`, validates allowlisted apps and safe URLs, opens apps before URLs, uses injected openers, preserves app/URL count summaries, and now reads its metadata from the shared app/website action descriptor.
- Reveal in Finder remains the generic reveal file/folder action; it still validates paths through the whitelist, supports future-artifact preview, requires the path to exist during execution, and opens Finder through `NSWorkspace.activateFileViewerSelecting`.
- Tier gating from `feature/local-risk-approval-engine` remains owned by `AgentRunner`; the new web/draft overwrite escalations live in adapter-owned `assessRisk(plan:context:)`, and stale approval protection still requires a fresh reassessment before execution.
- `AgentActionExecutor.execute(plan:log:)` remains the already-approved execution primitive; no new capability introduced a parallel confirmation or approval mechanism.
- Existing zip-plus-reveal chained execution still resolves reveal steps to the previous produced artifact, and the same shared chain resolution now also supports `open_generated_artifact`.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- SwiftSoup `2.13.5` is the repo's first third-party dependency and is pinned deliberately in `Package.swift`/`Package.resolved`. It was added because §4A.2 requires real HTML parsing/readability-style extraction rather than ad hoc string slicing; Sonny-owned extraction still does the product-specific scoring and metadata shaping.
- Fetched web content never enters `OpenAIPlanner.plan(command:)`. The executable `AgentPlan` is decided from the trusted user command first; only after that does `WebResearchMarkdownCapabilityAdapter.execute(...)` fetch pages and call the separate `OpenAIWebResearchSynthesizer`.
- The web synthesis prompt uses strict `WebResearchNote` structured output, not executable `AgentPlan` JSON. The trusted instruction is wrapped with `TRUSTED_USER_INSTRUCTION_BEGIN/END`; each fetched page is sent as a separate observed-content message wrapped with `UNTRUSTED_OBSERVED_CONTENT_BEGIN id=... source_url=... retrieved_at=...` and `UNTRUSTED_OBSERVED_CONTENT_END id=...`.
- The permanent red-team fixture in `WebResearchSynthesizerTests` includes observed HTML text that says to ignore prior instructions and emit fake plan/tool directives. Tests assert the trusted plan/instruction remain unchanged, the malicious text appears only inside the delimited untrusted segment, and execution writes only the expected Markdown artifact with fixed suggestions.
- The app/website action foundation now uses `LocalActionDescriptor` / `AppWebsiteActionDescriptors` for supported actions, required permissions, default risk tier, and fallback behavior. This keeps app/URL/workspace/draft/open-artifact metadata declarative without loosening app bundle allowlists or website URL validation.
- `open_app_search_url` intentionally uses fixed URL templates instead of arbitrary user-provided URL templates, AppleScript, Accessibility, or app UI control. Provider media playback remains branch #4; Power Mode remains branch #18 (renumbered 2026-07-15, see roadmap notes).
- `open_generated_artifact` extends the existing chained null-output artifact resolution used by `reveal_in_finder`; future artifact-opening actions should share this runtime helper rather than reimplement previous-step path lookup.
- `WebSearchProviding` was added as a protocol seam so a real provider can be wired into the existing `web_to_markdown` adapter later without changing risk tiering, output escalation, Markdown writing, or synthesis boundaries.

Known limitations / deferred scope:
- Production topic/search is not fully wired. This branch shipped the protocol-only `WebSearchProviding` seam plus fixture-backed search tests, while production uses `UnavailableWebSearchProvider` and returns `Web search provider not configured.` A real search-provider decision, credentials/runtime boundary, and provider implementation must be resolved before the v1 major release is announced.
- The §21.0A Workstream 0 topic/search exit criterion is therefore only partially satisfied: the adapter path and tests exist, but a configured production search provider does not.
- Active-browser-page input and logged-in/private browser content are not implemented. Sonny does not use browser cookies or private session state for web research in this branch.
- Explicit arbitrary multi-URL user parsing is not implemented; comparison support exists for multiple source URLs once the planner/provider supplies them.
- Paywall, CAPTCHA, robots.txt denial, and login-wall bypass are not implemented; those cases are refused rather than worked around.
- No unrestricted app UI control, Accessibility clicking/typing/scrolling, real provider media playback, hosted backend/search, Keychain/encrypted storage, instant utilities, Shortcuts bridge, follow-up correction, or usage transparency was implemented on this branch.
Open questions for the next chat (required, write "none" if true):
- Which production web search provider to use for `WebSearchProviding` remains open and must be resolved before announcing v1; it does not block `feature/provider-media-playback`.

Next branch: `feature/provider-media-playback` (§4A.4), converting the existing media-result-opening fallback into provider-aware Spotify/Apple Music playback where first-party provider APIs allow it.

--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/provider-media-playback
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §4A.4

Just completed: feature/web-research-app-foundation — Sonny now has a generic web-to-Markdown capability with SwiftSoup-backed extraction, strict untrusted-content separation, Markdown save/open/reveal behavior, HN as a preset inside the generic adapter, a protocol-only search seam, and descriptor-backed app/website actions including app search URLs, generated-artifact opening, and local draft creation.
Must preserve: web-to-Markdown direct URL tier 2 behavior with robots/login/CAPTCHA/paywall refusal, source links, timestamps, open/reveal suggestions, and tier 3 output-collision escalation; comparison-note support from multiple resolved sources; production topic/search must continue to fail clearly with `Web search provider not configured.` until a real provider is explicitly selected; Hacker News must keep the fixed HN URL, `HackerNewsFetching`, exact Markdown output structure, dry-run behavior, open/reveal suggestions, tier 2 gating, and exact tier 3 collision reason; `open_app_search_url` must remain fixed-template tier 1 URL opening only; `open_generated_artifact` must remain tier 1 whitelisted file opening with chained null-output resolution; `create_local_draft` must remain tier 2 local Markdown only with tier 3 overwrite escalation; app bundle allowlists and safe URL validation must not loosen; `AgentRunner` must continue to own approval gating and `AgentActionExecutor.execute()` must remain already-approved execution.
Known pitfalls to avoid repeating: fetched or observed external content must not enter executable `AgentPlan` generation; use the separate strict-schema untrusted-content prompt path for summarization; new capability-specific escalation belongs in adapter `assessRisk(plan:context:)`; do not add a parallel confirmation path; use the shared previous-artifact chain resolver for generated artifact follow-ups; do not introduce app UI clicking/typing/scrolling for media playback because Power Mode is branch #18 (renumbered 2026-07-15, see roadmap notes); production web search remains intentionally unavailable until a provider is chosen.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.

### Branch: feature/provider-media-playback
Status: complete
Date: 2026-07-08
Implementing agent: Codex
Reviewing agent: Claude

Spec sections covered: §4A.4 complete for provider-aware media playback seams, fixed-order playback failure diagnosis, fixture-tested Spotify and Apple Music match/resolution, route-aware dry-run previews, preserved provider result/search fallback, and risk/runner integration. Production Spotify OAuth/Web API calls and Apple Music MusicKit calls remain intentionally deferred before the v1 major release announcement, per the branch decision.
Files changed:
- `Sources/MacAgentCore/AgentActionExecutor.swift`
- `Sources/MacAgentCore/CapabilityAdapter.swift`
- `Sources/MacAgentCore/MediaPlaybackService.swift`
- `Sources/MacAgentCore/OpenAIPlanner.swift`
- `Sources/MacAgentCore/OpenMediaResultCapabilityAdapter.swift`
- `Tests/MacAgentCoreTests/AgentActionExecutorTests.swift`
- `Tests/MacAgentCoreTests/AgentRunnerTests.swift`
- `Tests/MacAgentCoreTests/MediaPlaybackServiceTests.swift`
- `Tests/MacAgentCoreTests/PlannerBoundaryTests.swift`
- `Tests/MacAgentCoreTests/ToolRegistryTests.swift`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 122 tests in 12 suites.

Behavior added:
- Added the dedicated `MediaPlaybackFailureDiagnosis.diagnose(_:)` function over `MediaPlaybackBlockers`, returning exactly one `MediaPlaybackFailureReason` in the required precedence order: authorization, subscription/Premium, active device, catalog match, then provider outage.
- Generalized the existing `MediaSearchMatcher` instead of adding a parallel scorer, keeping the title/artist normalization path used by iTunes fallback while adding optional album, duration, market/storefront scoring, and stable tie-breaking for provider resolvers.
- Added the Spotify playback seam and resolver: `SpotifyPlaybackProviding`, `UnavailableSpotifyPlaybackProvider`, `SpotifyPlaybackResolver`, and typed Spotify status/device/candidate/result models. Fixture tests cover success, transfer playback, missing auth, missing Premium, missing active device, catalog mismatch, outage/rate-limit, and multi-blocker precedence.
- Added the Apple Music playback seam and resolver: `AppleMusicPlaybackProviding`, `UnavailableAppleMusicPlaybackProvider`, `AppleMusicPlaybackResolver`, and typed Apple Music status/candidate/result models. Fixture tests cover authorized playback, missing authorization, missing subscription, catalog mismatch, provider outage, and multi-blocker precedence.
- Wired provider playback into `OpenMediaResultCapabilityAdapter` and `AgentActionExecutor`: dry-run previews now explicitly show `search`, `play`, `transfer-playback`, or `fallback-open`; execution tries the provider seam first and, when blocked, reports the diagnosed blocker plus the result from `context.mediaOpener.open(request)`.

Behavior preserved (required, no blanket claims):
- Existing `play_media` planner-facing schema is unchanged: it still uses `mediaProvider`, `mediaTitle`, optional `mediaArtist`, and optional exact `targetURL`; the strict planner schema and golden metadata tests cover this boundary.
- Existing provider/title validation and `MediaPlaybackRequest` construction are preserved for Apple Music and Spotify, including exact target URI handling when the user supplies one.
- Existing result-opening/search-fallback behavior is unchanged for real users today because both production providers remain unconfigured by default. Apple Music still opens supplied Apple Music URLs, best matching iTunes/Apple Music catalog album results, or Apple Music search; Spotify still opens supplied Spotify URIs or Spotify search.
- Existing iTunes-based Apple Music fallback lookup through `ITunesSearchAPIClient.bestTrack(...)` remains in place and continues to use the generalized `MediaSearchMatcher`; the provider resolver did not replace or bypass that fallback path.
- Existing `MediaOpening` injection behavior is preserved: tests prove blocked provider playback still falls through to the injected `context.mediaOpener.open(request)` fallback, while provider-success execution does not call the opener.
- `play_media` remains tier 1 auto-run with `dataLeavesDevice == true` and no new escalation; runner tests assert it still auto-runs through the existing `AgentRunner` risk contract.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- The branch reused and generalized `MediaSearchMatcher` instead of duplicating normalization/scoring logic. Spotify, Apple Music, and the iTunes fallback now share the same core title/artist matching behavior, with album/duration/market/storefront as optional scoring dimensions.
- Provider `preview(_:)` is deliberately synchronous and non-throwing because `CapabilityAdapter.preview(...)` is synchronous and dry-run must never make live OAuth, MusicKit, or network calls. Previews can only report static/known route information from the injected seam; unavailable production providers therefore preview `fallback-open`.
- `UnavailableSpotifyPlaybackProvider` and `UnavailableAppleMusicPlaybackProvider` intentionally map "not configured" to the authorization blocker, so the fixed diagnosis precedence does not need a separate seam-state exception.
- The adapter reports one diagnosed blocker plus the fallback result when playback is blocked. It does not enumerate every possible failure, because §4A.4 requires exactly one surfaced reason in fixed precedence order.
- Route-aware preview belongs at the adapter/provider seam boundary; real playback and transfer decisions remain provider concerns, while fallback opening remains the existing `MediaOpening` concern.

Known limitations / deferred scope:
- Spotify production playback is deferred before the v1 major release announcement, not permanently stubbed. The user has an existing Spotify Developer account, but real OAuth/PKCE credentials, scopes, token handling, device discovery, catalog search, and playback API calls still need to be wired before release.
- Apple Music production playback is deferred before the v1 major release announcement, not permanently stubbed. Real MusicKit playback requires Apple Developer Program membership that the user does not currently have, plus the corresponding developer capabilities/credentials before release.
- No live Spotify OAuth/Web API calls, Apple Music MusicKit calls, provider network traffic, Keychain token persistence, secure token storage, or provider app UI clicking/typing/scrolling were added on this branch.
- Candidate resolution is real and fixture-tested, but production catalog candidates still need to come from future real provider implementations.
Open questions for the next chat (required, write "none" if true): none.

Next branch: `feature/instant-utilities-shortcuts` (§4A.6, §4A.7), adding instant utility actions and a scoped Shortcuts bridge on top of the adapter/risk foundations.

--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/instant-utilities-shortcuts
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §4A.6, §4A.7

Just completed: feature/provider-media-playback — Sonny now has provider-aware Spotify and Apple Music playback seams, fixture-tested match resolution, fixed single-blocker diagnosis precedence, route-aware dry-run previews, and universal fallback to existing result opening while production providers remain intentionally unavailable.
Must preserve: fixed playback failure precedence through `MediaPlaybackFailureDiagnosis.diagnose(_:)`; generalized `MediaSearchMatcher` reuse; Spotify and Apple Music unavailable defaults with fallback-open behavior; existing Apple Music iTunes result/search fallback and Spotify URI/search fallback; `play_media` tier 1 auto-run/no escalation behavior; unchanged `play_media` planner-facing schema; no live OAuth/MusicKit/provider network calls until credentials and developer access are explicitly wired.
Known pitfalls to avoid repeating: provider `preview(_:)` is synchronous/non-throwing by design and must never make live calls; do not duplicate media scoring logic instead of reusing `MediaSearchMatcher`; do not introduce UI clicking/typing/scrolling app control for provider media; new capability-specific risk behavior must go through adapter `assessRisk(plan:context:)` and `AgentRunner`; production Spotify and Apple Music wiring remain deferred-before-v1 known limitations, not permanent stubs.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.

### Branch: feature/instant-utilities-shortcuts
Status: complete
Date: 2026-07-09
Implementing agent: Codex
Reviewing agent: Claude

Spec sections covered: §4A.6 and §4A.7 complete for backend/adapter logic and existing command-box smoke-test routing. Launcher palette UI is explicitly deferred pending quick-results-list wireframes.
Files changed:
- `Sources/MacAgent/AgentViewModel.swift`
- `Sources/MacAgent/ContentView.swift`
- `Sources/MacAgentCore/AgentActionExecutor.swift`
- `Sources/MacAgentCore/AgentPlan.swift`
- `Sources/MacAgentCore/AgentRunner.swift`
- `Sources/MacAgentCore/AutomationStores.swift`
- `Sources/MacAgentCore/CalculatorCapabilityAdapter.swift`
- `Sources/MacAgentCore/CalculatorService.swift`
- `Sources/MacAgentCore/CapabilityAdapter.swift`
- `Sources/MacAgentCore/ClipboardHistoryCapabilityAdapter.swift`
- `Sources/MacAgentCore/ClipboardHistoryService.swift`
- `Sources/MacAgentCore/DefaultCapabilityAdapters.swift`
- `Sources/MacAgentCore/InstantCommandResolver.swift`
- `Sources/MacAgentCore/InvokeShortcutCapabilityAdapter.swift`
- `Sources/MacAgentCore/OpenAIPlanner.swift`
- `Sources/MacAgentCore/RecentArtifactStore.swift`
- `Sources/MacAgentCore/RecentArtifactsCapabilityAdapter.swift`
- `Sources/MacAgentCore/RunningAppService.swift`
- `Sources/MacAgentCore/RunningAppSwitchCapabilityAdapter.swift`
- `Sources/MacAgentCore/ShortcutsBridgeService.swift`
- `Sources/MacAgentCore/SnippetExpansionCapabilityAdapter.swift`
- `Sources/MacAgentCore/SnippetSaveCapabilityAdapter.swift`
- `Sources/MacAgentCore/SnippetStore.swift`
- `Tests/MacAgentCoreTests/CapabilityRegistryTests.swift`
- `Tests/MacAgentCoreTests/ClipboardHistoryTests.swift`
- `Tests/MacAgentCoreTests/InstantCommandResolverTests.swift`
- `Tests/MacAgentCoreTests/PlannerBoundaryTests.swift`
- `Tests/MacAgentCoreTests/QuickDispatchTests.swift`
- `Tests/MacAgentCoreTests/RiskApprovalTests.swift`
- `Tests/MacAgentCoreTests/RunningAppAndRecentArtifactsTests.swift`
- `Tests/MacAgentCoreTests/ShortcutsBridgeTests.swift`
- `Tests/MacAgentCoreTests/SnippetExpansionTests.swift`
- `Tests/MacAgentCoreTests/ToolRegistryTests.swift`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 155 tests in 18 suites.

Behavior added:
- Added `InstantCommandResolver` and `AgentRunner.prepare(plan:source:)` so local instant commands can skip `OpenAIPlanner.plan(command:)` while still flowing through `AgentActionExecutor.prepare`, risk assessment, approval gating, execution, logs, previews, and summaries.
- Added tier 0 calculator/unit conversion with local parsing and Foundation measurement conversions; exact `calc`, `calculate`, `=`, bare arithmetic, and simple conversion commands resolve locally.
- Added clipboard history lookup with injectable pasteboard monitoring, ConcealedType/TransientType privacy filtering before content reads, dedupe, 100-item / 7-day / per-item text caps, local JSON storage, and a one-time existing-shell notice/toggle before default-on monitoring activates.
- Added exact-trigger snippet expansion from local JSON storage, plus the typed smoke-test command `snippet save ;trigger = expansion`; expansion is tier 0, while saving a snippet is tier 2 because it writes local JSON.
- Added running-app search/switch over injected `NSWorkspace.runningApplications`, tier 1, without using the launch allowlist because it only activates already-running apps and cannot launch new apps.
- Added recent-artifacts tracking for successful non-dry-run generated files and tier 0 lookup; opening a recent artifact reuses the existing `open_generated_artifact` tier 1 adapter path.
- Added quick routine/workspace dispatch for known saved names through trusted local `run_routine` / `open_workspace` plans; saved routine nested risk is still folded by `RunRoutineCapabilityAdapter` and tier 2+/tier 3 steps still pause through `AgentRunner`.
- Added `invoke_shortcut` as both planner-visible and instant-resolver-supported, using the fixed `/usr/bin/shortcuts run <name>` template through injectable seams, `.clarify` for unknown/misspelled names, and local JSON run history that demotes a Sonny-observed successful Shortcut from tier 2 to tier 1 until a later process-level failure clears it.
- Wired the existing command box in `AgentViewModel` to try `InstantCommandResolver` before falling back to `OpenAIPlanner`, allowing instant typed utilities to work without `OPENAI_API_KEY` while preserving planner fallback for non-instant commands.

Behavior preserved (required, no blanket claims):
- Non-instant typed commands still fall back to `OpenAIPlanner` and use the existing strict schema, tool registry prompt, prepared-run preview, approval, execution, and logging flow.
- Existing voice transcription still requires `OPENAI_API_KEY` because voice uses `OpenAITranscriber`; only typed instant commands can run without planner credentials.
- Existing planner-visible routine/workspace tools remain unchanged: `run_routine` and `open_workspace` are reused for quick dispatch instead of adding parallel execution paths.
- Existing approval behavior is preserved: tier 0 and tier 1 actions auto-run under the default policy, tier 2 requires lightweight confirmation, tier 3 requires explicit approval, and tier 4 refuses.
- Existing app launch allowlist remains in force for `open_app`; the new running-app switcher does not relax app-launch restrictions.
- Existing recent artifact recording only happens after successful execution through `AgentRunner`, never from dry runs or failed runs.
- Existing provider media playback, web research, document conversion, Finder, URL-opening, routine, workspace, local draft, and generated-artifact adapters continue to register through the default capability registry and pass the full regression suite.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- Instant utility commands are local-resolver-only: calculator, clipboard lookup, snippet save/expand, running-app switch, recent-artifact lookup/open resolution, and quick routine/workspace dispatch are intentionally excluded from planner tools to avoid reintroducing the model round trip. `invoke_shortcut` is different because it belongs to §4A.7, so it is both planner-visible and instant-supported.
- Planner bypass means bypassing only `OpenAIPlanner.plan(command:)`; instant plans still use the same `AgentRunner` and adapter risk pipeline. Do not add a second confirmation/execution path for future instant UI work.
- Shortcut demotion is based on a process-level "Sonny-observed successful invocation." The `shortcuts` CLI can exit 0 even if a Shortcut action silently fails internally, so Sonny cannot guarantee internal Shortcut success until a richer success signal exists.
- Clipboard privacy filtering must check pasteboard types and skip `org.nspasteboard.ConcealedType` / `org.nspasteboard.TransientType` before reading copied text content.
- Running-app switching deliberately does not use `MacAppCatalog` because switching only activates already-running apps; launching new apps remains allowlist-gated through `open_app`.
- Snippet creation is intentionally minimal and typed for smoke testing; it is tier 2 because it mutates local JSON even though snippet expansion is tier 0.

Known limitations / deferred scope:
- Launcher palette UI is deferred pending the quick-results-list wireframes for instant utilities. This is a sequenced follow-up, not a product gap or forgotten branch scope; the current branch intentionally stops at backend/adapter logic plus existing command-box smoke routing.
- There is no full snippet management UI yet beyond the typed `snippet save ;trigger = expansion` command.
- Automated tests avoid live Shortcuts execution and real clipboard side effects by using injectable seams; production Shortcuts behavior still depends on the user's installed Shortcuts and the macOS `shortcuts` CLI.
- Exposing Sonny capabilities as Shortcuts actions via App Intents remains out of scope.
Open questions for the next chat (required, write "none" if true): none.

Next branch: `feature/followup-usage-transparency` (§4A.8, §4A.9), adding follow-up correction and usage transparency on top of the now-shared command/adapter/risk spine.

--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/followup-usage-transparency
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §4A.8, §4A.9

Just completed: feature/instant-utilities-shortcuts — Sonny now resolves instant typed utility commands locally before planner fallback, has backend adapters/stores for calculator, clipboard history, snippets, running-app switch, recent artifacts, quick routine/workspace dispatch, and a planner-visible Shortcuts bridge with process-observed run-history demotion.
Must preserve: instant commands bypass only `OpenAIPlanner.plan(command:)` and still use `AgentRunner`/`AgentActionExecutor` risk gating; calculator/clipboard/snippet/running-app/recent-artifact/quick-dispatch remain instant-only; `invoke_shortcut` remains planner-visible and instant-supported; clipboard ConcealedType/TransientType filtering happens before content reads; quick routines preserve nested tier 2+/tier 3 approval gates; running-app switching does not relax the `open_app` launch allowlist; typed command-box instant routing works without `OPENAI_API_KEY` while non-instant typed commands still fall back to the planner.
Known pitfalls to avoid repeating: do not build launcher palette UI until quick-results-list wireframes are provided; do not create parallel confirmation/execution paths; do not treat `shortcuts` exit 0 as guaranteed internal Shortcut success; non-secret local JSON is acceptable for these stores, but branch #7 still owns broader storage/privacy hardening.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.

### Branch: feature/followup-usage-transparency
Status: complete
Date: 2026-07-09
Implementing agent: Codex
Reviewing agent: Claude

Spec sections covered: §4A.8 complete for local task-scoped follow-up correction. §4A.9 complete for the local approximate usage indicator; hosted billing/account/entitlement-backed usage remains deferred to §16.4 and later roadmap branches.
Files changed:
- `Sources/MacAgent/AgentViewModel.swift`
- `Sources/MacAgent/ContentView.swift`
- `Sources/MacAgentCore/AgentActionExecutor.swift`
- `Sources/MacAgentCore/AgentRunner.swift`
- `Sources/MacAgentCore/OpenAIPlanner.swift`
- `Sources/MacAgentCore/OpenAITranscriber.swift`
- `Sources/MacAgentCore/PriorTaskContext.swift`
- `Sources/MacAgentCore/TaskUsage.swift`
- `Sources/MacAgentCore/WebResearchSynthesizer.swift`
- `Tests/MacAgentCoreTests/AgentRunnerTests.swift`
- `Tests/MacAgentCoreTests/ClipboardHistoryTests.swift`
- `Tests/MacAgentCoreTests/InstantCommandResolverTests.swift`
- `Tests/MacAgentCoreTests/OpenAIPlannerTests.swift`
- `Tests/MacAgentCoreTests/OpenAITranscriberTests.swift`
- `Tests/MacAgentCoreTests/PlannerBoundaryTests.swift`
- `Tests/MacAgentCoreTests/PriorTaskContextTests.swift`
- `Tests/MacAgentCoreTests/QuickDispatchTests.swift`
- `Tests/MacAgentCoreTests/RunningAppAndRecentArtifactsTests.swift`
- `Tests/MacAgentCoreTests/ShortcutsBridgeTests.swift`
- `Tests/MacAgentCoreTests/SnippetExpansionTests.swift`
- `Tests/MacAgentCoreTests/WebResearchSynthesizerTests.swift`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 167 tests in 20 suites.

Behavior added:
- Added `PriorTaskContext`, `PriorTaskContextStore`, and a last-task-only rolling context snapshot containing previous command text, plan summary, compact step summaries, outcome status/summary, and timestamp.
- Added 10-minute bounded expiry for prior-task context; recording any newly resolved task replaces the old snapshot, so there is no growing history and no persistent chat memory.
- Changed `Planning.plan(command:)` to `Planning.plan(command:priorTaskContext:)` and added `AgentRunner.prepare(command:priorTaskContext:)`, so prior-task context reaches the planner as typed context instead of being concatenated into the raw command string.
- Updated `OpenAIPlanner` prompt construction with explicit follow-up instructions: short correction phrases reuse the prior task's exact action(s) with only the referenced field replaced, while complete standalone tasks still plan fresh.
- Wired `AgentViewModel` to offer eligible prior-task context for the next typed command, capture final/failed/clarification/approval-canceled outcomes, record command-only failed context when preparation fails before a `PreparedAgentRun` exists, and expose `recentTaskAffordanceText` for the existing popover.
- Added a passive recent-task affordance under the command input in the existing popover, showing the short prior task summary when context is eligible.
- Added `TaskUsageRecorder`, `TaskUsageSummary`, `AIUsageRecord`, and parser/estimator helpers for task-scoped local usage accounting.
- Captured real OpenAI Responses API token usage for `OpenAIPlanner` and `OpenAIWebResearchSynthesizer` when `usage.input_tokens`, `usage.output_tokens`, and `usage.total_tokens` are present.
- Added clearly marked fallback token estimates for planner/web synthesis when Responses `usage` is missing or null; reported and estimated tokens remain separate in data and UI.
- Captured `OpenAITranscriber` usage as reported token counts or reported audio duration seconds; duration usage is kept as seconds instead of converted into invented token counts.
- Threaded one per-task usage recorder through `AgentViewModel`, `OpenAIPlanner`, `AgentActionExecutor`, `EnvironmentWebResearchSynthesizer`, `OpenAIWebResearchSynthesizer`, and `OpenAITranscriber`, preserving voice transcription usage into the auto-started task.
- Added a compact, non-alarming local usage badge in the existing popover run-details area, including a truthful no-AI-requests state for instant-only/local tasks.

Behavior preserved (required, no blanket claims):
- Corrected follow-up plans still flow through the same `AgentRunner.prepare` -> `AgentActionExecutor.prepare` -> risk assessment -> approval -> `AgentActionExecutor.execute` pipeline as fresh planner commands; tier 2+ corrected plans still pause for approval before execution.
- Non-instant typed commands still fall back to `OpenAIPlanner`, use the strict schema decoder, receive tool-registry prompt context, and preserve the existing prepared-run preview, approval, execution, logging, and artifact-recording flow.
- Instant typed commands still bypass only `OpenAIPlanner.plan(command:priorTaskContext:)`; they still use `AgentRunner.prepare(plan:source:)`, adapter validation, risk gating, and execution, and instant-only calculator coverage now asserts zero AI requests.
- The prior branch's six `FailingPlanner: Planning` test conformances still compile with the new `priorTaskContext` parameter: instant command resolver, clipboard history, snippet expansion, running-app/recent-artifact, quick dispatch, and Shortcuts bridge tests.
- `AgentPlanDecoder.decodeStrict`, `AgentPlanSchema.responseFormat()`, `AgentStep`, and planner response-format schema stayed unchanged; follow-up correction is prompt/context only, not a new operation or plan field.
- Untrusted web observed-content delimiter handling from the web research branch remains scoped to externally fetched content; prior-task context is Sonny's own first-party state and did not reuse those delimiters.
- Clipboard history ConcealedType/TransientType privacy filtering, Shortcuts process-level demotion behavior, running-app switcher launch restrictions, quick routine nested risk folding, and typed command-box instant routing from `feature/instant-utilities-shortcuts` remain covered by the regression suite.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- Follow-up relevance is model-decided, not locally keyword-matched. Sonny always passes eligible prior-task context to the planner, and the prompt specifically treats short correction phrases such as "use X instead" / "try Y" / "no, scan Z instead" as reusing the prior task's exact action with only the referenced field replaced. Complete standalone tasks still ignore prior context and plan normally.
- Prepare-time failures must still become follow-up context. If validation/preparation throws before a `PreparedAgentRun` exists, `AgentViewModel` records the original command plus failed outcome with unavailable plan summary/steps; the planner prompt then infers the prior action from the previous command and outcome.
- Prior-task context is short-lived and last-task-only: 10-minute expiry, one stored snapshot, and rolling replacement after any newly resolved command, follow-up or unrelated.
- Do not fold prior-task context into the user's raw command string. Keep the typed `Planning.plan(command:priorTaskContext:)` signature and separate prompt rendering so future planners and tests can see whether context was offered.
- `OpenAIPlanner.defaultSystemPrompt(toolRegistry:)` now includes follow-up-correction instructions; `PlannerBoundaryTests` golden text was updated. Future prompt changes must keep the planner and golden tests in sync.
- `OpenAIPlanner`, `OpenAIWebResearchSynthesizer`, and `OpenAITranscriber` constructors now accept a `TaskUsageRecording` recorder; `OpenAITranscriber.TranscriptionResult` also carries optional usage. Future OpenAI-backed features should thread this recorder instead of creating independent counters.
- Usage records are task-local and approximate. Responses API reported token counts are authoritative when present, missing/null usage falls back to a rough text estimate marked `.estimated`, and transcription duration is reported as audio seconds rather than tokenized.
- Usage is recorded for successful HTTP responses before strict planner/note decoding finishes, so a malformed but billable model response can still count locally.
- The usage badge lives in the existing `NSPopover` only as an interim placement. Do not build a fake Command Center here; migrate this surface when branch #8 (`feature/product-shell-shared-state`) creates the shared-state product shell/Command Center foundation.
- Local-only usage transparency must not be treated as billing, entitlements, plan limits, rate limits, or account state. Those remain hosted/backend concerns for later roadmap branches.

Known limitations / deferred scope:
- No account creation, subscription state, entitlement checks, billing portal, plan limits, hosted usage history, or server-side metering were added.
- The usage indicator is local and approximate; estimated tokens use a simple text-length heuristic when OpenAI usage is absent.
- The recent-task affordance is passive and tied to the existing command input only; no persistent chat memory, long-term preference memory, or multi-turn conversation transcript was added.
- The existing popover placement for recent-task and usage UI is intentionally minimal. Fuller Command Center placement is deferred to branch #8's shared-state shell work and later billing/Command Center branches.
- Tests use fixture URL protocols and fake planners/transcribers only; no live OpenAI calls are made in the suite.
Open questions for the next chat (required, write "none" if true): none.

Next branch: `feature/local-storage-privacy-foundation` (§15.4), hardening local storage and privacy foundations before hosted backend/auth/account work.

--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/local-storage-privacy-foundation
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §15.4

Just completed: feature/followup-usage-transparency — Sonny now has short-lived task-scoped follow-up correction, planner-visible prior-task context, local per-task AI usage recording for planner/web synthesis/transcription, and minimal existing-popover affordances for recent task and usage.
Must preserve: corrected follow-up plans use the exact normal `AgentRunner`/`AgentActionExecutor` prepare, risk, approval, and execute pipeline; tier 2+ corrected plans still pause for approval; prepare-time failures still record command-only prior context for immediate correction; non-instant typed commands still fall back to strict-schema `OpenAIPlanner`; instant commands still bypass only planner calls and can show zero AI requests; prior-task context remains 10-minute, last-task-only, and non-persistent; planner context stays typed via `Planning.plan(command:priorTaskContext:)`; reported and estimated usage tokens stay separate; transcription duration remains seconds, not invented tokens; usage UI remains local-only and non-billing.
Known pitfalls to avoid repeating: do not concatenate prior-task context into raw command text; do not drop prior context when preparation fails before `preparedRun` is assigned; keep `OpenAIPlanner.defaultSystemPrompt` and `PlannerBoundaryTests` golden text in sync after prompt edits; update all `Planning` conformances when changing planner signatures; thread `TaskUsageRecording` through new OpenAI-backed features instead of adding parallel counters; do not build Command Center UI before branch #8 creates the shared-state product shell; do not add account/subscription/entitlement/billing logic on local-only branches.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.

### Branch: feature/local-storage-privacy-foundation
Status: complete
Date: 2026-07-09
Implementing agent: Codex
Reviewing agent: Claude

Spec sections covered: §15.4 complete for encrypted local storage, Keychain-backed local encryption key management, no-plain-file credential invariant preservation, and local data deletion for the persisted stores that exist today. Exclusions, cached entitlement state, persistent recent task history, backend secrets management, and enterprise security remain out of scope because those features are not real local stores yet or belong to later roadmap branches.
Files changed:
- `Package.swift`
- `Sources/MacAgent/AgentViewModel.swift`
- `Sources/MacAgent/ContentView.swift`
- `Sources/MacAgentCore/AutomationStores.swift`
- `Sources/MacAgentCore/ClipboardHistoryService.swift`
- `Sources/MacAgentCore/KeychainSecretStore.swift`
- `Sources/MacAgentCore/LocalDataDeletionService.swift`
- `Sources/MacAgentCore/LocalStorageEncryption.swift`
- `Sources/MacAgentCore/RecentArtifactStore.swift`
- `Sources/MacAgentCore/ShortcutsBridgeService.swift`
- `Sources/MacAgentCore/SnippetStore.swift`
- `Tests/MacAgentTests/AgentViewModelLocalStorageTests.swift`
- `Tests/MacAgentCoreTests/LocalStorageSecurityTests.swift`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 182 tests in 22 suites.

Behavior added:
- Added `KeychainSecretStore`, a reusable generic-password Keychain helper for data read/save/delete by service/account.
- Added `LocalStorageEncryptionKeyManager`, which loads a 32-byte local data encryption key from Keychain or generates and stores one on first app launch.
- Added `LocalStorageEncryption`, using CryptoKit `AES.GCM` authenticated encryption with the `SONNYENC1\n` file header plus combined nonce/ciphertext/tag bytes.
- Encrypted all seven existing local JSON stores at rest: routines, workspaces, clipboard history, clipboard history settings, snippets, recent artifacts, and Shortcut run history.
- Added transparent legacy plaintext JSON migration: files without the encrypted header decode as old JSON once, then rewrite encrypted after successful load.
- Added raw-byte tests proving known plaintext markers written through public store APIs are absent from the on-disk bytes for all seven stores.
- Added `LocalDataDeletionService`, deleting only the seven Sonny local store files and tolerating already-missing files.
- Added a direct `AgentViewModel.deleteLocalData()` settings/privacy action that stops clipboard monitoring, deletes local store files, clears relevant in-memory UI state, and refreshes saved routine/workspace and clipboard-setting surfaces.
- Added a destructive native confirmation dialog in the existing Status panel for local data deletion, explicitly naming the deleted local data and noting generated files/API keys are not deleted.
- Added app-level regression coverage for encrypted local-load failures. `AgentViewModel.refreshSavedItems()` and `refreshClipboardHistoryNotice()` now surface a visible error banner when an existing local data file cannot be decrypted or decoded, while missing first-run files still stay silent/empty.
- Added an in-memory, `NSLock`-guarded encryption-key cache inside `LocalStorageEncryption`, so the underlying Keychain-backed key manager is queried once after first successful retrieval instead of on every encrypt/decrypt call.

Behavior preserved (required, no blanket claims):
- Routine save/load/run behavior remains transparent to existing callers; quick routine dispatch and nested routine risk folding still use `RoutineStore` through the same public API.
- Workspace save/load/open behavior remains transparent to existing callers; quick workspace dispatch and app-before-URL launch behavior still use `WorkspaceStore` through the same public API.
- Clipboard history still skips ConcealedType/TransientType pasteboard items before reading content, still applies item/age/text caps, and still respects the existing notice/settings toggle.
- Snippet save and exact-trigger expansion still use the same public `SnippetStore` calls, with snippet saving tier 2 and expansion tier 0.
- Recent artifact recording still happens only after successful non-dry-run execution through `AgentRunner`, and recent artifact opening still routes through `open_generated_artifact`.
- Shortcut run-history demotion still uses the same process-level Sonny-observed success/failure semantics; encryption does not reinterpret `shortcuts` exit status.
- `OPENAI_API_KEY` remains environment-variable-only for planner, web synthesis, and transcription; no raw API credentials are written to plain files, and no new OAuth/provider token persistence was added.
- Prior-task context remains 10-minute, last-task-only, and in-memory only; this branch did not add persistent chat memory or recent-task-history storage.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- Bulk local JSON data is encrypted in files with AES-GCM; Keychain stores only the symmetric key, not the JSON store contents.
- Store APIs stayed source-compatible and DI-friendly by adding defaulted `encryption:` constructor parameters and changing only the private read/write serialization paths.
- Legacy plaintext migration was implemented instead of clean-slate unreadability, because it was low-cost and avoids losing developer test data accumulated across branches #1-6.
- Local data deletion intentionally does not delete the Keychain encryption key. This is data deletion, not a cryptographic reset/re-key flow; if a future branch needs "reset encryption identity," it should be a separate explicit action with its own warning.
- Local data deletion is intentionally not an `AgentOperation`, capability adapter, planner tool, or `AgentRunner` risk-gated action. It is a direct settings/privacy action on `AgentViewModel` with a native destructive confirmation dialog.
- Encrypted local-load failures must not be collapsed with `try?` into empty/default UI. Store APIs still return empty/default for missing files, but an existing file that throws during read/decrypt/decode is now treated as a user-visible local-storage problem; clipboard monitoring is stopped if clipboard settings cannot be loaded.
- `LocalStorageEncryption` must cache successfully retrieved key material in memory for the process lifetime. Re-reading Keychain on a timer path, especially clipboard-history polling every second in an unsigned development build, can create a repeating macOS Keychain prompt loop even when the user enters the correct password.
- `LocalStorageEncryption.shared` uses a test-process heuristic (`processName`/bundle path containing test markers or `XCTestConfigurationFilePath`) to supply a deterministic ephemeral test key under SwiftPM/XCTest. Production app/runtime defaults still use `LocalStorageEncryptionKeyManager` and Keychain. Future tests should prefer injected key managers rather than hitting the user's real login Keychain.
- The encrypted file format is versioned with the `SONNYENC1\n` prefix so a future file-format/key-rotation migration can distinguish encrypted-v1 bytes from legacy plaintext JSON.
- Persistent recent task history was not introduced. Branch #6's `PriorTaskContextStore` is deliberately memory-only, and creating a new persistent feature just to encrypt it would have been scope creep.

Known limitations / deferred scope:
- Exclusions and cached entitlement state are not implemented yet, so there is no local data to encrypt or delete for them on this branch.
- Persistent recent task history still does not exist; future memory/history branches should add their own encrypted store intentionally if they introduce one.
- Local data deletion removes Sonny's seven local store files only; it does not delete generated user artifacts in Desktop/Documents, the Keychain encryption key, `OPENAI_API_KEY` environment variables, or any future hosted account data.
- Backend security (§15.5), hosted secrets manager work, hosted auth/entitlements, billing, enterprise security (§15.6), SSO/SCIM, and admin policies remain later-branch work.
- No real OAuth tokens for Spotify/Apple Music and no entitlement credentials were persisted; this branch only creates the reusable Keychain pattern those future credentials should use.
Open questions for the next chat (required, write "none" if true): none.

Next branch: `feature/product-shell-shared-state` (§4A.1 shell only, §6.2, §6.3, §17.3), adding the shared-state product shell foundation so the menu-bar cockpit and future Command Center read/write one state layer instead of separate UI stacks.

--- Kickoff prompt for next chat (paste verbatim as the first message) ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/product-shell-shared-state
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §4A.1 shell only, §6.2, §6.3, §17.3

Just completed: feature/local-storage-privacy-foundation — Sonny now encrypts the seven existing local JSON stores at rest with AES-GCM, stores the symmetric local encryption key in Keychain, migrates legacy plaintext JSON on successful load, and exposes direct confirmed local data deletion in the existing Status panel.
Must preserve: encryption remains transparent to RoutineStore/WorkspaceStore/ClipboardHistoryStore/ClipboardHistorySettingsStore/SnippetStore/RecentArtifactStore/ShortcutRunHistoryStore callers; legacy plaintext JSON migration must still rewrite encrypted after successful load; existing encrypted files that cannot be decrypted/decoded must surface visible local-storage errors instead of presenting as empty/default state, while missing first-run files remain silent; the local encryption key must be cached in memory after first successful retrieval so polling paths do not repeatedly hit Keychain; local data deletion remains a direct settings/privacy action, not a planner/capability/AgentRunner-routed action; deletion removes local store files but not generated artifacts or the Keychain encryption key; `OPENAI_API_KEY` remains env-var-only; prior-task context remains short-lived, last-task-only, and non-persistent; instant commands still bypass only planner calls and continue through normal runner/risk behavior.
Known pitfalls to avoid repeating: Keychain stores only secrets/keys, not bulk JSON; do not add cryptographic key reset unless explicitly scoped as a separate destructive action; use injected key managers or the existing test-process fallback for storage tests rather than touching the user's real login Keychain; do not introduce a persistent recent-task-history store on branch #8 unless the product-shell scope explicitly requires it; branch #8 is the shared-state shell/Command Center foundation only, not billing/account/subscription/entitlement implementation.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.

### Branch: feature/product-shell-shared-state
Status: in progress
Date: 2026-07-13
Implementing agent: Codex
Reviewing agent: Claude

Status note (2026-07-14, resolved 2026-07-15): checkpoints 1-5 documented below are genuinely complete, tested, and were accurately "done" as originally scoped. But a same-day post-completion review found the built pages fall short of the wireframes in content depth and information architecture (not token-matching, which is accurate — see "Architectural decisions" below), and a founder/designer conversation surfaced two features bigger than UI polish that this branch's data model doesn't yet support: task-to-workspace association and routine scheduling. **Resolved in `feature/v1-strategy-replan`'s Phase 4 (2026-07-15): superseded, not reopened.** Branch 8 is frozen — no further commits land here, ever, including anything that might look like "just a small addition to an existing page." The follow-up work lands on `feature/command-center-depth-and-data-model` (branch 9) and `feature/routine-scheduling` (branch 10) in the roadmap table above. See `docs/sonny-founder-design-decisions.md` for the original findings.

Spec sections covered: §4A.1 continued (both surfaces still observe one shared `AgentViewModel`; task history is now part of that shared state, not a second independently-coded path). §6.2 complete for the subset the roadmap scoped to this branch: real, non-placeholder settings, privacy, stats, history, routines, and workspaces surfaces in the Command Center; account and Power Mode controls remain later-branch scope. §6.3A (Command Center): real Routines/Workspaces/Settings surfaces, and the "usage and impact stats" requirement fulfilled by the Insights dashboard, satisfying the "stats and activity principles" (track outcomes not surveillance, aggregate locally, let users delete history) through local-only computation over the encrypted store plus existing deletion coverage. §6.8 (Routines) and §6.9 (Workspaces): real list/run/open wiring with depth, spacing, and radius matched to the actual Figma wireframes. §6.12 (Permission Center): real, non-placeholder Settings > Privacy & Permissions readiness controls. §14.7 and §15.4: recent task history now exists as a real, encrypted, user-deletable local store, closing a gap explicitly deferred by branch #7. §17.3 partial: this branch covers the routines/workspaces, settings, and permission-center rows of that UI-surfaces checklist only; screen capture picker, Power Mode HUD, data inspector, account/billing, and the instant-utility surface remain explicitly out of scope for later branches. §6.3 (typed/voice/hotkey/selection input), listed for this branch in the original roadmap table, was not actually touched — input handling is unchanged from before this branch; noting this so the roadmap's original per-branch section guess and this entry do not silently disagree. Left partial: theme switching only implements Dark; Light and System are present in the UI as "Soon" placeholders, not functional — this is a deliberate v1 scope cut, not a spec requirement (the spec does not mandate multiple themes).

Files changed:
- `Sources/MacAgent/AgentActivityPresentation.swift`
- `Sources/MacAgent/AgentViewModel.swift`
- `Sources/MacAgent/AppDelegate.swift`
- `Sources/MacAgent/AppWindowCoordinator.swift`
- `Sources/MacAgent/CommandCenterView.swift`
- `Sources/MacAgent/ContentView.swift`
- `Sources/MacAgent/Resources/Fonts/Inter-VariableFont_opsz,wght.ttf`
- `Sources/MacAgent/Resources/Fonts/OFL-Inter.txt`
- `Sources/MacAgentCore/LocalDataDeletionService.swift`
- `Sources/MacAgentCore/TaskHistoryInsights.swift`
- `Sources/MacAgentCore/TaskHistoryStore.swift`
- `Tests/MacAgentCoreTests/LocalStorageSecurityTests.swift`
- `Tests/MacAgentCoreTests/TaskHistoryInsightsTests.swift`
- `Tests/MacAgentTests/AgentViewModelLocalStorageTests.swift`
- `Tests/MacAgentTests/ProductShellTests.swift`
- `docs/sonny-design-system-reference.md`
- `docs/sonny-v1-implementation-changelog.md`

Tests: `env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib` -> pass, 204 tests in 24 suites.

Behavior added:
- Rebranded the entire main-app design system from a placeholder warm/cream/serif palette to the actual Figma-matched palette (near-black backgrounds, `#5C84FE` accent, Inter typography), replacing every `SonnyTheme`/`SonnyType` token used across Tasks, Insights, Routines, Workspaces, and Settings.
- Wired Routines and Workspaces to real saved-item data in the Command Center (previously static placeholders), including run/open dispatch through the existing `RoutineStore`/`WorkspaceStore` APIs, plus depth/spacing/radius fidelity matched to the wireframes and a "Create workspace" ghost card in the wireframe's specified position.
- Authored `docs/sonny-design-system-reference.md`, documenting two distinct design systems: System A (main app — flat, opaque, Inter, zero shadows) and System B (floating widget + system notifications, not yet built — translucent "Liquid Glass" material, SF Pro, real multi-pass shadows, distinct per-action accent colors), built from direct Figma wireframe SVG and CSS exports rather than inference.
- Wired real Settings controls: a functional "Use pointer cursors" preference applied via `NSCursor.push()/.pop()` across all shared button styles, persisted through plain injected `UserDefaults` (deliberately not the encrypted store — see pitfalls below), and an Interface theme selector (Dark functional; Light/System marked "Soon").
- Added `TaskHistoryStore`, an eighth encrypted local store recording real task completions (command, start/completion timestamps, outcome status), following the same DI, encryption, and legacy-plaintext-migration pattern as the other seven stores, and wired into the existing `LocalDataDeletionService` file list.
- Added `TaskHistoryInsights`, pure/stateless aggregation logic (no internal `Date()` calls, fully deterministic) computing a Monday-start week-scoped completion count, completion rate, average completed cycle time, a 7-day per-day completion count array, a current-streak day count with a one-day grace period, and full previous-week stats for delta presentation.
- Replaced the Insights placeholder with a real dashboard: four stat cards (completed this week, completion rate, avg cycle time, current streak), a 7-day completion bar chart, and a recent-activity list, all reading `viewModel.taskHistoryRecords`. Added a matching "Recent task history" list to the Tasks page below the live task area.
- Fixed a real approval-visibility bug: commands started from Routines or Workspaces that required approval showed no visible prompt anywhere on those pages, forcing the user to guess to switch to Tasks. A shared `CommandCenterTaskActivitySurface` wrapper around the existing `AgentTaskActivityView` now renders on all three pages behind the existing `viewModel.hasTaskActivity` check.
- Fixed a real UX bug found in this branch's own testing: current streak reset to 0 the instant a new calendar day began, even after a real consecutive-day streak, before the user had any chance to act that day. Added a one-day grace period (streak only breaks after a full day passes with zero completions, matching Duolingo/GitHub-style streak conventions) and a `hasCompletedToday` field so the UI can distinguish "Active today" from "Keep it going today" instead of collapsing both into one binary state.
- Fixed a real error-messaging bug found in this branch's own review: a task-history *write* failure was surfacing the encrypted-local-data *load*-failure banner ("Sonny could not load encrypted local data... could not be decrypted or decoded"), which would misleadingly tell the user their existing history was corrupted when actually one new record just failed to save. Now sets an accurate, dedicated `errorMessage`, matching the existing save-failure precedent in `applyClipboardHistoryNoticeChoice`.
- Fixed a real narrow-window layout bug: Settings control rows (e.g. "Interface theme") wrapped character-by-character vertically below a certain window width. Added `SettingsAdaptiveControlRow`, a `ViewThatFits`-based row that falls back to a vertical stack instead of wrapping, applied to the pointer-cursor, theme, and delete-data rows.

Behavior preserved (required, no blanket claims):
- Routine save/load/run and workspace save/load/open still route through the same `RoutineStore`/`WorkspaceStore` public APIs used before this branch; only presentation changed, not dispatch logic.
- All seven pre-existing encrypted local stores (routines, workspaces, clipboard history, clipboard history settings, snippets, recent artifacts, Shortcut run history) remain encrypted at rest and unaffected by the new eighth task-history store; the full local-storage security suite, including raw-byte plaintext-absence checks, still passes.
- Local data deletion still deletes exactly the local store files (now eight, including task history) and still tolerates already-missing files.
- Clipboard history monitoring/filtering, snippet save and expansion, prior-task follow-up context (10-minute, last-task-only, non-persistent), and Shortcut run-history demotion are untouched by this branch and remain covered by their existing tests.
- The popover and Command Center continue to observe the same shared `AgentViewModel` instance per §4A.1; this branch added new published state (`taskHistoryRecords`, `usePointerCursors`) to that same shared instance rather than introducing a second state path for either surface.
- Dry-run mode continues to bypass the real execution/approval pipeline exactly as before; this branch changed where the approval surface renders, not dry-run semantics or the approval pipeline itself.
- Instant vs. planner-routed command handling, risk tiers, and the approval gate itself are unchanged; only their visibility on Routines/Workspaces pages was added.

Architectural decisions / pitfalls discovered (required, write "none" if true):
- The Figma MCP connector on the Starter plan is capped at 6 tool calls per month *total*, shared across every connection to the same Figma account (both the Claude and Codex connections draw from one pool). It was exhausted early in this branch and does not reset within any realistic session. Manual SVG export plus Figma's "Copy as CSS" proved more precise than the MCP anyway (exact shadow recipes, exact hex values) and should be the default data-gathering method for future wireframe-fidelity work, not a fallback.
- When exporting Figma frames manually: uncheck "Outline text" (checked, text exports as unreadable vector paths) and check "Include 'id' attribute" (preserves layer names). Select the specific component layer, not the outer desktop-mockup wrapper — a wrongly-scoped export produced a 39MB file (embedded wallpaper bitmap) versus 40KB for the correctly-scoped one.
- There are two genuinely different design systems, not one with variants: System A (this branch's territory: main app surfaces, flat/opaque, Inter, zero shadows anywhere) and System B (branch #11's territory — renumbered 2026-07-15, see roadmap notes: floating widget + system notifications, translucent "Liquid Glass" material with real multi-pass shadows, SF Pro/SF Pro Display, distinct per-action accent colors, radius 34px for the widget vs. 20px for notifications — not the same value). Branch #11 must read `docs/sonny-design-system-reference.md` before writing any UI code; System A tokens (`SonnyTheme`/`SonnyType`/`SonnyRadius` in `ContentView.swift`) do not apply there.
- Streak/week-boundary date math is easy to get subtly wrong; it was hand-traced against every test fixture in this branch, not just left to pass/fail on the test suite. Week boundaries are `[Monday 00:00, next Monday 00:00)`, half-open, via a `(weekday + 5) % 7` days-since-Monday formula. Current streak requires either today or yesterday to have a completed record to stay alive (one-day grace period), and breaks only once both are empty — do not regress this back to "today only" without deliberately re-deciding the UX tradeoff documented above.
- `recordLocalStorageLoadFailure` is reserved specifically for load/decrypt failures on an existing file; its banner text is hardcoded to say a local data file "could not be decrypted or decoded." Any *write*-path failure on any of the eight local stores must use a distinct, accurately worded `errorMessage` instead (see `applyClipboardHistoryNoticeChoice` for the established pattern). Reusing the load-failure banner for a write failure was a real bug introduced and caught within this same branch.
- Any new Command Center page that includes the command composer/dispatch surface must explicitly render `CommandCenterTaskActivitySurface` behind `viewModel.hasTaskActivity`, or approval prompts for commands started from that page will be invisible with no error and no indication anything is wrong. This is not automatic from adding a composer; it must be added per page.
- The pointer-cursor preference is intentionally plain `UserDefaults`, not routed through `LocalStorageEncryption`. It is a cosmetic preference with no privacy sensitivity, and the encrypted-store system has already caused two real bugs this project; do not add unnecessary stores to it. Its read must use `object(forKey:) as? Bool ?? true`, not `.bool(forKey:)`, or new users would incorrectly default to the preference being off.
- `ViewThatFits` (horizontal candidate first, with a `minWidth` floor on the label, falling back to vertical) is the established fix for label+control settings rows that need to survive a narrow, non-fullscreen window. Reuse `SettingsAdaptiveControlRow` for any future settings row rather than a fixed `HStack`.

Known limitations / deferred scope:
- The floating widget and system-notification surfaces (System B) do not exist in code at all yet; this branch only documents their design tokens. That is entirely branch #11's scope (renumbered 2026-07-15, see roadmap notes).
- Theme switching only implements Dark; Light and System are visible but inert ("Soon").
- The instant-utility quick-results-list wireframe still does not exist (missing since branch #5), and the Claude-style-vs-ChatGPT-style trimmed-menu-bar product decision is still unresolved. Both block branch #11 (renumbered 2026-07-15, see roadmap notes) from being properly planned, not just built.
- No account/subscription/billing/entitlement work was touched; out of scope for this branch as before.

Open questions for the next chat (required, write "none" if true):
- Who/how will the instant-utility quick-results-list wireframe get created before branch #11 (renumbered 2026-07-15, see roadmap notes) needs it?
- Is the floating widget's trimmed menu-bar treatment Claude-style or ChatGPT-style? This should be decided before branch #11 (renumbered 2026-07-15, see roadmap notes) UI work starts, not mid-branch.

Next branch: **superseded — do not start `feature/floating-command-widget` from this pointer.** The actual next branch is `feature/command-center-depth-and-data-model` (branch 9 in the roadmap table above), per `feature/v1-strategy-replan`'s Phase 4 resolution (2026-07-15). The kickoff prompt below for `feature/floating-command-widget` remains valid content for whenever that branch (now branch 11 in the revised roadmap) actually starts — it was not discarded, just resequenced — but it is not the immediate next branch.

--- Kickoff prompt for next chat (paste verbatim as the first message) — SUPERSEDED, see note above before using ---
Repo: /Users/sauranshbhardwaj/Desktop/macos-agent
Spec: docs/sonny-major-release-spec.md
Changelog: docs/sonny-v1-implementation-changelog.md — read the latest entry before anything else. Do not trust memory or assumptions over it; verify against current git state.

Branch: feature/floating-command-widget
Implementing agent: Codex  Reviewing agent: Claude
Primary target: §6.3A (menu-bar cockpit), §4A.1 (shared state layer); visual spec authority is `docs/sonny-design-system-reference.md` System B, not the prose spec.

Just completed: feature/product-shell-shared-state — the main Command Center app (Tasks, Insights, Routines, Workspaces, Settings) now matches the real Figma wireframes' System A design (flat/opaque/Inter/zero-shadow), reads real persistent task history for a working Insights dashboard, and shares one `AgentViewModel` across both surfaces including the new task-history state.
Must preserve: shared-state architecture (both surfaces observe one `AgentViewModel`, no independently-coded second state path); all eight encrypted local stores and their deletion coverage; the one-day streak grace period and its exact break condition; `CommandCenterTaskActivitySurface` on every page with a composer; System A tokens must not leak into System B surfaces or vice versa.
Known pitfalls to avoid repeating: do not assume Figma MCP tool calls are available — check quota first, default to manual SVG/CSS export; System A and System B are not variants of one system, don't reuse System A tokens for the widget; do not reuse `recordLocalStorageLoadFailure` for write-path failures on any store; any new page with a composer needs its own explicit `CommandCenterTaskActivitySurface`; do not start UI work until the instant-utility quick-results-list wireframe exists and the menu-bar-trim style decision is made.

Start in plan mode. Confirm git status is clean on main, confirm the changelog's account of the prior branch still matches the current code, then produce an implementation plan before editing anything. Do not commit, push, merge, or open a PR without explicit approval.
