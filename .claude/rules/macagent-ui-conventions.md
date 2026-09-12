---
paths:
  - "Sources/MacAgent/**"
---
# MacAgent (UI) conventions

`MacAgent` is the executable — the floating command widget (`FloatingWidgetView`, opened from the menu-bar icon or the push-to-talk hotkey) and the Command Center window. Both are views over one shared `AgentViewModel`. There is no menu-bar popover anymore — it was replaced entirely by the floating widget. Command Center's own command composer was later deleted too (`feature/ui-ux-wireframe-fidelity`, 2026-07-21) — the widget is now the *only* place to type or speak a command anywhere in the app; `ContentView.swift` now only holds shared System A tokens/components (`SonnyTheme`/`SonnyType`/`SonnyRadius`, button styles), not a view of its own.

## Shared state

The floating widget (`FloatingWidgetView.swift`) and the Command Center (`CommandCenterView.swift`) observe the *same* `AgentViewModel` instance — that's the whole point of the product-shell-shared-state work, carried forward when the widget replaced the old popover. New published state (a new local store's records, a new preference) gets added to that one instance. Never build a second, independently-coded state path for either surface, even for something that feels surface-local.

Because both surfaces render off the same state, a task submitted from either one is visible to both. `AgentViewModel.TaskOrigin` (`.commandCenter` / `.widget` / `.scheduled`) tracks what actually submitted the currently-active task, so the widget can tell its own task apart from one a Command Center row action submitted (`runRoutineWidget`/`openWorkspaceWidget`, both default to `.commandCenter` origin despite the "Widget" in their names) and avoid rendering a second, duplicate *progress* panel for the latter (`FloatingWidgetView.showsPanel`). Any new task-submitting entry point needs to pass its own real `origin` explicitly — it does not get inferred, and `dispatch`'s default is `.commandCenter`. (Corrected by SONNY-56: this used to read "progress/result". Only the progress half is live — `CommandCenterRunningIndicator` really does render progress for a Command-Center-originated run, so a widget progress panel would genuinely be a second one. There is no Command Center *result* panel for a widget result to duplicate, and a successful Command-Center-originated run's summary reaches no surface at all; it now posts a notification instead. Do not delete this paragraph, and do not "fix" the gap by passing `origin: .widget` from a row action — that would move progress into the widget while Command Center keeps showing its own.) `.scheduled` is the case a new entry point is likeliest to miss: the routine scheduler starts runs with nobody watching, and it is its own case so that the widget shows no progress panel for them while their permission/clarification/failure states still do surface, and so the task-history trigger keeps automated runs out of the Insights streak. (SONNY-175: this sentence listed two cases when there were three, and the one it left out was the unattended one.)

## Visual direction since 2026-09-08 (branch `ui-ux-claude`)

Every `SonnyTheme` token resolves against the window's appearance (a dark and a light reading each), and `SonnyAppearanceModel` sets the application's appearance from the Settings picker. So a view never asks which appearance it is in and never writes `Color.white` or `Color.black` for a surface or a text colour: it names a token, or `SonnyTheme.onSurface(dark:light:)` for a step the tokens lack. The floating widget's panel is pinned `.darkAqua` and its `WidgetTheme` literals stay white on purpose.

`SonnyTheme` / `SonnyType` / `SonnyRadius` are the system font on one cool-neutral ramp with a
three-value radius rule, plus `SonnySpacing`, `SonnyMetrics`, `SonnyMotion` and the shared controls
(`SonnyButtonStyle` with four tones and three sizes, `SonnyBadge`, `SonnyDialogHeader`,
`sonnyDialogFrame`, `sonnyPanel`, `sonnyCard`, `sonnyTextField`). A view writes no literal colour,
font size, radius or spacing; it names a token. `docs/sonny-ui-modernization-2026-09-08.md` is the
decision record. Where the section below says Inter, or names the routine detail sheet as a System
B copy inside System A, it is describing the state before that branch: the sheet is System A now and
`SonnyWidgetTheme.swift` is the only System B token set. Everything else in the section, the
two-system split above all, still holds.

## Design tokens — two separate systems, both in active use

`SonnyTheme` / `SonnyType` / `SonnyRadius` (defined in `ContentView.swift`) are System A: flat, opaque, Inter, zero shadows anywhere — used throughout Command Center. `WidgetTheme` / `WidgetType` (`SonnyWidgetTheme.swift`) are System B: translucent "Liquid Glass" material (a real `NSVisualEffectView` blur, not a blend-mode approximation of one), SF Pro/SF Pro Display, distinct per-action accent colors — used by the floating widget (`FloatingWidgetView.swift`) and system notifications (`SonnyNotificationService.swift`, though macOS renders that chrome itself). These are deliberately separate token sets, not variants of one another — don't extend `SonnyTheme` with glass/shadow properties, and don't reuse `WidgetTheme`/`WidgetType` outside the floating widget. See `docs/sonny-design-system-reference.md` for the full split, and `docs/sonny-founder-design-decisions.md` for at least one confirmed case (the routine detail view) that needs System B's material embedded inside a System A surface — a deliberate special case, not precedent for mixing the two generally. (`RoutineDetailView.swift` also keeps its own independent copy of the System B tokens for that case, rather than sharing `SonnyWidgetTheme.swift`'s — also deliberate, not an oversight.)

## Approval visibility

Command Center has its own permission/clarification/failure surface as of branch 10: `CommandCenterAttentionPanel` (`CommandCenterView.swift`), rendered unconditionally by every page that hosts `CommandCenterStorageNotice` and self-gating on its own state. It exists because a run can need a human while nobody is looking at the widget, and because at the time it was built the notification fallback could not fire — every post was gated on `isAnySonnySurfaceVisible`, permanently true once the widget became a permanent overlay. **That gate is gone**: SONNY-56 replaced it on 2026-08-17 with the founder's rule — notify when Sonny is not the app the user is working in — so notifications do fire now (`AppDelegate.isUserWorkingInSonny`, and `SonnyAttention` where the rule lives and is tested). The panel's own reason survives the repair intact, because a notification is suppressed precisely when the user *is* working in Sonny, which is exactly when this surface is the one they are looking at. (Corrected 2026-08-21 by SONNY-189; the same stale claim was corrected in `AppDelegate` by SONNY-113 and in `CommandCenterAttentionPanel`'s doc comment by PR #80's review, and this was the copy left behind in the file a session loads before every edit under `Sources/MacAgent/**`.) **It is not the case that a scheduled routine can leave an approval pending** — `performScheduledRun` executes with `approvalDecision: .approved(.tier2)` and routes every `RiskApprovalError` to `pauseSchedule` plus a notice (SONNY-31's ratified notify-and-pause design), so it never writes `approvalRequest` at all; the earlier wording here said an unattended run needing approval would otherwise be silently stuck, and that specific reachability does not exist. What does reach this panel is any foreground-started run's approval — including `performApproval`'s stale-approval re-arm — when Command Center is the surface the user is actually looking at. (Corrected by SONNY-64 / PR #40 review, F4, which traced the writers of `approvalRequest` after this sentence was inherited into that branch's own reasoning.) It mirrors `FloatingWidgetView`'s state precedence for the three states it has (permission > clarification > failure, failure only once the run stops) so the two surfaces cannot disagree about *which question wins*, and it is deliberately origin-agnostic — it renders whatever state exists without asking which surface produced it, so an approval reaches it whichever surface started the run. (That clause previously ended "so a scheduled run's approval reaches it", which is the same false premise corrected two sentences above and left this paragraph asserting a claim and its negation five sentences apart. A bounded edit that removes a premise has to remove it from the whole passage, not from the one sentence that stated it loudest.) `CommandCenterRunningIndicator` is still the separate, compact "something is running" line — render it per page by gating on `viewModel.isRunning || viewModel.isAwaitingApproval`.


### What a live screen-control session changes, on both surfaces (SONNY-255; the second surface, PR #132's F1)

**"The two surfaces can never disagree" was a claim about precedence and was read as a claim about panels, and the difference now matters.** Three things are true at once and the section above stated only the first:

1. **The precedence agrees.** Both surfaces put a permission above a clarification above a failure, and both show a failure only once the run has stopped.
2. **The widget's chain is longer, and must be.** It carries four screen-control states Command Center has no counterpart for — `.captureReview`, `.delegationReview`, `.sessionPaused` and `.controlling` — because a session's live controls belong on a permanent overlay rather than in a window that may be closed. `CommandCenterAttentionPanel` deliberately has no HUD.
3. **The widget's approval panel has two shapes**, and since PR #132 so does Command Center's. `WidgetPermissionPanel` and `permissionContent` each read `viewModel.visionSessionProgress` and render differently when it is non-nil. That is not a second approval surface: the request, the method that raises it and both answering entry points are the ordinary ones, and no surface is taught what a vision approval is.

**Why the second shape exists.** `.permission` outranks `.controlling` in the widget's chain (SONNY-255 — below it, an approval raised mid-session rendered on no widget surface for the whole length of every session, because `visionSessionProgress` is written at the top of every iteration and cleared only at session end). So while a question is parked the HUD is not the panel on screen, and row I's requirement that a session say what it is controlling — §13.4 — has to be met by whatever panel *is*. Both approval panels therefore carry the session's identity line and its step count while a session is live.

**The exits differ per surface, and each one is the same call with a word that says what it does.** Every door below ends in `cancelCurrentRun`; none of them is a second stop path.

| | no session live | session live |
|---|---|---|
| Widget, approval panel | ✗ cross (`onDeny` → `cancelCurrentRun`) and ✓ | **Stop** (`emergencyStopVisionSession`) and ✓ — no cross |
| Command Center, approval panel | "Deny" (`cancelCurrentRun`) and "Allow" | **"Stop"** (`emergencyStopVisionSession`, `.danger` tone) and "Allow" — no "Deny" |
| Widget, HUD (`.controlling`) | — | Pause and Stop |

**Why the refusal is relabelled rather than left alone.** Inside a session `cancelCurrentRun` ends *the whole session* rather than declining one step. An icon-only cross reads as "skip this step" and a button labelled "Deny" says it outright; both were the same claim, and `cancelCurrentRun`'s own doc comment calls that class of surprise the most expensive a program moving the user's real cursor can produce. Nothing about the behaviour changed on either surface — same call, same single press. When SONNY-80's standing note lands (a labelled "deny this step" that resumes the continuation without cancelling) it returns as a genuinely *different* control beside the Stop.

**Pause is the widget HUD's alone, and that is a reasoned departure from §13.4's list.** `pauseVisionSession` sets the attention monitor's flag, which the loop reads at the top of its *next* iteration — pressed while an approval is parked it freezes nothing, because the loop is already frozen on a continuation, and it would act only after the question is answered. A control that appears inert and then acts later is worse than one that is not offered.

**The words are shared; the views are not.** `ScreenControlSessionPresentation` (`AgentActivityPresentation.swift`) owns the identity line, the step line, the Stop's label and both accessibility names. The views cannot be shared — System B may not leave the widget and System A may not enter it, per the token section above — so the *sentence* is what has one owner. A hand-written copy on either surface is one session described two ways, and nothing in either file would catch it; `WidgetSessionApprovalPanelTests.bothSurfacesReadTheSessionsWordsFromOneOwnerAndNeitherHandWritesThem` is the scan that does.

**"Every page" is enforced rather than conventional as of SONNY-208.** `MemoryCommandCenterTests.everyCommandCenterPageRendersTheSharedAttentionAndStorageSurfaces` walks `CommandCenterDestination.allCases`, asserts the destination set and the scanned set are equal so a new page cannot arrive unchecked, and additionally asserts that neither self-gating surface sits inside the `isRunning || isAwaitingApproval` block — nesting a self-gating strip inside that conditional was a real shipped bug on the storage notice, and it is invisible to a check that only counts the token. Tasks is the one named exception, and only on the running surface: it renders `InProgressTaskGroup` under that same guard, the wireframe's own treatment, rather than the compact indicator.

**The HUD is origin-agnostic too, as of SONNY-299, and it was the one state that was not.** `hasVisibleWidgetPanel` had no `visionSessionProgress` term at all, so a live session with nothing parked on it fell through to the origin-gated `isRunning` branch and the widget rendered nothing — `state` resolved to `.controlling` and the panel that draws it was never on screen. Reachable rather than theoretical: `runTaskAgain` dispatches `origin: .commandCenter`, and a screen task run again from its Command Center row re-plans into a fresh session. The term is unconditional, and that is the decision rather than an origin gate left off — origin-gating the *working* panel is right because `CommandCenterRunningIndicator` already reports a Command-Center-origin run, and the HUD is not that kind of progress: it names the app and carries Pause and Stop, and `CommandCenterAttentionPanel` deliberately has no HUD for it to duplicate. So `.scheduled` needs no term either, and the reason is written at the branch: unattended screen control is refused three independent ways, and were one of those to move, showing the HUD is the answer this term should give anyway.

The floating widget is unchanged and still shows all three states for **every** task regardless of origin. That redundancy is deliberate, not an oversight: the widget is a permanent on-screen overlay while Command Center is a window that may be closed, so for an unattended run the widget is the more reliable surface for an approval, not the less. `AgentViewModel.hasVisibleWidgetPanel` is the single source of truth for both the widget's panel and the widget's own mic-hover-hint slot (`FloatingWidgetView.isMicHintSlotFree`). Do not origin-gate those three states without revisiting both. Until 2026-08-21 this named `FloatingWidgetWindowController`'s compositing decision as the second reader; that positioning mode was superseded on 2026-07-21, the controller has one mode, and nothing composites into Command Center anymore (SONNY-189). **"A regression test pins it" was checked rather than inherited while fixing that**, because the sentence read as though compositing itself were pinned: it is not, and cannot be — there is nothing left to assert. What is pinned is this predicate's value for the three attention states, by `CommandCenterAttentionSurfaceTests.widgetStillShowsAllThreeAttentionStatesForACommandCenterOriginTask` and `VisionSessionRunTests.theWidgetPanelIsVisibleWhileACaptureIsWaitingToBeReviewed`, with further assertions in `ConsequenceRuleDispatchTests`, `ScheduledRoutineRunTests`, `ClarificationExitTests` and `ResumableTaskRunTests` (`git grep -nE '#expect\(.*hasVisibleWidgetPanel' -- Tests/` → 29 assertion lines across 6 files at `372528e`). **That figure read 13 across 5 at `fef3684` until SONNY-299, and the difference is not drift in the sentence — it is the tree moving under a stamp that was complete when taken.** `fef3684` is 2026-08-21 and is non-ancestral today; the five files it named really were the whole population there, and `ResumableTaskRunTests.swift` did not exist yet. A stamped figure is true of the tree it was stamped on and of nothing else, so this is re-measured rather than adjusted — and the file list is re-enumerated with it, because a list of names goes stale the same way a count does and reads as complete either way.

## The run pill (SONNY-450)

While a run is in flight and the user has not expanded the widget since it started, the widget is
minimised into `RunPillView` in its own `RunPillWindowController`, pinned to the top-right of the
cursor's screen. The state is *derived* on the one view model — `AgentViewModel.isWidgetMinimised`
is "no expansion since the run started" and "there is a pill to show" — and the pill's words come
from `RunPillPresentation.make(state:command:)` over `AgentViewModel.widgetState`, which is the
widget's own state precedence hoisted off `FloatingWidgetView` so the two read one order. So a
parked question is "needs you" on the pill exactly when the widget would draw it and
`CommandCenterAttentionPanel` shows it; the pill answers nothing. Every summon
(`widgetPresentationRequest`) is an expansion, the pill's click included, and a minimised outcome
holds (`outcomeHolds`, the SONNY-121 hold widened) until then. The pill is System B and never a
`SonnyTheme` token; `RunPillPresentationTests` and `RunPillControllingTokenTests` scan for that.
There is one pill because there is one run; a pill per task is its own ticket.

**A live screen-control session minimises like any other run, and the pill is then the HUD**
(founder decision 2026-09-12, option B on PR #237's F1). This is the one pill state that carries
controls, and it exists because `WidgetControllingPanel`'s requirement — Sonny says it is
controlling, says which app, says what it is doing now, and puts Stop where the user can reach it —
is a product requirement rather than a courtesy, and minimising the widget would otherwise hide all
of it for the length of a session. So `RunPillPresentation.Kind.controlling` is its own kind, with
its own amber tint and cursor glyph, carrying the identity line, the action line, the step line,
Pause, Stop and the line naming `⌃⌥⎋`. Option A — a session that does not minimise at all — was
recommended by the coordinator and declined; the record is on SONNY-450.

The rules below are for anyone editing that pill, and each is something this repository has already
paid for once:

- **Controls must receive their own clicks.** The controlling pill is deliberately *not* wrapped in
  the ordinary pill's expand `Button`; the identity row is its own button and each control is its
  own button beside it. SONNY-443 shipped an overlay over the mic that claimed every point in its
  bounds, and the founders' clicks went nowhere while the button still looked live.
  `RunPillControlsReceiveClicksTests` sends real mouse events through a real, ordered-in
  `RunPillPanel` at every point of a 4 pt grid and records which action each one fires, so it tells
  Pause, Stop and the identity row apart from each other and from the glass around them; its control
  is SONNY-443's overlay, under which nothing fires. **Do not go back to `NSView.hitTest` for this.**
  It answers the hosting view at every point of a SwiftUI window, empty corner included, so it can
  only say no AppKit layer covers the window — which is all the first version of that suite could
  say (PR #237's delta review, N6). Two measured facts the sweep rests on: a panel that is **not**
  ordered in fires nothing anywhere, and a `.plain`-style button's clickable area is its *label*, so
  padding and height applied outside the button are dead — which is why the shared
  `WidgetSessionPauseButton` and `WidgetSessionStopButton` carry both inside the label with a
  `Capsule` content shape. **That click area is a capsule; what is drawn is a 28 pt circle**, so describe
  the control as a circle. And **anything drawn on top of a control ignores hit testing**: the hairline
  that traces every tinted widget button's edge took the clicks that landed on it, leaving a dead ring
  on the session's Stop that a 4 pt sweep could not see (PR #237's third delta review, B);
  `SharedSessionControlEdgeTests` sweeps at 0.5 pt for it. What no test here can see is the window
  server's handling of a first click on a panel that cannot become key; that is the manual row's.
- **Each control's action is pinned at its own site**, not counted across the pill
  (`RunPillControlBindingTests`). A count across the pill is satisfied by a swap, and swapping the
  actions behind Pause and Stop passed the whole suite until that suite existed.
- **One owner for the words, one view for each control.** Pause, Stop, their spoken names and the
  line naming `⌃⌥⎋` come from `ScreenControlSessionPresentation`; the widget's HUD, its approval panel
  and the pill render the same `WidgetSessionPauseButton`/`WidgetSessionStopButton`. A surface that
  spells one of them itself is a second copy nothing ties to the first.
- **The action line is measured, not eyeballed.** `RunPillPresentation.actionLimit` is laid out at
  the pill's real width in its real font with AppKit's own text layout
  (`RunPillControllingLayoutTests`), the instrument PR #228 used for the widget's Finder sentence.
- **A parked question still outranks the session**, as it always has: the pill goes to "needs you",
  the controls go with it, and answering happens in the widget. Nothing on the pill approves
  anything. While that question is parked the pill does not name the app or carry Stop — the
  widget's outranking panels do, the pill does not — and the hotkey stays live, so the way out
  survives even there.
- **Sonny will not act under its own pill, and the pill does not get out of the way.**
  `VisionPointResolver` refuses any click or scroll landing inside one of Sonny's visible windows,
  and the pill is one, so a corner of the controlled display is unreachable while the widget is
  minimised. The model cannot see the pill (its capture is the target window), so the refusal tells
  it what covered the point and names only routes its vocabulary can take
  (`VisionSessionRunner.ownWindowCoversThePoint`). Do not hide or move the pill to let an action
  through: the statement that Sonny is controlling this app must not disappear at the moment Sonny
  acts on it.

## Responsive rows

`SettingsAdaptiveControlRow` (a `ViewThatFits` horizontal-first, `minWidth`-floored, vertical-fallback pattern) is the fix for any label+control row that needs to survive a narrow, non-fullscreen window. Reuse it for new settings/control rows rather than a fixed `HStack` — a fixed `HStack` is what caused the narrow-width character-wrapping bug this pattern replaced.

## Preferences

A cosmetic, non-privacy-sensitive preference (e.g. pointer cursor behavior, the interface theme in `SonnyAppearanceModel`) goes through plain injected `UserDefaults`, not `LocalStorageEncryption` — don't add a new encrypted store for something with no privacy sensitivity. Read booleans with `object(forKey:) as? Bool ?? true`, not `.bool(forKey:)` — the latter silently defaults a missing key to `false`, which is wrong for any preference that should default to *on* for new users.

## Wireframe fidelity

Matching `docs/sonny-design-system-reference.md`'s exact colors/fonts/spacing/radius is necessary but has already proven *not sufficient* on this project — a fully token-accurate build still read as structurally thinner than the wireframes (missing grouping, missing metadata richness, missing whole sections). Before treating a page as matching its wireframe, check `docs/sonny-founder-design-decisions.md` for structural/content intent the static SVG doesn't fully capture, not just the token values.
