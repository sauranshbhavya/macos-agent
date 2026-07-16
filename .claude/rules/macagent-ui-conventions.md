---
paths:
  - "Sources/MacAgent/**"
---
# MacAgent (UI) conventions

`MacAgent` is the executable — the menu-bar popover and the Command Center window. Both are views over one shared `AgentViewModel`.

## Shared state

The popover (`ContentView.swift`) and the Command Center (`CommandCenterView.swift`) observe the *same* `AgentViewModel` instance — that's the whole point of the product-shell-shared-state work. New published state (a new local store's records, a new preference) gets added to that one instance. Never build a second, independently-coded state path for either surface, even for something that feels surface-local.

## Design tokens — System A only, in this target, today

`SonnyTheme` / `SonnyType` / `SonnyRadius` (defined in `ContentView.swift`) are System A: flat, opaque, Inter, zero shadows anywhere. That's what every current file in this target uses. System B — translucent "Liquid Glass" material, real multi-pass shadows, SF Pro/SF Pro Display, distinct per-action accent colors — belongs to the floating widget and system notifications, which don't exist in this target yet (that's branch 9's territory). When that work starts here, it is a second, separate token set, not a variant of System A — don't extend `SonnyTheme` with glass/shadow properties to serve it. See `docs/sonny-design-system-reference.md` for the full split, and `docs/sonny-founder-design-decisions.md` for at least one confirmed case (the routine detail view) that needs System B's material embedded inside a System A surface — that's a deliberately special case, not precedent for mixing the two generally.

## Approval visibility

Any Command Center page that includes the command composer must explicitly render `CommandCenterTaskActivitySurface` behind `viewModel.hasTaskActivity`. This is not automatic — a page can have the composer and silently show no approval prompt if this is missing, with no error, which has happened once already.

## Responsive rows

`SettingsAdaptiveControlRow` (a `ViewThatFits` horizontal-first, `minWidth`-floored, vertical-fallback pattern) is the fix for any label+control row that needs to survive a narrow, non-fullscreen window. Reuse it for new settings/control rows rather than a fixed `HStack` — a fixed `HStack` is what caused the narrow-width character-wrapping bug this pattern replaced.

## Preferences

A cosmetic, non-privacy-sensitive preference (e.g. pointer cursor behavior) goes through plain injected `UserDefaults`, not `LocalStorageEncryption` — don't add a new encrypted store for something with no privacy sensitivity. Read booleans with `object(forKey:) as? Bool ?? true`, not `.bool(forKey:)` — the latter silently defaults a missing key to `false`, which is wrong for any preference that should default to *on* for new users.

## Wireframe fidelity

Matching `docs/sonny-design-system-reference.md`'s exact colors/fonts/spacing/radius is necessary but has already proven *not sufficient* on this project — a fully token-accurate build still read as structurally thinner than the wireframes (missing grouping, missing metadata richness, missing whole sections). Before treating a page as matching its wireframe, check `docs/sonny-founder-design-decisions.md` for structural/content intent the static SVG doesn't fully capture, not just the token values.
