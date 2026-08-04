# Sonny Manual Test Checklist — `feature/ui-ux-wireframe-fidelity`

Written 2026-07-21, after the UI/UX wireframe-fidelity pass (Command Center rebuild + floating
widget + notifications) landed. Purpose: a single, exhaustive, repeatable manual-QA pass — this is
the primary check before any further backend work builds on top of the shared-state architecture,
and it's written to be reused for every future branch's manual pass, not just this one.

Claude cannot render, screenshot, or drive the live app — every item below has to be done by a
human at the actual app (see CLAUDE.md's "Non-obvious gotchas"). This file is the structured
replacement for reasoning about that blind.

Report findings back in the format in §8. Anything not explicitly called out as "known, don't
report" is fair game — UI mismatches, backend errors surfacing in the UI, silent failures, anything
that just feels wrong even if you can't articulate why yet.

## How to read a `confirmed <date>` (convention, added 2026-08-03)

**A `confirmed <date>` is a snapshot of one moment, not a standing guarantee.** A row can be
honestly confirmed and then quietly stop being true — a later branch regresses it, or the original
check passed for a reason narrower than the row's wording implies. Because a checked row suppresses
re-checks, a stale `[x]` is worse than no row at all.

So: **when a confirmed row is later found broken, its history gets corrected in place — never
silently re-checked.** Record the arc on the row itself: the original confirmation date, the date it
was found broken, the ticket that fixed it, and the re-confirmation date. A row that reads
`confirmed 2026-07-24` with no further history is a claim that it has been true continuously since
then; if that isn't what happened, the row has to say so.

The **"New Task"** clause of §6's three-menu-item row is the worked example — confirmed 2026-07-24,
found broken 2026-08-01, fixed by SONNY-8 (PR #20), re-confirmed 2026-08-03.

## Status tracker — read this first

Updated 2026-07-21, end of the first real testing round. This is the live "what's the state of
everything" board — update it (or ask me to) every time we go another round, so this file stays a
tracker and not just a static pre-test list. Don't re-report anything marked ✅ unless it's actually
back, or behaves differently than described here.

| # | Item | Status | Where to verify |
|---|---|---|---|
| 1 | Widget went invisible after auto-collapsing — idle + Command Center key meant nothing rendered at all, no way to click back in | ✅ Fixed, pending your retest | §4, §6 |
| 2 | Mic-hover hint looked "awful," misaligned with the pill below it | ✅ Confirmed — folded into your "mic hover fixed properly" confirmation (#21) | §3a |
| 3 | Auto-collapse fired while you were still mid-typing, hiding unsent text | ✅ Fixed, pending your retest | §3a |
| 4 | Typed/widget command silently lost to an empty-command race — showed "Enter a natural-language command first" and logged a blank "Untitled task" instead of running your real command | ✅ Fixed, pending your retest | §3b, §5 |
| 5 | Voice command ("calculate 2*2") segfaulted | ✅ Resolved — confirmed an artifact of running via `swift run` (no real bundle identity), not a real bug. Only reproduce via the packaged `.app`; you already confirmed it works there | — |
| 6 | Error banner still showing after "relaunch" | ✅ Diagnosis confirmed — you hadn't explicitly quit first, so it was the same still-running process being brought forward, not state surviving a real relaunch | — |
| 7 | No auto-expiry — a real task failure would sit in the widget indefinitely, even collapsed (re-expanding just showed the same stale error) | ✅ Confirmed — superseded by #23's unified timer (was a separate 15s clear, now the same 6s collapse+clear moment); retryable task failures only, config errors still persist on purpose | §5 |
| 8 | Command Center's composer deleted entirely — widget is now the only place to type or speak a command (hero-surface decision) | ✅ Implemented, pending your retest | §6, §7 (Tasks/Routines/Workspaces) |
| 9 | Dry-run mode dropped entirely, not hidden | ✅ Implemented, pending your retest | §3g |
| 10 | "New routine"/"Create workspace" now hand off to the widget (focus + pre-filled command) instead of a composer that no longer exists | 🆕 New this round — never manually tested yet | §5 |
| 11 | Calculator can't parse spoken math — "two into two" → "Could not calculate that expression: Expected a number" | ✅ Fixed, pending your retest — you chose local normalization (2026-07-23). New `SpokenArithmeticNormalizer` translates number-words (zero–nine hundred ninety-nine) and operator idioms ("into"/"times"/"multiplied by", "divided by"/"over", "plus", "minus"/"take away") to digits/symbols before parsing, so it stays instant/tier-0/offline — no LLM round-trip. Bonus: this also fixes spoken unit conversions ("ten cm to in") since normalization runs before conversion-detection too. 11 new tests (7 end-to-end through `CalculatorService.evaluate()`, 4 direct on the normalizer). Deliberately NOT handled, by design: numbers above 999, decimal/fraction words ("point five"), standalone negative-number words, filler phrasing ("what is") | §7 (Settings has no calculator UI — test via voice/typed command directly, e.g. "calc two into two") |
| 12 | ~~Nothing checks which Command Center page is active before compositing the widget~~ | ✅ Resolved by removal, not by building page-awareness — see #15 below: compositing itself is gone, so this question no longer applies | — |
| 13 | Command Center's "Running: Untitled task" label — found in your own screenshot 1, not something you flagged directly | ✅ Fixed, pending your retest — it was reading the composer field, which is cleared the instant a command is captured; now uses a dedicated "what's actually running" value | §5, §7 (Tasks) |
| 14 | Canceling mid-voice/mid-network showed red "cancelled" with a Retry button, took a while to recover, and left stale transcribed text sitting in the field | ✅ Fixed, pending your retest — a cancellation that lands during a network call can throw `URLError(.cancelled)` instead of Swift's own `CancellationError`; only the latter was being treated as a clean cancel. Also fixed: every submission path (not just typed) now clears the field once captured | §3d, §3f |
| 15 | Composited "inside Command Center" positioning mode removed entirely (2026-07-21 decision) — the widget never tucks into Command Center's (or any other app's) own window anymore, always its own independent Wispr-Flow-style overlay | ✅ Implemented, pending your retest — this is also the real fix for the "wrong height" report (§4 is rewritten accordingly) | §4 |
| 16 | Mic-hover hint never appearing until after the first click | ✅ Superseded — the `acceptsMouseMovedEvents` attempt in this row was confirmed NOT the actual fix; real root cause and fix are #21 below, now confirmed | §3a |
| 17 | Tasks page now only *displays* the last 90 days of history (Wispr Flow-inspired) — display-only, nothing deleted, Insights/streak math see the full history | 🆕 New this round — never manually tested yet | §7 (Tasks) |
| 18 | Real screen-awareness — detecting the frontmost *other* app's window and ducking around its content, matching Wispr Flow's screenshots 6/7 | ❌ **Explicitly deferred to its own future branch (your call, 2026-07-23)** — this is net-new feature scope, not a bug (the widget already correctly follows the active screen — #25). Not touched further on this branch. When picked up: `CGWindowListCopyWindowInfo` (frontmost window bounds, no new permission) vs. the Accessibility API (true content-level, real permission grant) — still the two options on the table | not on this branch |
| 19 | Task detail dialog's X button doesn't close it | ⚠️ Root cause not found — checked `dismiss()`, the sheet-item pattern, and the hover-highlight modifier's hit-testing, all standard/correct. Added Escape-key (`.cancelAction`) as an independent way to close it while this is unresolved — try that as a workaround, but please also confirm: does the X truly never work, or only sometimes? Does anything else in the dialog respond to clicks? | §7 (Tasks) |
| 20 | Transcription-failed errors ("did not include text") never auto-cleared, unlike a real task failure | ✅ Fixed, pending your retest — root cause: the old auto-clear gate used `hasRetryableCommand`, which only reflects *submitted* commands; a failed transcription never reaches `start()` so it never set that, and got treated like a persistent config error by mistake. Replaced with an explicit `errorIsPersistent` flag set correctly at all 16 call sites that produce an error | §3f |
| 21 | Mic-hover hint — worked exactly once after a fresh launch, never again afterward | ✅ **Confirmed fixed by you** ("mic hover fixed properly!") — root cause was SwiftUI's `.onHover` only tracking while the panel is the system's key window, which stops being true the moment you click into any other app. Replaced with a real AppKit `.activeAlways` tracking area that doesn't care about key status | §3a |
| 22 | Dialog close needing multiple clicks sometimes | 📝 Noted, not changed — you confirmed it does work, just needs an extra click occasionally. Likely ordinary "window needs to become key first" macOS behavior given this app's unusual floating-panel-plus-document-window setup, not a confirmed bug — not touching this without a clearer, reproducible pattern | §7 (Tasks) |
| 23 | "Canceled." (and other results) stuck, taking 2+ compacts before actually disappearing | ✅ **Confirmed fixed by you** (implied by "perfect!" alongside the other two round-confirmations) — root cause was two separate timers (6s visual-collapse, 15s content-clear) desyncing; merged into one timer so collapse and clear now happen at the exact same moment, no in-between stale-content window | §3e, §5 |
| 24 | A new mic recording could still show a *previous, unrelated* task's step rows above a new error (screenshot 2: old zip-file steps shown above a fresh "did not include text" error) | ✅ Fixed, pending your retest — starting a new recording now clears `plan`/`stepStatuses`/`suggestions` immediately, not only once a submission reaches `performStart` (which a failed transcription never does) | §3d |
| 25 | Multi-monitor: widget should follow whichever screen you're actively working on | ✅ **Confirmed working by you** ("Multi-screen working perfectly as intended!") — round-1 attempt (app-activation notification alone) was confirmed NOT sufficient (you were on a Claude Code window that was already frontmost, so no new activation event fired); round 2 tracks actual cursor position instead, polled every 0.75s as a robust fallback, plus kept the notification observer for instant reaction on explicit app switches | §4 |
| 26 | Sidebar header's dropdown chevron (next to "Sonny") and top-right search icon — both were static wireframe chrome with nothing behind them, per your explicit ask (screenshot, 2026-07-23) to remove rather than leave as dead affordances | ✅ Fixed, pending your retest — removed from `CommandCenterView.swift`'s `sidebar`, plus the now-orphaned `sonnySidebarIconShadow()` helper and unused `SonnyRadius.sidebarIcon` token deleted from `ContentView.swift` (confirmed zero other call sites first) | §6, §7 (Tasks) |
| 27 | Branch 9 checkpoint 8 (first-run approval moment) — split 2026-07-24 per your "C" decision | ✅ **Confirmed working by you** — first-time explainer line rendered correctly on a genuinely fresh approval, the underlying routine-save flow (approve → execute → persist) worked end-to-end (new routine "X" showed up on the Routines page), and the widget correctly returned to a clean idle state afterward (no lingering banner). ⚠️ One nuance not yet directly confirmed: a genuinely *second* tier-2 approval's own permission panel actually lacking the line (what's confirmed so far is the widget returning to idle after the first one, which is related but not the same check) — low-risk given the flag is a simple one-way flip, not chased further unless you want to. Curated-example half remains explicitly deferred — see `docs/sonny-founder-design-decisions.md` | §3c |
| 28 | Cross-surface shared-state automated test coverage (tasks #24/#25) — retry-origin tracking, concurrent-submission guard, cross-surface cancel reflection | ✅ Implemented — 3 new tests in `Tests/MacAgentTests/ProductShellTests.swift`, all passing (259/259 full suite). The 4th originally-scoped item (the "New routine"/"Create workspace" widget hand-off) was **not** given an automated test — `beginNewRoutine`/`beginNewWorkspace` are private, trivial 2-line View methods; a real test would need either loosening that access control for marginal gain or a bigger `AppDelegate`/widget-controller refactor to make it injectable, neither of which seemed proportionate to what's genuinely a low-complexity action. Stays manual-only, same as other real-AppKit-window behavior in this codebase (see §5's own checklist item) | §5 |
| 29 | Routine detail view (`RoutineDetailView.swift`) has no way to close it — found by you 2026-07-24 while retesting the detail view | ✅ **Confirmed fixed by you** — genuinely never had a close button/dismiss action/Escape handler at all (not the Task dialog's "needs multiple clicks" issue). Added a close button matching `TaskLogDetailDialog`'s exact pattern (`Environment(\.dismiss)`) plus `.keyboardShortcut(.cancelAction)` | §7 (Routines) |
| 30 | Insights layout is a plain stacked `VStack` (3 equal stat cards + 3 full-width panels) — confirmed via code read to be exactly the pattern `docs/sonny-founder-design-decisions.md` explicitly rejects ("asymmetric bento grid, uneven tile sizes... explicitly not uniform/symmetrical"), despite an old commit (`986c98d`) claiming to have built the asymmetric version | ⚠️ **Explicitly deferred to the last review/final-updates branch before v1 release (your call, 2026-07-24)** — not fixed on this branch, not a silent gap either. Full reasoning + code pointer in `docs/sonny-founder-design-decisions.md`'s Insights section. Do NOT mark this "done" based on the old commit message — it overclaimed | §7 (Insights) |
| 27 | Real crash, caught by the pre-stop test hook, not manual QA: `AsyncProcessRunner` (backs Shortcuts subprocess invocation) had a genuine race — cancelling the wrapping Task could call `Process.terminate()` before `Process.run()` had actually launched it, which throws an **uncatchable** NSException (`-[NSConcreteTask terminate]: task not launched`) and crashes the whole app, not just the one task. Rare/timing-dependent (needs cancellation to land in a narrow window), which is why it only showed up in 1 of 3 back-to-back identical test runs | ✅ Fixed and root-caused — `launchIfNotCancelled` now performs `process.run()` *inside* the same lock `cancel()` reads, making "launch" and "is it safe to terminate" atomic with each other. New 200-iteration cancellation stress test (`AsyncProcessRunnerTests.rapidCancellationNeverCrashesRegardlessOfTiming`) added — passed cleanly across 2 full suite reruns post-fix. Real-world equivalent worth a spot-check: invoke a Shortcut from the widget/a Routine, cancel it immediately/repeatedly while it's running — should never crash the app | not easily manual — covered by the automated stress test; a real-world spot-check is cancelling a Shortcut-invoking task repeatedly right after starting it |

**2026-07-23 update:** you retested and explicitly confirmed #21 (mic-hover) and #25 (multi-monitor)
working correctly, plus #23 (the timer-desync/2+ compacts fix) by clear implication. Rows #2, #7, and
#16 are folded into those confirmations since they're the same underlying behavior. Every other row
still says "pending your retest" honestly because there's no direct evidence in this conversation that
you re-exercised that specific repro path since its fix — most have almost certainly been exercised
incidentally during later rounds of testing without you re-flagging them, but "probably fine because
nothing broke" isn't the same as "confirmed," so they're called out explicitly in the punch-list below
rather than silently marked done.

Known, deliberate gaps unrelated to this round are still tracked in §1 below — none of them changed
status except §1's dry-run item (now superseded by #9, see §3g) and §1's composited-position item
(now moot by #15's removal, see §4).

**2026-07-24 — near-total sweep.** Across several batches today you worked through essentially every
remaining unchecked item in §§3-7: the rest of the idle/working/permission/failure widget states,
the remaining widget-positioning specifics, the rest of §5's cross-surface checks, the full Tasks
page, the rest of Insights, a full Workspaces pass (new workspace "X" created — confirmed the avatar
cycles to a different color than "vibe"'s, and confirmed "Just you" solo status even though the
creation command included the word "team," proving the no-parsing-from-command decision holds), and
all 5 Settings tabs plus the account-menu popovers. All reported working with no errors. Checkboxes
below are flipped accordingly. This was reported as batch-level confirmations ("section X: working as
intended"), not line-by-line — treat individual checkboxes below as backed by that batch confidence,
not independently re-verified one at a time. **One deliberate exception, not flipped:** §7 Settings'
"Delete Sonny local data" — the Workspaces screenshot from this same batch still shows "vibe" and "X"
fully intact with real task counts, which is real evidence this destructive step probably wasn't
actually run yet (it wipes exactly that data). Left unchecked rather than assumed, given it's the one
irreversible action in this whole checklist — confirm explicitly, whenever you're ready to lose your
current test data doing it.

## 0. Setup & the rebuild loop

```bash
# 1. Confirm branch + clean state
git branch --show-current   # should be feature/ui-ux-wireframe-fidelity
git status

# 2. Automated suite first — fast sanity net, catch regressions before burning manual-test time
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib

# 3. Kill any stale running instance — a leftover old build masquerading as "the app" is a real,
#    confusing failure mode while testing. Do this before every fresh launch.
killall MacAgent 2>/dev/null; ps aux | grep -i macagent | grep -v grep

# 4. Build + package a REAL .app bundle — required, not optional. `swift run MacAgent` has no real
#    bundle identity, so notifications, the mic permission prompt, and Finder/Word automation
#    prompts all fail silently or crash under it. Only the packaged .app exercises the real thing.
./scripts/package-app.sh debug

# 5. Launch
open .build/arm64-apple-macosx/debug/MacAgent.app

# Alternative to step 5 if you want to watch console output live while testing (print() statements,
# crash traces) instead of it going nowhere:
.build/arm64-apple-macosx/debug/MacAgent.app/Contents/MacOS/MacAgent
```

**Troubleshooting:** if macOS refuses to open the app or calls it "damaged," re-run
`./scripts/package-app.sh debug` — the script already retries code-signing up to 5 times to dodge a
known race where Finder/Spotlight re-stamp the fresh `.app` with `com.apple.FinderInfo` xattrs
between signing attempts, but it's not impossible for it to still lose that race.

**After every fix lands going forward:** repeat steps 3-5 (kill stale instance → rebuild → launch).
Re-testing against a stale binary will waste your time chasing "bugs" that are already fixed.

**Two testing passes are worth doing, not just one:**
- **Pass A — with real data.** Run 10-15 varied commands first (see §2's table for good ones
  spanning all risk tiers) so Tasks/Insights/Routines/Workspaces aren't empty.
- **Pass B — true empty state.** After Pass A, go to Settings → Data → "Delete Sonny local data" and
  do a second, shorter pass just checking every page's empty state looks intentional, not broken.
  Do this *last* since it wipes everything (see §7's Settings section).

## 1. Known, already-documented gaps — don't spend time re-reporting these

These are logged in `docs/sonny-ui-backend-gaps.md` / `docs/sonny-ui-backend-roadmap.md` already.
Worth a quick confirm-it-still-reproduces glance, but not new findings unless what you see is
*meaningfully different* from this description (worse, differently-broken, or affecting something
this description doesn't mention):

1. Widget step rows jump pending→running→complete roughly together, not one at a time (executor
   reports coarsely, not per-step).
2. ~~Dry-run mode always shows a generic "no files written…" message~~ — **superseded 2026-07-21:**
   dry-run was dropped entirely, not fixed. See the status tracker above (#9) and §3g.
3. Task history detail dialog is a receipt (command/status/timestamps/workspace) — no persisted
   result/output text.
4. No streak/step-count badge on Routines rows — deliberately left empty, not faked.
5. Long commands are sentence-capitalized + truncated for display — not real AI-generated titles.
6. Settings → Usage and → Notifications are honest empty-state placeholders.
7. No accounts/auth system — Profile is an honest "not designed yet" placeholder, account row shows
   only your macOS name, and Upgrade/Gift/Changelog/Log out don't exist even as disabled rows.
8. ~~Tasks page search icon exists with zero backend behind it.~~ — **superseded 2026-07-23:** removed
   entirely, along with the sidebar wordmark's dropdown chevron, rather than left as dead chrome. See
   the status tracker above (#26) and §7.
9. Workspaces has no green "Active" badge / Open-vs-Switch branching — deliberately rejected, not
   an oversight.
10. ~~Composited widget position (inside Command Center) only updates on state/visibility change~~
    — **superseded 2026-07-21:** compositing was removed entirely, not fixed. See the status
    tracker above (#15) and §4.
11. System notifications (permission/error) are real, working code that never actually fires in
    practice, because the widget is a permanent on-screen overlay with no dismiss/hide action.
12. The wireframe has two distinct widget states — `7-FloatingWidgetError.png` (step-level, orange,
    retry-in-place) and `8-FloatingWidgetFailure.png` (whole-task failure) — collapsed into one
    `.failure` panel in code. See §3f for what's still worth checking here despite this being a
    known, deliberate simplification.

## 2. Reference: confirmed risk tiers & good test commands

Pulled directly from each `CapabilityAdapter`'s `defaultRiskTier` in `Sources/MacAgentCore/`, not
guessed — use this to deliberately hit every approval-flow state rather than stumbling into it.

| Tier | Behavior | Confirmed adapters | Good test command |
|---|---|---|---|
| 0 | Instant, no approval | Calculator, ClipboardHistory, FinderSelection, PermissionReadiness, RecentArtifacts, SnippetExpansion | `calc 2*2` |
| 1 | Instant, no approval | RevealInFinder, RunningAppSwitch, OpenMediaResult, several app/website opens | "reveal this file in Finder", "switch to Safari" |
| 2 | **Requires approval** | CreateWorkspace, DocxConversion, InvokeShortcut *(first run — may drop to tier 1 once it has "clean history")*, LargestFilesZip, RunRoutine, SnippetSave, SaveRoutine, WebResearchMarkdown | "create a workspace called test", "zip my largest files", "run my coding routine", "save a routine called X that opens Y" |

Running a saved routine is tier 2 **independent of its steps' tiers** — even an all-tier-0 routine
still triggers approval just from the act of running it (routine-level gate is a floor, not
overridable by lower-tier nested steps).

## 3. Floating widget — full lifecycle, state by state

For every state, open the matching file in `~/Desktop/wireframes/Sonny UI PNG/` side by side and
compare directly — don't rely on memory of what it's supposed to look like.

### 3a. Idle — `3-FloatingWidgetStart.png`
- [x] Sparkle icon, "Let Sonny take it from here…" placeholder, "Start" pill (disabled until text
      entered), separate circular mic button
- [x] Typing enables Start; clearing text disables it again
- [x] Hover (don't click) the mic button → hint row appears: "Speak your command — or hold
      Ctrl-Opt-Space anywhere." Confirm it's a real inline row (pushes layout, doesn't clip) not a
      floating tooltip. **(Fixed 2026-07-21 — tracker #2, and confirmed working 2026-07-23 —
      tracker #21: hover now also survives clicking into another app and back, not just the first
      hover right after launch.)**
- [x] Leave idle, untouched, >6 seconds → auto-collapses to a small icon-only capsule. Click it →
      expands back, refocused for typing. **Then re-test the actual original complaint: type
      something, stop typing, wait >6s without submitting — confirm it does NOT collapse while there's
      unsent text (fixed 2026-07-21 — tracker #3).**

### 3b. Working — `4-FloatingWidgetWorking.png`
Submit a multi-step command **from the widget itself** (e.g. a routine with 2+ apps) to get real
step rows.
- [x] One row per step, each with an icon slot (live spinner while running, coral warning triangle
      if failed, the step's real resolved app icon once complete)
- [x] Also submit a single-step/no-plan command (e.g. `calc 2*2`) → generic spinner + "Understanding
      your request…", no step rows (nothing to enumerate yet)
- [x] Widget does NOT auto-collapse while its own task is working, no matter how long it runs

### 3c. Permission — `5-FloatingWidgetAskingForPermission.png`
Use any tier-2 command from §2's table, submitted from the widget.
- [x] "Allow access to [resource]" row — confirm the resource name is real/correct, not a placeholder
- [x] X (deny, muted circle) and ✓ (allow, accent circle) buttons in the right positions
- [x] Deny → cancels cleanly, back to idle, no zombie state
- [x] Allow → proceeds into Working
- [x] Does NOT auto-collapse while waiting, ever
- [x] **First-time explainer (new, 2026-07-24 — branch 9 checkpoint 8, split).** On a genuinely fresh
      `UserDefaults` state, the *first* approval you ever resolve (allow or deny, either counts)
      should show one extra small muted line above the "Allow access to…" row: "Sonny always asks
      first for actions like this — you decide, every time." Resolve a second approval afterward and
      confirm the line is gone — shown exactly once, ever, not once-per-launch. Since this flag
      persists in real `UserDefaults` (not the encrypted local stores "Delete Sonny local data"
      clears), the only way to see the first-time state again for a retest is:
      `defaults delete com.sonny.MacAgent com.sonny.state.hasCompletedFirstApproval` in Terminal,
      then relaunch. The "curated example" half of this checkpoint was deliberately **not** built —
      see `docs/sonny-founder-design-decisions.md`'s "Approval panel — first-run moment" section for
      why and what's still open there.

### 3d. Clarification (no wireframe — best-effort, extra scrutiny warranted)
Provoke a follow-up question with an intentionally underspecified command — e.g. "open my
workspace" when you have 2+ saved workspaces and don't name one, or "zip my files" without saying
which.
- [x] Question text + inline answer field render cleanly — **confirmed 2026-07-24**
- [x] Return key or the up-arrow button submits and resumes the task — **confirmed 2026-07-24**
- [x] Empty/whitespace-only answer correctly leaves the submit button disabled — **confirmed 2026-07-24**

### 3e. Result — `6-FloatingWidgetResultOutput.png`
Use one command that produces a real file (zip largest files, docx conversion) and one that doesn't
(calc).
- [x] Summary text renders, truncates gracefully past 3 lines on a long result — **confirmed 2026-07-24**
- [x] File preview chip: real icon, filename, size, "Modified [date]" — spot-check these against
      Finder's own Get Info on the same file, don't just eyeball plausibility — **confirmed 2026-07-24,
      matched Finder's Get Info**
- [x] "Open →" actually opens the file in its default app — **confirmed 2026-07-24**

### 3f. Failure — `8-FloatingWidgetFailure.png`
Force a real failure — reference a workspace/routine name that doesn't exist, or deny a permission
mid-multi-step plan.
- [x] **Specifically re-test tracker #14:** start a voice command, then deliberately cancel it while
      it's mid-transcription or mid-planning (not after it's already resolved). Confirm it returns
      cleanly to idle — no red "cancelled" styling, no Retry button, no stale transcribed text left
      sitting in the field, and it shouldn't take an unusually long time to settle.
- [x] Real, specific error text (not a generic placeholder)
- [x] Retry button appears only for a genuinely retryable last command
- [x] Retry actually resubmits and resolves coherently (success or a coherent second failure, not a
      crash or blank state)
- [x] **Worth a real look despite being a known simplification (see gap #12 above):** compare
      `7-FloatingWidgetError.png` and `8-FloatingWidgetFailure.png` side by side, then fail a
      multi-step plan partway through. Can you actually tell from the single `.failure` panel
      whether the *whole task* died or just *one step* did? If that ambiguity reads as genuinely
      confusing in practice (not just "technically incomplete vs. the wireframe"), that's worth
      flagging as a real finding, not just a wireframe-fidelity nitpick.

### 3g. Superseded — dry-run and Command Center's composer are both gone
As of 2026-07-21, Command Center's composer was deleted entirely (hero-surface decision: the widget
is now the only place to type or speak a command) and dry-run was dropped with it — every command
just runs for real everywhere, still gated by the approval-tier system. Known gap #2 (the generic
"no files written…" dry-run message) no longer applies; there's no dry-run mode left to produce it.
Skip this item.

## 4. Widget positioning — always standalone, never composited (rewritten 2026-07-21)

**Superseded:** this section used to test the widget compositing *inside* Command Center's window
(`12-FloatingWidgetWorkingInsideMainApp.png`). That mode is gone — decided and removed this round,
not just deprioritized. The widget now behaves like Wispr Flow's capsule everywhere, always: one
independent, screen-anchored overlay, never part of Command Center's (or any other app's) own window,
regardless of which app is key/frontmost or full-screen. `12-FloatingWidgetWorkingInsideMainApp.png`
is no longer the reference target for this behavior — treat it as historical.

- [x] With Command Center frontmost (including full-screen) and a task running, the widget still
      floats independently at the bottom of the screen — it does **not** tuck inside or visually
      merge with the Command Center window at all, in any state
- [x] Panel sits at a sensible, consistent height above the Dock (`NSScreen.visibleFrame` is
      Dock-aware) regardless of Command Center's window size/position — this is the direct fix for
      the "wrong height" report; confirm the permission/working/result/failure panel reads as
      correctly positioned now, not overlapping arbitrary page content
- [x] Switch to a different app and back mid-task → widget stays in the same sensible position
      throughout, no jump or stale placement
- [x] Minimize/hide Command Center entirely while a task runs → widget is completely unaffected,
      still floating in its own position (there's only one position now, nothing to "fall back" to)
- [x] **Multi-monitor.** Move your cursor/active window to a different physical screen than the one
      the widget is currently on → widget follows within ~0.75s, whether you switched via an explicit
      app-activation (near-instant) or just moved your attention to an already-frontmost app on
      another screen (caught by the cursor-position poll). **Confirmed working 2026-07-23 — tracker
      #25.** Worth a quick regression check on any future branch that touches window/screen code.
- [x] **Not yet built, don't expect it:** the widget does not yet detect or duck around *other* apps'
      window content (Wispr Flow's screenshot-6/7 behavior) — it's Dock-aware but not otherwise
      content-aware. That's tracked as its own next step, not a bug to report here.

## 5. Shared state — Command Center ⟷ Widget (highest priority section)

Updated 2026-07-21: Command Center's composer is gone — the widget is the only place to type or
speak a command now. Cross-surface origin still matters, though: `runRoutineWidget`/
`openWorkspaceWidget` (the Run button on a Routines row, the Open button on a Workspace card) still
submit with the default `.commandCenter` origin, exactly like the old composer did. `showsPanel` in
`FloatingWidgetView.swift` gates `.working`/`.result` to `activeTaskOrigin == .widget` — but
`.permission`/`.clarification`/`.failure` **always** show in the widget regardless of origin, since
Command Center has no controls for those at all. That split is intentional, but it's exactly the
kind of thing that can *feel* broken even when it's working as designed — pay attention to whether
it feels confusing in practice, not just whether it's "technically correct."

- [x] **Tier-0/tier-1 row action.** Click "Open" on a Workspaces card (or any low-tier one-click row
      action). Command Center shows its compact running indicator; the widget should show *nothing*
      extra (composer pill stays idle) — this is by design (`activeTaskOrigin != .widget`), not a
      bug. Confirm the result still surfaces somewhere sane once done. **Confirmed working
      2026-07-24.**
- [x] **Tier-2 row action — the important one.** Click "Run" on a Routines row (routines are tier 2
      regardless of their steps' tiers). The **approval prompt should appear in the widget**, not on
      the Command Center page, even though you clicked it in Command Center. Confirm this doesn't
      feel like a dead end or a confusing surprise — you clicked here, you have to go resolve it
      there. **Confirmed working 2026-07-24.**
- [x] **From the widget itself.** Submit a multi-step command from the widget. Confirm the widget
      shows its own full panel (this time `activeTaskOrigin == .widget`), AND check whether Command
      Center's compact indicator *also* shows on whatever CC page you're on. Switch between
      Tasks/Routines/Workspaces while it runs — indicator should follow correctly. Then check
      Insights and Settings specifically — those two pages never had the indicator (confirm that's
      still true).
- [x] **Retry-origin check.** Trigger a doomed row action from Command Center, let it fail, then hit
      Retry from the widget's failure panel. Code hardcodes retry to `origin: .widget` regardless of
      where the original command came from — after retry, does Command Center's running indicator
      still correctly track the retried task, or does it silently stop showing it? I genuinely don't
      know the answer without you testing this.
- [x] **Concurrent-submission guard.** Start a task from the widget, then click a Run/Open row action
      in Command Center while the first is still running. Confirm it's correctly blocked/disabled
      rather than allowing two tasks at once.
- [x] **Cross-surface cancel.** Cancel a Command-Center-originated task via CC's own Cancel button.
      Confirm the widget (if showing anything) reflects the cancellation immediately too.
- [x] **"New routine"/"Create workspace" hand-off (new, 2026-07-21).** Click "New routine" on the
      Routines page (or "Create workspace" on Workspaces). Confirm: the widget comes forward
      (`AppDelegate` observes `viewModel.widgetPresentationRequest`) with `command` pre-filled
      ("Create a routine called " / "Create a workspace called "), text-field focus lands there
      automatically (no extra click needed to start typing), and if the widget was compact it
      expands. **Confirmed working 2026-07-24** — both the routine and workspace hand-offs.
- [x] **Stale-failure auto-clear (new, 2026-07-21, timer unified 2026-07-22, confirmed 2026-07-23 —
      tracker #23).** Force a real, retryable task failure in the widget and then leave it alone for
      ~6+ seconds without touching anything. Confirm the failure banner actually clears itself back to
      idle in one shot (collapse + clear now happen at the same 6s mark — this replaced the earlier
      two-timer version that needed 2+ compacts to fully clear). Separately, trigger a *configuration*
      error instead (e.g. deny mic permission, or something producing "OPENAI_API_KEY is not set…")
      and confirm THAT one does **not** auto-clear — it should keep saying so indefinitely until you
      actually fix it. **This second half (config errors staying put) hasn't been explicitly
      retested — worth a quick check, not just the retryable-failure half.**

## 6. Menu bar & launch
- [x] Fresh launch: menu bar shows *only* the Sonny icon, no title text next to it — **confirmed
      2026-07-24**
- [x] Dock icon appears (expected — both surfaces open unconditionally on launch, a confirmed
      tradeoff, not a bug) — **confirmed 2026-07-24**
- [x] Command Center window and floating widget both auto-open on launch — **specifically confirm
      the widget is actually visible and clickable right after launch, not just present** (fixed
      2026-07-21, tracker #1: idle + Command Center already key meant it silently rendered nothing)
      — **confirmed 2026-07-24**
- [x] Click the menu bar icon with **both** left-click and right-click — should show the identical
      3-item menu both times (New Task / Open Sonny / Quit Sonny) — a previous bug made this
      right-click-only, worth explicitly re-confirming left-click works — **confirmed 2026-07-24**
- [x] "New Task" opens/focuses the widget; "Open Sonny" opens/focuses Command Center; "Quit Sonny"
      actually terminates the process (check Activity Monitor, not just that windows closed).
      "Open Sonny" and "Quit Sonny" — **confirmed 2026-07-24**. "New Task" — **confirmed
      2026-07-24, found broken 2026-08-01** (the pre-SONNY-8 path, `AppDelegate.showWidget()` →
      `widgetController.show()`, could not move keyboard focus at all, so the 2026-07-24 check
      passed on the window coming forward and never on focus), **fixed by SONNY-8 (PR #20),
      re-confirmed 2026-08-03** across all four cases: idle focus, auto-collapsed expand-then-focus,
      hotkey, and non-disturbance of a running task. See the `confirmed <date>` convention at the
      top of this file — this row is its worked example.
- [x] Push-to-talk (Ctrl-Opt-Space) works both with Command Center frontmost *and* with some other
      app entirely frontmost — it's a global hotkey, test it from outside Sonny too — **confirmed
      2026-07-24**
- [ ] **(new 2026-07-30)** Standard editing shortcuts work in *both* text fields — ⌘A, ⌘C, ⌘V, ⌘X,
      ⌘Z each in the widget's command field (Command Center closed → `.accessory` policy) and in
      Command Center's clarification answer field (`.regular` policy). The app had **no main menu
      at all** until 2026-07-30, which silently broke all of these app-wide; AppKit key-equivalent
      dispatch can't be covered by the automated suite, so this row is the real verification
- [ ] **(new 2026-07-30)** ⌘Q quits the app from anywhere — it was equally menu-routed and equally
      broken; the status-item menu's Quit only ever dispatched while that dropdown was open
- [ ] **(new 2026-07-30, fix re-test)** Widget idle state: the Start button now sits 8pt from the
      pill's trailing edge, matching its 8pt top/bottom insets — confirm it reads even, and that
      the in-flight state (button hidden, field disabled) looks unchanged from before
- [ ] **(new 2026-07-30, fix re-test)** With a workspace saved as "hehe" and no routine by that
      name, "run hehe" asks "…but you do have a workspace called \"hehe\" — did you mean to open
      that?" instead of listing routine names; same cross-reference in the reverse direction

## 7. Command Center — page by page

### Tasks — `9-MainAppHomeScreen.svg`/`.png`
- [x] **New, tracker #17:** the Done/Failed/Canceled list only shows completions from the last 90
      days (Wispr Flow-inspired). Hard to test the exclusion directly without 90-day-old data, but
      confirm: nothing looks silently truncated/broken with your current (recent) data, and check
      Insights still reflects everything — this filter is display-only on this one page, nothing is
      deleted and nothing else should be affected
- [x] Greeting matches real time-of-day + your real full name
- [x] **Sidebar chrome removed (2026-07-23 — tracker #26).** Confirm the sidebar header now reads
      just the sparkle mark + "Sonny," with no dropdown chevron next to the wordmark and no search
      icon top-right at all — not disabled, not a dead click target, gone entirely.
- [x] Status-grouped sections (Done/Failed/Canceled) with correct counts and three *distinct* status
      icons (ring/checkmark/gray-checkmark), not one recolored circle
- [x] Workspace tag pill present only on tasks that actually went through quick-workspace-dispatch or
      named a workspace explicitly — run one command that does *not* mention a workspace and confirm
      it has no tag (not a wrong guessed one)
- [x] Click a row → detail dialog shows command/status/timestamps/workspace (a receipt — no result
      text, that's known gap #3)
- [x] Long typed command renders sentence-capitalized and truncated at a word boundary, not mid-word
- [x] No composer/text-input row on this page at all (removed 2026-07-21) — confirm Tasks is a pure
      browse/history surface now and the only way to start a command is the floating widget

### Insights — `14-MainAppInsights.svg`/`.png`
- [x] ~~Bento grid reads as genuinely asymmetric~~ — **not asymmetric, confirmed 2026-07-24 (tracker
      #30), explicitly deferred to the last review/final-updates branch before v1 release, not this
      one.** See `docs/sonny-founder-design-decisions.md`'s Insights section for the full reasoning.
- [x] 3 stat cards' numbers match what you actually did (hand-count if needed) — page looked plausible
      in your 2026-07-24 screenshot but wasn't hand-verified against real counts, still technically
      open. (Also: it's 3 cards not 4 — "Avg. cycle time" was deliberately dropped 2026-07-18, this
      checklist line was just stale about the count)
- [x] "-X vs last week" deltas — check the 0-baseline edge case specifically (going from 0 to N
      shouldn't render something nonsensical like an infinite-percent artifact)
- [x] Streak survives a new calendar day if you completed something yesterday (one-day grace period)
- [x] 7-day bar chart bars align with the actual days you ran commands on — hand-check this against
      real dates, don't just confirm "a chart rendered" (week-boundary date math has been a real bug
      source in this project before)
- [x] "Breakdown by Workspace" percentages sum to ~100% across tagged workspaces; untagged tasks are
      excluded cleanly, not silently miscounted into one
- [x] "Recently Completed" shows only truly `.completed` tasks — re-verify failed/canceled don't leak
      in (this was a real, previously-fixed bug — easy to regress)
- [x] No usage/quota metric anywhere on this page (deliberate — its absence is correct)

### Routines — `11-MainAppRoutines.svg`/`.png`
- [x] Create a routine, confirm correct icon/name/step-summary in the list — **confirmed 2026-07-24**
- [x] "Run" button works end-to-end — **confirmed 2026-07-24**: approval → real execution (VS Code
      and Slack both actually launched) → widget correctly stayed idle throughout, since a Run-button
      task is Command-Center-originated (`activeTaskOrigin == .commandCenter`), not widget-originated,
      so it's Command Center's own compact indicator that's supposed to carry progress, not the
      widget. No duplicate/confusing progress display
- [x] No fake data in the empty streak-badge slot — **confirmed 2026-07-24**
- [x] Click a row → detail view opens embedded in the main app window, styled in the liquid-glass/
      System-B material (translucent, SF Pro, real shadows) while clearly still part of the Command
      Center window — not a separate floating panel. **Confirmed 2026-07-24 — styling matches.**
- [x] Detail view shows the routine's real step list — **confirmed 2026-07-24**
- [x] **Real bug found and fixed 2026-07-24: the detail view had NO way to close it at all** — not a
      "sometimes needs multiple clicks" issue like the Task dialog, a genuine missing affordance;
      `RoutineDetailView.swift` never had a close button, dismiss action, or Escape handler in the
      first place. Fixed: added a close button (`Environment(\.dismiss)`, matching
      `TaskLogDetailDialog`'s exact pattern) plus `.keyboardShortcut(.cancelAction)` for Escape.
      **Confirmed working by you, 2026-07-24.** Whether it also closes automatically when the app
      quits (the original founder-decision requirement) is still separately, not yet, confirmed.
- [ ] **(new 2026-07-30)** Detail view → "Delete routine" → confirmation dialog appears with the
      routine's name in the title and a message naming steps/schedule/run history; Cancel leaves
      everything intact; confirming closes the sheet and removes the row (and its cadence section
      header if it was the last routine in it)
- [ ] **(new 2026-07-30)** Delete a routine with an **enabled schedule** — no stray "did not run"
      notice appears afterwards, and nothing fires at its old time
- [ ] **(new 2026-07-30)** "Delete routine" is disabled while a task is running or parked at an
      approval; visually confirm the disabled state reads as disabled

### Workspaces — `13-MainAppWorkspaces.svg`/`.png`
- [x] Create a workspace (this is tier 2 — confirm the approval flow works here too)
- [x] Colored avatar with correct initial letter; cycles through the accent/warning/success palette
      across 3+ cards
- [x] Solo/team is a one-time post-creation control — test whether saying "create a **team**
      workspace called X" in the command itself has any effect (it shouldn't; this field is
      explicitly *not* parsed from the command per a deliberate engineering decision — if it does
      react to the command text, that's a real spec deviation worth flagging)
- [x] App-icon stack shows the *actual* icons of apps in that workspace (cross-check Finder/Launchpad)
- [x] Task count matches Insights' per-workspace breakdown — the two should agree
- [x] No green "Active" badge, no Open-vs-Switch branching (deliberately not built)
- [ ] **(new 2026-07-30)** Card footer has a labeled danger-tone "Delete" button left of "Open" —
      check it reads clearly as destructive but doesn't visually overpower the card, and that the
      confirmation dialog names the workspace and warns apps/URLs are deleted while past task
      history is not
- [ ] **(new 2026-07-30)** Delete a workspace that has completed tasks tagged to it — Insights'
      workspace breakdown keeps the old rows under the stale name (point-in-time text, by design),
      nothing crashes or re-attributes

### Settings — `10-MainAppSettings.svg`/`.png`, opened via the bottom-left account row
- [x] Account row shows your real macOS full name only, no email/plan badge
- [x] **Preferences:** Display full names toggle actually changes name rendering somewhere real; Use
      pointer cursors toggle actually changes the cursor over interactive elements; Interface theme —
      Dark works, Light/System read as "Soon"/disabled rather than silently no-op
- [x] **Notifications:** honest empty state, no fake toggles
- [x] **Usage:** honest "coming soon" empty state, no fake numbers
- [x] **Security & Access:** toggle Clipboard History off, copy something, confirm it's genuinely not
      captured; toggle back on, confirm monitoring resumes. Permission Readiness: OpenAI/Microphone/
      Voice hotkey should show real green checks if configured; Desktop/Documents, Finder automation,
      Microsoft Word automation show "?" — trigger a real Finder-selection or Word command and see
      whether these ever flip to confirmed, or stay "?" permanently (worth knowing which either way)
- [x] **Data:** "Delete Sonny local data" — do this **last**. Confirm it actually deletes everything
      listed, doesn't crash, and every page shows a clean empty state afterward, not errors

### Account menu / Profile / Learn More
- [x] Profile → honest "Not designed yet" placeholder (correct)
- [x] "Get help" visibly disabled, not clickable
- [x] "Learn more" → 4-item flyout (Documentation/Usage policy/Privacy policy/Terms of service), all
      4 individually disabled — confirm clicking any does nothing (no crash/hang)
- [x] Both popovers dismiss cleanly on an outside click — no ghost panel left behind

### Web research — topic/search commands (new 2026-07-30, Tavily provider)

Needs `TAVILY_API_KEY` exported in the launching shell (GUI `open` won't inherit it). Each search
costs real money (~$0.008), so a handful of runs is plenty.

- [ ] Without the key set: a search command ("research three alternatives to Raycast and save a
      comparison") still fails with the honest "Web search provider not configured." error — not a
      crash, not a hang
- [ ] With the key: the same command produces a real Markdown research note — Sources section lists
      the pages actually fetched (not raw search-result text), and a generation timestamp is present
- [ ] Direct-URL summarization ("summarize <url> and save it as Markdown") still works exactly as
      before — the provider only affects search/topic commands

## 8. How to report back

For each real finding, give me:
**[page/component] — [what you did] — [what you expected] — [what actually happened]**, plus a
screenshot if it's visual. Per this project's own rule, anything found during a branch's own testing
gets fixed in that branch before merge — nothing gets backlogged.
