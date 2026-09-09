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

## Plan for the phases ahead

Ordered by how much of the product each unlocks; each phase ends verified and pushed.

2. **Appearance**: real Light and System themes. The token layer becomes appearance-aware, a
   cosmetic preference stores the choice, the Settings picker goes live, and the widget stays
   dark by design.
3. **Settings completeness**: a real Notifications page, a real Usage page, Profile as the
   account surface, and a keyboard-shortcuts panel and About window in place of items that lead
   nowhere.
4. **Menu bar**: a status item that shows Sonny's state, and a status menu that is worth opening.
5. **Command Center**: a jump-to palette on ⌘K over pages, routines, workspaces and tasks;
   sidebar collapse; empty states with composed glyphs; loading states.
6. **Widget**: a polish pass on every state within System B.
7. **Second review**: the same adversarial workflow over the whole tree, a fix round, and the
   measurements re-taken at the head that carries them.
