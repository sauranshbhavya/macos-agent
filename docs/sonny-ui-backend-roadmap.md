# UI updates owed to future backend work

Written 2026-07-20, after the floating-widget (System B) + notifications branch
(`feature/ui-ux-wireframe-fidelity`) brought Command Center and the widget to a stable baseline
against their wireframes. Where `docs/sonny-ui-backend-gaps.md` looks *backward* (UI that's already
built with no real data behind it yet), this file looks *forward*: for each piece of backend work —
already shipped or still on the roadmap — it states the specific UI update that needs to land
alongside it, and where in the code that update belongs. The goal is that a branch doing backend work
doesn't have to rediscover "oh, and the UI needs to change too" mid-implementation; it's already
scoped here.

Branch numbers below match the ones already in use in `docs/sonny-v1-implementation-changelog.md`
and `docs/sonny-ui-backend-gaps.md` as of this writing — the roadmap has been renumbered before, so
confirm the actual target branch at implementation time rather than trusting a number here.

## Dry-run preview for pure computations

**Backend:** `docs/sonny-ui-backend-gaps.md`'s "dry-run mode gives a generic message" gap — a
per-capability dry-run preview (e.g. `CalculatorCapabilityAdapter` actually computing and returning
the real answer under dry run, since evaluating `2*2` has no side effect worth gating).

**UI update owed:** once a capability can report a real dry-run preview value instead of nothing,
`AgentViewModel.performStart`'s dry-run branch (`Sources/MacAgent/AgentViewModel.swift`) needs to
prefer that real preview text over the current hardcoded "Dry run complete. No files were written…"
string. That flows automatically into both places `finalSummary` renders (Command Center's own
result display and `WidgetResultPanel` in `Sources/MacAgent/FloatingWidgetView.swift`) — no separate
per-surface UI work needed once the string itself is real, but worth a visual check that a longer
real answer still reads well in both the width-472 widget panel and Command Center's own layout.

## Incremental per-step execution status

**Backend:** `docs/sonny-ui-backend-gaps.md`'s stepStatuses gap — `AgentActionExecutor.executeChain`
(and the single-capability `execute` path) reporting per-step-id completion via callback as each
segment actually finishes, instead of `markAllSteps(.running)`/`markAllSteps(.complete)` around the
whole run.

**UI update owed:** structurally, none — `WidgetWorkingPanel`/`WidgetStepRow`
(`Sources/MacAgent/FloatingWidgetView.swift`) already render whatever `stepStatuses` says, row by
row, reactively. What *is* owed is a visual pass once real incremental updates exist: confirm the
row-by-row spinner-to-checkmark transition actually reads smoothly in practice, not just in theory —
`.animation(_:value: widgetStateKey)` on `FloatingWidgetView.body` currently only re-triggers on
top-level state changes (idle → working → result, etc.), not on `stepStatuses` mutating within
`.working`. If per-step transitions look like a hard cut rather than an animated one once real data
drives them, add a second `.animation(value:)` keyed off a cheap hash/count of `stepStatuses`.

## Routine run-history and streak badge

**Backend:** branch 10 (`feature/routine-scheduling`) adding real run-count/last-run-date/streak
tracking to `StoredRoutine` (`Sources/MacAgentCore/AutomationStores.swift`), which doesn't exist at
all today — see `docs/sonny-ui-backend-gaps.md`'s "Routines row streak/step-count badge" gap.

**UI update owed:** once a routine has real per-run history to compute a streak from, add the yellow
(`#F2BE00`) dot + number badge to `RoutineRow` in `Sources/MacAgent/CommandCenterView.swift` — the
`Spacer(minLength: 14)` immediately before the `Run` button is the wireframe-mapped slot, already
reserved and empty for exactly this.

## Routine real scheduling

**Backend:** branch 10 — a defined run time, enabled/disabled toggle, and cadence grouping for
routines, none of which exist yet.

**UI update owed:** `RoutineRow`'s current `Run` button (`Sources/MacAgent/CommandCenterView.swift`)
is an explicit temporary affordance — the wireframe's own row has no Run button at all; that slot is
reserved for schedule-time text + an enabled/disabled toggle. Swap it out once real scheduling data
exists rather than layering the toggle in alongside the button.

## AI-generated command titles

**Backend:** an LLM call to summarize a long typed command into a short title (like a chat app
auto-titling a new conversation), plus a new persisted field on `CompletedTaskRecord`
(`Sources/MacAgentCore/TaskHistoryStore.swift`) to hold it so it isn't re-generated on every render.
Needs a decision on synchronous-at-completion vs. lazy generation first.

**UI update owed:** `TaskHistoryRow` and `InsightsRecentActivityRow`
(`Sources/MacAgent/CommandCenterView.swift`) currently display
`command.sentenceCapitalized.truncatedForRowDisplay()` — real, display-only interim fixes, not a
summary. Once a real generated title is persisted, both rows need to prefer it over the raw command
text. If generation ends up lazy/async rather than synchronous-at-completion, the rows also need a
transient "titling…" state (or just fall back to the current truncated-raw-text treatment) for the
window between a task completing and its title actually landing.

## Persisted result/output text for completed tasks

**Backend:** a new field on `CompletedTaskRecord` (plus the usual encrypted-store migration, per
`LocalStorageEncryption`'s existing pattern) to persist the real result/output text
(`AgentViewModel.finalSummary`) at completion time — today it's only live in memory while a task is
active or just finished, then gone.

**UI update owed:** `TaskLogDetailDialog` (opened from any row in the Tasks page's Done/Canceled/
Failed list, in `Sources/MacAgent/CommandCenterView.swift`) currently shows command, status,
timestamps, and workspace — a receipt. Once the real output text is persisted, add a section to that
dialog rendering it, matching how `WidgetResultPanel` presents `finalSummary` live in the widget.

## Settings → Usage real aggregation

**Backend:** `TaskUsageRecorder` (branch 6, `Sources/MacAgentCore/`) already records approximate
per-task token/cost usage, but nothing aggregates it, and there's no credits/billing system (branch
13) to weigh it against yet.

**UI update owed:** `SettingsUsagePage` (`Sources/MacAgent/CommandCenterView.swift`) ships as an
honest empty-state placeholder today. Needs both real aggregation logic and a product decision on
what to actually show (raw token counts? cost estimate? request count over time?) before it can show
real numbers — don't build the display ahead of that decision.

## Settings → Notifications real preferences

**Backend:** none yet, and possibly none ever — Sonny uses native macOS notifications
(`docs/sonny-founder-design-decisions.md`), so there may be nothing to configure. A product decision
is needed on whether specific events (which ones notify, which don't) become user-configurable.

**UI update owed:** `SettingsNotificationsPage` (`Sources/MacAgent/CommandCenterView.swift`) stays an
honest empty-state until that decision is made. If it lands, this page gets real toggles — do not
build placeholder controls ahead of the decision.

## Accounts/auth system (branch 13)

**Backend:** no accounts/auth system exists yet at all.

**UI update owed, in one shot once this lands:**
- `ProfileDialogView` — currently an honest "Not designed yet" placeholder; needs its real design
  once there's real direction on what a Sonny profile is.
- The account row (`Sources/MacAgent/CommandCenterView.swift`) — currently shows only
  `NSFullUserName()`, no email/plan badge, since there's no account data to show one.
- The explicitly-not-built account-menu rows — Language, Upgrade plan, Get apps and extensions, Gift,
  View changelog, Log out — none exist even as disabled placeholders today (per explicit prior
  instruction not to fake them). These become real once there's a real account/session to act on.
- Unlocks the billing-context half of Settings → Usage above.

## "Data Sent to AI" inspector (branch 14, `feature/screen-intelligence`)

**Backend:** no context-bundle capture exists anywhere in the codebase yet (§6.13/§14.5 of the spec).

**UI update owed:** there is no reserved slot for this anywhere in Command Center or the widget
today — unlike the routine streak badge, this isn't a matter of filling in an empty spot. Before or
alongside that branch's backend work, decide where this surfaces: a Settings tab, a per-task section
in `TaskLogDetailDialog`, or something inline in the floating widget's result panel. Worth deciding
early since it changes what the backend capture needs to expose (a single bundle per task vs.
something queryable after the fact).

## Tasks page search

**Backend:** none — no search index, no query path against `TaskHistoryStore`
(`Sources/MacAgentCore/TaskHistoryStore.swift`) records.

**UI update owed:** the search icon in `TasksToolbarRow` (`Sources/MacAgent/CommandCenterView.swift`)
is a real, intentionally-kept requirement with nothing behind it. Needs both the backend query path
and a UI decision — inline filtering of the existing list vs. a dropdown of matches vs. a dedicated
results view — before implementation, since that shapes what the query path needs to return (full
records vs. ranked snippets).

## Command Center's own missing permission/clarification/failure UI

**Backend:** not backend work itself, but directly relevant to any backend work that can trigger a
task without the floating widget being the surface that's actually in front of the user —
scheduled/background routine execution (branch 10) is the clearest case.

**Current state:** today, `.permission`/`.clarification`/`.failure` are only ever actionable/visible
through the floating widget (`FloatingWidgetView.showsPanel` leaves these three states ungated
specifically because Command Center's own `CommandCenterRunningIndicator` deliberately shows none of
them — see its doc comment in `Sources/MacAgent/CommandCenterView.swift`). The system-notification
fallback that's supposed to cover "user isn't looking at the widget" is currently unreachable in
practice, and — per direct decision, 2026-07-20 — will stay that way: the widget is a permanent
on-screen overlay by design, no dismiss/hide action is being added, and notifications are accepted as
effectively unused for now (see `docs/sonny-ui-backend-gaps.md`'s "notification fallback path is
currently unreachable" finding for the full reasoning).

**UI update owed:** because the notification-fallback route is now off the table by that decision,
whichever branch ships scheduled/background execution has exactly one option, not an either/or: build
Command Center its own real, native surface for permission/clarification/failure. A routine running
unattended has no widget being watched and no working notification fallback — without a
Command-Center-native surface for these three states, an unattended run that needs approval or fails
would be silently stuck/invisible. This is a hard prerequisite for background execution being usable
at all, not a nice-to-have polish item.

## Workspaces' persistent "active workspace" concept

**Backend:** none, by deliberate choice — see `docs/sonny-ui-backend-gaps.md`'s "Skipped by explicit
decision" section for the full reasoning (risk of silently mis-tagging tasks to the wrong workspace,
plus new shared cross-surface state once the floating widget exists).

**UI update owed:** none unless this is deliberately revisited. If it ever is, the green "Active"
badge and "Open" vs. "Switch" button branching (`13-MainAppWorkspaces.svg`) and the Tasks page's
"Personal" scope pill (`9-MainAppHomeScreen.svg`) are the two wireframe elements waiting on it — both
already identified, neither built. Needs a real design for what "active" means and how it's
set/cleared before either gets built, not just the visual badge.
