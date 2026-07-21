---
paths:
  - "Sources/MacAgent/**"
---
# MacAgent (UI) conventions

`MacAgent` is the executable — the floating command widget (`FloatingWidgetView`, opened from the menu-bar icon or the push-to-talk hotkey) and the Command Center window. Both are views over one shared `AgentViewModel`. There is no menu-bar popover anymore — it was replaced entirely by the floating widget; `ContentView.swift` now only holds shared System A tokens/components (`SonnyTheme`/`SonnyType`/`SonnyRadius`, `AgentCommandComposerView`, button styles), not a view of its own.

## Shared state

The floating widget (`FloatingWidgetView.swift`) and the Command Center (`CommandCenterView.swift`) observe the *same* `AgentViewModel` instance — that's the whole point of the product-shell-shared-state work, carried forward when the widget replaced the old popover. New published state (a new local store's records, a new preference) gets added to that one instance. Never build a second, independently-coded state path for either surface, even for something that feels surface-local.

Because both surfaces render off the same state, a task submitted from either one is visible to both. `AgentViewModel.TaskOrigin` (`.commandCenter` / `.widget`) tracks which surface actually submitted the currently-active task, so the widget can tell its own task apart from one Command Center's composer submitted and avoid rendering a second, duplicate progress/result panel for the latter (`FloatingWidgetView.showsPanel`). Any new task-submitting entry point needs to pass its own real `origin` explicitly — it does not get inferred, and the default is `.commandCenter`.

## Design tokens — two separate systems, both in active use

`SonnyTheme` / `SonnyType` / `SonnyRadius` (defined in `ContentView.swift`) are System A: flat, opaque, Inter, zero shadows anywhere — used throughout Command Center. `WidgetTheme` / `WidgetType` (`SonnyWidgetTheme.swift`) are System B: translucent "Liquid Glass" material (a real `NSVisualEffectView` blur, not a blend-mode approximation of one), SF Pro/SF Pro Display, distinct per-action accent colors — used by the floating widget (`FloatingWidgetView.swift`) and system notifications (`SonnyNotificationService.swift`, though macOS renders that chrome itself). These are deliberately separate token sets, not variants of one another — don't extend `SonnyTheme` with glass/shadow properties, and don't reuse `WidgetTheme`/`WidgetType` outside the floating widget. See `docs/sonny-design-system-reference.md` for the full split, and `docs/sonny-founder-design-decisions.md` for at least one confirmed case (the routine detail view) that needs System B's material embedded inside a System A surface — a deliberate special case, not precedent for mixing the two generally. (`RoutineDetailView.swift` also keeps its own independent copy of the System B tokens for that case, rather than sharing `SonnyWidgetTheme.swift`'s — also deliberate, not an oversight.)

## Approval visibility

Command Center itself has no approval/permission UI of its own. `CommandCenterRunningIndicator` (`CommandCenterView.swift`) is a deliberately compact "something is running" line (spinner + command text + Cancel) — render it wherever a page needs it by gating on `viewModel.isRunning || viewModel.isAwaitingApproval`. The real Approve/Deny controls, the clarification-answer field, and the task-failure message all live only in the floating widget (`WidgetPermissionPanel` / `WidgetClarificationPanel` / `WidgetFailurePanel` in `FloatingWidgetView.swift`) — since it observes the same shared `AgentViewModel`, nothing is unreachable from a Command-Center-originated task, just not visible on Command Center's own page. `SonnyNotificationService` exists as a fallback for when neither surface is in front of the user, but the widget is currently a permanent on-screen overlay by deliberate design (no dismiss/hide action exists), so that fallback path is effectively unused today — a known, accepted tradeoff, not a bug (see `docs/sonny-ui-backend-gaps.md`). Any future work that can trigger a task without a user actually watching the widget (scheduled/background routine execution is the clear case) needs to build Command Center its own real surface for these states rather than assume the widget-only UI covers it — see `docs/sonny-ui-backend-roadmap.md`.

## Responsive rows

`SettingsAdaptiveControlRow` (a `ViewThatFits` horizontal-first, `minWidth`-floored, vertical-fallback pattern) is the fix for any label+control row that needs to survive a narrow, non-fullscreen window. Reuse it for new settings/control rows rather than a fixed `HStack` — a fixed `HStack` is what caused the narrow-width character-wrapping bug this pattern replaced.

## Preferences

A cosmetic, non-privacy-sensitive preference (e.g. pointer cursor behavior) goes through plain injected `UserDefaults`, not `LocalStorageEncryption` — don't add a new encrypted store for something with no privacy sensitivity. Read booleans with `object(forKey:) as? Bool ?? true`, not `.bool(forKey:)` — the latter silently defaults a missing key to `false`, which is wrong for any preference that should default to *on* for new users.

## Wireframe fidelity

Matching `docs/sonny-design-system-reference.md`'s exact colors/fonts/spacing/radius is necessary but has already proven *not sufficient* on this project — a fully token-accurate build still read as structurally thinner than the wireframes (missing grouping, missing metadata richness, missing whole sections). Before treating a page as matching its wireframe, check `docs/sonny-founder-design-decisions.md` for structural/content intent the static SVG doesn't fully capture, not just the token values.
