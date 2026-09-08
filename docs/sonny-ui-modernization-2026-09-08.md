# Sonny UI modernization, branch `ui-ux-claude` (2026-09-08)

The record of the decisions behind the System A design layer in `Sources/MacAgent/ContentView.swift`
and the page work that followed it. `docs/sonny-design-system-reference.md` stays as the wireframe
provenance; where the two disagree, this file is the live one for this branch and that one says
where a value came from.

The brief: the app's styling was inconsistent and read as assembled rather than designed. The ask
was to make it feel the way professional Mac apps feel. The taste skills under `.agents/skills/`
(installed from `Leonxlnx/taste-skill`) were the audit vocabulary; most of their rules are about
marketing pages, so what carried over is the part about restraint, one palette, one type scale, one
radius rule, real states on every control, and honest motion.

## Design read

A redesign-overhaul of a native macOS agent app (a Command Center window plus a floating command
widget) for a design-conscious builder audience, in a "professional Mac app" language (Things,
Craft, Raycast, Linear for Mac): system typography, one cool-neutral grey family, one brand accent,
native controls where one exists, and a complete state vocabulary (hover, pressed, focus, disabled,
selected, empty, loading, error) with restrained motion that honours Reduce Motion.

Dials: variance 3, motion 3, density 6. A tool people live in, not a landing page.

## What does not change

- Behaviour. No view-model logic, no store, no approval or shared-state rule moved. Same actions,
  same entry points, same origins. A styling branch that changes behaviour is a defect.
- The two-system split. System A (Command Center and its dialogs) is flat and opaque with no
  shadows. System B (the floating widget and notifications) keeps its real vibrancy and its own
  tokens, confined to the overlay. Neither imports the other's tokens, and the tests that pin that
  (`ResumeOfferPresentationTests`, `ClientVersionSurfaceTests`) still pass.
- The founders' copy rule: no explanatory or how-it-works copy in the product.
- Information architecture: the five sidebar destinations, the account menu, Settings as a sheet.

## The decisions

1. **Typography moves from Inter to the system font.** A Mac app that ships its own web sans reads
   as a port. SF Pro switches between its Text and Display optical sizes on its own at 20pt, so
   nothing sets tracking by hand. The widget already used SF; the two systems are now
   typographically coherent while keeping their material split. Numbers that sit in columns use
   monospaced digits. The bundled Inter, Golos and Instrument Serif files are still registered by
   `AppDelegate` and still in `Resources/Fonts`; nothing draws with them any more, and removing
   them is a packaging change deliberately left for a founder to decide.
2. **One cool-neutral ramp, opacity-based text and hairlines.** Surfaces are opaque and step up in
   luminance by level (sidebar, canvas, panel, card, menu). Text, hairlines, hover, pressed and
   selected fills are white at an opacity, so every one composes the same on every level and no
   view picks a grey. The brand accent `#5C84FE` is preserved: a redesign keeps the brand colour.
3. **One radius rule.** Controls, rows, badges and inputs 6; cards and panels 10; sheets 12; pills
   a capsule. The older names (`container`, `panelCard`, `workspaceCard`, `routineIcon`,
   `themeSwatch`) survived as aliases while the page lanes migrated and were deleted once no call
   site named them.
4. **One button system.** `SonnyButtonStyle` has four tones (primary, secondary, tertiary, danger)
   and three sizes (small 24, regular 28, large 32), with hover, pressed, keyboard focus and
   disabled built in. Command Center's two private button styles were retired onto it and then
   deleted; the routine detail sheet's fourth went with its System B copy.
5. **Native controls where a native one exists**: switch toggles, menu pickers.
6. **Motion**: one curve family in `SonnyMotion`; every animated change reads Reduce Motion through
   `sonnyAnimation` rather than a bare `withAnimation`.
7. **Routine detail joins System A.** The founder intent recorded in
   `docs/sonny-founder-design-decisions.md` was one consistent way to watch Sonny work, whichever
   surface the user is on. That is met by giving the routine detail the same row grammar as the
   widget's step log. It is not met by the blend-mode imitation of glass the view carried, which
   had no vibrancy behind it inside a flat window and was the single most visible inconsistency in
   the app. **This reverses a recorded founder decision and is flagged for founder review**; the
   view's old token set is gone rather than left as a second copy nobody draws with.
8. **Copy**: sentence case for every button and label that is not a proper noun; no em dashes in a
   string a user can see; unavailable menu items are disabled rather than suffixed "(Soon)".

## The tokens

| group | what it holds |
|---|---|
| `SonnyTheme` | `sidebar` #0F1012, `ink` #141518, `collectionSurface` #191A1E, `surfaceRaised` #1F2126, `surfaceRaised2` #262930; `text` white .92, `muted` .60, `textTertiary` .38, `textOnAccent`; `border` white .09, `cardBorder` .06, `fillHover` .05, `fillPressed` .09, `fillSelected` .10; `accent` #5C84FE with `accentSubtle` .14 and `accentBorder` .40; `success` #4CC38A, `warning` #E8B84A, `danger` #E5484D; `chartBarMuted` accent .22 |
| `SonnyType` | `pageTitle` 22 semibold, `settingsContentTitle` 20 semibold, `settingsSectionLabel` 15 semibold, `heroStat` 26 semibold monospaced digits, `headline` 13 semibold, `bodyEmphasis` 13 medium, `body` 13, `itemTitle` 12 medium, `caption` 12, `microEmphasis` 11 medium, `micro` 11, `eyebrow` 11 medium, `avatar` 13 medium, `mono` 12, `sidebarWordmark` 13 semibold |
| `SonnyRadius` | `control` 6, `card` 10, `sheet` 12, `pill` capsule |
| `SonnySpacing` | 4 / 8 / 12 / 16 / 20 / 24 / 32, `pageInset` 24 |
| `SonnyMetrics` | sidebar 220, nav row 30, list row 36, compact row 28, toolbar 36, controls 24 / 28 / 32, icons 14 / 13 / 11 / 24 |
| `SonnyMotion` | `quick` .15s, `standard` .22s, `emphasized` .3s snappy |

Shared components beside them: `SonnyBadge`, `SonnyDialogHeader`, `SonnyDialogCloseButton`,
`sonnyDialogFrame(_:)` with three named sizes, `sonnyPanel()`, `sonnyCard(isHovered:)`,
`sonnyDivider()`, `sonnyTextField(size:)`, `sonnyHoverHighlight()`, `sonnyPointerCursor()`,
`sonnyAnimation(_:value:)`; and in Command Center, `commandCenterPageFrame()` and
`commandCenterPanel()` for the five pages' shared shell.

Removed as dead at the branch's start (no site in `Sources/` or `Tests/` named them, measured with
`grep -rn -F` at `6d7bf058`): `SonnyType.brand`, `.hero`, `.panelTitle`, `.tagline`, `.command`,
`.panelIcon`; `SonnyTheme.cream`, `.glassShade`, `.panelTint`, `.info`; `sonnyLogoGlow()` (a
shadow in a zero-shadow system, with one call site, removed with it).

## What the audit found

Seven surface surveys, one over the tests that pin UI source, one over the founders' decision log
and one over the sibling `ui-ux` branch ran before any page was touched, and a cross-surface
critique read all of them. The findings that shaped the work, each with where it was measured:

- **Four button styles for one primitive.** `SonnyButtonStyle` (34pt fixed-width branch, ~28pt
  otherwise, radius 8 hard-coded four times), `CommandCenterHeaderActionStyle` (28pt),
  `CommandCenterRowActionStyle` (23pt, about thirty call sites) and `RoutineDetailActionStyle`
  (26pt, System B). Only the two private ones dimmed when disabled. Now one style.
- **Hit targets under the floor almost everywhere.** The 23pt row-action style, seventeen 23pt
  circular controls in the widget, a 30x20 custom toggle, and every sheet's close control at
  exactly 24pt. `SonnyMetrics.controlSmall` is 24, `controlRegular` 28, the widget's
  `WidgetTheme.controlSize` 28, and the close control 28.
- **No spacing or icon scale.** Ten distinct horizontal and thirteen distinct vertical padding
  literals on the Tasks page alone; icon glyphs at 8, 9, 10, 11, 12, 13 and 14pt with no rule;
  seven raw `.font(.system(size:))` sites in Command Center beside eighteen tokenised ones;
  twenty-one of twenty-three in the widget. `SonnySpacing`, `SonnyMetrics` and two widget icon
  tokens replace them.
- **Radii below the token floor.** Chart bars and swatches at 2 and 3, a repeated 12 for close
  buttons, a 6 used as a literal beside the token that equalled it. Three values and a capsule now.
- **Three toggles, four text-field recipes, nine one-off sheet sizes.** Native switches, one
  `sonnyTextField`, three named sheet sizes.
- **The routine detail sheet straddled both systems**: its own copy of System B tokens whose type
  ramp disagreed with the widget's, native pickers with no forced appearance on a hard-coded dark
  panel, the three-shadow recipe the widget file's own comment said was tried and rejected, and
  `SonnyTheme` reached into for every semantic colour. It is System A now.
- **Copy drift**: sentence-case triggers paired with Title Case confirmations in three files, one
  delete dialog quoting its subject in curly quotes, "(Soon)" suffixes on menu items, em dashes in
  user-visible strings, every notification titled "Sonny".
- **Accessibility gaps**: the widget's Allow and Deny (the highest-stakes controls in the app) with
  no VoiceOver name, the mic with none, no keyboard path to any two-choice widget panel, sidebar
  selection with no `isSelected` trait, stat tiles read as three separate elements.
- **What was already right and was kept**: colour and type routed through tokens on nearly every
  Command Center surface, the two-system split, `SettingsAdaptiveControlRow`, the shared-state and
  approval rules, the founders' per-page decisions on which surface shows what.

The sibling `ui-ux` branch (the other founder's pass with the same skills) converged on the same
three big moves: system font, a graphite ramp, and folding routine detail into System A. What this
branch deliberately did not take from it: taglines under every page title (explanatory copy),
demoting the Tasks greeting to a subtitle, recolouring System B's accents toward System A, and
restyling the founder-drawn mode segmented control.
