# UI/UX pass — backend gaps

Written during the `feature/ui-ux-wireframe-fidelity` branch: a UI-only pass rebuilding the Command
Center to match `/Users/sauranshbhardwaj/Desktop/wireframes/` (PNG/SVG/CSS exports) exactly, per
explicit instruction to ignore `docs/sonny-design-system-reference.md` and
`docs/sonny-founder-design-decisions.md`'s interpretive overrides and match the literal wireframe
files everywhere. That branch did not touch backend/data-model code. This file lists every wireframe
element that either (a) got built visually with no real data behind it yet, or (b) was deliberately
*not* built because there's no defensible real value to show — so a future backend-focused session
knows exactly what's still owed, instead of having to re-diff the wireframes from scratch.

## Not built: real system notifications for approval/permission requests

**Major, load-bearing gap — read this before touching approval UI on any Command Center page.**

Per direct instruction (2026-07-18, Routines page review): the rich inline
Plan/Preview/step-log/Approval surface that used to render on Tasks/Routines/Workspaces whenever a
command was running was "not at all" what was wanted there — "logs + summary + activity should
just be a flow as to how that thing worked under the hood, that's it." It's been replaced
(`CommandCenterRunningIndicator` in `Sources/MacAgent/CommandCenterView.swift`) with a single
compact line (spinner + command text + Cancel), no approval controls, no step breakdown.

**Where approval/permission requests are supposed to go instead:** a real macOS system
notification, top-right corner — the user pointed directly at this being already specified in the
wireframes: `/Users/sauranshbhardwaj/Desktop/wireframes/Sonny UI PNG/1-PermissionNotification.png`
and `2-ErrorNotification.png` (System B — see `docs/sonny-design-system-reference.md` §3 for the
liquid-glass token recipe both of these use). **This does not exist in the codebase at all today.**
No `UNUserNotificationCenter`/`NSUserNotification` integration, no notification-posting code
anywhere in `Sources/`. Building it needs: real macOS notification permission request/handling,
posting a notification when `AgentViewModel.approvalRequest` becomes non-nil (and for permission-
readiness failures), and — this is the hard part — a way for the user to actually act on it
(Approve/Deny) from *within* the notification itself (macOS notification action buttons) or by
clicking through to the app. Matching the wireframe's two exact visual states is System B work,
same design system as the not-yet-built floating widget (branch 11 in the old roadmap numbering).

**What still works in the meantime, so this isn't a hard functional gap today:** the menu-bar
popover (`ContentView.swift`'s `AgentTaskActivityView`, untouched by this UI pass, out of its
Command-Center-only scope) still renders the full step log, Plan/Preview, and a real
Approve/Deny `ApprovalPanel`. Both surfaces observe the same shared `AgentViewModel`, so a
command started from the Command Center that needs tier-2+ approval can still be approved or
denied — just by opening the popover, not from whichever Command Center page it was started on.
**This is a real, known UX regression to call out, not a hidden one**: there is currently zero
indication *on the Command Center pages themselves* that something is waiting for approval beyond
the compact line's "Waiting for approval: ..." text — no prompt to go check the popover. Once real
notifications exist, that becomes the actual fix; until then, whoever picks this up should decide
whether a temporary "check the menu bar" hint is worth adding to the compact indicator.

## Not built: persisted result/output text for completed tasks

The new `TaskLogDetailDialog` (click any row in the Tasks page's Done/Canceled/Failed list) shows
command, status, timestamps, and workspace — a "receipt," not a narrative. `CompletedTaskRecord`
(`Sources/MacAgentCore/TaskHistoryStore.swift`) has never persisted the actual result/output text
(e.g. "created workspace X with 3 apps," a generated file path, a research summary) — only the
pass/fail signal. `AgentViewModel.finalSummary` has this text *live* while a task is active/just
finished, but it's never written into the historical record, so it's gone by the time someone opens
an old entry's detail dialog later. If a richer "what did it actually produce" view is wanted here,
`CompletedTaskRecord` needs a new field (plus encrypted-store migration, following the same pattern
as every other field addition to this struct) to persist that text at completion time.

## Not built: Routines row streak/step-count badge

Wireframe (`11-MainAppRoutines.svg`): every routine row has a yellow (`#F2BE00`) dot + number
between the row body and the trailing schedule-time/toggle slot. The SVG layer is literally named
`streak` — **not** step count. `CLAUDE.md`'s own "Non-obvious gotchas" section already documents a
prior mistake of wiring this badge to `routine.steps.count`, which is wrong on its face (a routine's
step count doesn't decay/reset the way a streak does).

`StoredRoutine` (`Sources/MacAgentCore/AutomationStores.swift`) has no run-count, last-run-date, or
streak field at all today — there is no real per-routine execution history to compute a genuine
streak from. Building the badge now would mean either repeating the known step-count mistake or
fabricating a number with no real meaning, so it was left off this pass rather than shipped wrong.

**What's needed:** a real per-routine run-history concept (at minimum: timestamps of past
runs/completions per routine name) that a streak can be computed from — this naturally lands
alongside branch 10 (`feature/routine-scheduling`)'s scheduling/execution-trigger work, since that
branch already needs to track when a routine last ran. Once that data exists, add the badge to
`RoutineRow` in `Sources/MacAgent/CommandCenterView.swift` (the `Spacer(minLength: 14)` right before
the `Run` button is the correct wireframe-mapped slot).

## Not built: AI-generated command summaries (like a chat app auto-titling a conversation)

Per direct user feedback (2026-07-18, Tasks/Home page review): a long typed command should get a
short, AI-generated title the way Claude/ChatGPT summarize a new chat's name — not just truncated
raw text. Two real interim UI fixes shipped in the meantime: displayed commands are now
sentence-capitalized (`String.sentenceCapitalized`) and word-boundary-truncated at 60 characters
(`String.truncatedForRowDisplay`, both in `Sources/MacAgent/CommandCenterView.swift`) wherever a
`CompletedTaskRecord.command` renders as a row title (`TaskHistoryRow`,
`InsightsRecentActivityRow`). Neither mutates the stored `command` value — display-only.

Real summarization needs an actual LLM call (cost/token implications — this project already tracks
per-task usage via `TaskUsageRecorder`, branch 6) plus somewhere to persist the generated title
alongside the raw command in `CompletedTaskRecord`/`TaskHistoryStore`, so it doesn't get
re-summarized on every render. Decide whether it happens synchronously at task-completion time (so
history always has a title) or lazily/on-demand.

## Not built: real content for Settings > Notifications and Settings > Usage

Per direct user feedback (2026-07-18): Settings moved out of the main sidebar into its own dialog
(`SettingsDialogView` in `Sources/MacAgent/CommandCenterView.swift`), opened from a new bottom-left
account row — following the Claude desktop app's account-menu pattern. The dialog now has 4
categories: Preferences (unchanged content), Notifications (new), Usage (new), Security & Access
(renamed from "Privacy & Permissions," same content — permission readiness + delete local data).

Both new tabs (`SettingsNotificationsPage`, `SettingsUsagePage`) ship as honest empty-state
placeholders — real copy explaining nothing's configurable yet, not fabricated controls or numbers.
What's actually needed once there's real product direction:
- **Notifications**: Sonny uses native macOS notifications (per `docs/sonny-founder-design-decisions.md`),
  so there may be nothing to configure here ever, or there may be real preferences to add later
  (e.g. which events notify). Needs a product decision, not an engineering guess.
- **Usage**: `TaskUsageRecorder` (branch 6) already records approximate per-task token/cost usage,
  but there's no aggregate summary anywhere and no credits/billing system (branch 13, not started)
  to weigh it against. A real Usage tab needs both real aggregation logic and a decision on what to
  actually show before billing exists.

Also not built: Language, Upgrade plan, Get apps and extensions, Gift Claude-equivalent, View
changelog, Log out — per explicit instruction, none of these exist in Sonny's account menu at all
(not even as disabled placeholders); the account row shows the macOS full name only
(`NSFullUserName()`, unconditional — no email/plan badge), since Sonny has no real accounts/auth
system yet (also branch 13 territory).

**Built as disabled placeholders (2026-07-18 round 3), real destinations still needed:**
- "Get help" (account menu) — should redirect to Sonny's own website help page once one exists.
- "Learn more" (account menu) — real destinations still needed: Documentation, Usage policy,
  Privacy policy, Terms of service, matching the "docs, usage policy, privacy policy, etc." the
  user named. **Round 6 (2026-07-18):** rebuilt as a real side flyout — "Learn more" itself is
  enabled and opens a second `.popover()` (`learnMoreFlyoutContent`, anchored `.leading`) listing
  all 4 items, matching the Claude reference screenshot's behavior. Each of the 4 items is still
  individually disabled pending real URLs.
- Both rows use `Sources/MacAgent/CommandCenterView.swift`'s `accountMenuRow` helper —
  `isEnabled: false` until real URLs exist, following the same pattern as the Settings theme
  dropdown's Light/System options.

**Real bug fixed (2026-07-18 round 5):** the account row's name text (`Text(profileName)`) never
rendered in the actual running app — only the avatar's initial letter showed, confirmed by the user
across two rounds (a `frame(maxWidth:)` fix in round 4 did not resolve it). Root cause: on macOS, a
native `Menu`'s custom label, when its first child is a composite icon-like view (a `ZStack`
combining a filled shape and overlaid text — the avatar), appears to get mis-extracted by
SwiftUI's AppKit bridging, silently dropping every sibling view after it. `SettingsThemeDropdown`
never hit this because its label is plain `Text`, no composite icon. Fixed by rebuilding the whole
account row as a plain `Button` + `.popover()` instead of `Menu` — a `Button`'s label always
renders exactly as authored, with no such native-representation ambiguity. Worth remembering if a
future `Menu` with an icon-shaped custom label silently drops content again: this is the same bug,
not a new one — switch to `Button` + `.popover()` rather than re-attempting frame/sizing fixes.

**Resolved (2026-07-18):** "Profile" is a real, clickable account-menu item (first in the list,
above Settings) that opens its own separate dialog (`ProfileDialogView` in
`Sources/MacAgent/CommandCenterView.swift`) — not a static header line, and not a tab inside the
Settings dialog. Its actual content is explicitly undecided ("I will need to plan what it does
later," per the user) — it ships as an honest "Not designed yet" placeholder, same close-X chrome
as Settings. Design this for real once there's real direction on what a Sonny profile even is
(no accounts/auth system exists yet either, so this is likely gated on branch 13 anyway).

## Not built: Tasks page search

Per direct user feedback (2026-07-18, Tasks/Home page review): the toolbar row's filter icon was
removed outright (no filter feature planned), but the search icon (`TasksToolbarRow` in
`Sources/MacAgent/CommandCenterView.swift`) is kept as a real, named requirement — search across
active/in-progress/completed tasks. Nothing behind it exists yet: no search index, no query
matching against `TaskHistoryStore` records, no UI for results. The user referred to this as
"branch #9" work; the roadmap has been renumbered multiple times already (see
`docs/sonny-v1-implementation-changelog.md`), so confirm the actual target branch at implementation
time rather than trusting that number.

## Skipped by explicit decision (not a gap — logged for completeness)

Per direct confirmation during the UI/UX audit (2026-07-18), these wireframe elements were
deliberately **not** built, so a future session shouldn't reintroduce them without re-confirming:

- **Workspaces' green "Active" badge + "Open" vs. "Switch" button branching** (`13-MainAppWorkspaces.svg`)
  and **Tasks' "Personal" scope pill** (`9-MainAppHomeScreen.svg`) — both imply a persistent
  "active workspace" session concept. This was raised again during this pass (the user's instruction
  to ignore backend concerns when building UI would have allowed building it visually with
  placeholder/local-only state), but the user chose to keep the prior engineering rejection instead:
  a persistent active-workspace concept risks silently mis-tagging one-off tasks to the wrong
  workspace — a real correctness problem for a stats feature — and introduces shared cross-surface
  state that could produce surprising behavior once the floating widget (branch 11) exists. If this
  is ever revisited, it needs a real design for what "active" means and how it's set/cleared, not
  just the visual badge.

## Existing, already-documented gaps (not new — carried forward from branch 9's own notes)

These were already known before this UI pass and remain unresolved; listed here only so this file is
a complete single reference rather than one of several partial ones:

- **Routines real scheduling** (defined run time, enabled/disabled toggle, cadence grouping) — branch
  10 (`feature/routine-scheduling`) territory. The Routines list's "Run" button was kept as a
  temporary affordance in this pass (explicit decision, 2026-07-18) since the wireframe's row has no
  Run button at all — that visual slot is reserved for schedule-time + toggle. Swap it out once real
  scheduling ships.
- **Settings**: the "System" label on the third interface-theme option is still an unconfirmed guess
  baked into shipped UI copy (`docs/sonny-design-system-reference.md` §5 open question #3) — the
  wireframe never renders this text anywhere in its export.
- **"Data Sent to AI" inspector** (§6.13/§14.5) — no context-bundle capture exists anywhere in the
  codebase; depends on branch 14 (`feature/screen-intelligence`).
