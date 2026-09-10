# `ui-ux-claude` work log

The running record of everything done on this branch, appended as each phase lands and pushed
with it. The decision record is `docs/sonny-ui-modernization-2026-09-08.md`; the per-branch
changelog entry is at the top of `docs/sonny-v1-implementation-changelog.md`; this file is the
diary, newest phase last. Every figure carries the head it was measured at.

The brief, from the founder on 2026-09-08: a free hand over the entire frontend of Sonny,
including the "soon" and pending designs, nothing outside the frontend touched, no questions
asked, and no comparison with the sibling `ui-ux` branch (the founders compare at the end).

## Phase 1, 2026-09-08: the design layer and every existing surface on it

Landed in PR #224 (draft). Head `aca5804c` at the end of the phase.

- `Sources/MacAgent/ContentView.swift` rebuilt as the one System A design layer: the system font,
  one cool-neutral ramp, a three-value radius rule, spacing, metrics, motion gated on Reduce
  Motion, one button system (four tones, three sizes), badges, dialog chrome, panel, card, divider
  and text-field surfaces.
- Sidebar and shell, the attention surfaces, and every page and dialog moved onto it in nine
  parallel lanes; routine detail left its private fake-glass copy for System A; the widget kept
  its material and gained 28pt controls, VoiceOver names, Return and Escape on every two-choice
  panel, Reduce Motion, and tooltips.
- Copy: sentence case, no em dashes in user strings, the chord as key glyphs, one notification
  title per category, no "(Soon)" suffixes.
- Verified: 3012 tests in 201 suites with 8 known issues at `838bebe8` (the flagged command),
  0 warnings at `838bebe8` (`scripts/warnings`), an adversarial review workflow with 26 confirmed
  findings all fixed or recorded.
- Founder answers of 2026-09-08 ratified every flagged decision and restored the monthly
  schedule note.

## Phase 2, 2026-09-08: Light and System appearances

- `Sources/MacAgent/SonnyAppearance.swift` (new): `SonnyAppearance` (dark / light / system) and
  `SonnyAppearanceModel`, a cosmetic preference in plain `UserDefaults` that sets
  `NSApp.appearance` at launch and on change. Dark is the default for a new install.
- `SonnyTheme`: every token is now an `NSColor` with a dynamic provider carrying a dark and a
  light reading (surfaces step down from paper in light; foreground tokens are black at an
  opacity; the accent darkens to `#3B67E9`); `SonnyTheme.onSurface(dark:light:)` for the mode
  control's wireframe-literal steps. No view changed: a view names a token and is right in both.
- `AppDelegate` owns the model and applies it before any window exists; `AppWindowCoordinator`
  injects it into the Command Center's environment so the Settings sheet's picker binds to it;
  the widget's panel pins `.darkAqua` so System B stays dark by design.
- Settings › Preferences › Interface theme is live: Dark, Light and System, no disabled items.
- Docs: decision 12 in the decision record, notes in the design-system reference and the UI
  conventions rule, three appearance rows in the manual checklist.
- Verified: 3012 tests in 201 suites with 8 known issues on the tree `c20bc4a9` carries (the flagged command, run before the commit; the Swift tree is the commit's), build clean.

## Phase 4, 2026-09-08: the menu bar shows Sonny's state

- `Sources/MacAgent/StatusItemPresentation.swift` (new): one value type maps (running, waiting
  for approval, failed) to the status item's glyph, tint and VoiceOver name, with the widget's own
  precedence (waiting outranks working outranks a failure, and a failure shows only once the run
  has stopped). Idle is the inverse glyph untinted; every other state is the filled glyph, tinted
  accent, warning or danger.
- `AppDelegate` observes `isRunning`, `approvalRequest` and `errorMessage` together and applies
  the presentation to the status-bar button (`contentTintColor` on the template image, the label
  as the tooltip). The status menu's items are unchanged; `ProductShellTests` pins them.
- `Tests/MacAgentTests/StatusItemPresentationTests.swift` (new): five tests on the mapping.
- Widget: the step and job rows' icon slots go from 13pt to 16pt, the one size System B's own
  rows still drew smaller than the glyphs beside them.
- Verified: the full flagged suite at `6309bcd9`, 3017 tests in 202 suites passed with 8 known
  issues (five tests added). The first run of it caught a scan reading the new observer in place
  of the notification channel it looks for by the first `viewModel.$errorMessage` in the file; the
  observer moved below those channels with a comment saying why (`6309bcd9`).

## Phase 3, 2026-09-08: the settings that said "soon", and an account menu with real destinations

Two lanes, merged at `cf1af8a3`.

- **Account menu**: Account (or Sign in), Settings (⌘,), a divider, Keyboard shortcuts (⌘/),
  About Sonny. Gone: the Profile placeholder dialog, the disabled Get help row, and the Learn more
  flyout with its four disabled items and its hover-dwell timer (`HoverTeardownAuditTests`'
  three assertions about that mechanism now assert its absence). The app menu gains
  "Settings…" ⌘, through `CommandCenterCommands`, an environment object the coordinator owns and
  the menu bumps.
- `Sources/MacAgent/KeyboardShortcutsView.swift` (new): three groups (Command Center, Widget,
  Anywhere), rows with key caps, the ⌘-number rows built from `CommandCenterDestination.allCases`
  and the chords read from the hotkey types.
- `Sources/MacAgent/AboutSonnyView.swift` (new): the mark, the name, "Version 1.0 (1)" from the
  bundle with a development-build fallback, the copyright line.
- **Notifications page**: six switches, one per notification kind, backed by
  `SonnyNotificationPreferences` (plain `UserDefaults`, default on) and honoured by a guard at the
  top of each `SonnyNotificationService.post…` method through a defaulted `isEnabled` closure.
- **Usage page**: a Plan section (plan badge, screen-control runs, last top-up, read from the
  account model and the allowance) and a This-task section from `taskUsageSummary` (requests,
  tokens reported or estimated, voice seconds), with an empty state when nothing is running. The
  integrator corrected the tokens row's discriminator after the lane reported that
  `hasUsageDetails` is true for any usage at all.
- `ScreenControlUsageSurfaceTests.insightsCarriesNoUsageMetricOfAnyKind` widened its count to
  admit the Usage page as the second legitimate reader of the allowance, Insights still at zero.
- Verified: the full flagged suite at `72083b3d`, 3017 tests in 202 suites passed with 8 known issues; `scripts/warnings` 0 at `72083b3d` (clean). Then `9e05cde3` hides the window's centred title, which the sidebar's wordmark already says.

## Phase 5, 2026-09-08: going anywhere from the keyboard, and a sidebar that gets out of the way

One lane, merged at `ddcd8b7c`.

- `Sources/MacAgent/JumpToPaletteView.swift` (new): ⌘K opens a palette over pages, routines,
  workspaces and the twenty most recent tasks; ↑ ↓ move, Return activates, Escape closes; a page
  selects itself, a routine or workspace opens its detail through `CommandCenterCommands`
  (`routineToOpen`, `workspaceToOpen`, consumed by the two pages the same two-door way Tasks
  consumes a detail request), a task raises the existing task-detail request. The matcher is a
  value type with seven tests (`JumpToPaletteTests`).
- The sidebar collapses to 56pt on ⌘⌥S (or its toggle above the account row): mark, an accent
  plus button, icon-only rows and the avatar, each with a tooltip; the width animates through
  `sonnyAnimation`; the choice persists in plain `UserDefaults`.
- The Keyboard shortcuts sheet lists both.
- Before the merge, on the same day: `ad5a2f5b` made Insights' recently-completed rows open
  their task's receipt through the same request a notification uses; `9e05cde3` hid the window's
  centred title, which the sidebar's wordmark already says.
- Verified: the full flagged suite at `ddcd8b7c`, 3024 tests in 203 suites passed with 8 known issues (seven tests added); `scripts/warnings` 0 warnings at `ddcd8b7c`.

## Phase 6, 2026-09-08: the second review and its fix round

- The same adversarial workflow as phase 1 ran over phases 2 to 5 (base `838bebe8`): six
  reviewers, every finding attacked by a skeptic; 20 findings, 17 confirmed, 3 refuted, one
  verifier lost to a schema retry cap and its finding read by hand.
- The one high finding was real: Settings › Usage read the subscription and the allowance but
  nothing fetched them until the Account dialog opened, so a signed-in user who opened Settings
  first read "Signed out". The page now runs the dialog's two refreshes on appear.
- Everything else fixed in `d2a8d78f`: Insights rows are buttons only when they lead somewhere
  (a record with an id; a workspace that still exists) and the workspace rows gained the chevron;
  the palette's rows carry the `isSelected` trait; the mode control's light track equals its dark
  one; a Window menu with Minimize and Close makes the shortcuts sheet's ⌘W true; the collapsed
  sidebar's widths and the chevron size are metrics tokens; routine detail's empty steps use the
  shared empty state; the Usage page's task section is titled for the last task as well as a
  running one and its estimate row is one VoiceOver element; the plan badge left the Account
  dialog's subscription row, whose line already says the plan.
- Verified: the full flagged suite at `d2a8d78f`, 3024 tests in 203 suites passed with 8 known issues; `scripts/warnings` 0 at `d2a8d78f` (clean).

## Phase 7, 2026-09-08: empty states that act

- `CollectionEmptyState` takes an optional action, drawn as a secondary button under the
  message. The Tasks page offers "Ask Sonny" when nothing has ever run (the same presentation
  request the sidebar's button raises; a search with no result and an unreadable store keep the
  plain sentence), Routines offers "New routine" and Workspaces offers "Create workspace", each the
  page's own toolbar action, so a first launch shows what to do rather than what is missing.
- Verified: 3024 in 203, exit 0, 8 known issues at `31ddef2f` (the flagged suite); `scripts/warnings` 0 at
  `31ddef2f`, exit 0, every file compiled.

## Phase 8, 2026-09-08: the copy boundary re-measured, the two value types mutated, the final figures

- Decision 13 said every remaining em dash sat in a sentence a test pins by value. Re-measured with
  the command it now carries, four did not: no test reads the vision pause summary or the
  scheduled-run notice, and the quarantine confirmation and the terminals-never detail are pinned
  by fragments the dash sits outside. Each took a period, a colon or a comma, every founder word
  intact (`1c8540d8`). Fifteen dashes remain in the UI target's string literals: two console
  lines, one act-log line, the founders' explainer twice, and ten in sentences their tests hold
  with the dash inside the pinned text.
- `StatusItemPresentation` and `JumpToPalettePresentation` went under a fourteen-mutant battery by
  property. Hand-tracing the plan first found two assertions the suites did not hold (the failed
  state's tint and the waiting and failed names; a whitespace-only query), added at `813a8089`
  before the battery ran. Result: `scripts/mutate` over the two value types the branch added, fourteen mutants by property, at `813a8089`: 14 killed, 0 survived, 0 unattributed (its report is kept at `.build/mutate/813a808-20260908T234615-40023/report.log`); every kill is named by a test with a plain connection to its mutant, and three of them (the failed state borrowing the working tint, the waiting state borrowing the working name, the query matched with its whitespace) died only to the assertions the hand-trace added at `813a8089`, which is the direct evidence those were needed; the baseline read `PASSED  3026 tests in 203 suites`.
- Verified: 3026 in 203, exit 0, 8 known issues at `813a8089` (the flagged suite; the count line is quoted in
  the changelog entry); `scripts/warnings` 0 at `813a8089`, exit 0, every file compiled.

## Phase 9, 2026-09-09: the menu bar named like the app

- The status item's dropdown said "New Task" for the action the sidebar calls "Ask Sonny"; it
  now says "Ask Sonny" and carries Settings…. The app menu gains About Sonny (a second
  `CommandCenterCommands` counter the coordinator bumps after fronting the window, turned into
  the account menu's own sheet) and the standard Hide Sonny ⌘H, Hide Others ⌥⌘H and Show All
  with nil targets; the Keyboard shortcuts sheet lists ⌘H. `ProductShellTests` pins both menus
  by title, target, selector and key equivalent (decision 14). The first full suite on it trapped:
  the builder set `NSApp.windowsMenu`, nil in a test process; the launcher installs it now
  (`d525cf58`, and a pitfall paragraph in the changelog entry).
- Verified: 3027 in 203, exit 0, 8 known issues at `d525cf58` (the flagged suite);
  `scripts/warnings` 0 at `d525cf58`, exit 0, every file compiled; the phase 8 battery carried on
  the four conditions, its two targets and two killing suites unchanged between `813a8089` and
  `d525cf58`.

## Phase 10, 2026-09-09: the Help menu, and opening the app while it runs

- The main menu gains Help with one item, Keyboard shortcuts on ⌘/, through a third
  `CommandCenterCommands` counter; the launcher installs it as `NSApp.helpMenu`, which puts the
  system's search field over every menu item. The window's hidden ⌘/ button stays for when it is
  key, since a view answers a key equivalent before the menu bar does.
- A Dock click, a second launch from Spotlight or Launchpad, or a Finder double-click while the
  app runs now shows Command Center when it is not on screen, through the coordinator's own
  visibility rather than AppKit's `hasVisibleWindows`, which counts the widget's panel; a visible
  window is left to AppKit's activation. `ProductShellTests` pins the Help menu beside the app
  menu and drives the reopen path from nothing, from visible, and from closed.
- Verified: 3028 in 203, exit 0, 8 known issues at `d9adc3fa` (the flagged suite);
  `scripts/warnings` 0 at `d9adc3fa`, exit 0, every file compiled; the phase 8 battery carried on
  the four conditions, its two targets and two killing suites unchanged between `813a8089` and `d9adc3fa`.

## Phase 11, 2026-09-09: the founders' first round of asks, after running the branch

The founders ran the packaged branch and asked for four things: a countdown of the recording cap,
better Run again and task viewing, an information-density slider, and a menu for the extra and
destructive actions on workspaces and memory. Four questions went back (what Run again should do
and where it lives; a pane or a sheet; whether density touches text; the menu's glyph) and the
recommended answer was chosen for each (decisions 15 to 18). The work ran as lanes again: voice,
tasks and overflow in parallel from `ccfe63cc` (the head that added `SonnyOverflowMenu` to the
design layer so two lanes would not build two menus), then density alone on the merged tree,
because it edits every row-height site including the ones the other lanes rewrote.

- **Voice** (`643848ab`, merged `2a5ffa86`): `VoiceRecordingCountdown`, a value type holding the
  listening window (177 seconds, three under the cap, room for a late main thread, so what the widget records is accepted), the
  thirty-second warning, the label ("2:59") and the VoiceOver phrase; `voiceRecordingStartedAt` on
  the view model, set with `isRecordingVoice` and cleared on every path that clears it; an
  auto-stop `Task` armed at start that calls the same `stopVoiceRecordingAndTranscribe()` the
  mic's Stop and the hotkey release call, cancelled by any manual stop; the label leading the mic
  in the composer, ticking in a `TimelineView`, width reserved for "9:59", faint until the last
  thirty seconds and then the widget's new attention token; the mic's VoiceOver value reads "Stop,
  2 minutes 59 seconds left". Ten tests: seven on the value type, three on the auto-stop, which
  can only reach the stop path's failure arm in a test process (no real recorder), and say so.
- **Tasks** (`b9371e58`, merged `2a7fda0a`): the page is an `HSplitView`, list at 300 minimum and
  pane at 320, which leaves 11pt at the 900-wide window minimum with the sidebar expanded; the
  sheet and `TaskLogDetailDialog` are gone. A row press, the ⌘K palette, Insights and the
  finished-run notification all select into the pane through one door; ↑↓ walk the visible rows of
  every expanded section, ⌫ opens the delete confirmation, Esc clears; the selection survives a
  refresh while its record exists and a task selected from outside expands its collapsed section.
  `TaskReceiptView` is the redesigned receipt: the command, a status badge and the metadata, then
  Run again (primary), Edit and run, Follow up and a more-actions menu holding Delete task; the
  result in full; "What Sonny planned" showing the plan summary only, because a founder decision of
  2026-07-18 says the stored steps are never rendered (question raised); and "What Sonny did on
  screen" moved intact with its delete in a section menu. `editTaskAndRunAgain` fills the widget
  with the command and carries the workspace, refused in flight and during a clarification. The
  row's context menu gained the three actions above its delete. Seventeen tests, fourteen on
  `TasksSelectionPresentation` and three on the new door. `TaskDetailPresentation`'s height maths
  lost its consumer and stays, with a doc comment and a question, since nothing deletes a test here.
- **Overflow** (`a8471381`, merged `d1eac8b7`): the workspace card keeps Open and New task and
  moves Mark as team and Delete workspace into its menu; the memory row keeps View and the toggle
  and moves Delete; the entries sheet's row keeps Continue and moves Delete. Every moved action
  keeps its label, its role, its disabled predicate and its confirmation. The per-entry Remove
  inside the workspace editor and the Security page stay where they are, as the brief said. Eight
  tests, six of them separate counted source scans with two positive controls.
- The merged tree at `2a7fda0a`: 3063 in 206, exit 0, 8 known issues, exactly the thirty-five
  tests the three lanes added.
- **Density** (`379808de`, merged `a766043a`, run alone on the merged tree): `SonnyDensity`, three
  stops with named values (rows 30/36/44, nav 26/30/36, compact 24/28/32, toolbar 32/36/40, card
  inset 12/16/20, list gap 0/0/4, section gap 12/16/24, card floor 170/190/210) and a `scaled`
  helper for the one-off heights, Default equal to the shipped metrics by test; an environment
  value the Command Center root republishes from `SonnyDensityModel` (plain `UserDefaults`, the
  appearance model's shape, an unknown stored string reading as Default) so every page and every
  sheet re-reads it live with no state reset; every row, toolbar, group header, card inset, list
  gap and page gap converted, in the sidebar, the five pages, the ⌘K palette, the shortcuts
  sheet, the routine detail and the Settings sidebar; text, icons, control heights, radii,
  dialog chrome and the widget untouched. A three-stop slider under the interface theme in
  Settings › Preferences with the stop names beneath it. Six tests.
- Reviewed by a third adversarial workflow over the merged tree at `a766043a`, five reviewers (the pane, the menus, the countdown, density, and rules and tests) with every finding attacked by an independent skeptic: 21 findings, 20 confirmed, 1 refuted. One high: the density slider collapsed its accessibility subtree, so VoiceOver could read the stop but not move it. Twelve medium: the receipt's delete clearing the selection before the model had removed anything; the mic's VoiceOver value read off a plain `Date()` rather than the label's tick; four menu items that lost their per-subject labels in the move; the card's disabled predicates and the memory row's predicate unasserted or loosely anchored; Default's four unmetricked density values pinned by ordering only, and a rounding test that truncation would pass; the one-second auto-stop margin against measured main-actor delays. Seven low: the list's ⌫ with the search field focused (the pair the skeptics split on; the guard is right under either reading), a missing double-schedule test, two stale comments, a literal width. Every one fixed in `01aa3be3`, and the battery's design added the identity-guard test at `edaa0cd3`.
- Verified: 3073 in 208, exit 0, 8 known issues at `edaa0cd3` (the flagged suite; the count line is
  quoted in the changelog entry); `scripts/warnings` 0 at `edaa0cd3`, exit 0, every file compiled;
  `scripts/mutate` at `edaa0cd3`, 28 mutants by property (the nine palette mutants re-run because the density lane edited their file, five on `TasksSelectionPresentation`, four on `SonnyDensity`, five on `VoiceRecordingCountdown`, three on the auto-stop and two on Edit and run): 28 killed, 0 survived, 0 unattributed (its report is kept at `.build/mutate/edaa0cd-20260909T172537-89083/report.log`); every kill is named by a test with a plain connection to its mutant, and the auto-stop's recording-identity guard died only to the test its design showed missing, added at `edaa0cd3`.

## Phase 12, 2026-09-09: the founders' second round, after running phase 11

Seven asks came back from running phase 11 with screenshots: the task pane always present and
unclosable, the Insights breakdown card mis-sized against its neighbours, the memory row's menu and
View in the wrong places, Compact judged a stop nobody would choose, the workspace card's Open
redundant beside a face that opens the detail, the chart's hover count wrapping in its column, and
a way to choose how many tasks to see. No question needed to go back; decisions 19 to 23 record the
calls made. Four lanes ran in parallel from `ee88c3e4` on disjoint regions.

- **Tasks list** (`021df3d6`, merged `7a29814b`): the pane renders only with a selection, nothing
  is selected on appear, the receipt's header carries a close control ("Close task") and Esc still
  clears; the appearance animates through `sonnyAnimation`. `TaskListPageSize` (10, 25, 50, 100,
  All; default 25; a `UserDefaults` store on the collapse store's pattern) caps the search-filtered
  records before grouping, a "Show" picker leads the search field, a footer reads "25 of 69 shown"
  with Show all beside it, and a task requested from elsewhere that falls outside the window lifts
  the cap for that visit only. Sixteen tests: fourteen on the value type and store, two scans.
- **Insights** (`0e5dc010`, merged `3015935f`): the bento's second row is an `HStack(alignment:
  .top)` spanning the grid's four columns, the breakdown panel filling the row the chart sets, with
  the stat cards' own `SonnySpacing.md` gap between them (the brief said `lg`; the lane measured the
  stat row and matched it). The chart's day label no longer changes on hover; the count sits in a
  pill above the hovered bar, `fixedSize`, one line, with an accessibility value on the column, and
  `WeeklyCompletionChartPresentation.countLabel(for:)` holds the wording (two tests).
- **Memory and workspaces** (`64baf46a`, merged `2af40170`): the memory row reads icon, texts,
  toggle, then the menu, with View first in the menu and Delete after a divider; the workspace
  card's face has New task alone, now the primary, and its menu reads Open (still
  `openWorkspaceWidget`, still disabled in flight), Mark as team, Delete workspace. The entries
  sheet's row already had the target shape. Two scans added, one extended. The lane's question:
  the detail sheet has no way to open the widget for its workspace; whether it should is the
  founders' (not added).
- **Density, two stops** (`34f1512c`, merged `fe9fcd3c`): `SonnyDensity` is Default and
  Comfortable; a stored "compact" reads as Default through the existing fallback, pinned by test;
  the control is a two-way segmented picker with its label and value on the picker itself, since a
  slider with two stops reads as broken. Two tests added, three followed the case removal.
- **The receipt's layout** (`46672792` and the review's fix round `0307de0d`), after the founder ran the round and found the pane
  "too cluttered and badly positioned": the list had no ceiling, so it kept every spare point of
  width and the receipt sat at its 320pt floor with its title wrapped, "Completed in 8s" broken
  across lines and all three buttons truncated. The list is a 260 to 380 column with a 320 ideal
  and the receipt grows from 360 with a 520 ideal; the metadata reads on one line or, narrower,
  with the badge on its own line, every phrase but the workspace name `fixedSize`; the three buttons are `fixedSize` and
  fall to two rows where three do not fit; sections keep a steady `xl` gap and the prose a little
  leading. Two reviewers and their skeptics (layout; rules and tests) confirmed 12 findings on the rework, none refuted: the delete confirmation had moved onto the menu that `ViewThatFits` builds once per candidate, the dropped-dialog shape this app has documented twice; the metadata row sat beside the close control and lost 40pt of the width it was measuring; a duplicated badge; an empty row in the fallback for a record with no actions; a comment claiming more `fixedSize` than the code had; five split widths with no name; no scan pinning the candidate order or the `fixedSize`; and the changelog's byte-identical sentence gone stale at the rework. Every one answered in `0307de0d` (the confirmation on the `ViewThatFits`, the metadata row at full width, `SonnyMetrics` tokens for the widths, `TaskReceiptSourceScanTests`), and the entry's figures are restated there.
- Reviewed by a fourth adversarial workflow over the merged tree at `fe9fcd3c`, five reviewers (the Tasks list, Insights, the memory row and the card, density, and rules and tests) with every finding attacked by an independent skeptic: 20 findings, 18 confirmed, 2 refuted. Two high: the chart's hover pill needed about 27pt above the bar row and the title was 16pt away, so it landed on the title on every hover (found by three reviewers); and only the breakdown panel was flexible in height, so a panel taller than the chart put the gap back under the chart. Ten medium: a page size shrunk below the selection leaving the pane open on a row the list no longer drew (found twice); the Show picker and the 220pt search field not fitting the list's 300pt floor (found twice); the two-segment density picker cramped in a 180pt frame; the request override's guard and ternary pinned by an assignment's text only, and no pin on what a shrunk size does to the selection; the primary tone and Open's predicate asserted by bare containment. Six low: the pill spilling past the card at the ends of the week, the chart's wiring unpinned, and three more scan gaps. Every one fixed in `5ac01639`, plus the two auto-stop tests' wall-clock windows the insights lane's first run had exposed; the battery then exposed the other half of that bet and `559fa6b3` closed it.
- Verified: 3097 in 211, exit 0, 8 known issues at `559fa6b3` (the flagged suite; the count line is
  quoted in the changelog entry); `scripts/warnings` 0 at `559fa6b3`, exit 0, every file compiled;
  `scripts/mutate` at `559fa6b3`, 12 mutants by property (the density model's four re-run because their file moved, four on `TaskListPageSize`, one on the chart's wording, and the three auto-stop mutants re-run because their killing suite moved): 12 killed, 0 survived, 0 unattributed (its report is kept at `.build/mutate/559fa6b-20260910T095513-17728/report.log`); every kill is named by its own suite. A first run at `5ac01639` killed its first ten and stalled on the eleventh, the mutant that drops the cancel, because two tests awaited a cancelled task's value; it was stopped through its trap, which restored the tree, and the tests read the flag instead (`559fa6b3`).

## The plan

Every phase in the plan has landed and the changelog entry is restated at the head that carries
everything. What is left is the founders': the manual pass from the checklist's branch section,
the comparison with the `ui-ux` branch, and the merge.
