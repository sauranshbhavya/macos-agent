# UI/UX pass — backend gaps

Written during the `feature/ui-ux-wireframe-fidelity` branch: a UI-only pass rebuilding the Command
Center to match `/Users/sauranshbhardwaj/Desktop/wireframes/` (PNG/SVG/CSS exports) exactly, per
explicit instruction to ignore `docs/sonny-design-system-reference.md` and
`docs/sonny-founder-design-decisions.md`'s interpretive overrides and match the literal wireframe
files everywhere. That branch did not touch backend/data-model code. This file lists every wireframe
element that either (a) got built visually with no real data behind it yet, or (b) was deliberately
*not* built because there's no defensible real value to show — so a future backend-focused session
knows exactly what's still owed, instead of having to re-diff the wireframes from scratch.

## Resolved (2026-07-19): floating widget (System B) + real system notifications

The gap below this note described the state before the floating-widget phase. As of 2026-07-19
both are built:

- **Floating widget** (`Sources/MacAgent/FloatingWidgetView.swift`, `SonnyWidgetTheme.swift`,
  `FloatingWidgetWindowController.swift`) replaces the old menu-bar `NSPopover` entirely
  (`ContentView.swift`'s `ContentView`/`AgentTaskActivityView`/`ApprovalPanel`/etc. are deleted).
  The menu-bar icon (now icon-only, no title) and the existing Ctrl-Opt-Space push-to-talk hotkey
  both open it. It implements all 6 wireframe lifecycle states (§3.3) plus a best-effort 7th
  (clarification, no wireframe — see below), driven entirely by real `AgentViewModel` state: step
  rows from `plan.steps`/`stepStatuses`, the permission row from the real `approvalRequest`
  (tier-based risk approval, not a macOS system-permission prompt), the result card from real
  `finalSummary`/`suggestions` plus live `FileManager` attributes and the file's real `NSWorkspace`
  icon, and the failure row from the real `errorMessage`. Composited positioning inside the
  Command Center window (§3.4) is implemented but only repositions on state/visibility change, not
  continuously while the Command Center window is being dragged — a minor polish gap, not
  incorrect, just not live-tracked.
- **System notifications** (`Sources/MacAgent/SonnyNotificationService.swift`) are real native
  `UserNotifications` banners per `docs/sonny-founder-design-decisions.md` ("native macOS
  notifications for v1, not a custom overlay") — macOS renders the chrome shown in
  `1-PermissionNotification.png`/`2-ErrorNotification.png` itself; this class only supplies
  title/body/action (Allow / Retry) and routes the actions back to real `AgentViewModel` behavior
  (`start()` / `retryLastCommand()`). `AppDelegate` posts them only when neither the widget nor the
  Command Center window is currently visible/frontmost, so they're a fallback for "user is in
  another app," not a duplicate of the inline UI.

**New real gap this surfaced:** `AgentActionExecutor`/`AgentRunner` update `stepStatuses` coarsely
— `markAllSteps(.running)` before execution, `markAllSteps(.complete)` or `.failed` after, all at
once — not incrementally per step as a multi-step chain (e.g. a multi-step routine, or a
scan-then-zip pair) actually progresses. The wireframe's own Working state (`4-FloatingWidgetWorking.png`)
shows genuine row-by-row progress: one step checked off while the next spins. The floating widget
renders whatever `stepStatuses` actually says, so today a multi-step plan's rows visually jump
straight from all-pending to all-spinning to all-done/failed, rather than progressing one at a
time. Fixing this for real needs `AgentActionExecutor.executeChain` (and the single-capability
`execute` path) to report per-step-id completion via a callback as each segment finishes, not just
before/after the whole run — that's executor-layer work, out of scope for this UI-focused branch.

**Also surfaced, smaller:** §3's own open question #5 (exact SF Symbol identity of a few icon-only
buttons — mic, retry, Allow/Deny) was never resolved from the wireframe alone (no readable label,
inferred from convention/position). The widget currently uses `mic`/`mic.fill` (via
`viewModel.voiceButtonIcon`, reused from the same real voice-recording state the old popover used),
`arrow.clockwise` (retry), `xmark`/`checkmark` (Deny/Allow) — reasonable SF Symbol choices, not
confirmed pixel-identical to Figma's originals; worth a visual gut-check against the actual app.

**Clarification state (no wireframe):** `AgentViewModel.clarificationQuestion` is a real, reachable
state (the planner asking a follow-up question) that none of the 8 wireframes cover. Built as a
best-effort inline row matching System B's visual language (question text + an inline answer field
styled like a lighter-weight version of the compose pill), reusing the existing real
`submitClarification()` path — flagged here since, unlike every other state, there's no wireframe
to hold this specific design to.

**Also resolved as part of this same branch:** the clipboard-history consent notice
(`ClipboardHistoryNotice`, previously the *only* UI for `clipboardHistoryEnabled` anywhere, and
only ever rendered inside the now-deleted popover) is now a persistent toggle in Command Center's
Settings → Security & Access → "Clipboard History" section, wired through the same
`applyClipboardHistoryNoticeChoice()` method so it still both persists the choice and starts/stops
real monitoring, not just a cosmetic switch. This was a real regression risk this branch's own
restructuring would otherwise have caused (deleting the popover with no replacement UI would have
made a privacy-sensitive toggle permanently unreachable) — fixed directly rather than left as a gap.

**New gap surfaced (2026-07-20), resolved same day: the notification fallback path is currently
unreachable — by deliberate decision, not left open.**
`AppDelegate.isAnySonnySurfaceVisible` (`Sources/MacAgent/AppDelegate.swift`) gates every
`SonnyNotificationService` post on `widgetController.isVisible || commandCenterWindow?.isKeyWindow`.
`widgetController.hide()` is never called anywhere in the app (confirmed via a full-project grep) —
the widget opens on launch and just stays open; combined with its window being `.floating` level
with `.canJoinAllSpaces` and `.fullScreenAuxiliary` (`FloatingWidgetWindowController.makePanel()`),
it's genuinely on screen over every app and every Space at all times. That means
`isAnySonnySurfaceVisible` evaluates `true` in every real scenario, so the permission/error
notification posts this branch built — whose entire purpose was covering "user is in another app" —
are wired correctly but never actually fire under the app's current lifecycle. Not a crash and not
user-visible as broken (the widget's own inline UI genuinely does cover the same states instead),
but it means one of this branch's two headline deliverables ships as dead code today.

**Decision (2026-07-20, direct confirmation):** the widget stays a permanent on-screen overlay by
design — no dismiss/hide action is being added. Notifications are therefore accepted as effectively
unused in their current form; this is a known, documented tradeoff, not a silently-shipped gap (see
`docs/sonny-founder-design-decisions.md`'s "Notifications" section, which already frames the
native-notifications choice as "explicitly open to revisiting later, not permanent"). The real
consequence lands on future work, not this branch: scheduled/background routine execution (branch
10, `feature/routine-scheduling`) is exactly the future scenario where a task can need
approval/clarification/failure-reporting with no one actually watching the widget, and — since the
notification fallback isn't reachable and won't be made reachable by adding a dismiss action — that
branch must give Command Center its own real, native surface for those three states rather than
relying on the widget or on notifications. See `docs/sonny-ui-backend-roadmap.md`'s "Command
Center's own missing permission/clarification/failure UI" entry for the specifics.

**Composited-position staleness, expanded beyond dragging:** the "not continuously tracked while
dragging" note above is one instance of a broader gap — `FloatingWidgetWindowController.reposition()`
only runs from `show()` or `contentFrameDidChange` (the widget's *own* content resizing); there's no
observer on the Command Center window's key status, move, or resize. So switching focus away from
Command Center to another app (or back), not just dragging the window, leaves the widget glued to
its last composited-vs-standalone position and pill-visibility state until something else happens to
trigger a reposition.

---

The original gap description follows, preserved for history/context:

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
liquid-glass token recipe both of these use).

## Not built: dry-run mode gives a generic message instead of a real preview

Surfaced 2026-07-20 while manually testing the floating widget: submitting `calc 2*2` with
Command Center's own Dry Run toggle on returns the same fixed string `AgentViewModel.performStart`
hardcodes for *every* dry-run command — "Dry run complete. No files were written, no apps were
opened, and no documents were converted." — regardless of what the command actually was. For a
calculator command this reads as broken (the user asked "what's 2×2," dry run answered "no files
were written," never mentioning 4), even though nothing is actually wrong: this is pre-existing
behavior, not something introduced or touched by the floating-widget work — `dryRun` only lives on
Command Center's own composer (the floating widget always bypasses it, per this project's earlier
"Always real, tier-gated" decision), and this generic string predates this branch entirely.

The real gap: dry-run mode's whole design only accounts for *side-effecting* operations (files
written, apps opened, documents converted) — it has no concept of previewing what a *pure
computation* (the calculator, and likely other read-only/no-side-effect operations) would actually
produce. A real fix needs either a per-capability dry-run preview (the calculator adapter computing
and showing the real answer even under dry-run, since evaluating `2*2` has no side effect worth
gating), or at minimum a message that doesn't imply nothing happened when the honest answer is "this
command has no side effects to preview, but here's what running it for real would produce." Worth
scoping alongside whichever branch next touches `CalculatorCapabilityAdapter`/`performStart`'s
dry-run branch in `Sources/MacAgentCore` / `Sources/MacAgent/AgentViewModel.swift`.

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
