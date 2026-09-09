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
- Verified: VERIFY7_PLACEHOLDER

## Plan for the phases ahead

Ordered by how much of the product each unlocks; each phase ends verified and pushed.

8. **Final measurements** at the head that carries everything, and the changelog entry restated
   there.
