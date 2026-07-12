# Sonny Design System Reference

Source of truth for Sonny's visual design, extracted from the user's own Figma wireframes (file key `YdPaDQ7zCGc6e9BnpJIzcI`) on 2026-07-12. Extracted via SVG export + "Copy as CSS" on individually-selected layers (the Figma Dev Mode MCP connector hit its Starter-plan monthly quota — 6 calls/month — after limited use, so this document is built from manual exports, not live API queries). Cross-checked against raw SVG `<filter>` definitions and literal `<text>` nodes where CSS layer-name comments were ambiguous or stale.

Treat this document as authoritative for implementation. Where something is genuinely unconfirmed, it's marked **UNCONFIRMED** — do not silently guess past those markers; ask instead.

Source files live at `/Users/sauranshbhardwaj/Desktop/wireframes/`, named `<number>-<ScreenName>.svg` / `.md` (CSS). Reference table at the bottom of this doc maps every file.

---

## 1. Two separate design systems — read this first

The wireframes contain **two unrelated visual systems**, not one shared one. Do not blend them.

- **System A — Main App / Command Center.** Everything under the Sonny app window: Tasks, Insights, Routines, Workspaces, Settings, the sidebar. Inter typeface, flat opaque colors, no shadows anywhere. This is what branch 8 (`feature/product-shell-shared-state`) already implements.
- **System B — Floating Widget + System Notifications.** The Spotlight-style floating command bar and macOS Notification Center banners. SF Pro / SF Pro Display typeface, a translucent "Liquid Glass" material with heavy blend-mode layering, genuine multi-pass drop shadows, and its own accent-color set that does **not** match System A's accent. This belongs to branch 9 (`feature/floating-command-widget`), not yet built.

When branch 9 starts, it needs its own token set from day one — it should not inherit `SonnyTheme`/`SonnyType`.

---

## 2. System A — Main App / Command Center

### 2.1 Foundation colors

| Token | Hex | Usage |
|---|---|---|
| Background (`ink`) | `#090909` | App window background, sidebar |
| Body/collection panel fill | `#0F1011` | The bordered content panel inside each screen |
| Card / raised row fill | `#16171A` | Workspace cards, toolbar buttons, group-section headers |
| Outer border | `#25262B` | Body panel border, row dividers |
| Card border | `#1A1B20` | Workspace card border, button border — **distinct from outer border, don't collapse the two** |
| Accent | `#5C84FE` | Icons, avatars, active states, chart peak-bar — see §2.4 on inconsistency |
| Muted text | `#959699` | Secondary/timestamp/subtitle text (also seen as `#939496`/`#999A9D` — treat as the same intent, use `#959699` as canonical) |
| Primary text | `#FFFFFF` | Titles, primary labels |
| Sidebar nav item text | `#E2E3E5` | Slightly warmer than pure white — this is the shared sidebar component's nav-item label color, present on every main-app screen (not Home-specific) |
| Warning / streak | `#F2BE00` | Routine step-count badge and dot |
| Success / green | `#3FB950` | Positive deltas, completed-status dots |
| Traffic lights | `#FF5C60` (close) `#FAC800` (minimize) `#35C759` (zoom) | Window controls |

**Confirmed: zero shadows anywhere in System A.** Checked across Routines, Workspaces, Home, Settings, Insights — every card, row, and panel is flat. The only shadow-like effects in main-app screens belong to shared nav chrome, not content: a very subtle `drop-shadow(0px 1px 2px rgba(0,0,0,.04)) drop-shadow(0px 2px 4px rgba(0,0,0,.04))` on a few sidebar icon buttons, and a logo ambient glow `drop-shadow(0px 0px 19.8px rgba(255,255,255,.11))`. Neither is worth chasing for card/row content.

### 2.2 Typography

Inter throughout, no exceptions in System A screens (the two SF Pro appearances on the Home screen belong to a floating-widget mockup composited into that screenshot for context, not to the app chrome itself).

| Role | Size / weight / line-height | Color |
|---|---|---|
| Page title | 23px / 500 / 28px | `#FFFFFF` |
| Section/panel title | 13px / 500 / 16px | `#FFFFFF` |
| Routine row / sidebar nav title | 13px / 500 / 16px | `#FFFFFF` or `#E2E3E5` |
| Workspace card title | **14px** / 500 / 17px | `#FFFFFF` — one size step larger than routine-row titles, confirmed distinct, don't collapse the two |
| Row subtitle/detail | 11px / 400 / 13px | `#959699` |
| Toolbar button label (e.g. "+ New routine") | 12px / 500 / 15px | `#FFFFFF` |
| Small row-action button label (e.g. "Open"/"Switch"/"Run") | **11px** / 500 / 13px | `#FFFFFF` — smaller than toolbar buttons, confirmed distinct |
| Hero stat number (Insights) | 22px / 500 / 27px | `#FFFFFF` |
| Micro/badge text | 10-11px / 400-500 | `#959699` or accent-matched |

### 2.3 Corner radius — chosen per component type, not one universal scale

| Radius | Used for |
|---|---|
| `4px` | Body/collection panels, small buttons, badges, nav rows |
| `6px` | Routine icon container specifically |
| `8px` | Workspace cards, avatars |
| `10px` | Sidebar top icon button |
| `16px` | Outer app window |
| `20px` | Pills/badges (e.g. "Active" badge) |
| `48px` | Project/tag pills (Home screen) |
| Full circle (`1000px`/`100px`) | Traffic lights, toggle knobs, small status dots — **not** the workspace/routine avatars, which are rounded squares at 8px/6px, not circles |

Insights panel cards (stat cards, chart panel, workspace-breakdown panel, recent-activity panel) use **6px**, not the 8px used by Workspaces cards — this is a real, confirmed difference between the two screens, not an error to "fix."

### 2.4 Resolved: canonical accent is `#5C84FE`

Three different blues appeared across the wireframe set:
- `#5C84FE` — the baseline, used on Routines/Workspaces icons+avatars and the Insights chart's peak bar
- `#5E69D1` / `#6D78D5` / `#575AC6` (an indigo family) — used on Settings' toggle track and theme-swatch accent dots
- `#5E6AD2` — Linear's own brand purple, appearing on the Home screen's "Done" status dot (this screen is a re-skinned Linear template with leftover unconverted styling in places — see §2.5)

**Decided 2026-07-12: `#5C84FE` is the one canonical accent everywhere.** The indigo family and Linear's purple are un-cleaned template residue, not intentional design — already how checkpoint 2's rebrand implemented it. When checkpoint 3 builds real Settings toggles, use `#5C84FE`, not the indigo family shown in the Settings wireframe.

### 2.5 Important caveat — Home and Insights content is largely placeholder

Both the Home/Tasks screen and Insights screen are built on a re-skinned Linear (project-management tool) template. Confirmed via literal CSS layer names and stale duplicated component names ("Linear", "Inbox" ×5, "Making Linear's design system"). Only the **chrome was actually relabeled** to Sonny (sidebar wordmark renders "Sonny", nav items render Tasks/Insights/Routines/Workspaces/Settings) — the task titles, project names, and stats shown are Linear's own placeholder content, not anything Sonny-specific. Use the **structural pattern** (stat-card layout, bar-chart style, list-row style, grouped-by-status layout) when building checkpoint 4 — do not use the literal copy or numbers shown.

### 2.6 Checkpoint 3 (Settings) — real content spec

Settings sidebar has an account section with four rows: Profile, **Preferences** (shown active/selected), Notifications, Security & Access — only "Preferences" has a detailed wireframe. No wireframe exists for "Privacy & Permissions" (the app's other current placeholder row) — that gap needs to be filled before or during checkpoint 3, either with new wireframes or your own design judgment.

Preferences page, confirmed real controls:
- **"Display full names"** — toggle. Description: "Show full names of users instead of shorter display names."
- **"Use pointer cursors"** — toggle. Description: "Change the cursor to a pointer when hovering over any interactive element."
- **"Interface theme"** — a 3-option picker (swatch buttons). First option confirmed "Dark" (selected). Second inferred "Light". Third option's label is **UNCONFIRMED** — its text box is proportioned for a longer word (plausibly "System") but was never rendered as readable text in the export. Description: "Select or customize your interface color scheme."

Toggle track radius `20px`, knob full-circle, knop shadow `0 0 4px rgba(0,0,0,.25)` (the one shadow exception in System A, confined to this one control). Theme swatch buttons use `5px` radius (a value not seen elsewhere).

Open question: this Settings window is authored at `1093px` wide, versus `1440px` for every other main-app screen (Home, Routines, Workspaces, Insights). **Confirm whether Settings is intentionally narrower** (e.g. a modal-like panel) or whether this is unintentional Figma sizing before implementing.

### 2.7 Checkpoint 4 (Insights) — real content spec

Layout, top to bottom inside the body panel (24px/30px padding, 16px gap between sections):

1. **Stat row** — 4 equal-width cards, `12px` gap. Each: muted label (12px) → hero number (22px/500, largest text on the page besides the title) → delta line (11px, green `#3FB950` if positive / muted gray if neutral). Real equivalents: completed-this-week count, completion rate, avg cycle time, current streak — source from `TaskUsageRecorder`/`TaskUsageSummary` (branch 6), not fabricated.
2. **Weekly bar chart** — single-series, 7 columns (Mon-Sun), no axis lines, no gridlines, no Y-axis labels — just bars plus day labels underneath. Bars have `3px` rounded tops. One bar (whichever day is the peak) renders in accent `#5C84FE`; all others render in muted navy `#242E52`. Drive bar height from the real data ratio, not fixed pixels.
3. **Workspace breakdown** — horizontal progress bars, one row per workspace: small colored swatch (matches a per-workspace color) → workspace name → track → trailing percentage. **Note**: in the wireframe itself, the drawn bar width doesn't precisely match its printed percentage (a wireframe authoring imprecision) — drive the real implementation's width from the actual percentage, not by eyeballing the mock.
4. **Recent activity list** — simple rows, no dividers: colored status dot (green = completed) + item name + right-aligned relative timestamp (e.g. "Today, 9:41 AM").

---

## 3. System B — Floating Widget + System Notifications

Not yet built (branch 9). Captured here so the spec exists before that branch starts.

### 3.1 Foundation

- **Typeface**: SF Pro / SF Pro Display, not Inter. One recurring non-standard weight value, `510` — this is Apple's SF Pro "Medium" optical-weight token, distinct from standard 400/500/600/700; use where the source specifies it.
- **Material**: a translucent "Liquid Glass" system, not a flat fill. Base panel color `#1A1A1A`, layered via `linear-gradient` + `rgba(26,26,26,.5)` doubled, blend modes `lighten`/`luminosity`. Edge/rim is not a real border — it's a 3-pass hairline `#A6A6A6` box-shadow (`±1.25px` offset + a `0.5px` outline pass, blend `plus-darker`).
- **Panel radius**: **not uniform across System B — two distinct values.** The floating widget's own pill and expanded step-log panel use `34px` (on the 40px-tall pill this exceeds half-height and renders as a full stadium; on the taller panel it renders as a genuine soft rounded rect). The **system notification banner uses a different, smaller radius: `20px`** on its 344×56 card — don't apply the widget's 34px to notifications, they're visually distinct components that happen to share the same shadow/glass recipe (§3.2). Circular buttons in both: `1000px`.
- **Accent colors — do not reuse System A's `#5C84FE`.** These are per-action, not one universal accent:
  - `#0091FF` — primary actions (the "Start"/"Open" pill buttons)
  - `#FF9230` — generic secondary circular button (reused for both a mic-looking button and a retry button — this color means "secondary circular action," not any specific meaning)
  - `#30D158` — Allow/confirm action (inferred from the green iOS-system-color convention and position; the permission prompt has no text labels, this reading is contextual, not printed)
  - `#FF7474` — error indicator (icon glyph color + triggers a text-brightness promotion from muted to full white on its row)
  - `#FF383C` — a distinct, more saturated red seen on a dismiss/error button (separate from the softer `#FF7474` icon color)
  - Neutral/untinted button variant: `rgba(153,153,153,.17)` fill, same `#A6A6A6` hairline, lighter shadow (`0 8px 15px rgba(0,0,0,.04)`) — used for a Deny/dismiss-style action, no color tint

### 3.2 Shadow recipe (exact, reusable — confirmed byte-identical across every widget state checked)

```
box-shadow:
  1.25px 0 0 -0.75px #A6A6A6,
  -1.25px 0 0 -0.75px #A6A6A6,
  0 0 0 0.5px #A6A6A6,
  0px <offset>px 48px rgba(0,0,0,.45);
```
Where `<offset>` is `8px` for the system notification banner and `18px` for the floating widget's own panels — same algorithm, different vertical drop distance depending on how "elevated" the element should feel.

Inner glass highlight (all glass surfaces): `inset 0 40px 10px -40px #1A1A1A, inset 0 -40px 10px -40px #1A1A1A`. Tinted circular buttons only get one more highlight layer on top: `inset 0 40px 30px -40px #E6E6E6`.

### 3.3 Lifecycle states, confirmed from the wireframe set

1. **Idle** — pill only (472×40). Leading icon (61% opacity), ghost placeholder query text with an active blinking cursor `|`, trailing blue "Start ⌄" pill button. A separate circular icon button (orange-tinted, likely voice/mic — inferred from the circular-tinted-button convention, not printed) floats 12px to the pill's right, outside the pill itself.
2. **Working** — pill persists unchanged; a step-log panel expands **upward** above it (bottom-edge-pinned, panel grows as rows are added, confirmed by comparing panel heights across states while the bottom y-coordinate stays fixed). Each row: icon slot (static glyph if done, live 8-blade indeterminate spinner if active) + label text. **Text opacity is the state signal**: done/inactive rows sit at `rgba(255,255,255,.55)`, the active row is full `#FFFFFF`.
3. **Asking for permission** — a third row appends to the same panel: "Allow access to [icon] [Documents folder]" in full white, plus two icon-only circular buttons (neutral "Deny", green `#30D158` "Allow") — no modal, no text-labeled buttons, just this inline row.
4. **Result / success** — panel shows a body sentence + a file-preview chip (48×48 thumbnail, filename, size, modified date) + a blue `#0091FF` "Open" pill button, right-aligned.
5. **Step-level error (retryable)** — the failed row's icon turns coral `#FF7474`, its text promotes to full white (same "active" treatment as a working row), and an orange `#FF9230` circular retry button attaches to that specific row. Other rows are unaffected — this is a per-step failure, not a task-level one.
6. **Task-level failure (terminal)** — after the step rows, a final line reads "Sonny failed to complete the task" in full white (confirmed verbatim from the SVG's literal text content, high confidence). The pill below shows the same empty-input/"Start"-pill layout as the idle state, **but with a retry button attached to the bar** (a 36×36 circular button 12px to the pill's right — the same position idle's mic-like button occupies, but functioning as a task-level retry here). So this state offers both: type a new command, or retry the whole failed task via the attached button — it is not a hard dead-end requiring a fresh command. This is still a distinct resolution path from step-level error (§3.3.5's inline per-row retry) — one retries a single step, this retries the whole task — but "must start over with new input" was an overstatement on my part in an earlier draft of this doc; corrected here.

### 3.4 Positioning when composited with the main app window

Confirmed from a wireframe showing both surfaces open simultaneously: the widget does **not** float centered on the screen or docked to the screen edge when the main app window is also open. It sits **inset inside the main window**: window origin (432,124) at 1440×969, widget origin (740,847) at 491×142 — that's 308px in from the window's left edge and 104px up from the window's bottom edge, landing in the left-of-center, lower portion of the window (roughly 21%-55% of window width, near the bottom). Not centered, not full-width. In this composited state, only the step-log panel appears; the separate idle input pill is not shown alongside it.

---

## 4. Source file reference

All files at `/Users/sauranshbhardwaj/Desktop/wireframes/`. Each has a matching `.svg` and `.md` (CSS).

| # | File | Screen | System |
|---|---|---|---|
| 1 | PermissionNotification | macOS Notification Center banner, permission-style | B |
| 2 | ErrorNotification | macOS Notification Center banner, error-style | B |
| 3 | FloatingWidgetStart | Widget idle state | B |
| 4 | FloatingWidgetWorking | Widget mid-task, step log | B |
| 5 | FloatingWidgetAskingForPermission | Widget inline permission row | B |
| 6 | FloatingWidgetResultOutput | Widget success/result card | B |
| 7 | FloatingWidgetError | Widget step-level error + retry | B |
| 8 | FloatingWidgetFailure | Widget task-level terminal failure | B |
| 9 | MainAppHomeScreen | Tasks dashboard (Linear-template content, chrome only is real) | A |
| 10 | MainAppSettings | Settings → Preferences sub-page | A |
| 11 | MainAppRoutines | Routines screen (already implemented, checkpoint 2) | A |
| 12 | FloatingWidgetWorkingInsideMainApp | Widget composited over the open main app window | A + B together |
| 13 | MainAppWorkspaces | Workspaces screen (already implemented, checkpoint 2) | A |
| 14 | MainAppInsights | Insights screen (Linear-template content, pattern only is real) | A |

---

## 5. Open questions — do not silently resolve these, ask first

1. ~~Which accent blue is canonical~~ — **resolved 2026-07-12**: `#5C84FE`, see §2.4.
2. Is the Settings window's narrower width (1093px vs. 1440px elsewhere) intentional?
3. What does the third Settings theme-swatch option actually say? (Plausibly "System", unconfirmed.)
4. No wireframe exists for the "Privacy & Permissions" Settings row — needs new design input before checkpoint 3 finishes that page.
5. The exact SF Symbol identity of a few icon-only buttons in the floating widget (voice/mic button, permission Allow/Deny icons) is inferred from convention and position, not confirmed by a readable label — worth a visual gut-check when branch 9 actually starts.
