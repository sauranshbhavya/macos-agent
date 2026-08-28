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

## Where a manual item lives (convention, added 2026-08-26)

**Every manual-test item a ticket produces is added to this file as an unchecked row before the
ticket closes.** A PR note or a ticket comment may summarize them, but this file is the only place
the founders test from — an item recorded anywhere else is an item they never see. Not
hypothetical: SONNY-281's **thirteen** items lived only on PR #118 — seven in its body, six more
added by its review rounds' dated notes (the PR numbers them 1–7 and 8–13) — while the rows
SONNY-282 and SONNY-283 added the same days reached this file. The gap surfaced only when the
outgoing coordinator checked both branches' items against the file, and the first recovery pass
then took the six and left the seven: recovering *the* items means the whole population, latest
notes and original body alike (2026-08-26; all thirteen are now in §3d, the body's seven first,
because those are the reported defect and the notes' six are the edges the review rounds found).
A row names its ticket, and a row recovered late also names where it was recovered from.
WORKFLOW.md's ticket-template bullet used to say items "aggregate into the PR's manual checklist" —
the sentence SONNY-281's session followed exactly — and now names this file instead.

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
| 31 | Real crash, caught by the pre-stop test hook, not manual QA: `AsyncProcessRunner` (backs Shortcuts subprocess invocation) had a genuine race — cancelling the wrapping Task could call `Process.terminate()` before `Process.run()` had actually launched it, which throws an **uncatchable** NSException (`-[NSConcreteTask terminate]: task not launched`) and crashes the whole app, not just the one task. Rare/timing-dependent (needs cancellation to land in a narrow window), which is why it only showed up in 1 of 3 back-to-back identical test runs | ✅ Fixed and root-caused — `AsyncProcessRunner` now brackets `process.run()` with a `ProcessBox` that holds the process, a launch phase and the cancelled flag under one `NSLock`: `register(_:)` before the launch refuses to start at all if cancellation already arrived, and `confirmLaunched()` immediately after it hands the terminate to whichever of the two got there second, so `terminate()` is only ever called on a process that finished launching. **`run()` itself is deliberately *not* inside the lock** — this row said it was, and named `launchIfNotCancelled`, `AsyncProcessRunnerTests` and `rapidCancellationNeverCrashesRegardlessOfTiming`, none of which exist (`git grep` over `Sources` and `Tests` at `126507c` → 0 each); corrected 2026-08-26 by SONNY-290. The 200-iteration cancellation stress test is `AgentActionExecutorTests.asyncProcessRunnerCancelledBeforeLaunchDoesNotCrash` (`Tests/MacAgentCoreTests/AgentActionExecutorTests.swift:134` at `126507c`), and `asyncProcessRunnerCancelsRunningProcess` beside it covers the other half. Real-world equivalent worth a spot-check: invoke a Shortcut from the widget/a Routine, cancel it immediately/repeatedly while it's running — should never crash the app | not easily manual — covered by the automated stress test; a real-world spot-check is cancelling a Shortcut-invoking task repeatedly right after starting it |

**Row numbering corrected 2026-08-26 (SONNY-290).** The last row of the table above was numbered 27
a second time, after 30. It is 31 now; nothing else in this file referenced either number.

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

**2026-08-26 — the batch this file gained since `140829b` (PR #116).** You ran the twenty-one rows
added to this file since that merge — §3d's thirteen SONNY-281 rows and four SONNY-283 ones, and
§3d-bis's four SONNY-282 ones (`git diff 140829b 5339640 -- docs/sonny-manual-test-checklist.md |
grep -E '^\+- \[ \]' | grep -oE 'SONNY-28[123]' | sort | uniq -c` → 13, 4 and 4 at `5339640`) — on
the packaged app at `main` `5339640`, and reported them working. It came back as a batch — "yeah the
manual checklist works" — not line by line, exactly like the 2026-07-24 sweep above. The rows carry
**(batch)** beside the date so that reading one row is enough to know it: it means backed by that
batch confidence, not independently re-verified one at a time.

**One row asked a question rather than pass-or-fail and got its answer explicitly, so it carries the
answer instead of the batch marker.** §3d-bis's tooltip row doubted that `.help()` tooltips were
reachable in this widget at all; you hovered the tick and the cross and said "yes tooltips
appeared". That row keeps the doubt's history rather than being quietly ticked — the
`confirmed <date>` convention at the top of this file, applied to a doubt resolved rather than to a
confirmation broken. The source comments that recorded the doubt were outside this file;
**SONNY-295 corrected them on 2026-08-27** — two in `FloatingWidgetView.swift` and a third in
`AgentActivityPresentation.swift` that the ticket had not named and a sweep by claim found.

**What this pass did not cover, said plainly so the new ticks are not read wider than they are.**
Forty-eight rows were unchecked before it (`grep -cE '^- \[ \]'
docs/sonny-manual-test-checklist.md` → 48 at `5339640`); twenty-one of those are this batch, so
twenty-seven are left. Every one of them predates `140829b`, none of them was in front of you on
2026-08-26, and they are SONNY-293's triage rather than this pass's evidence. An unchecked row here
still means nobody has said anything about it.

## 0. Setup & the rebuild loop

### 0a. One-time setup on this Mac — do this before anything else, once (added 2026-08-17, SONNY-153)

**Skip this and every permission you grant will be thrown away the next time the app is rebuilt.**

Just run step 1 below. It does nothing it has already done, so running it when you did not need to
costs a second and nothing else. Do not try to decide in advance whether you need it —
`security find-identity -p codesigning | grep "Sonny Local Dev"` tells you whether the certificate
exists, which is only half the setup: the other half is answering the keychain dialog, and a
certificate that exists with the dialog unanswered looks identical in that listing while still
blocking every build.

```bash
# 1. Create the certificate the app is signed with. Run this in a real terminal window: macOS
#    asks a question partway through and you have to click the answer.
./scripts/create-signing-identity.sh
#    >>> When macOS asks whether codesign may use the key, click "Always Allow", not "Allow". <<<
#    "Allow" answers only once and the dialog comes back on every single build.

# 2. Throw away the permission grants macOS is still holding. They are already dead — each one
#    points at a build that no longer exists — and they are exactly what makes the app say
#    "Not granted" while System Settings shows the switch turned on.
killall MacAgent 2>/dev/null
tccutil reset All com.sonny.MacAgent

# 3. Build, package and launch.
./scripts/package-app.sh debug
open .build/arm64-apple-macosx/debug/MacAgent.app

# 4. Grant Screen Recording and Accessibility again in System Settings, and relaunch the app when
#    it asks you to. Microphone and Desktop access are asked for by the app when it first needs
#    them, so there is nothing to pre-grant for those.
```

**You do this once.** After it, grants stay put across rebuilds and across worktrees, and the
rebuild loop in §0b is all you need.

`tccutil reset All com.sonny.MacAgent` clears every permission for Sonny and nothing else — the
bundle identifier on the end scopes it. If you would rather clear them one at a time, these are the
four macOS was actually holding when this was diagnosed:

```bash
tccutil reset ScreenCapture com.sonny.MacAgent
tccutil reset Accessibility com.sonny.MacAgent
tccutil reset Microphone com.sonny.MacAgent
tccutil reset SystemPolicyDesktopFolder com.sonny.MacAgent
```

**What this is not.** The certificate is a local build credential. It lives in this Mac's login
keychain, is never committed, and is not a distribution identity — it does nothing for anyone else
installing Sonny, and Gatekeeper still refuses these builds on any other machine. **It does not
satisfy the v1 release requirement**, which is a Developer ID signed *and notarized* build
(SONNY-106 section E, gated on the Apple Developer enrolment in section F). Do not tick that
condition off the back of this. To remove the certificate again:
`security delete-identity -c "Sonny Local Dev"`.

### 0b. The rebuild loop

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

**Troubleshooting: the app says a permission is "Not granted" but System Settings shows it turned
on.** That means the build's signature changed, not that anything in the app is broken. macOS ties
each grant to the signature of the build that was running when you gave it; when the signature
moves, the grant stops applying and the app is told, correctly, that it has no permission. Fix it
with §0a — most often you have not run `./scripts/create-signing-identity.sh` on this Mac yet, or
you answered the keychain dialog with "Allow" instead of "Always Allow". To confirm before doing
anything, this prints one line per refusal, naming the service:

```bash
/usr/bin/log show --predicate 'process == "tccd"' --info --last 1h \
  | grep "com.sonny.MacAgent" | grep "Failed to match"
```

Then clear the dead grants and re-grant:

```bash
killall MacAgent 2>/dev/null
tccutil reset All com.sonny.MacAgent
./scripts/package-app.sh debug
open .build/arm64-apple-macosx/debug/MacAgent.app
```

**Troubleshooting: `./scripts/package-app.sh` prints "Code signing as …" and then stops with no
further output.** It is not stuck — macOS is showing a dialog asking whether codesign may use the
signing key, and the dialog can be behind another window or on another display. Answer it with
"Always Allow". If you cannot find it, quit the packaging run, and run
`./scripts/create-signing-identity.sh` from a terminal, which raises the same dialog deliberately
and explains it.

**Troubleshooting:** if macOS refuses to open the app or calls it "damaged," re-run
`./scripts/package-app.sh debug` — the script already retries code-signing up to 5 times to dodge a
known race where Finder/Spotlight re-stamp the fresh `.app` with `com.apple.FinderInfo` xattrs
between signing attempts, but it's not impossible for it to still lose that race.

**Release builds sign differently from debug, and that is deliberate (SONNY-156).** Everything above
is the `debug` loop and is unchanged. `./scripts/package-app.sh release` additionally signs with the
hardened runtime and with `Packaging/MacAgent.entitlements`, both of which Apple's notarization
requires, and then checks its own work: it refuses to finish if the sealed bundle carries
`com.apple.security.get-task-allow` (which notarization rejects) or if the hardened runtime is
missing. A clean release run prints `com.apple.security.get-task-allow: absent`, `hardened runtime:
on`, and the two entitlements it sealed. **A release build is still not distributable** — it is
signed with the local development certificate, so Gatekeeper refuses it on any other Mac, and
notarization has never been run. See §0a and `Packaging/signing-identity`.

**If a release build behaves differently from a debug one, suspect the hardened runtime first.** It
restricts things debug does not: microphone access and Apple Events are the two Sonny uses, which is
why `Packaging/MacAgent.entitlements` grants both. If voice input or Finder/Word automation works in
debug and fails in release, that file is where to look, and it is worth reporting rather than
working around — whether the Apple Events entitlement is needed at all is an open question that only
a real notarized build settles.

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
- [x] Hover (don't click) the mic button → hint row appears: "Click to speak or hold
      Ctrl-Opt-Space." Confirm it's a real inline row (pushes layout, doesn't clip) not a
      floating tooltip, and that it goes on its own after about three seconds with the pointer left
      where it is. **(Fixed 2026-07-21 — tracker #2, and confirmed working 2026-07-23 —
      tracker #21: hover now also survives clicking into another app and back, not just the first
      hover right after launch. Wording, the three seconds and the *first* hover are SONNY-179,
      2026-08-19 — re-checked and confirmed by the founder 2026-08-20, ticked by SONNY-178.)**
- [x] SONNY-179 specifically — **confirmed by the founder 2026-08-20** ("collapse with the pointer
      on the mic, expand, hover once, hint appears"), ticked by SONNY-178. **The precondition is the whole mechanism — without it this item
      passes on the broken build too and proves nothing.** Hover the mic and *leave the pointer
      resting on it* while the widget collapses to the small capsule (~6s after the last thing you
      did). Then click the capsule open and hover the mic **once**. The hint must appear on that
      first hover. It is the pointer being on the mic *at the moment of the collapse* that stranded
      the old boolean; with the pointer anywhere else, the next hover was a real transition and the
      hint appeared even before this branch.
- [x] SONNY-179, the risk the fix takes on — **confirmed by the founder 2026-08-20**, ticked by
      SONNY-178. **What this one observed, and how far it reaches** — scoped, because the first
      version of this note stated a universal negative from a single observation (PR #84 review, F5).
      *Measured once*: on Apple Silicon, macOS 26.5.2 (build 25F84), 2026-08-20, hovering the mic and
      keeping the pointer moving slightly inside the button for about ten seconds while the hint row
      appeared and disappeared, resizing the window beneath it. **In that run the hint went once and
      did not come back**, so on that machine, that OS build and that gesture, the re-registering
      tracking area produced no extra `mouseEntered`. That is the open risk of responding to every
      arrival, and it did not fire. It is **not** established as a property of AppKit: one
      observation cannot rule out a different OS version, a different pointing device, or a faster
      resize cadence. Re-run this row on any macOS upgrade rather than treating it as settled. Hover the mic and keep the pointer **moving slightly
      inside the button** for about ten seconds. The hint must go once at ~3s and must **not** come
      back. Every mouse-entered now re-shows the hint and re-arms the three seconds — that is the
      fix, and it also means the old design's accidental absorbing of a repeat is gone, so this is
      the check that AppKit is not manufacturing extra arrivals when the row appearing and
      disappearing resizes the window under a moving pointer.
- [ ] **The pointing-hand cursor survives a teardown under the pointer** (SONNY-178, PR #84 review
      F3). This is the joint the cursor refutation could not verify: `.onDisappear` popping the
      pushed cursor is read from the code, and nothing in a test process can make SwiftUI tear a view
      down under a real pointer. Two gestures, both in **Command Center** (this row lives in §3a
      because that is where the audit's record points, not because the widget is involved):
      *(a)* open the account menu, rest the pointer on a row so the cursor is the **pointing hand**,
      and press **Escape**. The arrow must return **immediately** — a hand that persists over the
      rest of the app is the leak, and it would survive until something else pushed and popped.
      *(b)* Open a workspace detail sheet, rest the pointer on a control showing the pointing hand,
      and dismiss the sheet with Escape. Same expectation.
- [ ] **A dwell timer does not outlive the menu that owns it** (SONNY-178, PR #84 review F2 — the
      one live defect the audit's second pass found). Open the account menu, rest the pointer on
      **Learn more**, and within a fraction of a second — before the flyout opens — press
      **Escape**. Then open the account menu again. The Learn-more flyout must be **closed**: before
      the fix, the pending dwell fired after the row was gone and left the flyout flag set, so the
      next opening of the menu showed it already open with no hover.
- [ ] **The re-arm** (SONNY-178). Hover the mic, let the hint go on its own at ~3s, then move the
      pointer **off** the mic and back **on**. The hint must appear again, with a fresh three-second
      countdown — not stay away because it has "already been shown". This is the property that makes
      a second hover and a first the same event, which is the whole of SONNY-179's design; the
      collapse item above only proves one specific stranded case.
- [ ] **The no-API-key variant** (SONNY-178). With no API key configured, hover the mic. A different
      message appears — the configuration one, naming what to do — and it must **not** time out: it
      stays for as long as the pointer rests there. The two variants differ in kind, not in wording
      (`MicHoverHintPresentation.autoDismissDelay` is `nil` for this one), so a shared countdown
      would be wrong rather than merely inconsistent. Check the wording matches what pressing the
      mic says, since the same condition drives both.
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

### 3c-bis. An approval raised *during* a screen-control session (new 2026-08-26, SONNY-255)

Start a screen-control session in Normal mode against an app the other rows use (Safari is easiest)
and steer it at a control it will treat as destructive or as affecting others — a Delete, a Send.
That raises a real approval mid-loop, which is the state every row here is about. All six rows are
new behaviour: before this ticket the widget showed the controlling HUD for the whole session and
the approval reached no widget surface at all, so the run looked like it had stalled.

- [ ] **(new 2026-08-26, SONNY-255)** When the approval is raised, the widget shows the **approval**
      rather than the HUD — the "Allow access to …" row with its ✓, and above it a single row reading
      **"Sonny is controlling Safari"**, the step count, and a red **Stop**. The HUD's action line
      ("Looking at Safari") is deliberately not there: at the moment the question is raised it still
      describes the start of the step, not the action being asked about
- [ ] **(new 2026-08-26, SONNY-255)** In that state the main composer at the bottom reads **"Answer
      above first…"**, not "Sonny is working…" — it now points at a panel that really does hold a
      question. During the rest of the session, with nothing pending, it still reads "Sonny is
      working…", which is SONNY-247's own row a few lines below
- [ ] **(new 2026-08-26, SONNY-255)** Press **✓**. The panel goes straight back to the HUD — app,
      action line, step count, Pause, Stop — and the session carries on and finishes. It must not sit
      on the approval panel after the press
- [ ] **(new 2026-08-26, SONNY-255)** Provoke the approval again and press **Stop** instead. The
      session ends, the action it was asking about never happens, and the widget shows "Canceled."
      Nothing should read as though you declined one step and the session continued
- [ ] **(new 2026-08-26, SONNY-255)** While a session is live there is **no ✗ cross** in the approval
      panel — Stop is the only refusal, because pressing the cross here ends the whole session and an
      icon-only cross reads as "skip this step". Then run an ordinary tier-2 command with no screen
      control: the ✗ is back, and §3c's Deny row above behaves exactly as it always did
- [ ] **(new 2026-08-26, SONNY-255; rewritten 2026-08-27 after PR #132's review F1 changed what this
      row is checking)** With the mid-session approval up, open Command Center. Its attention panel
      shows the same question, and mid-session its buttons are **Stop and Allow** — *not* Deny and
      Allow, which is what it showed until F1. Above them it names the session the same way the
      widget does: "Sonny is controlling Safari" and the step count. Answering it **there** clears
      the widget's panel too — one approval, two surfaces, never two answers
- [ ] **(new 2026-08-27, PR #132 review F1)** Press **Stop** on Command Center's panel. It must end
      the session exactly as the widget's Stop does — the action under question never happens, the
      widget's panel clears, and the task reads "Canceled." The word is the whole of what changed:
      that button did the identical thing when it said "Deny", which is why it stopped saying it
- [ ] **(new 2026-08-27, PR #132 review F1)** With an ordinary tier-2 approval and **no** screen
      control, open Command Center: its panel says **Deny and Allow** again, with no session row
      above it. Deny cancels the run as it always did

### 3c-ter. A screen-control session the widget did not start (new 2026-08-27, SONNY-299)

The HUD used to be gated on the run having been started *from the widget*, so a screen session
started anywhere else drove the screen with the widget showing nothing at all — no statement of what
Sonny was controlling, no Pause, no Stop. The emergency hotkey (Ctrl-Opt-Esc) still worked; nothing
on screen said so. Both rows are about the same panel, reached by the one door that reaches it.

**Two things that are not failures, said first so neither reads as one** (PR #140 review, F5 —
both rows over-claimed in the direction that manufactures a false failure report):

- **The HUD yields to a question.** While one is parked — an approval, and in Safe mode the capture
  review or a delegation — the panel on screen is that question and not the HUD, and that is
  correct: since SONNY-255 those panels carry the session's identity line and its step count
  themselves, so the session is still named. The HUD returns the moment you answer.
- **Run again re-asks the planner rather than replaying the first run**, so the second run may
  resolve to something that is not a screen session at all. If nothing controls anything, that is
  the planner's answer and not this fix. Retry with a command that is plainly screen-shaped — "in
  Safari, open the Bookmarks sidebar" — and check the HUD on that one.

- [ ] **(new 2026-08-27, SONNY-299)** Run one screen-control task from the widget and let it finish.
      Then open **Command Center → Tasks**, open that task's row, and press **Run again**. Whenever
      the second session is running with nothing parked on it, the widget must show the HUD —
      **"Sonny is controlling Safari"**, the action line, the step count, **Pause** and **Stop** —
      exactly as it does for a session you started by typing into the widget. Before this fix the
      second session showed nothing at all: the ordinary pill, or the collapsed capsule
- [ ] **(new 2026-08-27, SONNY-299)** During that second session press the HUD's **Pause**. The
      widget swaps to the **paused panel** — "Sonny paused controlling Safari…", with **Resume** and
      **End** — which is where Resume lives; the HUD itself carries Pause and Stop only. Press
      **Resume** and let the session finish. The controls have to actually work from this door, not
      merely be drawn. Pause takes effect at the top of the next step rather than instantly, so the
      HUD staying up for a moment before the paused panel appears is the design and not a lag

### 3c-quater. Safe mode's capture review says "Step 1 of 12" (new 2026-08-27, SONNY-303)

`VisionCapturePreview` carried the iteration and no cap, and the panel put the app's *name* where the
cap belongs — so the pre-send review read "Step 2 of Safari". The founder's decision of 2026-08-27
was to add the cap to the type rather than drop the "of …" half, so the line now goes through the
same owner the HUD and both approval panels read. The shipping cap is **12**
(`VisionSessionLimits.default.maximumIterations`), so that is the number to expect.

- [ ] **(new 2026-08-27, SONNY-303)** Put Sonny in **Safe** mode and start a screen-control task. At
      the capture review — the panel showing the picture before it is sent — the small line at the
      bottom left must read **"Step 1 of 12"**, two numbers. Anything with an app name after the
      "of" is the defect. Press **Send**, answer the action approval, and on the next capture review
      the same line must read **"Step 2 of 12"** — the left number moves, the right one does not

### 3d. Clarification (no wireframe — best-effort, extra scrutiny warranted)
Provoke a follow-up question with an intentionally underspecified command — e.g. "open my
workspace" when you have 2+ saved workspaces and don't name one, or "zip my files" without saying
which.
- [x] Question text + inline answer field render cleanly — **confirmed 2026-07-24**
- [x] Return key or the up-arrow button submits and resumes the task — **confirmed 2026-07-24**
- [x] Empty/whitespace-only answer correctly leaves the submit button disabled — **confirmed 2026-07-24**
- [ ] **(new 2026-08-23, SONNY-247)** The caret lands in the answer field on its own when the
      question appears — type immediately, without clicking anything first, and the letters go into
      the answer
- [ ] **(new 2026-08-23, SONNY-247)** The main composer at the bottom now reads "Answer above
      first…" instead of "Let Sonny take it from here…", and its wand glyph is dimmer. Click it,
      try to type, then copy something and try ⌘V into it — it still takes nothing, which is
      correct, but it should now look and read as deliberate rather than as a hung app. **This is
      the whole of what the ticket changed** — the composer was always disabled here, it just never
      said so, and the founder reported it twice on 2026-08-23
- [ ] **(new 2026-08-23, SONNY-247)** While an ordinary run is in flight (no question), the same
      composer reads "Sonny is working…" — a different sentence, because there is nothing above to
      answer
- [ ] **(new 2026-08-23, SONNY-247, from PR #107's review; corrected 2026-08-26 by SONNY-255 — the
      part about approvals is no longer true and would fail if checked as written)** During a
      **screen-control** session the composer reads "Sonny is working…", not "Answer above first…",
      **while nothing is parked on you**. That is deliberate: the panel above is the controlling HUD
      (app, step count, Pause, Stop) and it carries no question, so pointing at it would be a lie.
      **The clause this row used to carry — "including if Sonny asks for an approval part-way
      through it" — was true only because the approval reached no widget surface at all**, which was
      the defect SONNY-255 fixed. An approval now takes the panel and the composer says "Answer above
      first…" for as long as it is up; §3c-bis is where that is checked
- [x] **(new 2026-08-25, SONNY-283)** With a question pending, press **Ctrl-Opt-Space** and let go
      without speaking. The caret should be in the **answer field** — type a letter and it lands
      there. Before this the hotkey did nothing at all in this state
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-25, SONNY-283)** With a question pending, hold Ctrl-Opt-Space and **speak an
      answer**, then release. The transcript should appear **in the answer field**, not in the main
      composer, and nothing should run until you press Return or the up-arrow — speaking feeds the
      field, it does not send it. Then do the same with the **mic button**, which used to be
      present and inert here; it should now record, and the transcript should land in the same
      field. If the field already has text when you speak, the transcript is appended after a
      space, the way dictation lands at the caret — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-25, SONNY-283 — must not regress)** In the same state, the caret still never
      jumps into the disabled main composer — not on the hotkey, not on the menu-bar "New Task",
      not on re-opening the widget from its collapsed capsule. And typing without clicking still
      lands letters in the answer field, exactly as SONNY-247's row above says
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-283, from PR #119's review F1)** With a question pending, type half
      an answer, then hold the hotkey and speak the rest — and press **Return while the mic is still
      live, and again during the second or two after you release it** while the transcript is on its
      way. Nothing should happen either time: the question stays, the typed half stays, the widget
      does not show "Clarification needed" as a *result* and does not offer to resume the task, and
      the main composer stays empty. The up-arrow Send (and Command Center's Send) should be greyed
      out for the whole of that window and come back the moment the transcript lands. Then Return
      sends. Before this fix that Return silently destroyed the question
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's body by SONNY-292)** **Control.**
      Send `2 + 2`. It answers `2 + 2 = 4.`, instantly. This path never reached the planner and
      never broke — it is here so the rows under it have something to be read against
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's body by SONNY-292)** Send `2 + 2 =` —
      the same sum with the `=` a person types at the end. It answers `2 + 2 = 4.`, **instantly**,
      not "Calculation is unsupported by the registered local tools." after a network round-trip.
      Then the same with `2+2=?`. This is the founder's original report
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's body by SONNY-292)** Send `=` alone.
      Sonny asks "What would you like me to calculate?" — answer `2 + 2` and it answers
      `2 + 2 = 4.` The **running label** and the **Tasks row** both read `= 2 + 2` — the request
      and the answer joined, not `=` on its own and not `2 + 2` on its own
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's body by SONNY-292)** On the `= 2 + 2`
      Tasks row the row above leaves behind, press **Run again**. It answers `2 + 2 = 4.` again and
      asks **no question** — the row carries the completed command, so there is nothing left to
      clarify. **Retry** after a failure takes the same path — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's body by SONNY-292)** Send `calc`
      alone, then answer the what-would-you-like-to-calculate question with `calc 5 * 5` — an
      answer that restates the command instead of continuing it. It answers `5 * 5 = 25.`
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's body by SONNY-292)** Send
      `run shortcut Nonexistent` (any name you have no Shortcut for). Sonny asks which Shortcut to
      run — answer with the **real name of a Shortcut you do have**. The planner takes the
      exchange, so expect a round-trip rather than an instant answer. **The failure to catch is
      the same question re-asked instantly**: that would mean the answer had been completed
      locally into `run shortcut Nonexistent <name>`, which resolves to the same question again
      rather than to a plan — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's body by SONNY-292)** Provoke a
      **planner**-asked clarification — `zip my three largest files`, answered with the folder, is
      the PR's own example — and check it proceeds on the request plus the answer exactly as
      before. A question the planner asked is never completed locally, even when the answer would
      resolve on its own, so this is the path that must be **unchanged**
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's notes by SONNY-292)** Send `calc`
      alone, then answer the what-would-you-like-to-calculate question with `banana`. Sonny's
      **own** calculation error appears **instantly** — "Could not calculate that expression: …",
      the same error `calc banana` typed directly gets — not the planner's "Calculation is
      unsupported…" refusal after a network round-trip — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's notes by SONNY-292)** With **both**
      Focus Writer and Writer running, send `focus` and answer the which-app question with the
      **full name** — `Focus Writer`. It switches to **Focus Writer**, not to an app called
      "Writer". Both readings of that answer resolve only when both apps are running, so this is
      the state that tells them apart; the pair the row needs is any app named `Focus <Something>`
      alongside one named `<Something>`, and Focus Writer/Writer is the fix's own example —
      **confirmed 2026-08-26 (batch)**.
      **Known, don't report (R-a, founder decision 2026-08-26, recorded on PR #118):** with
      **only** Writer running, the same exchange still switches to Writer — pinned as a record so
      drift is seen, deliberately not fixed
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's notes by SONNY-292)** With **neither**
      of that pair running — no "Focus Writer" and no "Writer" — send `focus` and answer
      `Focus Writer`. It fails instantly with "No running app matched Focus Writer." and does not
      ask the planner. **Check the precondition before reporting this one:** with Writer alone
      running it switches to Writer, which is R-a in the row above and not a defect
      — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's notes by SONNY-292)** Send `=` alone,
      and answer the question with `=2+2` — an answer that itself starts with `=`. The answer is 4,
      instantly — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's notes by SONNY-292)** Send
      `snippet save` with nothing after it. The question reads "Use the format ;trigger =
      expansion." Answer with the **body alone** — `;sig = Best, Sonny` — and the snippet saves
      under `;sig` — **confirmed 2026-08-26 (batch)**.
      **Known, don't report (stated residual on PR #118):** answering by retyping the
      whole command instead saves a snippet under the junk trigger `snippet save ;sig` — tier 2
      auto-runs under the consequence rule — visible and deletable on the Memory page
- [x] **(new 2026-08-26, SONNY-281, recovered from PR #118's notes by SONNY-292)** Quit Sonny
      while it is asking what to calculate (`=` alone raises the question; quit before answering).
      Relaunch, take the widget's partway-through offer with the **tick** (or Continue from
      Command Center → Memory → Unfinished tasks), and answer `2 + 2`. The answer is `2 + 2 = 4.`
      — before the fix's review round this path sent the answer to the planner and it was refused,
      because Continue replays the paused plan as a resumed task — **confirmed 2026-08-26 (batch)**

### 3d-bis. Unfinished-task offer (row 13, SONNY-210; layout and controls SONNY-244 — no wireframe)
Start something long and multi-step, then quit Sonny before it finishes — "summarize
https://news.ycombinator.com and save it as a markdown file on my desktop" is the founder's own
case. Relaunch and open the widget.
- [ ] **(new 2026-08-23, SONNY-244)** The offer reads "You were partway through "…"." with a **tick
      and a cross** below it, right-aligned, the tick tinted and the cross plain. No text buttons.
      **Say whether the two glyphs read as the same size** — the tick is 11pt and the cross 10pt,
      while the only other pair of these two glyphs in the app (the permission panel's Allow and
      Deny) is 10pt for both. Left as-is deliberately: it is your call, not a session's
- [ ] **(new 2026-08-23, SONNY-244)** **The controls sit below the message, never on top of it** —
      this is the defect. Use a command long enough that the message wraps to two lines, and check
      it more than once: it rendered correctly some of the time on the broken build, so a single
      good look proves nothing. Try it both ways — open the widget from the menu-bar icon and from
      the Ctrl-Opt-Space hotkey — and with a short command as well as a long one
- [x] **(new 2026-08-23, SONNY-244; words changed 2026-08-25, SONNY-282; found in doubt 2026-08-23,
      confirmed reachable 2026-08-26)** Hover the tick and then the cross and **say whether a
      tooltip appears at all** — it should read "Continue" and "Don't ask again". This one was
      genuinely in doubt: `FloatingWidgetView` records `.help()` as confirmed unreliable in this
      widget, which is why the mic's hint is a real row rather than a tooltip, so these two words
      might simply not have been reachable for a sighted user, and if no tooltip appeared the tick
      and cross carried no words at all and that needed a decision. **They are reachable.** The
      founder hovered both on 2026-08-26 and the tooltips appeared ("yes tooltips appeared") — the
      first direct evidence in this project's record that `.help()` fires anywhere in this widget,
      so the decision this row was holding open is not owed. **Only that half is the founder's:**
      that a tooltip appears on each is what was
      observed; *what* the two say is not a manual finding but the code's own constants,
      `ResumeOfferPresentation.continueLabel` and `declineLabel`, "Continue" and "Don't ask again"
      (`Sources/MacAgent/AgentActivityPresentation.swift:471` and `:482` at `5339640`). What was
      stale was the source's reading rather than this row — `WidgetResumeOfferPanel`'s doc comment
      still said the tooltip "may simply not fire" and that "the plain reading is that a sighted
      user loses the words". That file was outside what SONNY-294 could touch; **SONNY-295 corrected
      it on 2026-08-27**, in that panel's doc comment and in `ResumeOfferPresentation.continueLabel`'s,
      which carried the same doubt in a second file. The mic button's own claim is left standing on
      purpose: it is a different control, and one hover here says nothing about it
- [ ] **(new 2026-08-27, SONNY-295)** The two **other** tooltips in the widget have never been
      hovered by anyone, and one pass answers them: hover the **compact capsule** (the small pill
      Sonny shrinks to when idle) — it should say **"Open Sonny"** — and, with a follow-up question
      on screen, hover the clarification panel's **cancel** control. Say for each whether a tooltip
      appears. These two predate the finding above and were left in place on a "free if it works"
      footing; nothing depends on them, so this is filling in the record rather than checking a fix
- [x] **(new 2026-08-25, SONNY-282 — replaces the 2026-08-23 row)** Press the cross **once**, then
      quit and relaunch Sonny **several times**. The offer for that task must **never come back**.
      This is the defect: you pressed it three times across three relaunches on 2026-08-25 and it
      returned every time, because the cross meant "not now" by design. It now means "don't ask
      again" for that one task. If another unfinished task is waiting, *that* one is offered next —
      declining one does not silence the rest — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-25, SONNY-282)** After the cross, open Command Center → Memory → Unfinished
      tasks. The task is **still listed** — the cross deletes nothing — with "Declined" on its row
      before the time, and the row now has a **Continue** button beside Delete. Continue from there
      should run only what was left of the task, the same way the widget's tick does, and the row
      goes away when it finishes. A row for a task Sonny must not finish on its own (one whose
      remaining work runs a Shortcut, a routine or a screen session) has no Continue, only Delete —
      that is deliberate and unchanged from SONNY-210 — **confirmed 2026-08-26 (batch)**
- [x] **(new 2026-08-25, SONNY-282)** Continue a declined task from Memory and make it stop again
      (pull the network before it opens its page, or quit mid-run). The widget **offers it again**
      — picking it up from Memory counts as re-engaging with it, so the decline is spent. Press the
      cross again and it stays gone across relaunches as before — **confirmed 2026-08-26 (batch)**

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
      error instead and confirm THAT one does **not** auto-clear — it should keep saying so
      indefinitely until you actually fix it. (**The example this row used to give — "something
      producing `OPENAI_API_KEY is not set…`" — is no longer reachable as of 2026-08-27, SONNY-130**:
      no client reads a provider key. Denying mic permission still is, and is the example to use.) **This second half (config errors staying put) hasn't been explicitly
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
- [ ] **(new 2026-07-30, fix re-test; second half superseded 2026-08-23 by SONNY-247)** Widget idle
      state: the Start button now sits 8pt from the pill's trailing edge, matching its 8pt
      top/bottom insets — confirm it reads even. **The in-flight state is no longer meant to look
      unchanged from before**, which is what this row used to ask: the placeholder now names the
      state and the wand glyph dims. Check it against §3d's rows instead of against memory
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

- [ ] **(new 2026-08-20, SONNY-65)** Open a workspace's detail sheet. Its **Apps** rows now show the
      app's real icon beside the name. Cross-check against the card behind the sheet: the same app
      must show the same icon on both, since both now resolve through `WorkspaceAppIconResolver`.
      The name is still the full verbatim string — an icon is *additional* to it, never instead of
      it, because the whole point of this sheet is checking an entry against the one a consent
      prompt named.
- [ ] **(new 2026-08-20, SONNY-65)** Add an app to a workspace that is **not installed on this Mac**
      (any plausible name will do). Its row must show the **name only** — no icon, and specifically
      **not** the dashed-square placeholder the card's stack uses for the same case. A placeholder
      here would imply the entry is broken; it is stored, valid, and simply unresolvable on this
      machine.
- [ ] **(new 2026-08-20, SONNY-65)** In the same sheet, confirm the **URLs** and **File locations**
      rows show no icon at all. All three dimensions share one row view, so this is the check that
      the icon is dimension-scoped rather than leaking into rows that have nothing to resolve.
- [ ] **(new 2026-08-20, SONNY-65)** Narrow the Command Center window (not fullscreen) with a
      detail sheet open. The app rows must still read properly — icon and name on one line, remove
      button reachable, nothing character-wrapped. The row is a `SettingsAdaptiveControlRow`, and
      an icon is new width inside it.
- [ ] **(new 2026-08-20, SONNY-65)** If any entry shows a muted "Not in effect — …" note, confirm
      that note still reads as the **dominant** signal on the row rather than the icon beside the
      name. SONNY-41's inert rendering stays primary over any icon decoration; the two are
      independent fields, so this is a visual judgement no test can make.

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

### Sign-in and the account menu (new 2026-08-26, SONNY-128)

**Before these items**, two things have to be true, and neither is a test item — they are the setup
without which the items cannot be run at all.

1. A gateway has to be answering. There is no staging or production host yet (`./scripts/deploy.sh
   staging` and `production` are stubs that exit 3, and the first real remote deploy is owed on
   SONNY-192), so the target is the local one: `cd server && ./scripts/deploy.sh local`, which
   builds the image, runs it, and verifies `/v1/health` serves that build. **That is the one
   command, and there is no second hand-run step** (new 2026-08-27, SONNY-306): it also forwards
   the gateway's own credentials out of the shell you run it from — `SUPABASE_JWT_SECRET`,
   `SUPABASE_JWT_ISSUER`, `SUPABASE_JWT_AUDIENCE`, `SUPABASE_ANON_KEY`, `DATABASE_URL` and
   `RATE_LIMIT_SALT` — each one only when you have exported it, naming any it did not find. Export
   them in that terminal first; the script never asks for one, stores one or prints one.
   (`SUPABASE_SERVICE_ROLE_KEY` is deliberately **not** on that list — founder decision of
   2026-08-27: nothing calls the one method that uses it, so a container should not be holding the
   project's most dangerous credential to use none of it.)

   **The command now ends with `==> auth routes are mounted` when you export all six** (updated
   2026-08-27, SONNY-307), and that line is the thing to read before starting: it is the container
   telling you it will actually serve a sign-in. Export none of the three `SUPABASE_` names and it
   says `auth routes are NOT mounted` and answers 404 — health-only, correct, and not a defect.
   Export *some* of them and the container **refuses to start** and names what is missing, which is
   also correct: a half-configured gateway would answer 404 to every sign-in while looking healthy.

   **What still has to come from outside this repository, and it is the only thing left.** The four
   rows below need a real Supabase project: its JWT secret, issuer and anon key, and a Postgres the
   container can reach with this repository's migrations applied (`npm run migrate -- up`). **The
   project exists** — `zpyyljfsqrxulhmgkhfp` (sonny-dev) — and what is left is the founder-owned
   setup around it, deferred as one sitting on **SONNY-280** (its founder-deferral comment of
   2026-08-27, resume steps (1) to (5)). **This said "No such project exists yet ... recorded on
   SONNY-307", which was true when it was written on 2026-08-27 at 17:52 and superseded by that
   deferral comment the same day** (corrected 2026-08-28, SONNY-330 — the same correction PR #147's
   review made to "What every call cost", which carries the project detail). The failure the
   correction prevents is specific: a founder goes to create a project, finds sonny-dev already
   there with its migrations applied, never opens the JWT Keys page, and meets a 401 on every call
   with nothing here to explain it. The code is in place and measured end to end against the
   container: the route answers, reaches Postgres, calls Supabase, and is refused only because the
   project name in the test configuration does not resolve. **The code that mails you is Supabase's,
   not ours** — so whether the mail arrives is a Supabase project setting (its SMTP) rather than a
   change here, and SONNY-280's step (2) is that setting.

   The three rows that need only the app can be run today — the two pointed at a host which does
   not answer, and the narrow-window layout one.
2. The debug build has to be pointed at it. `defaults write com.sonny.MacAgent SonnyBackendBaseURL
   http://127.0.0.1:8080` — a `defaults` value rather than an environment variable **because the
   relaunch in item 2 loses an environment variable**: `/usr/bin/open -n` starts the new process
   from launchd's environment, not the terminal's. The sign-in dialog prints the host it resolved
   at the bottom in a debug build, so that line is the confirmation the pointer took. Release
   builds have no such switch and no such line.

Everything below is in the packaged `.app` (`./scripts/package-app.sh`, then open the bundle) —
a bare `swift run` has no bundle identity and several of these paths need one — **except the first
row, which is a Terminal check of the setup in item 1 above.** Sign-in is opened from the
bottom-left account row → **Sign in**.

- [ ] **(new 2026-08-27, SONNY-306; updated 2026-08-27, SONNY-307) — Terminal, not the app.** Run
      `cd server && ./scripts/deploy.sh local` twice from the same terminal: once with none of the
      eleven credentials exported, and once with whichever of them you actually hold exported first.
      Both runs must end with `==> ok — serving <sha>`. The first must say `forwarding 0 of 11` and
      then list all eleven names on the `not set here` line; the second must say `forwarding N of
      11` and list only the ones you left out. (**The counts said 6 until 2026-08-28**, which was
      right when this row was written and went stale as SONNY-130, SONNY-131 and SONNY-132 each
      added provider keys to the same array —
      `sed -n '/^PASSTHROUGH=(/,/^)/p' server/scripts/deploy.sh | grep -cE '^  [A-Z_]+$'` → 11 at
      `55f4c9b`. Corrected by SONNY-330. The six the paragraph above names are still the gateway's
      own; the script's count is over all eleven.) **No run may print a credential's value anywhere** —
      that is the row's real subject, so read the output rather than skimming it. The first run ends
      with `auth routes are NOT mounted`; the second ends with `auth routes are mounted` if you
      exported all six, and otherwise refuses to start naming what is missing.

- [ ] **(new 2026-08-27, SONNY-307; precondition corrected same day, PR #137 F4) — Terminal, not
      the app. Needs no Supabase project, but it does need a database.** The Supabase values may be
      placeholders — this row is about the wiring, not about a real sign-in — **but `DATABASE_URL`
      may not be**: this route reaches Postgres before it ever calls Supabase, so a placeholder
      there gets a connection error and a **500**, not the 200 below. The first draft of this row
      said "placeholder values are fine" without that exception and would have failed as written.
      Same precondition the four sign-in rows carry, and here it is the only one.

      Start one and apply the migrations first:
      ```
      docker run -d --name sonny-gw-db -e POSTGRES_PASSWORD=postgres -p 55433:5432 postgres:17
      cd server && DATABASE_URL=postgres://postgres:postgres@localhost:55433/postgres \
        npm run build && npm run migrate -- up
      export DATABASE_URL=postgres://postgres:postgres@host.docker.internal:55433/postgres
      ```
      (`host.docker.internal` in the exported value, not `localhost` — the gateway is in a container
      and `localhost` there is the container.) Then export the four Supabase names and
      `RATE_LIMIT_SALT` with any values you like, run `./scripts/deploy.sh local`, and:
      `curl -s -X POST http://localhost:8080/v1/auth/email/start -H 'Content-Type: application/json'
      -d '{"email":"you@example.com"}'`. It must answer **200** with a `request_id` and
      `expires_in: 600` — the sign-in route running for real, through a real pool, against a real
      database. Then `docker logs sonny-gateway-local` and read the last few lines: they must contain
      `"auth":"mounted"` on the `gateway listening` line, and **no credential value, no email
      address and no `supabase.co` URL anywhere** — that is the row's real subject, so read the
      output rather than skimming it. With a placeholder project name you will also see one
      `sign-in code send failed` line naming only an error type — that is the adapter reporting it
      could not reach a project that does not exist, and the 200 you got is the contract's
      deliberate uniform answer, not a failure to report. Finish with
      `docker rm -f sonny-gateway-local sonny-gw-db`.

- [ ] **(new 2026-08-26, SONNY-128)** Sign in with a real address: type it, press **Send code**,
      read the code out of the mail, type it, press **Sign in**. The dialog's title becomes
      *Account* and the row shows the address you signed in with. Then **quit Sonny and reopen it**,
      open the same dialog, and confirm it still says Account with the same address — no code, no
      second sign-in.
- [ ] **(new 2026-08-26, SONNY-128) — the headline check.** Sign in. Then, still in the same launch,
      open Settings → Security & Access → Screen access, press **Request access**, and use the
      **Relaunch Sonny** button that appears. When the app comes back, open the account row again
      and confirm you are **still signed in**. This is the one failure the whole ticket exists to
      prevent: macOS forces that relaunch on a first run, and a session held only in memory would be
      gone at exactly that moment.
- [ ] **(new 2026-08-26, SONNY-128)** Press **Sign out**. Confirm the dialog returns to the email
      field, and that quitting and reopening still shows signed out. Then confirm **your local data
      survived it** — Routines, Workspaces and Snippets still list what they listed, and clipboard
      history still has its entries. Sign-out, "delete my local data" and "reset the encryption
      identity" are three different actions, and this row is the check that this one did only its
      own job.
- [ ] **(new 2026-08-26, SONNY-128; corrected 2026-08-27, PR #133 F6)** Point the pointer at
      something that is *not* loopback (`defaults write com.sonny.MacAgent SonnyBackendBaseURL
      https://sonny-offline-check.invalid`), **turn wifi off**, relaunch, open sign-in, type any
      address and **press Send code**. The message must read as a human sentence naming the real
      problem — you are offline — and must not be a status code, a URL, or anything about tokens.
      **Pressing Send code is the point of the row**: opening the dialog fires no request at all,
      so the original wording asked for an observation the app cannot produce and would have read
      as a defect. Loopback is called out because `127.0.0.1` keeps answering with wifi off, so the
      obvious version of this check silently tests nothing.
- [ ] **(new 2026-08-26, SONNY-128)** With wifi back on and the pointer still at a host that does
      not exist, try to send a code. The message must be **different** from the offline one — the
      network is fine and the backend is not, and those two need different words.
- [ ] **(new 2026-08-26, SONNY-128)** Get the code wrong on purpose, then let one expire (they last
      ten minutes) and try it, then use a good one twice. Each of the three should say something
      different, and none of them should be a raw error or mention spam folders. Also press **Send a
      new code** and confirm a second mail arrives and the newer code is the one that works.
- [ ] **(new 2026-08-26, SONNY-128)** Narrow the Command Center window (not fullscreen) with the
      sign-in dialog open. The email row and the code row must stay readable — the field and its
      button on one line, or stacked, never character-wrapped. Both are
      `SettingsAdaptiveControlRow`s, which is the pattern that exists for exactly this.

### Setup for every section behind the gateway (new 2026-08-28, SONNY-330)

**Every section from here down that runs something against the gateway wants the same setup, and
until this note each described that setup for itself.** They drifted apart as the gateway changed
underneath them, which is what this note exists to stop: SONNY-130's blocked its rows on SONNY-307,
which had landed; SONNY-131's blocked its rows on "SONNY-307's successor", which was never a ticket
and is not one now; SONNY-132's assumed a container up and serving while its neighbour said none
could exist. Each section below now states only what it *adds* to this.

**1. A gateway answering.** `cd server && ./scripts/deploy.sh local`, exactly as the sign-in section
above describes it — one command, no second hand-run step. It forwards, by name, whichever of
**eleven** credentials you exported in that shell
(`sed -n '/^PASSTHROUGH=(/,/^)/p' server/scripts/deploy.sh | grep -cE '^  [A-Z_]+$'` → 11 at
`55f4c9b`): the six gateway ones that section lists, plus `OPENAI_API_KEY`, `TAVILY_API_KEY`,
`VISION_API_KEY`, `ANTHROPIC_API_KEY` and `CEREBRAS_API_KEY`. Export whichever ones a section names
*before* that command, and nowhere else.

**2. The debug build pointed at it.** `defaults write com.sonny.MacAgent SonnyBackendBaseURL
http://127.0.0.1:8080`, as that section describes, with the dialog's debug line as the confirmation.

**3. The packaged app launched from Finder, with no provider key exported in any shell it was
launched from.** A Finder launch inherits no shell environment, which is the whole point: a row that
passes only because a key happened to be exported has proved nothing.

**SONNY-307 landed, so nothing below blocks on it.** `src/server.ts` supplies `AuthDeps` now — PR
#137, `f8f5c75` (`git merge-base --is-ancestor f8f5c75 origin/main` exits 0) — and the container's
own probe reports what that produced: given `SUPABASE_JWT_SECRET`, `SUPABASE_JWT_ISSUER` and
`SUPABASE_ANON_KEY` (the three trigger names) together with `DATABASE_URL` and `RATE_LIMIT_SALT`,
`./scripts/deploy.sh local` ends `==> auth routes are mounted`. Given none of the three it ends
`auth routes are NOT mounted` and serves health alone, which is correct rather than a defect. Given
some of them the container refuses to start and names what is missing, which is also correct.

**What does gate these rows is signing in through the app.** Everything except `/v1/health` and the
two sign-in routes is authenticated, so every row that runs a command needs a real sign-in, and that
needs a Supabase project that can mail you a code. **That is the deferred identity sitting:
SONNY-280's founder-deferral comment of 2026-08-27, and its numbered resume checklist, steps (1)
through (5), in that order.** SONNY-280 is the ticket to name. There is no "SONNY-307 successor",
and nothing on the board is waiting to mount auth routes — 93 open items, none of them that
(`scripts/plane list open`, read 2026-08-28).

**Do not go looking for the project: it exists**, and its migrations were applied. "What every call
cost" below carries the detail rather than this note repeating it — the project ref, the
session-pooler connection string that the direct host cannot replace, and the three things that
block a sign-in independently of one another (the JWT key mode, the locked Magic Link template, and
a `deploy.sh local` that has never run against the real project). Read that section before the
sitting, not during it.

**Two migrations landed after that record, so the resume runs `npm run migrate -- up` again first.**
SONNY-280 recorded ten applied to the real project; the repository carries twelve
(`ls server/src/db/migrations/*.sql | wc -l` → 12 at `55f4c9b`), and `0011` and `0012` were both
authored after the deferral comment
(`git log --diff-filter=A --format='%ad' --date=iso -- 'server/src/db/migrations/001[12]*.sql'` →
two lines, `2026-08-27 22:06:51 -0400` and `2026-08-27 18:11:32 -0400`, against a deferral comment
written at `2026-08-27T21:39:52Z`, which is 17:39 -0400 — both after it). Sign-in reaches Postgres
before it calls Supabase, so a project missing them is a 500 that looks nothing like a missing
migration.

**None of this was established by running it, and that is deliberate.** The credentials are the
founders' and the sign-in happens in the app, which no agent tests; what is above is the tree as it
stands at `55f4c9b` plus what SONNY-280's deferral recorded. **Resume step (4) is where a founder
finds out** whether steps (1) to (3) actually landed — export the real names, run the one command,
read the `auth routes are mounted` line.

**What can be run before that resume**, so these sections are not one flat wall:

- **SONNY-132's `model routing` row.** That line is printed at startup by every container, signed in
  or not (`server/src/app.ts:343` at `55f4c9b`), so it needs step 1 and nothing else.
- **SONNY-130's three-minute recording row.** The refusal is the Mac's, checked before the file is
  even read (`Sources/MacAgentCore/OpenAITranscriber.swift:155` at `55f4c9b`) — no container, no
  sign-in.
- **SONNY-130's signed-out row.** A build that has never signed in is in the same state as one that
  signed out: with no tokens stored the request is refused before it is sent
  (`Sources/MacAgentCore/SonnyBackendClient.swift:436` at `55f4c9b`), which is the sentence that row
  asks for.
- **The rows that say "Terminal, not the app" on their own face** — the two in the sign-in section
  above, and the migration rehearsal in "What every call cost". Those need a Postgres, not a
  project.

Every other row in these sections waits on the sitting. A 401, a `404 resource.not_found` on a
sign-in route, or a command that stops with *"Sign in to Sonny to run this."* is that wait showing
itself — not a defect, and not worth reporting until step (5).

### The four routes behind the backend (new 2026-08-27, SONNY-130)

**This section is where the row stops being plumbing.** The planner, web-research synthesis, voice
transcription and web search all run through Sonny's own gateway now, under your sign-in, with no
provider key anywhere on your Mac.

**Setup is the shared note above, plus `OPENAI_API_KEY` and `TAVILY_API_KEY` exported before
`./scripts/deploy.sh local`.** Both are already in the script's passthrough, put there by this
ticket's own work. **Two of the rows below run today** — the three-minute recording row and the
signed-out row — **and the rest wait on SONNY-280's resume**, for the reason the note gives.

*(This paragraph used to block every row on SONNY-307, which is Done and merged, and to ask for two
keys to be added to a passthrough that already held them. Corrected 2026-08-28, SONNY-330.)*

- [ ] **(new 2026-08-27, SONNY-130) — the headline check.** Sign in, then run an ordinary typed
      command ("open Safari"). It should plan and run exactly as before. **This is the first time in
      the project's life that works with no provider key on the machine**, so if it works, the
      credential really has moved.
- [ ] **(new 2026-08-27, SONNY-130)** Hold the push-to-talk hotkey, speak a short command, release.
      The transcript should arrive and dispatch as it always did. Note that the mic is no longer
      blocked by a missing key — before this branch a Finder launch left it refusing with "No API
      key is set up", which is precisely the failure this row is checking is gone.
- [ ] **(new 2026-08-27, SONNY-130)** Run a web-research command that needs a search ("research
      what's new in Swift 6 concurrency and save it as markdown"). Both halves go through the
      backend now — the search and the synthesis — so a note that comes back with real sources means
      both worked.
- [ ] **(new 2026-08-27, SONNY-130)** **Hold the record hotkey for more than three minutes**, then
      release. It must refuse with *"That recording is too long. Sonny listens for up to 3 minutes
      at a time."* — a human sentence, no status code, no mention of bytes or uploads. The recorder
      also stops itself a few seconds past the cap, so the file cannot grow without limit while you
      are waiting; nothing should be uploaded at all.
- [ ] **(new 2026-08-27, SONNY-130)** Turn **"Don't save this task"** on, then run a command. It
      should behave identically. (What it changes on the backend — `retention: "none"` — is not
      observable from the app, and the backend does not store anything yet either: SONNY-134 builds
      the content store. This row is checking the switch did not break the run.)
- [ ] **(new 2026-08-27, SONNY-130)** Sign **out**, then try to run a command. It should fail with
      *"Sign in to Sonny to run this."* rather than a status code, a URL, or anything about
      providers or tokens. (What the product should do about being signed out — beyond saying so —
      is `feature/row-12-degradation`'s; this row is only checking the sentence is human.)
- [ ] **(new 2026-08-27, SONNY-130)** After any of the above, open **Tasks** and check the run's
      usage line still shows token counts. The numbers now come from the server rather than from the
      app's own estimate, and the one thing that must not have happened is the summary silently
      going blank.

### The gateway honours the idempotency key (new 2026-08-28, SONNY-300)

**What this section is and is not.** All four of contract §9.2's sentences are covered by automated
tests and were measured against a live container while the ticket was built, so these rows are not
"check the feature works" — they are the two things no agent can check. The first is that putting a
hook on *every* `POST` did not disturb ordinary use, which only a real app run shows. The second is
what a genuinely flaky network does, which no test can stage.

Setup is the shared note above; nothing here needs a provider key. **Every row here waits on
SONNY-280's resume** — the first two run commands in the app, and the last, though it is a Terminal
row, needs an access token from a signed-in run. (Pointer added 2026-08-28, SONNY-330: this said
"the sign-in section's setup, plus the container from the section above" and said nothing about the
wait.)

- [ ] **(new 2026-08-28, SONNY-300) — the regression row, and the important one.** With the app
      pointed at a local gateway, sign in and run three or four ordinary commands of different kinds
      — a typed command, a spoken one, a web-research one. Every `POST` the app makes now passes
      through a new pair of hooks and a database write, so what this row is looking for is *nothing*:
      no new delay you can feel, no failure, no repeated work. If a command that used to work now
      fails, or the app feels slower to start a task, that is this branch.
- [ ] **(new 2026-08-28, SONNY-300) — what a bad network does.** Start a command, then turn Wi-Fi off
      mid-run and back on a few seconds later. The app retries with the same key, so the worst it
      should do is finish or fail with an ordinary human sentence. **What must not happen is the run
      being charged twice or done twice** — if a research command comes back having fetched
      everything twice, or a note is written twice, say so.
- [ ] **(new 2026-08-28, SONNY-300) — Terminal, not the app.** With the container running, send the
      same request twice with one key and confirm the second is free. Replace `<TOKEN>` with an
      access token from a signed-in run (the sign-in section says how):

      ```
      B='{"task_id":"t","retention":"standard","messages":[{"role":"user","text":"hello"}],
          "response_schema_name":"Plan","response_schema":{"type":"object"}}'
      for i in 1 2; do
        curl -s -D- -o /dev/null -X POST http://127.0.0.1:8080/v1/plan \
          -H "Authorization: Bearer <TOKEN>" -H 'Content-Type: application/json' \
          -H 'Idempotency-Key: 11111111-2222-4333-8444-555555555555' -d "$B" | grep -i '^HTTP\|^sonny-request-id'
      done
      ```

      Both should answer `200`, and **both should carry the same `sonny-request-id`** — that repeated
      id is the whole guarantee, visible in one line: the second request returned the first one's
      stored response instead of calling a provider again. Then change one word inside the body and
      send it a third time with the same key: it must answer `409` with `idempotency.conflict`.
### Screen control behind the backend (new 2026-08-28, SONNY-131)

**The fifth and last credential-bearing route.** Screen control now runs through Sonny's own gateway
under your sign-in, with no `OPENCODE_API_KEY` anywhere — that variable is read by nothing, and the
app no longer has a "screen control is not configured" state at all.

**Setup is the shared note above, plus one variable:** `./scripts/deploy.sh local` also forwards
`VISION_API_KEY`, which is the credential this route needs. **Every row here runs a real
screen-control session, so every one of them waits on SONNY-280's resume** — a screen-control run
plans first, and planning is authenticated, so a signed-out app never reaches a capture at all.

*(This paragraph used to block these rows on "SONNY-307's successor". No such ticket has ever
existed, and SONNY-307 itself is Done and merged. Corrected 2026-08-28, SONNY-330.)*

- [ ] **(new 2026-08-28, SONNY-131) — the headline check.** Packaged `.app` from Finder, no
      environment variables at all. Run a real screen-control task through several iterations — a
      goal needing three or four clicks on small controls. It should behave exactly as it did
      before. **Nothing on your Mac holds a vision key now**, so if it works, the credential has
      moved.
- [ ] **(new 2026-08-28, SONNY-131)** Run one on the **largest display available**, with heavy
      content on screen (a photo library, a paused video, a map). It must not fail with *"The window
      screenshot is N bytes…"*. That message appearing at all is worth reporting with the number it
      quotes: the ceiling is now the same number on both sides of the network, so seeing it means
      the two have come apart.
- [ ] **(new 2026-08-28, SONNY-131)** Switch to **Safe mode** and start a session. The capture-review
      panel must still appear before each send, showing the screenshot. **The reason to run it is
      that this is the only place a human sees what is about to leave**, and the capture path is what
      this ticket rewired around. (The parenthetical here used to say the panel is where a *wire*
      shape change would show as a blank frame; PR #144's R4 corrected it. The panel is built from
      `payload.redactedImageData` directly — `VisionSessionRunner.swift:366` — and never sees the
      request body, so a change to the wire cannot blank it.)
- [ ] **(new 2026-08-28, SONNY-131)** Put something secret-shaped on screen (an `sk-`-prefixed string
      in a text editor is enough) and start a Safe-mode session. The preview must show a solid black
      rectangle over it, hard-edged, no ghosting. **Redaction is upstream of everything this ticket
      touched and must be exactly as it was** — this row is the check that says so.
- [ ] **(new 2026-08-28, SONNY-131)** Stop a session mid-run with the **emergency stop**. It must
      stop immediately, and what you are told must read as a stop rather than as a failure — no
      *"Sonny couldn't finish this one. Try again."*. (That sentence really did appear here during
      this ticket, on a stop that reached a request already in flight, and the fix is the reason this
      row exists.)
- [ ] **(new 2026-08-28, SONNY-131; rewritten the same day after PR #144's F1)** After a session,
      run `docker logs <the gateway container>` and count the `POST /v1/screen/analyze` lines. There
      should be **one per iteration**, matching the step count the HUD showed. That is the whole of
      what this ticket's metering requirement can be checked against from outside the app, and it is
      a real check: one usage record per iteration is the decision, and the request count on the wire
      is that decision made visible.
      **Do not look in Tasks for a usage line — there is none, and that is not this ticket's to
      build.** Nothing in the app renders `taskUsageSummary` (`git grep -n taskUsageSummary --
      Sources` → 4 lines, all in `AgentViewModel.swift`, none of them a view), `CompletedTaskRecord`
      carries no usage field, and Settings → Usage says so in the product's own words: *"Sonny tracks
      approximate usage per task today, but a full summary isn't built yet."* The record exists and is
      asserted by tests; **the surface is SONNY-214's** (corrected 2026-08-28, SONNY-133 — this row
      said "SONNY-133-adjacent work", and that ticket landed on the same day with "a usage UI" in its
      own non-goals, so it would have sent the next reader to a ticket that had already declined it).
      The first version of this row sent you to Tasks to find something no view draws.
### Which provider serves a route, and failover (new 2026-08-28, SONNY-132)

**What changed:** which model provider plans a command is now a server setting, not a fact about
your Mac. `SONNY_PLANNER` is gone, `CerebrasPlanner` is gone, and the app holds no provider name,
no vendor endpoint and no model identifier. Anthropic ships as a real second provider, so a route
can fail over when the first provider is having a bad hour.

**Setup is the shared note above, plus the keys you want the container to hold:**
`./scripts/deploy.sh local` forwards `ANTHROPIC_API_KEY` and `CEREBRAS_API_KEY` alongside
`OPENAI_API_KEY` and `TAVILY_API_KEY`, so exporting a key in the launching shell is all it takes to
give the container one. **These rows change only what is exported before `./scripts/deploy.sh
local`, and never the app** — that is the whole thing being checked. **The last row, the startup
line, runs today**; the rest need a signed-in run and wait on SONNY-280's resume.

*(This paragraph assumed a container up and serving while the SONNY-131 section beside it said no
such container could exist. Both halves are answered in the note above. Corrected 2026-08-28,
SONNY-330.)*

- [ ] **(new 2026-08-28, SONNY-132) — the headline check.** Run the same typed command ("open
      Safari") twice from an unchanged app: once with the container started with
      `MODEL_ROUTE_PLAN=openai` exported, and once with `MODEL_ROUTE_PLAN=anthropic`. Both should
      plan and run normally, and **nothing in the app should look different between the two** — not
      the plan, not the timing beyond ordinary variation, not the Tasks row. If you can tell which
      one served from inside the app, that is the finding.
- [ ] **(new 2026-08-28, SONNY-132)** Do it a third time with `MODEL_ROUTE_PLAN=cerebras` and
      `CEREBRAS_API_KEY` exported. Same expectation. This is the option that used to need
      `SONNY_PLANNER=cerebras` and a key on your own Mac.
- [ ] **(new 2026-08-28, SONNY-132) — failover, invisible.** Export a **deliberately wrong**
      `OPENAI_API_KEY` (say `sk-not-a-real-key`) together with a **working** `ANTHROPIC_API_KEY`,
      leave `MODEL_ROUTE_PLAN` unset so the default `openai,anthropic` chain applies, and run a
      command. **Expected: it works, and the app says nothing about it.** A wrong key is a `401`,
      which is a refusal rather than an outage, so this actually checks the honest-failure row
      below; to exercise failover itself, point `OPENAI_BASE_URL` at something that refuses
      connections (`http://127.0.0.1:9/v1`) instead — an unreachable provider is what failover is
      for. Either way, the finding is a raw error, a status code, a vendor name, or a strip
      announcing that a different provider was used.
- [ ] **(new 2026-08-28, SONNY-132) — failure, honestly.** Now break **both**: unreachable
      `OPENAI_BASE_URL` and no `ANTHROPIC_API_KEY` at all. The command should fail with a human
      sentence — *"Sonny couldn't finish this one. Try again."* — and **no provider name, no URL, no
      status code**. A raw error here is the finding.
- [ ] **(new 2026-08-28, SONNY-132) — no vendor anywhere.** With everything working, use the app
      normally for a few minutes and look for any provider name in any surface: the widget, the
      Tasks list and a task's detail, Insights, Settings → Usage, an error strip, a notification.
      There should be none. (The usage line names the *route* — "plan" — rather than a model, which
      is the intended reading, not a finding.)
- [ ] **(new 2026-08-28, SONNY-132) — the notice strip that should no longer exist.** Nothing you do
      should produce a dismissible strip in the widget saying which planner was used and why. That
      strip was SONNY-85's and it is deleted; seeing one means it came back.
- [ ] **(new 2026-08-28, SONNY-132) — startup line, one look.** Run `docker logs
      sonny-gateway-local | grep '"msg":"model routing"'` once, and check the chain it prints is the
      one you exported and that **no key or fragment of a key appears in it**. This is the only row
      here that looks at the server rather than the app, and it is the one that would catch a
      credential leaking into a log line.

### A stop on the text routes is a stop, not a failure (new 2026-08-28, SONNY-320)

**What you are checking is one sentence and one history row.** Before this ticket, pressing Stop
while Sonny was talking to the backend was reported as a failure: the steps went red, the banner
read *"Sonny couldn't finish this one. Try again."*, and the run was written to Tasks as failed. A
stop is not a failure, and it should never invite you to retry something you deliberately stopped.

**Setup is the shared note above, plus a real `OPENAI_API_KEY` and `TAVILY_API_KEY` exported before
`./scripts/deploy.sh local`.** **Every row here runs a command in the app, so every one of them
waits on SONNY-280's resume.**

*(This section was written pointing at SONNY-330 because the three setup notes above it were stale
or contradicted each other, and it asked whether a real sign-in works today. SONNY-330's answer, on
2026-08-28: the three notes are rewritten into the one above, nothing is blocked on missing code any
more, and what these rows wait on is the deferred identity sitting. Folded in 2026-08-28,
SONNY-330.)*

**These rows need a request that is genuinely in flight for a second or two**, so they cannot be run
against a gateway that answers immediately.

- [ ] **(new 2026-08-28, SONNY-320) — the headline check.** Type an ordinary command and press
      **Stop while it still says it is planning** — that window is a second or two, so be ready. It
      should say **"Canceled."**, with the steps shown as canceled rather than failed, and **no red
      banner at all**. Seeing *"Sonny couldn't finish this one. Try again."* is the defect this
      ticket fixed coming back.
- [ ] **(new 2026-08-28, SONNY-320)** Open **Tasks** and find that run. It should be recorded as
      **canceled**, not failed. This is the half you would still be living with a week later: a
      history full of red rows for runs you stopped on purpose.
- [ ] **(new 2026-08-28, SONNY-320)** Run a web-research command that needs a search ("research
      what's new in Swift 6 concurrency and save it as markdown") and press **Stop during the
      "Searching web for …" line**. Same result: "Canceled.", no red banner, a canceled row in Tasks.
- [ ] **(new 2026-08-28, SONNY-320; expectation corrected 2026-08-28 by SONNY-328 — read this
      rather than the sentence it replaces.)** Run the same web-research command and press **Stop
      while it is fetching sources** (the "Fetching https://…" lines, which come after the search).
      **This row originally said the window was not fixed** and asked you to report which of two bad
      endings you saw — a saved note listing the stopped sources as skipped, or a red banner. Both
      of those were real, both were reproduced by a test, and **SONNY-328 fixed them in the same
      branch as this row**, so the expectation is now the same as every other row in this section:
      **"Canceled.", no red banner, a canceled row in Tasks, and no Markdown file written**. A saved
      file, or a note whose "Skipped Sources" section lists the sources you stopped, is now the
      finding rather than the expected result. (SONNY-328's own rows are in the section below,
      which is where the detail lives.)
- [ ] **(new 2026-08-28, SONNY-320)** Confirm a **real** failure still reads as a failure. Stop the
      container, then run any command: it should still show the red banner and its own sentence. A
      predicate that answered "cancelled" too eagerly would have swallowed this, and that is the
      direction nothing else in this section would catch.
### A stop while web research is fetching sources (new 2026-08-28, SONNY-328)

**Same sentence as the section above, one mechanism further down.** SONNY-320 fixed the four text
routes — planning, transcription, search, synthesis — by making their error types transparent to the
one cancellation predicate. This is the fifth place a stop can land and the one no conformance could
reach: the loop that fetches each source page. It caught `CancellationError`, and the `URLSession`
underneath it raises `URLError(.cancelled)`, so a stop was recorded as *an unreachable source* and
the run carried on.

**Setup is the shared note above's, plus a real `OPENAI_API_KEY` and `TAVILY_API_KEY` exported
before `./scripts/deploy.sh local`** — the same as the section directly above, because these rows
run the same kind of command. **So they wait on SONNY-280's resume for the same reason those do**,
and that is stated here rather than left to be inherited from a neighbouring section: this file's
own history is sections whose setup notes drifted apart as the thing underneath them changed, which
is what SONNY-330's shared note exists to stop. These rows additionally need a command with several
sources, so there is a fetch window to press Stop inside; a single-URL command finishes too fast.

- [ ] **(new 2026-08-28, SONNY-328) — the headline check.** Run **"research what's new in Swift 6
      concurrency and save it as markdown"**, wait for the **"Fetching https://…"** lines to start,
      and press **Stop while they are still going**. Expected: **"Canceled."**, steps canceled
      rather than failed, **no red banner**, and a **canceled** row in Tasks.
- [ ] **(new 2026-08-28, SONNY-328) — the half that is easiest to miss, and please check it
      explicitly.** Look in the folder the note would have been saved to. **There must be no
      Markdown file for that run.** The defect's quietest ending was a run that completed and saved
      a note after you pressed Stop; if a file is there, open it — a **"## Skipped Sources"** section
      listing the sources you stopped is exactly the shape this ticket removed.
- [ ] **(new 2026-08-28, SONNY-328)** Confirm the per-source tolerance still works, because that is
      what the fix had to avoid breaking. Run a comparison command over **two real URLs plus one
      that does not exist** ("compare <url A> and <url B> and <url C> and save it as markdown", with
      C a 404 on a real host). It should **still succeed**, write the note, and name the dead one
      under "Skipped Sources". One dead source sinking the whole run would be this fix overreaching.

### What every call cost (new 2026-08-28, SONNY-133)

**What changed:** the gateway now records one metering event per call, on every route, and screen
control — which recorded nothing anywhere before SONNY-131 gave it a client-side record — is the
reason the table exists. **This is where SONNY-17's pricing numbers come from**: the free-tier
allowance and the paid price stop being guesses the moment the rows below produce a per-session
figure.

**Four of the five rows below queue behind the deferred identity sitting, and that is recorded here
rather than discovered at the terminal.** Every metered route is authenticated, so a metering event
needs a caller signed in *through the app*, which is the email-code flow. What that waits on is
**SONNY-280's founder-deferral comment of 2026-08-27, and its numbered resume checklist** — steps
(1) through (5) of it, in that order. **Do not go looking for the project: it exists.**

- **The Supabase project is `zpyyljfsqrxulhmgkhfp` (sonny-dev), and all ten migrations are applied
  to it.** Use the **session pooler** connection string — `postgres.<ref>` as the username, port
  5432 — because the direct `db.<ref>` host is IPv6-only and does not resolve on the founder's
  network. That is the working `DATABASE_URL` form and it is already recorded on SONNY-280.
- **Three further things block these rows independently, and any one of them is a 401 or a dead
  end.** (a) **The JWT key mode, which is the first stop** — the project provisioned with an ECC
  (P-256) key as CURRENT and Legacy HS256 as PREVIOUS, and this gateway verifies HS256 only, so a
  token minted under the ECC key fails the gate with a 401 and nothing about it looks like a
  configuration problem. Project Settings → JWT Keys; the rotation back to Legacy HS256 was
  mid-flight when the deferral landed and **whether it completed is unconfirmed**. (b) **The Magic
  Link template is LOCKED** until custom SMTP is configured, so `{{ .Token }}` is not in the mail
  body and no mail can carry a code — Resend test mode is the fast path SONNY-280 records. (c)
  **`./scripts/deploy.sh local` has never been run with real credentials against that project** —
  the `auth routes are mounted` probe has fired only against placeholders, which is resume step (4)
  and is where a founder finds out whether (a) and (b) actually landed.
- **What is emphatically *not* the blocker: SONNY-280's step 1.** That is the collective manual
  pass and it finished on 2026-08-25, 27 of 27 items at `140829b`. An earlier draft of this section
  named it, and named SONNY-307's "no Supabase project exists" — a statement true when written on
  2026-08-27 at 17:52 and superseded by the deferral comment at 21:39 the same day. Corrected
  2026-08-28 (PR #147's review, F1). The failure that correction prevents is specific: a founder
  goes to create a project, finds `sonny-dev` already there with its migrations applied, does not
  open the JWT Keys page, and meets a 401 on every metered call with nothing here to explain it.

**What was already measured, so these rows are the remaining half rather than the whole thing.** The
code ran end to end against a real container and a real Postgres while the ticket was built —
eighteen metering events from nineteen requests, a retry that wrote one, an incognito session metered
identically — with an access token minted by hand against the same HS256 secret the gate verifies,
and with the model provider stubbed. What no agent can do is sign in through the app or spend a real
vendor credential, and that is exactly what these rows are for.

**Setup for the four, once that resume has run:** the sign-in section's setup, plus the container
from "The four routes behind the backend", plus `VISION_API_KEY`. Then run `cd server && npm run
build` once, and read the reports with `DATABASE_URL=<the same one the container uses> npm run usage
-- <command>` — the same session-pooler URI the container is given, not the direct host.

- [ ] **(new 2026-08-28, SONNY-133) — Terminal, needs only a Postgres. This one is runnable today.**
      With a database and `npm run build` done, rehearse the migration both ways:
      `npm run migrate -- up`, then `npm run migrate -- down`, then `npm run migrate -- up` again.
      The `down` must say `rolled back: 0012_metering_records_what_every_call_cost` and the table
      must be gone (`\dt sonny.*` in `psql`); the second `up` must bring it back. Then run
      `npm run usage -- span` against the empty table: it must say *"no metering events in this
      window"* rather than printing an empty report or an error. A rollback that leaves the table, or
      a re-apply that fails, is the finding — this is the rehearsal that makes a migration safe to
      run against a real database later.

- [ ] **(new 2026-08-28, SONNY-133) — after SONNY-280's resume steps (1)–(5). The headline row, and the
      one the pricing waits on.** Sign in, then run **three or four real screen-control sessions** of
      different lengths — a short one that finishes in two or three steps, and one that needs eight
      or more. Note the step count the HUD shows for each. Then run
      `npm run usage -- sessions`. There must be one block per session, `iterations` matching the
      step count you saw, and a `megapixels sent` figure that is larger for the longer sessions.
      **Send me the whole output** — this is the measurement, and the numbers in it are what SONNY-17
      turns into a credit weight. What would be a finding: a session missing entirely, an iteration
      count that does not match the HUD, or `no tokens 0 of N` where you expected numbers and got
      none (that last one is not necessarily wrong — the footer explains why — but say so).

- [ ] **(new 2026-08-28, SONNY-133) — after SONNY-280's resume steps (1)–(5).** Run one screen-control
      session with **"Don't save this task"** on. It must appear in `npm run usage -- sessions` like
      any other, with `retention none` on its block. **A missing session is the finding**, and it is
      the one this row exists for: incognito changes what is stored and never what is billed
      (founder, via SONNY-14), so a metering design that dropped these would quietly make exactly
      those runs free.

- [ ] **(new 2026-08-28, SONNY-133) — after SONNY-280's resume steps (1)–(5).** Start a screen-control
      session, then **turn Wi-Fi off mid-run and back on** a few seconds later. However the session
      ends, run `npm run usage -- sessions --session <that session>` afterwards and check the
      iteration count against the number of steps the HUD actually took. **A retry must not appear
      twice.** If the count is higher than the steps you saw, that is the finding and it is the one
      the whole idempotency claim exists to prevent.

- [ ] **(new 2026-08-28, SONNY-133) — after SONNY-280's resume steps (1)–(5). Read this row before
      running it: it is not "find the usage screen".** There is **no per-task usage surface in the
      app**, and that is not this ticket's to build — Settings → Usage says so in the product's own
      words (*"Sonny tracks approximate usage per task today, but a full summary isn't built yet."*),
      nothing renders `taskUsageSummary`, and the surface is SONNY-214's. SONNY-131's row was
      rewritten the same day to stop sending you to look for one, and this row would have repeated
      the mistake if it had been written from the ticket's wording. **What to check instead:** run an
      ordinary typed command, a spoken one, and a screen-control session, and confirm each behaves
      exactly as it did before — no new pause, no new failure, nothing that reads as the app waiting
      on something. **Every one of those now writes a database row *before* the response leaves the
      server, which is why this row is worth running at all**: the write is on the critical path, a
      third database round trip ahead of the bytes, so it is the one change on this branch a user
      could in principle feel. (This row said "after its response" when it was written, one commit
      before the write moved — the inversion of the branch's own central decision, and it told the
      founder there was nothing that could be felt. Corrected 2026-08-28, PR #147's review, F2.)

### Retention, deletion, and what support can see (new 2026-08-28, SONNY-134)

**What changed:** the backend now keeps the content of your calls for **30 days** — the command text,
the voice recording, the redacted screenshot, the reply, and a provider's error body — and, just as
importantly, it now has the two ways content does *not* get kept: a delete that reaches everywhere,
and a "Don't save this task" run that is never stored at all. The founder confirmed the thirty days
on 2026-08-28.

**Read this before running any of it: one row below is runnable today and the rest need sign-in.**
The three sign-in rows queue behind **SONNY-280's founder-deferral comment of 2026-08-27 and its
numbered resume checklist, steps (1)–(5), in that order** — the same gate SONNY-133's rows sit
behind, and its section above carries the detail that matters (the Supabase project
`zpyyljfsqrxulhmgkhfp` exists with its migrations applied, use the **session pooler** connection
string, and the JWT key mode is the first thing to check). Nothing here needs a provider credential
beyond what those rows already need.

**One thing this branch deliberately did not build, so a row below does not ask you to look for it.**
The app's own delete button still deletes only the Mac's copy: `AgentViewModel.deleteTask` does not
call the new endpoint, because SONNY-134 was scoped server-only for parallel-lane disjointness
(`docs/sonny-row-12-plan.md` §8.2). The endpoint is real and reachable; wiring the button to it is a
separate ticket. The row below therefore calls the endpoint with `curl`, which is what actually
exists to test.

- [ ] **(new 2026-08-28, SONNY-134) — Terminal, needs only a Postgres. This one is runnable today.**
      With a database and `npm run build` done, rehearse the migration both ways:
      `npm run migrate -- up`, then `npm run migrate -- down`, then `npm run migrate -- up` again.
      The `down` must say `rolled back: 0013_content_is_kept_on_its_own_clock` and **all five tables
      must be gone** (`\dt sonny.*` in `psql`: `retained_content`, `training_snapshot`,
      `training_snapshot_member`, `content_deletion`, `content_access`); the second `up` must bring
      them back. Then run `npm run support -- deletions` against the empty table: it must say *"no
      deletions recorded"* and explain that this is the expected answer until content is old enough
      to expire, rather than printing an error. A rollback that leaves a table behind, or a re-apply
      that fails, is the finding.

- [ ] **(new 2026-08-28, SONNY-134) — after SONNY-280's resume steps (1)–(5). The headline row.**
      Sign in, run **one ordinary task** (a typed command that reaches the planner), and note the
      task from Command Center. Then, in a terminal with the same `DATABASE_URL` the container uses:
      `npm run support -- account <your account id>`. It must show `content` with **at least one
      call retained**, a `next expiry` about thirty days out, and your usage beside it. Then delete
      that task's server copy — the app cannot do this yet, see the note above — with
      `curl -X DELETE -H "Authorization: Bearer <an access token>"
      http://localhost:8080/v1/tasks/<task id>`; it must answer `200` with `requests_deleted` at
      least 1. Re-run the account report: `content` must be back to **0 call(s) retained**, and
      `npm run support -- deletions` must show a `task` row naming that task. **What would be a
      finding:** a `404` from the delete, a `requests_deleted` of 0 for a task you just ran, or
      content still showing after the delete.

- [ ] **(new 2026-08-28, SONNY-134; command widened 2026-08-28 after PR #148's review) — after
      SONNY-280's resume steps (1)–(5).** Run one task with **"Don't save this task"** on. Then check
      **both** places this gateway can hold response content, because the review found the leak in
      the second one and a check of the first alone would have passed straight over it:
      <br>&nbsp;&nbsp;**(a)** `npm run support -- account <your account id>` — **`content` must say
      0 call(s) retained** for it, while `usage` shows the call, one more event than before.
      <br>&nbsp;&nbsp;**(b)** in `psql` against the same database:
      `SELECT idempotency_key, state, response_body IS NOT NULL AS has_body FROM sonny.idempotency_key
      ORDER BY claimed_at DESC LIMIT 5;` — the row for that run must read **`released` and `has_body`
      = f**. A `completed` row with `has_body` = t is the finding, and it is the exact defect PR
      #148's F1 measured. **Do not check this with a `LIKE` over `response_body::text`** — that
      column is `bytea`, the cast gives hex, and the comparison answers a clean zero even when the
      reply is sitting there; use `convert_from(response_body,'UTF8')` if you want to read one.
      <br>This is the guarantee the whole feature rests on and the one most easily lost by accident:
      **content appearing in either place for that task is the finding.** The accepted cost is
      deliberate and is not a finding — if that run misbehaves, nothing stored can explain why, and
      that is the feature working. A second accepted cost, also not a finding: a retry of an
      incognito call re-runs rather than replaying, so you may see two provider calls for one
      operation.

- [ ] **(new 2026-08-28, SONNY-134) — after SONNY-280's resume steps (1)–(5). Read this row before
      running it: it is a judgement call, not a pass/fail.** Run
      `npm run support -- account <your account id>` and ask yourself the real question: **is this
      enough to answer a support email, and is it more than you should be able to see without
      asking?** It shows account state, how you sign in, what you have called and how it went, and
      how many calls are retained and of what kinds — and no content, and not the email address
      behind your identity. Then read one call's content deliberately:
      `npm run support -- content --request <a Sonny-Request-Id> --operator <your name> --reason
      "checking retention manually"`. It must refuse without either flag, print the request text and
      the response, print the screenshot and any recording as **sizes rather than bytes**, and then
      `npm run support -- accesses` must show your own lookup with the reason you typed. **Tell me
      if the account report is missing something you would actually need**, or if it shows something
      you think it should not. This is the row where the access decision gets its only real test.

### Web research — topic/search commands (new 2026-07-30, Tavily provider)

**Superseded by the section above as of 2026-08-27 (SONNY-130).** Search no longer reads
`TAVILY_API_KEY` on this Mac at all: the credential is the gateway's, and a search command goes
through Sonny's backend under your sign-in. The two key-shaped rows below are struck through rather
than deleted, because what they *tested* — the shape of a good research note, and direct-URL
summarization being unaffected — is still worth checking, and the section above is where the
credential half is now checked from. Each search still costs real money, so a handful of runs is
plenty.

- [x] ~~Without the key set: a search command still fails with the honest "Web search provider not
      configured." error~~ — **no longer reachable.** `TavilySearchProvider` cannot fail to
      construct, so `AgentViewModel` no longer falls back to `UnavailableWebSearchProvider`, and
      that sentence is unreachable from the search path. A search made while signed out says "Sign
      in to Sonny to run this." instead, which is the row in the section above.
- [ ] ~~With the key:~~ **signed in**, the command ("research three alternatives to Raycast and save
      a comparison") produces a real Markdown research note — Sources section lists the pages
      actually fetched (not raw search-result text), and a generation timestamp is present
- [ ] Direct-URL summarization ("summarize <url> and save it as Markdown") still works exactly as
      before — the provider only affects search/topic commands

### Prompt-text folds — screen control and web research (new 2026-08-26, SONNY-226 / SONNY-231)

**Almost nothing here is founder-checkable, and that is stated rather than left as an empty
section.** Both tickets change *prompt text* — what the vision model and the web-research synthesizer
receive — and nothing else. No pixel of the app changes, and the prompts themselves are handed to a
model API and to nothing else, so there is no surface a human can read them on. The line counts, the
shapes and the escaping are all pinned by `InterpolatedFieldLineFoldTests`, and every one of those
assertions was shown to fail against the unfolded tree.

The two rows below are the *only* part a test cannot reach, because no test in this repo calls a
model: whether a model still behaves the same on the changed prompt. Ordinary app names and ordinary
page text are provably unchanged scalar-for-scalar (`textWithoutALineBreakIsUntouched`), so these are
sanity checks on end-to-end behaviour, not on the fold.

- [ ] **(SONNY-231)** Run one ordinary screen-control task on an app whose name contains a space —
      "in Google Chrome, open a new tab" or similar. It should behave exactly as it did before: the
      model still finds and clicks controls, and nothing in the session reads as confused about which
      app it is in. What would show a regression is the model losing track of the app.
- [ ] **(SONNY-226)** Run one web-research task that fetches a real page ("summarize <url> and save it
      as Markdown"). The note should still summarise the page's actual body — the readable text is
      deliberately *not* folded, so a note that reads as one run-on line, or that has lost the page's
      paragraphs, is the regression to report.

### Prototype-limitation re-check — the parts the tree cannot answer (new 2026-08-27, SONNY-296)

SONNY-296 re-checked the seven dated prototype-limitation findings in the spec's §4 and §4A.4
against the tree. Most of them the suite settles. **Three do not, and these rows are exactly those
three** — not a re-test of things already pinned, and not a request to confirm what a passing test
already proves.

- [ ] **(SONNY-296, music — the one open finding)** In the packaged app, run **"Play Jimmy Cooks by
      Drake on Apple Music"**, and then **"Play Bad Habit by Steve Lacy on Spotify"**. Expected, and
      this is the *correct* behaviour today rather than a bug to report: neither one plays. Each
      should report that provider playback is unavailable and then open the provider instead —
      Apple Music should land on the actual track's album page (it resolves the track through the
      public iTunes Search API first), Spotify on a search for the query. What *would* be a finding:
      a raw error, a hang, a silent no-op, or a summary claiming playback started. Also try one with
      the provider app not installed, and one with no network, and report whatever the user sees.
- [ ] **(SONNY-296, Command Center surfaces)** Open Command Center and confirm all six controls §4's
      fourth bullet names are actually there and usable, since no test in this repo renders a view:
      the **account** row at the bottom left; **Settings** opening from it with all five sections
      (Preferences, Notifications, Usage, Security & Access, Data); task **history** on the Tasks
      page; **stats** on Insights *and* on Settings → Usage; **privacy** controls on Settings → Data;
      and the **Safe | Normal | Power** dial at the top of Settings → Security & Access. A control
      that is present but does nothing, or a page that renders empty where it should have content,
      is the finding.
- [ ] **(SONNY-296, web research end-to-end)** Run **"summarize <a real public article URL> and save
      it as Markdown"** against a page you can read yourself. The suite proves this path with a fake
      page loader and a fake synthesizer, so what is unverified is the real one: the note should name
      that URL as a source, carry a generation timestamp, and summarize the page's actual body. A
      note that summarizes the wrong page, or carries no source link, is the finding. (This overlaps
      the SONNY-226 row above deliberately — that one asks about paragraph structure after the
      prompt fold, this one about the source-and-timestamp contract §4A.2 sets.)

### The approval panel names the file a nested routine will write (new 2026-08-28, SONNY-218)

One row, and it is the only founder-visible thing on `fix/three-small-client-defects`. SONNY-264's
half of that branch changes no surface at all: it refuses an output path that leads out of
`~/Desktop`/`~/Documents` with the same sentence that has always been shown for a path the user
named, and reproducing it needs a symbolic link planted by hand.

- [ ] **(SONNY-218)** Save a routine that creates a draft — "teach Sonny a routine called Notes that
      drafts a note" — then ask, in one command, for **a note *and* that routine**: "draft a note
      called Note, then run the Notes routine". Read the approval panel before approving: its
      "Will include:" lines must name **two different files**, the second ending `-2.md`. Approve,
      and both of those exact files must exist afterwards. The bug this fixes is the panel naming
      one filename twice while the run wrote two — so a panel that shows the same name twice, or a
      filename on disk that the panel never mentioned, is the finding. Worth running the two steps
      in the other order too ("run the Notes routine, then draft a note called Note"), which is a
      different code path and had the same defect.

## 8. How to report back

For each real finding, give me:
**[page/component] — [what you did] — [what you expected] — [what actually happened]**, plus a
screenshot if it's visual. Per this project's own rule, anything found during a branch's own testing
gets fixed in that branch before merge — nothing gets backlogged.
