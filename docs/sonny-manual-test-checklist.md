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
| 30 | Insights layout is a plain stacked `VStack` (3 equal stat cards + 3 full-width panels) — confirmed via code read to be exactly the pattern `docs/sonny-founder-design-decisions.md` explicitly rejects ("asymmetric bento grid, uneven tile sizes... explicitly not uniform/symmetrical"), despite an old commit (`470f61f`) claiming to have built the asymmetric version | ⚠️ **Explicitly deferred to the last review/final-updates branch before v1 release (your call, 2026-07-24)** — not fixed on this branch, not a silent gap either. Full reasoning + code pointer in `docs/sonny-founder-design-decisions.md`'s Insights section. Do NOT mark this "done" based on the old commit message — it overclaimed | §7 (Insights) |
| 31 | Real crash, caught by the pre-stop test hook, not manual QA: `AsyncProcessRunner` (backs Shortcuts subprocess invocation) had a genuine race — cancelling the wrapping Task could call `Process.terminate()` before `Process.run()` had actually launched it, which throws an **uncatchable** NSException (`-[NSConcreteTask terminate]: task not launched`) and crashes the whole app, not just the one task. Rare/timing-dependent (needs cancellation to land in a narrow window), which is why it only showed up in 1 of 3 back-to-back identical test runs | ✅ Fixed and root-caused — `AsyncProcessRunner` now brackets `process.run()` with a `ProcessBox` that holds the process, a launch phase and the cancelled flag under one `NSLock`: `register(_:)` before the launch refuses to start at all if cancellation already arrived, and `confirmLaunched()` immediately after it hands the terminate to whichever of the two got there second, so `terminate()` is only ever called on a process that finished launching. **`run()` itself is deliberately *not* inside the lock** — this row said it was, and named `launchIfNotCancelled`, `AsyncProcessRunnerTests` and `rapidCancellationNeverCrashesRegardlessOfTiming`, none of which exist (`git grep` over `Sources` and `Tests` at `1b67b29` → 0 each); corrected 2026-08-26 by SONNY-290. The 200-iteration cancellation stress test is `AgentActionExecutorTests.asyncProcessRunnerCancelledBeforeLaunchDoesNotCrash` (`Tests/MacAgentCoreTests/AgentActionExecutorTests.swift:134` at `1b67b29`), and `asyncProcessRunnerCancelsRunningProcess` beside it covers the other half. Real-world equivalent worth a spot-check: invoke a Shortcut from the widget/a Routine, cancel it immediately/repeatedly while it's running — should never crash the app | not easily manual — covered by the automated stress test; a real-world spot-check is cancelling a Shortcut-invoking task repeatedly right after starting it |

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

**2026-08-26 — the batch this file gained since `dd4ebae` (PR #116).** You ran the twenty-one rows
added to this file since that merge — §3d's thirteen SONNY-281 rows and four SONNY-283 ones, and
§3d-bis's four SONNY-282 ones (`git diff dd4ebae 368ab85 -- docs/sonny-manual-test-checklist.md |
grep -E '^\+- \[ \]' | grep -oE 'SONNY-28[123]' | sort | uniq -c` → 13, 4 and 4 at `368ab85`) — on
the packaged app at `main` `368ab85`, and reported them working. It came back as a batch — "yeah the
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
docs/sonny-manual-test-checklist.md` → 48 at `368ab85`); twenty-one of those are this batch, so
twenty-seven are left. Every one of them predates `dd4ebae`, none of them was in front of you on
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
- [ ] **(new 2026-08-28, SONNY-251)** **The collapsed capsule now has a VoiceOver name, and it had
      none at all before.** Turn VoiceOver on (Cmd-F5), let the widget collapse to the small pill,
      and move VoiceOver's cursor onto it. It must announce **"Open Sonny"**. Before this ticket it
      carried a tooltip and no accessibility name, so it announced whatever macOS makes of an SF
      Symbol called `wand.and.stars.inverse` — the other three icon-only controls in the widget have
      always had a full name. This is the fix; the hover half of it is the §3d-bis row below
- [ ] **(new 2026-08-30, SONNY-338 — replaces the 2026-08-28 wording-call row, which asked the
      question this answers)** The two controls no longer share three words. With the capsule in
      front of you it still says **"Open Sonny"** and still expands the *widget*; click the menu-bar
      icon and its middle item now reads **"Open Command Center"** and still opens the *Command
      Center window*. Each control is named after where it goes, which is what you and Bhavya
      decided on 2026-08-30. Nothing else in either surface changed — the wider menu-bar treatment
      is still SONNY-109's

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

### 3c-quinquies. A screen-control run says how many are left (new 2026-09-02, SONNY-214)

**What changed:** the widget now shows a small muted line — `12 runs left`, SONNY-212's number,
nothing else — at the foot of its glass panel whenever a **screen-control** task is waiting on its
approval or in flight, and never beside an ordinary free task. The figure is fetched when the task
goes in flight, so it needs the gateway container up and a signed-in session (SONNY-212's setup,
`CREDIT_PLANS` included). No explanatory copy anywhere: the number, the word "left", and that is the
whole sentence.

The line's *window* is the one thing here that differs from the ticket's own wording, decided
2026-08-31 and worth knowing before you test it: in **Normal** and **Power** a screen-control
session raises no approval prompt at all, so there is no "about to run" moment to hang a line on and
it shows during the run instead. In **Safe** mode the approval pause is that moment and the line is
there before you press anything.

- [ ] **(new 2026-09-02, SONNY-214)** In **Normal** mode, ask for a screen-control task ("open my
      reading list in Safari using screen control"). **The line appears on the widget's panel while
      the session runs** — there is no approval prompt in Normal, so the working/controlling panel is
      where it shows — and it reads the same number `curl .../v1/account/credits` reports. It may
      land a beat after the panel does; it is fetched, not cached.
- [ ] **(new 2026-09-02, SONNY-214)** In **Safe** mode, ask for the same task. **The line is already
      there on the approval panel, before you press Allow** — the literal "about to run" moment.
- [ ] **(new 2026-09-02, SONNY-214)** Ask for an ordinary free task — a calculation, a web search,
      opening an app. **No runs-left line anywhere**, on any panel state, working through result.
      This is the row the ticket exists for; run it right after one of the two above so you know a
      figure was in hand.
- [ ] **(new 2026-09-02, SONNY-214)** Run one screen-control task to completion and read its result
      panel. **The line is gone the moment nothing is pending or in flight** — the result does not
      inherit it.
- [ ] **(new 2026-09-02, SONNY-214)** With the gateway container stopped (or signed out), ask for a
      screen-control task. **The run proceeds exactly as before and no line appears** — no zero, no
      placeholder, no error sentence. A failed read renders nothing rather than a number nobody
      served.

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
      (`Sources/MacAgent/AgentActivityPresentation.swift:471` and `:482` at `368ab85`). What was
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
      footing; nothing depends on them, so this is filling in the record rather than checking a fix.
      **(Note 2026-08-28, SONNY-251: still true of the hover, and no longer true of the capsule's
      words in general — it had no VoiceOver name at all, and now has one. The row for that is in
      §3a.)**
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
      right-click-only, worth explicitly re-confirming left-click works — **confirmed 2026-07-24**.
      **(Note 2026-08-30, SONNY-338: the middle item is now titled "Open Command Center". The
      confirmation above is unaffected — it is about the menu appearing on both clicks — and the new
      title has its own unchecked row in §3a.)**
- [x] "New Task" opens/focuses the widget; "Open Command Center" (titled "Open Sonny" until
      SONNY-338, 2026-08-30) opens/focuses Command Center; "Quit Sonny" actually terminates the
      process (check Activity Monitor, not just that windows closed).
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
- [x] No usage/quota metric anywhere on this page (deliberate — its absence is correct) —
      **confirmed 2026-07-24, and still correct.** Briefly retired on 2026-09-02, when SONNY-214
      added a `Screen Control — 12 of 20 runs left this month` row to this page, and reinstated the
      same day when the founders ruled that the row moves to the Account section instead (PR #188).
      **Why that nearly stuck is worth more than the row:** this line is the only visible reflection
      in the repository of `docs/sonny-founder-design-decisions.md`'s Insights decision — no usage or
      quota metric here, on stated product-strategy grounds — so retiring it as a stale wireframe
      note retired a founder decision without anybody naming it. It is now held by a test as well
      (`ScreenControlUsageSurfaceTests.insightsCarriesNoUsageMetricOfAnyKind`), so the next attempt
      fails the suite instead of reaching a founder's manual pass.

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

### Memory (new 2026-08-28, SONNY-243)

- [ ] **Every row's count now names what it counts.** Open Command Center → Memory. Each row's
      grey line used to read "**N saved**" whatever the row was; it now reads `3 routines`,
      `2 workspaces`, `184 tasks`, `26 artifacts`, `1 folder`, `12 copied items`, `4 snippets`,
      `2 apps`, `1 unfinished task`. **Say whether the nouns read right to you** — the three that
      are not simply the row's own title are the ones worth a second look: **artifacts**,
      **copied items**, and **unfinished task** (spelled out rather than "task" because Task history's
      rows are tasks too and the two counts must not look addable). Every noun lives in one switch,
      so any of them is a one-line change if you want different words
- [ ] **The pair you reported on 2026-08-23 no longer reads as a contradiction.** Ask Sonny to write
      two files into the same folder (`~/Desktop` is what you used). Then Memory → Output locations
      should read **"1 folder · newest …"**, and pressing **View** should show
      **"Desktop · ~/Desktop · used 2 times · last …"**. Both numbers are still what they always
      were — what changed is that each one now says what it is counting. Say whether the two still
      read as though one of them is wrong

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
- [ ] **(new 2026-08-28, SONNY-233)** **Read the two sentences before you press anything, and do
      the press itself last.** The detail line under **Delete Sonny local data** used to name ten of
      the thirteen kinds of thing the wipe deletes, and the **confirmation dialog** named nine — so
      the two surfaces describing one irreversible press disagreed with each other as well as with
      the wipe. Both now read one sentence built from the store list itself, and the four that had
      gone missing are in it: **what past tasks planned**, **allowed apps**, **unfinished tasks**
      and (in the dialog) **common output locations**. Check that the page and the dialog say the
      same thing, and **say whether the sentence is too long to read** — it is **fifteen** items now
      (corrected 2026-09-03, PR #194's F8: it said thirteen, which was already one behind when this
      row was written and two behind once SONNY-333 added *deletions Sonny hasn't finished*, and the
      whole row is a judgement about length so the number is load-bearing to it), and the
      alternative considered and rejected was pointing at the Memory page instead, which
      would have stopped the sentence naming *records of what Sonny did on screen*
- [ ] **(new 2026-08-28, SONNY-233)** Then press it, as the row above says — confirm the wipe still
      does what it always did, and that nothing in the new wording promises something the press does
      not take

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
      `d5020b0`. Corrected by SONNY-330. The six the paragraph above names are still the gateway's
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

      Start one and apply the migrations first. **Its name and port are derived, not typed** —
      a container name and a host port are machine-wide, and a session's own test database may
      well be up while you do this (SONNY-355):
      ```
      LANE="$(basename "$(git rev-parse --show-toplevel)")"
      docker run -d --name "sonny-gw-db-$LANE" -e POSTGRES_PASSWORD=postgres -p 0:5432 postgres:17
      PORT="$(docker port "sonny-gw-db-$LANE" 5432 | head -1 | sed 's/.*://')"
      : "${PORT:?no host port — did the docker run above fail?}"
      until docker exec "sonny-gw-db-$LANE" pg_isready -q -U postgres; do sleep 1; done
      cd server && DATABASE_URL="postgres://postgres:postgres@localhost:$PORT/postgres" \
        npm run build && npm run migrate -- up
      export DATABASE_URL="postgres://postgres:postgres@host.docker.internal:$PORT/postgres"
      ```
      (`-p 0:5432` asks Docker for any free host port and `docker port` reads back which one, so
      nothing here collides with a container already running. The `pg_isready` line is a readiness
      wait and you need it: `docker run -d` returns when the container has started, and Postgres
      runs `initdb` before it accepts anything — 11 to 38 seconds, measured twice 2026-08-29 — so a migration
      run started immediately fails with `Connection terminated unexpectedly` and nothing else.
      And `host.docker.internal` in the exported value, not `localhost` — the gateway is in a
      container and `localhost` there is the container.) Then export the four Supabase names and
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
      `docker rm -f sonny-gateway-local "sonny-gw-db-$LANE"`.

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

### First run as one sequence (new 2026-08-28, SONNY-137)

**What changed:** launching on a Mac with no Sonny state now starts an ordered sequence — sign in,
then Screen Recording, the relaunch macOS forces, then Accessibility — instead of dropping you into
an empty Command Center to find out what is missing by hitting errors. The two steps are the dialogs
that already existed; what is new is that something triggers them, in that order, and that the app
comes back into the sequence after the relaunch rather than at the beginning or at the end.

#### The reset, and why every row names which parts of it it needs

The sequence records that it is over, and the two grants it walks you through are sticky. So a row
run against the state the previous row left behind tests nothing, or names a button that is not on
screen. **This section was rewritten on 2026-08-28 (PR #159's review, F1) because its first version
did exactly that**: it defined the reset as two `defaults delete` lines, and then row 3 — the
headline row — asked you to press *Request access* and *Relaunch Sonny* after row 2 had already
granted Screen Recording, at which point `ScreenAccessOnboardingView` renders neither control
(`permissionBlock` draws its actions only while a grant is missing, and the relaunch guidance
requires Screen Recording still to be ungranted).

**The full reset is four things.** Do them with Sonny running for (a), then quit for the rest:

- **(a) Sign out** — bottom-left account row → **Sign out**. Needs the app running, so it comes
  first. Skip it if you were never signed in.
- **(b) Forget the sequence** — with Sonny quit:
  ```bash
  defaults delete com.sonny.MacAgent com.sonny.state.firstRunFinished
  defaults delete com.sonny.MacAgent com.sonny.state.firstRunSkippedSteps
  ```
  Either line prints *"does not exist"* when the key was never written; that is not an error.
- **(c) Revoke the two grants**:
  ```bash
  tccutil reset ScreenCapture com.sonny.MacAgent
  tccutil reset Accessibility com.sonny.MacAgent
  ```
- **(d) Relaunch the packaged app.** `./scripts/package-app.sh`, then open the bundle. **Not
  `swift run`** — it writes to a different `defaults` domain and has no bundle identity for the
  permission prompts this sequence drives.

Each row below says **Full reset** (all four) or names the subset it needs. Where a row leaves the
Mac in a state the next one wants, that is said too, so the section runs top to bottom.

**One row needs a live sign-in and waits; the rest run today.** The headline check — sign in, grant
Screen Recording, relaunch, come back **signed in** at the next step — needs a real account, which
is **SONNY-280's founder-deferral comment of 2026-08-27 and its numbered resume checklist, steps
(1) through (5)**, plus the sign-in section's own setup above. Every other row is runnable now,
**including the relaunch-and-resume mechanic itself**: declining the sign-in step reaches the same
relaunch on the same sequence, so only the signed-in half is owed.

- [ ] **(new 2026-08-28, SONNY-137) — the clean-machine row. Full reset.** Launch. The sequence must
      open on **sign in** — not on an empty Command Center, and not on the screen-access dialog.
      Nothing anywhere in it may show a raw error, a status code, a URL or a variable name.
      **Then press Escape.** The screen-access step must appear; the sheet must **not** simply
      vanish, and it must not flicker away and leave first run gone for the rest of this launch.
      (Escape routes through the sheet's own dismissal, which is a different path from the dialog's
      close X, and it is the one path no test in this repository can predict.) Leave the app here for
      the next row.
- [ ] **(new 2026-08-28, SONNY-137) — the resume mechanic, runnable today without an account.**
      Continuing from the row above, you are on the screen-access step. Press **Request access**
      under Screen Recording, switch Sonny on in System Settings, and use the dialog's **Relaunch
      Sonny** button. When the app comes back it must open **on the screen-access step with Screen
      Recording showing Granted** — not on sign-in, and not on nothing. That is "comes back at the
      right step"; the row below is the same journey with an account.
      **While that sequence is on screen, type something into the floating widget and run it** (a
      calculation will do). It must work: the sequence is a sheet on Command Center and is not
      meant to block the widget.
      **Then look at the composed sheet before dismissing it.** It is a bordered rounded card with a
      button bar under it, and the two steps have different fixed sizes, so the sheet resizes between
      them. That is *unpolished by design* — SONNY-109 owns how it looks — but say so if it reads as
      **broken** rather than plain, because that distinction is worth having before SONNY-109 rather
      than after.
      **This row leaves Screen Recording granted.** The next row starts with a full reset.
- [ ] **(new 2026-08-28, SONNY-137) — the headline row, and it waits on SONNY-280's resume steps
      (1)–(5)** plus the sign-in section's setup. **Full reset**, launch, and **sign in for real** on
      the first step. The sequence must move to screen access by itself. Grant Screen Recording,
      relaunch from the dialog, and confirm two things when the app comes back: you are **still
      signed in** (bottom-left account row reads *Account* with your address), and you are back **on
      the screen-access step**. A user who signs in, grants a permission and finds themselves signed
      out has hit the worst bug this row can ship, on their first run.
- [ ] **(new 2026-08-28, SONNY-137) — declining everything. Full reset**, then launch and decline
      **both** steps: **Sign in later**, then **Set up later in Settings**. (The full reset is what
      makes the sign-in step appear at all — after the row above you are signed in, and a satisfied
      step is never shown.) Confirm Sonny is usable rather than stuck: run something in the widget
      that needs neither the backend nor a screen grant. Then confirm the stated way to finish is
      really there — Settings → Security & Access → Screen access → **Set up** opens the same dialog,
      and the bottom-left account row still offers **Sign in**.
- [ ] **(new 2026-08-28, SONNY-137) — resuming mid-sequence.** **Reset (b) only** — the two
      `defaults delete` lines — then launch and quit while the sequence is on screen, without
      pressing anything. Reopen. It must come back on the **same step** rather than starting over or
      skipping ahead. (Only (b) is needed: the previous row left you signed out and ungranted, so
      both steps are still outstanding.)
- [ ] **(new 2026-08-28, SONNY-137) — it runs once.** Continuing from the row above, decline both
      steps to reach the end. Quit and reopen **twice**: it must not run again either time. **That
      half runs today.**
      **The sign-out half waits on SONNY-280's resume steps (1)–(5), for the same reason the headline
      row does** — being signed in at all needs a real account, so "sign out and reopen, and confirm
      it still does not run" cannot be reached until then. Run it in the same sitting as the headline
      row: finish that row, then quit, reopen, sign out, and reopen again. It must still not run,
      because signing out is not a new first run — which is the one thing that tells a persisted flag
      apart from a state derived from whether you are signed in.
      (An earlier version of this row said the sign-out half was "already covered by the row above"
      and could be skipped. It is not covered by any row above, and it is not optional: no row before
      it signs out, and the row it credited — resuming mid-sequence — never signs in. PR #159's
      cycle-2 review.)
- [ ] **(new 2026-08-28, SONNY-137) — one model behind both doors. Reset (b) and (c)**, launch, and
      get to the screen-access step (decline sign-in if it appears). Press **Request access** under
      Screen Recording, then close the sequence and open Settings → Security & Access → Screen
      access. The relaunch guidance must be there too — it is the same model behind both doors, and
      a second one would tell you a relaunch is owed in one place and not the other.
- [ ] **(new 2026-08-28, SONNY-137) — if feasible.** A genuinely clean macOS user account. That is
      the only true clean-machine test, and it is a rehearsal rather than the real thing until
      notarization (row 20, SONNY-108): the first genuinely clean first run by someone who is not a
      founder happens after that, close to launch.

#### The relaunch that cannot come back (new 2026-08-30, SONNY-348)

**What changed:** pressing **Relaunch Sonny** used to quit this app whatever happened to the new one.
If the new instance could not start, Sonny was simply gone — no window, no menu bar icon, nothing to
say why, on a Mac where you had just granted it a screen-recording permission. It now quits only
after the reopen has actually worked, and says **"Couldn't restart Sonny."** under the button when it
has not.

**Forcing the failure needs no special build**: rename the bundle out from under the running app.
macOS keeps the running process alive, and `open` then has nothing at that path to reopen.

**Note added 2026-08-31 (SONNY-379):** the code behind these two rows was rewired — `DefaultAppRelauncher` is handed its bundle, its reopen and its terminate rather than naming them
itself — with no change to what either row should do, so they are that ticket's manual test unchanged.
The second half of the first row (rename the bundle back, press again, and the app actually restarts) is
the part that proves the shipping app got the real wiring rather than a test double: nothing automated in
this repository can run `/usr/bin/open` or `NSApp.terminate`, so a founder pressing the button is the only
check there is.

- [ ] **(new 2026-08-30, SONNY-348) — the failed reopen. Reset (b) and (c)**, launch the packaged
      app, and get to the screen-access step (decline sign-in if it appears). Press **Request access**
      under Screen Recording so the relaunch guidance appears. **Leave Sonny running** and, in a
      terminal, rename the bundle:
      ```bash
      mv .build/arm64-apple-macosx/debug/MacAgent.app .build/arm64-apple-macosx/debug/MacAgent-moved.app
      ```
      Now press **Relaunch Sonny**. Sonny must **stay running** — same window, same menu bar icon —
      with **"Couldn't restart Sonny."** under the button, and nothing else: no second Sonny, no
      error code, no URL, no advice about what to do next. Then rename the bundle back
      (`mv ... MacAgent-moved.app ... MacAgent.app`) and press **Relaunch Sonny** again: the message
      must clear, and this time the app must actually restart.
- [ ] **(new 2026-08-30, SONNY-348) — the same control behind the other door.** Repeat the row above
      from **Settings → Security & Access → Screen access** rather than from first run. It is one
      model behind both doors, so the failure must read the same in both.

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
`d5020b0`): the six gateway ones that section lists, plus `OPENAI_API_KEY`, `TAVILY_API_KEY`,
`VISION_API_KEY`, `ANTHROPIC_API_KEY` and `CEREBRAS_API_KEY`. Export whichever ones a section names
*before* that command, and nowhere else.

**2. The debug build pointed at it.** `defaults write com.sonny.MacAgent SonnyBackendBaseURL
http://127.0.0.1:8080`, as that section describes, with the dialog's debug line as the confirmation.

**3. The packaged app launched from Finder, with no provider key exported in any shell it was
launched from.** A Finder launch inherits no shell environment, which is the whole point: a row that
passes only because a key happened to be exported has proved nothing.

**SONNY-307 landed, so nothing below blocks on it.** `src/server.ts` supplies `AuthDeps` now — PR
#137, `554d85a` (`git merge-base --is-ancestor 554d85a origin/main` exits 0) — and the container's
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
(`ls server/src/db/migrations/*.sql | wc -l` → 12 at `d5020b0`), and `0011` and `0012` were both
authored after the deferral comment
(`git log --diff-filter=A --format='%ad' --date=iso -- 'server/src/db/migrations/001[12]*.sql'` →
two lines, `2026-08-27 22:06:51 -0400` and `2026-08-27 18:11:32 -0400`, against a deferral comment
written at `2026-08-27T21:39:52Z`, which is 17:39 -0400 — both after it). Sign-in reaches Postgres
before it calls Supabase, so a project missing them is a 500 that looks nothing like a missing
migration.

**None of this was established by running it, and that is deliberate.** The credentials are the
founders' and the sign-in happens in the app, which no agent tests; what is above is the tree as it
stands at `d5020b0` plus what SONNY-280's deferral recorded. **Resume step (4) is where a founder
finds out** whether steps (1) to (3) actually landed — export the real names, run the one command,
read the `auth routes are mounted` line.

**What can be run before that resume**, so these sections are not one flat wall:

- **SONNY-132's `model routing` row.** That line is printed at startup by every container, signed in
  or not (`server/src/app.ts:343` at `d5020b0`), so it needs step 1 and nothing else.
- **SONNY-130's three-minute recording row.** The refusal is the Mac's, checked before the file is
  even read (`Sources/MacAgentCore/OpenAITranscriber.swift:155` at `d5020b0`) — no container, no
  sign-in.
- **SONNY-130's signed-out row.** A build that has never signed in is in the same state as one that
  signed out: with no tokens stored the request is refused before it is sent
  (`Sources/MacAgentCore/SonnyBackendClient.swift:436` at `d5020b0`), which is the sentence that row
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
  pass and it finished on 2026-08-25, 27 of 27 items at `dd4ebae`. An earlier draft of this section
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

**One thing this branch deliberately did not build — and SONNY-333 has since built it (2026-09-03).**
When these rows were written the app's own delete button deleted only the Mac's copy, because
SONNY-134 was scoped server-only for parallel-lane disjointness (`docs/sonny-row-12-plan.md` §8.2),
so the headline row below called the endpoint with `curl`. It no longer has to: Sonny's own Delete
now reaches the server. **The row keeps the `curl` as its fallback and presses the button first** —
see the dated amendment inside it — and the app-driven rows of their own are in *Delete a task and
the server's copy goes with it* (SONNY-333), near the end of this section.

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
      that task's server copy. **Amended 2026-09-03 (SONNY-333): press the app's own Delete first.**
      In Command Center &rsaquo; Tasks, right-click that task and choose *Delete task*, confirm, and
      wait a few seconds. Then re-run the account report: `content` must be back to **0 call(s)
      retained**, and `npm run support -- deletions` must show a `task` row naming that task. If it
      does not, fall back to the original form of this row —
      `curl -X DELETE -H "Authorization: Bearer <an access token>"
      http://localhost:8080/v1/tasks/<task id>`, which must answer `200` with `requests_deleted` at
      least 1 — and **tell us that the button did not do it**, because that is the finding rather
      than the `curl` succeeding. **What would also be a finding:** a `404` from the `curl`, a
      `requests_deleted` of 0 for a task you just ran, or content still showing after either.

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

### No environment variable is required for anything (new 2026-08-28, SONNY-136)

**This is SONNY-106 section E's condition, and it is the one section here whose first half needs no
gateway, no sign-in and no host.** Every provider credential and model name is gone from the app;
what is left is a build that either has a Sonny account or does not. The rows are split accordingly,
because a section that put all of them behind the shared setup note above would hide the half that
can be checked today.

**Setup for the rows that run now: none at all, and that is the check.** Open a *fresh* terminal,
export nothing, run `./scripts/package-app.sh`, then launch the bundle by **double-clicking it in
Finder**. A Finder launch inherits no shell environment, which is exactly the condition every user
who is not a founder in a terminal is in.

**What a command that needs the backend says today, so it is not reported as a defect.** No
production host exists yet — `SonnyBackendHost.productionBaseURL` is `nil` until SONNY-192 chooses
one — so a build with no `defaults write com.sonny.MacAgent SonnyBackendBaseURL` pointing at a local
gateway fails every backend call before it builds a URL, with *"This build has no Sonny account
service."* That is the honest sentence for that state, not an outage.

#### Runs today

- [ ] **(new 2026-08-28, SONNY-136) — the headline check.** With the app launched from Finder out of
      a shell that exported nothing, run each of these and confirm every one completes: `calc 2 + 2 *
      3`; a saved routine by name (`run routine <name>`); a saved workspace (`open workspace
      <name>`); `snippet save addr = 221B Baker Street` and then `addr` on its own; `clipboard
      history`. **None of these should touch the network at all.** This is the guarantee spec §16.3
      makes and one of the three recorded reasons the agent loop stayed on the Mac.
- [ ] **(new 2026-08-28, SONNY-136)** Turn **wifi off** and repeat the five above. Same answers. Then
      type an ordinary command ("open Safari") and read what it says: it must be one human sentence
      with no status code, no URL, no provider name and no variable name. On a build with no backend
      pointer set that sentence is *"This build has no Sonny account service."*
- [ ] **(new 2026-08-28, SONNY-136)** Open **Settings → Permission Readiness**. There must be **no
      "OpenAI" row at all**, and no row anywhere on the page telling you to export or set anything.
      The first row is **Sonny account**; signed out it reads *"Sign in to Sonny in Command
      Center."* and shows **Needs action**. Press **Refresh** and confirm it settles rather than
      flickering between states.
- [ ] **(new 2026-08-28, SONNY-136)** Press the **mic** in the widget, and hold the push-to-talk
      hotkey, on this same Finder-launched build. Neither may refuse with anything about a key —
      *"No API key is set up. Add one, then relaunch Sonny."* is deleted, and a refusal quoting it
      means something reintroduced the constant. (Whether the transcription then succeeds is the
      gateway's row below.)

#### Waits on SONNY-280's resume (a local gateway and a real sign-in)

- [ ] **(new 2026-08-28, SONNY-136)** Signed in, with the local gateway up: **Settings → Permission
      Readiness** shows the Sonny account row as **Ready**. Its sentence is *"Signed in, and your
      plan is confirmed."* since SONNY-336 — it read *"Signed in."* when this row was written, and
      the row now reports the plan as well as the session. Sign out and press
      Refresh: it returns to **Needs action**. This is the row that replaced the one reporting on a
      credential nothing reads.
- [ ] **(new 2026-08-28, SONNY-136)** Signed in, gateway up, then **stop the container** (`docker
      stop` the deploy, or `Ctrl-C` it) and run a typed command. It must say *"Sonny couldn't finish
      this one. Try again."* — and the readiness row must **stay Ready**, because a dead backend has
      not signed you out. A row that flips to Needs action here is a defect.
- [ ] **(new 2026-08-28, SONNY-136)** Signed in, gateway up, wifi **off**, and the backend pointer
      pointing at something that is not `127.0.0.1`: a typed command must say *"You're offline.
      Everything Sonny does on this Mac still works."* — and then the five local commands in the
      first row must actually still work, which is what makes that sentence true rather than a
      slogan. (A pointer at `localhost` cannot produce this row: loopback survives wifi being off.)
- [ ] **(new 2026-08-28, SONNY-136)** Sign **out**, then run a typed command: *"Sign in to Sonny to
      run this."* Then run `calc 2 + 2` while still signed out — it must complete. Being signed out
      takes the model routes away and nothing else.
- [ ] **(new 2026-08-28, SONNY-136)** Start a **screen-control session** and let it run several
      steps. It should finish normally. There is nothing to see here when it works — the row exists
      because a token expiring between iterations is invisible by design, and the failure mode it
      would replace is a session that dies partway with *"…It stopped after N steps in <app>."*

#### Waits on a real host (SONNY-192)

- [ ] **(new 2026-08-28, SONNY-136)** With the backend deliberately down on the first real deployed
      environment, walk every surface that can raise a failure — a typed command, a voice command, a
      web-research command, a screen-control session — and confirm each says something true and human
      rather than a status code. This is the row the ticket's own manual list asks for and the only
      one that cannot be approximated locally.

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

### A short article about a wall is served (new 2026-09-05, SONNY-256)

Sonny used to refuse to read a *short* page that merely mentioned a paywall or a CAPTCHA, as though
the page were guarded by one. The two pages below are the ticket's own worked example: the same
blog, the same template, the same subject, and before this change they got opposite answers 1 000
characters apart. **Both should now be summarized normally.** Each command is one direct-URL
summarization, the shape row 2013's last item already describes, so nothing new has to be learned
to run them.

- [ ] **(SONNY-256)** **The short post is read.** Run **"summarize
      https://simonwillison.net/2006/Dec/19/botbouncer/ and save it as Markdown"**. It is an
      ordinary link-blog post whose one sentence about the subject reads "Neat concept: a third
      party service for ensuring that an OpenID has passed a CAPTCHA." **Expected:** a real note,
      naming that URL as its source. **What would be a finding:** the refusal **"Sonny will not
      bypass CAPTCHAs."**, which is exactly what this page used to get and the whole reason for the
      ticket.
- [ ] **(SONNY-256)** **The longer post on the same blog still reads, so nothing was traded away.**
      Run **"summarize https://simonwillison.net/2026/Jun/16/captcha-on-at-least-one-ampersand/ and
      save it as Markdown"**. This one was already served before the change; it is here as the
      control. **Expected:** a real note. **What would be a finding:** any refusal at all, which
      would mean the fix broke a page that used to work.
- [ ] **(SONNY-256)** **A real wall is still refused — please do try to break this one.** Ask Sonny
      to summarize a page you know is gated, ideally one that shows a "confirm you are human" or
      "are you a robot" challenge rather than a sign-in form. **Expected:** Sonny declines and names
      the wall, exactly as before. **What would be a finding, and it is the important one on this
      page:** Sonny producing a note whose content is the wall's own message — "Please confirm you
      are a human", a reference number, an IP address. That would mean the check stopped firing
      where it should, which is the error this change was careful not to make and is worth more to
      us than the two rows above.

### A short page that quotes a login wall or a paywall is served (new 2026-09-07, SONNY-429)

SONNY-256 stopped Sonny refusing a short page that merely *mentions* a CAPTCHA. The same defect
survived on the login and paywall side: a short page **quoting** a gate's own sentence — "sign in
to continue", "subscribe to continue reading" — was still refused as though the page were the gate.
Measured over 425 pages, 56 innocent pages stop being refused and none that was served becomes
refused. All four rows below are one direct-URL summarization each.

- [ ] **(SONNY-429)** **A comment page quoting a login wall is read.** Run **"summarize
      https://news.ycombinator.com/item?id=42644950 and save it as Markdown"**. Its top comment reads
      `"Sign in to continue" - as you are new to HN I can tell you that is a big stopper right
      there.` and it has one reply. **Expected:** a real note, naming that URL as its source. **What would be
      a finding:** the refusal **"Sonny will not bypass login walls."**, which is what this page got
      before the change. **If you get an HTTP error instead, that is not a finding** — Hacker News
      rate-limits uncached item pages and answered 403 to Sonny on 2026-09-07, while its front page
      and `item?id=1` answered 200. `PublicWebPageLoader` refuses on the status before the detector
      runs, so a 403 tells you nothing either way about this change. Try again later, or skip to the
      Google row below, which answers reliably.
- [ ] **(SONNY-429)** **A comment page quoting a paywall is read.** Run **"summarize
      https://news.ycombinator.com/item?id=22224690 and save it as Markdown"**. Its top comment opens
      `"You are in private mode. Subscribe to continue reading."` and then complains about it; it has
      two replies.
      **Expected:** a real note. **What would be a finding:** **"Sonny will not bypass paywalls."**
      **An HTTP error is not a finding**, for the reason on the row above.
- [ ] **(SONNY-429)** **A real login wall or paywall is still refused — this is the row worth most.**
      Ask Sonny to summarize a page you know is gated behind a sign-in or a subscription. **Expected:**
      either Sonny declines and names the wall, or it reports that it could not find anything readable
      on the page. **What would be a finding, and it is the important one:** a note whose *content* is
      the gate's own message — "Please log in to continue", "Subscribe to continue reading", a sign-up
      form's labels. This change knowingly gives up refusing a gate in the 200-to-2 000 visible-character
      band whose only wording is one of those three. **One such page is known and named in the row
      below** — the record used to say none had been found, and PR #222's reviewer found one.
- [ ] **(SONNY-429)** **The accepted cost, on a page that answers reliably — this is the one to judge
      the trade on.** Run **"summarize https://accounts.google.com/signin/v2/identifier?service=mail
      and save it as Markdown"**. This is Google's account sign-in interstitial: HTTP 200, 843 visible
      characters, and its visible text opens `Sign in to continue to Gmail`. It is the exact shape this
      change gives up, it is reachable (Sonny's robots check allows it), and it is one of the most
      common login walls on the web. **Expected:** Sonny reports it could not find anything readable
      on the page — the extractor throws on all four of Google's sign-in hostnames, so no summary of
      the sign-in form is produced. **Before this change you would have got "Sonny will not bypass
      login walls.", which is the better message, and losing it is the cost.** **What would be a
      finding:** an actual summary — the email field, the "Forgot email?" link, the language picker —
      which would mean Sonny is describing a login form to you as though it were content. **If you
      would rather keep the old refusal than accept this, say so: this row is where that veto lands.**

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

### Is this user allowed, and have they used more than they are allowed (new 2026-08-28, SONNY-135)

**What changed:** the gateway now signs an entitlement claim the Mac verifies **locally, with no
network call**, and enforces a per-account rate limit and a per-account spend cap before any provider
is called. Nothing is gated yet — which capability keys gate which features is row 18's (SONNY-23) —
so what these rows check is the machinery and the two directions it must fail in.

**The first row is the headline and it needs nothing set up.** The other three need a signed-in
session and a container, and therefore queue behind the same deferred identity sitting the metering
rows above name: **SONNY-280's founder-deferral comment of 2026-08-27 and its numbered resume
checklist, steps (1) through (5)**. The three blockers that section lists — the project's JWT key
mode, the locked Magic Link template, and `deploy.sh local` never having run with real credentials —
block these rows identically, and for the same reason: every metered route is authenticated.

**Setup for the last three, once that resume has run.** The metering section's container setup, plus
three new variables the container now requires wherever sign-in is mounted — a gateway given the
Supabase names and not these **exits 78 naming them**, which is the intended failure and not a
regression:

```
export ENTITLEMENT_SIGNING_KEY="$(openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\n')"
export ENTITLEMENT_SIGNING_KEY_ID=sonny-dev-1
export SPEND_CAP_UNITS=3          # deliberately tiny, so the cap is reachable by hand
./scripts/deploy.sh local
cd server && npm run build && npm run entitlements -- public-key   # prints "sonny-dev-1  <key>"
```

Then point the app at that container and hand it the public key, both of which are debug-only and
exist in no build a user runs:

```
defaults write com.sonny.MacAgent SonnyBackendBaseURL http://127.0.0.1:8080
defaults write com.sonny.MacAgent SonnyEntitlementPublicKeys "sonny-dev-1:<the key printed above>"
```

- [ ] **(new 2026-08-28, SONNY-135) — the headline row, and it needs no server, no sign-in and no
      network at all.** In the packaged app, turn Wi-Fi **off**. Then run, in the widget: a
      calculation (`calc 12 * 9`), a saved snippet by its trigger, a saved routine (`run <name>`),
      and a saved workspace (`open <name>`). **All four must work exactly as they do online.** This
      is the guarantee the whole row-12 architecture leans on — free local capabilities never consult
      an entitlement, so there is nothing for a missing network to fail closed on — and a refusal, a
      hang, or a message about a plan or a connection on any of the four is the finding. Do it signed
      out as well as signed in; the answer must be identical.
- [ ] **(new 2026-08-28, SONNY-135) — after SONNY-280's resume steps (1)–(5).** With the container
      running and the app signed in, run three commands that reach the backend (any planning command
      will do). The third must be refused, because `SPEND_CAP_UNITS=3` and each call spends one unit.
      **Read the message the app shows**: it must say *"You're out of allowance for this period."* —
      a sentence, not a raw error, not a status code, and not an invitation to try again. Then run
      `npm run entitlements -- show <account-id>` and confirm it reports 3 spent of 3. What would be
      a finding: a fourth call succeeding, a raw error string, or a message telling the user to wait.
- [ ] **(new 2026-08-28, SONNY-135) — after the row above, and it is the offline half of it.** With
      the cap still exhausted, turn Wi-Fi off and repeat the four local commands from the headline
      row. They must all still work: the cap bounds what goes to the backend and touches nothing
      local. Then, still offline, run a command that needs the backend — it must fail with *"You're
      offline. Everything Sonny does on this Mac still works."* rather than with an allowance
      message, because being offline and being out of allowance are different states and the app
      must not confuse them.
- [ ] **(new 2026-09-04, SONNY-405; row rewritten 2026-09-04 after PR #201's F1) — billing's names
      reach the container, and this row runs before the three below it.** Until this ticket
      `./scripts/deploy.sh local` forwarded none of billing's seven variables, so the rows below
      started a container with no `POST /v1/billing/webhook` at all and the provider's delivery got a
      404. **Check the container's environment, not a route** — the reason is the next row's note.
      Run `cd server && ./scripts/deploy.sh local` twice from the same terminal.

      **First with no `BILLING_` variable exported at all.** The `not set here, so not forwarded:`
      line must name all five of `BILLING_PROVIDER`, `BILLING_WEBHOOK_SECRET`,
      `BILLING_CHECKOUT_URL`, `BILLING_PROVIDER_ACCESS_TOKEN` and `BILLING_PLANS`; the run must end
      `==> ok — serving <build>` — a deployment that takes no payments is a supported one and must
      start — and:

      ```
      docker inspect sonny-gateway-local --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -c '^BILLING_'
      ```

      must answer **0**. **Then export the five and run it again**, values of your own, no provider
      account needed:

      ```
      export BILLING_PROVIDER=polar
      export BILLING_WEBHOOK_SECRET='not a real secret'
      export BILLING_CHECKOUT_URL=https://buy.example.test/checkout/x
      export BILLING_PROVIDER_ACCESS_TOKEN='not a real token'
      export BILLING_PLANS=prod_x=paid:screen_control
      ./scripts/deploy.sh local
      ```

      None of the five may appear on the `not set here` line now, the run must end
      `==> ok — serving <build>`, and the same `docker inspect` must answer **5** — and print the
      five names, which is worth reading rather than trusting the count. **Anything but 5 on the
      second run is the finding**, and it means the names did not travel. (`grep -c` answering 0 and
      then 5 with nothing else changed is what makes the 5 a measurement; both were run on 2026-09-04
      against a container started with `deploy.sh`'s own `-e NAME` form.)
- [ ] **(new 2026-09-04, SONNY-405; added after PR #201's F1) — why the row above reads the
      environment and not the webhook route, which is worth knowing before you debug a 404 here.**
      Nothing to run; read it. `registerBillingRoutes` is gated on `billing && billingStore`, and
      `billingStore` exists only when `auth` does — which needs the three `SUPABASE_` names,
      `DATABASE_URL` and `RATE_LIMIT_SALT`. So **a container given all five billing names and no auth
      names answers 404 on `POST /v1/billing/webhook` even when the passthrough is working
      perfectly.** Measured on the built gateway on 2026-09-04: five billing names only → health `ok`
      and webhook **404**; the identical five plus the auth prerequisites this section's setup block
      already lists → webhook **401**. So a 404 here means "auth is not wired", and `deploy.sh`
      prints that on its own line — `==> auth routes are NOT mounted`. If you want the route check as
      well as the environment check, run it only with the section's container setup live, and read
      that line first.
- [ ] **(new 2026-09-04, SONNY-405) — a half-configured billing container says which name is
      missing, before you go looking.** From the row above, `unset BILLING_WEBHOOK_SECRET` and run
      `./scripts/deploy.sh local` again. Two things must happen and the first is the point of putting
      these names on the credential array: `BILLING_WEBHOOK_SECRET` appears on the
      `not set here, so not forwarded:` line **before the container starts**, and then the container
      refuses to come up — `verify` fails and dumps `docker logs`, which must carry a startup error
      naming `BILLING_WEBHOOK_SECRET`. **A container that comes up healthy here is the finding**: it
      would mean a gateway serving a webhook endpoint with no secret, which refuses every real
      delivery and looks exactly like an outage. Re-export the secret before running the rows below.
- [ ] **(new 2026-08-30, SONNY-211) — the end-to-end subscription, and it is the founders' row that
      nothing else can stand in for.** In the Polar dashboard, create the product, create a webhook
      endpoint pointing at the gateway's `POST /v1/billing/webhook`, and copy its signing secret.
      Start the gateway with `BILLING_PROVIDER=polar`, that secret in `BILLING_WEBHOOK_SECRET`, the
      product's hosted checkout link in `BILLING_CHECKOUT_URL`, and
      `BILLING_PLANS=<product id>=paid:screen_control`. Then, signed in: call
      `POST /v1/billing/checkout`, open the URL it returns, and **complete a real test subscription**.
      Within seconds `npm run entitlements -- show <account-id>` must report the plan and the
      capability, and `SELECT event_type, outcome FROM sonny.billing_event` must show the delivery
      with outcome `applied`. **A `subscription.active` delivery landing as anything but `applied` is
      the finding**, and the outcome column says which of the five other things it was —
      `unmatched` most likely, which means the account id did not survive the round trip through the
      checkout link.
- [ ] **(new 2026-08-30, SONNY-211) — the cancellation half, immediately after the row above.** In
      the Polar dashboard, **cancel** the test subscription. `sonny.billing_event` gains a row; the
      entitlement's `revoked_at` is set; and the next `GET /v1/account/entitlements` the app makes
      returns a claim with **no capabilities** while still naming the plan. What would be a finding:
      the capability surviving, the row not arriving at all (which means the endpoint or its secret
      is wrong, not that the code is), or the account losing its plan key as well as its capability.
      **Note that Polar cancels in two steps** — clicking cancel usually keeps access to the end of
      the paid period and only later revokes it — so the *immediate* correct answer may be "nothing
      changed yet", and that is the behaviour, not a bug. The revocation follows when Polar says
      access has ended.
- [ ] **(new 2026-08-30, SONNY-211) — the plan-change question, and it is one action that settles a
      code decision.** Run it after the end-to-end row above, on the same live test subscription.
      **Before you change anything**, record the current subscription id:
      `SELECT billing_subscription_id FROM sonny.entitlement WHERE account_id = '<account-id>';`
      — write the value down verbatim. Then, in the Polar dashboard, **change that subscription's
      plan** (switch it to a different product or price; create a second product first if there is
      only one). Wait a few seconds, then run the same `SELECT` again and also
      `SELECT event_type, outcome FROM sonny.billing_event ORDER BY received_at;`.

      **The whole question is whether the two subscription ids are the same string.** It is not a
      judgement about whether things "look right" — copy both ids and compare them character by
      character.

      - **Same id** → the provider modifies the subscription in place. Record that. It means the
        out-of-order plan-change regression recorded on this branch is **unreachable**, and the
        finding closes with no code change. Expect the new delivery's `outcome` to be `applied`.
      - **Different id** → the provider cancels and creates. Record that too. **The two ids are the
        whole answer, and this one means the regression is reachable — whatever else you see in the
        same run.** The fix is then code rather than a note: the refusal has to tell "a foreign
        subscription while mine is live" from "the replacement for mine".

        **Two things this can look like, and both are normal.** Which one you get depends only on the
        order the two webhook deliveries happened to arrive in, which nobody controls:

        - `billing_event` shows a **`conflict`** row and the entitlement is **wrong** afterwards
          (no capabilities). The new subscription arrived before the old one's cancellation. This is
          the regression happening in front of you, and **wrong is the *expected* result in this
          branch — do not file it as a new bug.**
        - `billing_event` shows **only `applied`** rows and the entitlement is **correct**. The two
          deliveries happened to arrive in order. This is **equally** a cancel-and-create and equally
          means "different id": it does **not** mean the regression is absent, only that this run did
          not hit the ordering that triggers it.

        So a working entitlement here is not a passing result and not a mis-run — record "different
        id" either way, and note which of the two you saw.

      **Report the two ids and the `outcome` column either way**, including when nothing looks
      broken: "same id, outcome applied" is the answer that closes the finding, and it is only an
      answer if somebody writes it down. If no new `billing_event` row appears at all within a
      minute, that is its own finding — the webhook endpoint is not subscribed to the event type the
      plan change produces.
- [ ] **(new 2026-09-04, SONNY-408; precondition corrected 2026-09-04 after PR #201's F2) — the
      command that tells somebody about a charge nobody can account for, run against a database with
      nothing wrong in it.** With a container and a `DATABASE_URL` (the same one the `test:db` block
      in `server/README.md` sets up is fine), **empty the two tables first** — this row said "with
      nothing wrong in it" and did not make it so, and `npm run test:db` leaves rows behind, because
      each database test truncates in `beforeEach` and nothing truncates after the last one, so
      whatever the final test planted survives the run:

      ```
      psql "$DATABASE_URL" -c "DELETE FROM sonny.credit_topup; DELETE FROM sonny.billing_event;"
      cd server && npm run build && npm run billing-debts
      echo $?
      ```

      (`psql` is not on a stock Mac; the `docker exec` form is in the row below and works the same.)
      `echo $?` goes **on its own line with nothing between it and the command**. It must print
      `no unresolved billing debt` and exit **0**. Do this before the row below, so that the non-zero
      exit there means something: a command that exits 1 on everything is not a signal. **What a test
      run leaves in those two tables is not empty and is not stable**, which is why the delete is the
      fix rather than "run it on a fresh database": measured on 2026-09-04 at this head,
      `npx vitest run test/billing-debts.db.test.ts` alone leaves exactly one `unconfirmed` top-up
      (`order-1`) and one `unmatched` delivery (`evt-1`), on which this row answers a full report and
      exit 1 — while a whole `npm run test:db` happened to leave both tables empty, because a later
      file's `beforeEach` truncated them. Which of the two you get depends on the run order, so the
      row makes the state rather than assuming it.
- [ ] **(new 2026-09-04, SONNY-408) — and it exits non-zero when there is something to say, with the
      order id you would go and look up.** Plant one row of each kind by hand, against the same
      database. (**If `psql` is not installed** — it is not on a stock Mac — reach it through the
      container instead: `docker exec -e PGPASSWORD=postgres "sonny-gw-db-$LANE" psql -U postgres -c
      "<the same SQL>"`. Both were run this way on 2026-09-04 and the SQL below is verbatim what
      worked.)

      ```
      psql "$DATABASE_URL" -c "INSERT INTO sonny.credit_topup (account_id, provider, provider_order_id, period_start, attempt_no, outcome, consented_at, runs_left_at_trigger, credits_remaining_at_trigger) VALUES (gen_random_uuid(), 'polar', 'order-planted-1', date_trunc('month', now()), 1, 'unconfirmed', now(), 0, 0);"
      psql "$DATABASE_URL" -c "INSERT INTO sonny.billing_event (provider, event_id, event_type, outcome) VALUES ('polar', 'evt-planted-1', 'subscription.active', 'unmatched');"
      npm run billing-debts
      ```

      The output must name `order-planted-1` and `evt-planted-1`, must mark the top-up
      **`resolvable`** rather than any `STRANDED` label (it is in the current period), and `echo $?`
      must print **1**. **A zero exit here is the finding** — it would mean a check built on this
      command passes while money is outstanding. With `BILLING_PROVIDER` unset the report also prints
      a paragraph saying the provider half of the classification could not be checked; that is the
      command being honest about what it did not do, not a finding. Then delete the two planted rows.
- [ ] **(new 2026-09-04, SONNY-408) — the boundary case, which is the one nothing will ever fix on
      its own.** Plant the same top-up row again with `period_start` set to the **previous** month —
      change `date_trunc('month', now())` to `date_trunc('month', now() - interval '1 month')` and use
      a new order id — and run `npm run billing-debts` again. That row must be marked
      **`STRANDED (period)`**, not `resolvable`, and the report must carry the paragraph explaining
      that the self-healing path looks only inside the account's current period so no future attempt
      will reach it. **A row from
      a past month reported as `resolvable` is the finding**: it would tell an operator to wait for
      something that is never coming. Delete the planted row afterwards.
- [ ] **(new 2026-08-31, SONNY-216) — the portal opens, and it opens for the right person.** Do this
      immediately after SONNY-211's end-to-end subscription row, on the same test account, with
      `BILLING_PROVIDER_ACCESS_TOKEN` set to an Organization Access Token carrying
      `customer_sessions:write` (Polar dashboard) and the app's entitlement key pointed at the
      gateway (`defaults write com.sonny.MacAgent SonnyEntitlementPublicKeys "<kid>:<key>"`, from
      `npm run entitlements -- public-key`). In the app: open **Account** from the bottom-left row of
      Command Center. The dialog must show a line reading `<plan> · Active` under the email address,
      and a **Manage subscription** button beside it. Press it. A browser opens Polar's customer
      portal **already signed in as that customer** — no email prompt, no one-time code. **The email
      prompt appearing is the finding**, and it means the pre-authenticated session was not used;
      that is the failure the whole design exists to avoid, because Sonny's identity key is never the
      email address and a Hide My Email user has no address to type.
- [ ] **(new 2026-09-05, SONNY-380) — a customer whose card was declined is told so, and the control
      changes with it.** **Needs a live Polar test subscription and a card that declines** — Polar's
      test mode publishes card numbers that fail on a renewal charge; this row cannot be run without
      one, and it is the only way to produce the state, because nothing in the app or the gateway
      sets it. Same setup and same account as SONNY-216's portal row above. With the subscription
      **active**, open **Account**: the line reads `<plan> · Active` and the button reads **Manage
      subscription**. Now make the renewal fail — swap the card on the Polar dashboard for a
      declining test card and trigger the renewal, or replay a `subscription.past_due` delivery for
      that subscription — so that the gateway records the failure (`SELECT past_due_since, grace_until
      FROM sonny.entitlement WHERE account_id = '<id>'` must show both set). Close Account and open
      it again. **The line must read `<plan> · Past due` and the button must read `Update payment`.**
      Press it: the same Polar portal opens, pre-authenticated, exactly as it does in the Active
      state. **The line still reading `Active` here is the finding** — that is the whole defect this
      ticket was filed for, and it is what a user saw for the entire fourteen-day window while their
      access quietly ran out. **Then, without closing the Account sheet, fix the card in the portal
      and switch back to Sonny.** The row re-reads by itself when the window comes back (founders'
      decision of 2026-09-05) — so within a moment the line should become `<Plan> · Active` with
      **Manage subscription**, without you closing and reopening Account. **Two things here are not
      findings.** If it still says `Past due`, wait a few seconds and switch away and back once
      more: the gateway only learns from Polar's webhook, and a return that beats the delivery
      honestly still reads past due. And it re-reads only after a press — switching back to Sonny
      with no press behind it must *not* change the line, which is what stops an open sheet asking
      the server on every app switch. **What is a finding is the line never changing at all**, even
      after the webhook has landed (check `past_due_since` is now NULL in `sonny.entitlement`), or
      changing without a press. Two things that are **not** findings: Sonny still works normally
      throughout, because §16.4 keeps the capabilities through the window on purpose; and there is no
      sentence anywhere explaining what "Past due" means or how long is left — the line is a state
      and a control by decision, and **an explanatory sentence appearing is itself a finding**.
- [ ] **(new 2026-09-05, SONNY-380) — what the line says with the network off, which is deliberately
      less than it says with it on.** With the account in the **past due** state from the row above
      and Account already opened once so the claim is cached, turn Wi-Fi off and reopen Account. The
      row must still render — the claim is local — and it will read `<plan> · Active` with **Manage
      subscription**, because payment state is a network read and this Mac cannot make one. That is
      the founders' decision of 2026-09-05 and is the expected result; **an error sentence under the
      row is the finding**, and so is the row vanishing. Turn Wi-Fi back on, close and reopen
      Account, and it must return to `Past due` / `Update payment`.
- [ ] **(new 2026-09-05, SONNY-380) — the state clears with the person.** In the past-due state,
      press **Sign out** and sign in as a different account that has never subscribed. The Account
      dialog must show **no subscription row at all** — no `Past due` line and no `Update payment`
      button, not even for a moment while the reads behind it complete. **Either one appearing, however
      briefly, is the finding**: it is the previous customer's billing state on a new person's screen.
- [ ] **(new 2026-08-31, SONNY-216) — the control is absent for someone who never paid, and this is
      the row that matters most.** Sign in on a **fresh** account that has never subscribed. Open
      Account. There must be **no subscription line and no Manage subscription button at all** — not
      a greyed-out one, not one that shows an error when pressed. **Any visible Manage control here
      is the finding.** The gateway also refuses this account with `409
      entitlement.no_subscription`, so a control that appears and then fails would look like it
      nearly worked; not offering it is the requirement.
- [ ] **(new 2026-08-31, SONNY-216) — what Polar answers for a customer it does not have, and it
      settles a mapping that was chosen without evidence.** With the gateway configured, call
      `POST /v1/billing/portal` **as the fresh never-subscribed account** from the row above and
      record **both the upstream status and the response body verbatim** — the body is now half the
      check (PR #183, F5) and the reason is the row below this one. The code treats **404 with a
      JSON-object body** as "no customer" and **everything else 4xx, including 422, as a provider
      refusal**. **If it is a 404 with a JSON body**, nothing changes and this row is discharged.
      **If it is 422**, the mapping must flip: `server/src/billing/polar.ts`'s `polarPortalSession`
      is where the branch lives, and `treats a 422 as a refusal rather than as a missing customer` in
      `server/test/billing.test.ts` is the test whose reasoning inverts with it. **If it is a 404
      whose body is not a JSON object**, the mapping is right and `looksLikeAMissingCustomer` needs
      widening to that shape. **The consequence of leaving it wrong is one-directional and that is
      why it was chosen this way**: an unknown id answered 422 today reports a loud fault to a user
      who has nothing to manage, which is harmless; the opposite mistake would tell a **paying
      subscriber** they have no subscription, which is a support incident that reads like data loss.
- [ ] **(new 2026-08-31, SONNY-216) — the 404 that is not about a customer, which is the direction
      the row above cannot reach.** The row above provokes an unknown customer against a *correctly
      configured* gateway, so it can only ever settle what Polar answers for a missing customer — it
      is blind to a 404 that arrives for any other reason, and that is the dangerous one (PR #183,
      F5). Set `BILLING_API_BASE_URL` to a valid https origin that is not Polar and answers a 404
      **with HTML or an empty body — not with a JSON object**. `https://example.com` is one that
      does; **do not use a JSON API**, because many answer `{"detail":"Not Found"}`, which
      `looksLikeAMissingCustomer` accepts by design, so the app would say "There's no subscription
      on this account." and that would be the code working correctly rather than the finding this
      row is looking for. **Record the body either way** — it is what tells a real pass from a
      coincidence. Restart the gateway and press **Manage subscription**
      as a **real paying subscriber**. The app must say **"Sonny couldn't open your billing page."**
      and the gateway must log `billing portal refused by provider` at `error`. **The finding is the
      app saying "There's no subscription on this account."** — that is a paying customer being told
      their subscription does not exist because an operator mistyped a hostname, and it is the exact
      outcome the 422 reasoning calls a support incident that reads like data loss. Note that
      `BILLING_API_BASE_URL` now refuses a non-https origin and one carrying a path, so use an https
      origin with no path.
- [ ] **(new 2026-09-02, SONNY-214) — how many screen-control runs the plan has left, beside the
      plan.** Same setup and same account as SONNY-216's portal row above; do it straight after that
      one, so the `<plan> · Active` line and the **Manage subscription** button are already on screen
      and confirmed. A third line sits with them: **`Screen Control`** on the left and
      **`N of M runs left this month`** on the right. N and M must match `screen_control_runs_left`
      and `screen_control_runs_included` from `curl .../v1/account/credits` for that account. Label
      and number only — **any sentence explaining what a run is, what draws on the allowance, or what
      happens at zero is the finding.** (It was built on Insights first; the founders moved it here
      on 2026-09-02 so that page stays free of quota metrics. Insights must show nothing of the kind
      — §7's Insights row is the check for that.)
- [ ] **(new 2026-09-02, SONNY-214) — the figure goes down when a run is spent.** Run one
      screen-control task to completion, then **close Account and reopen it** — the figure is fetched
      when the dialog appears, not on a timer. The number has dropped by what the session cost, and
      still agrees with the curl.
- [ ] **(new 2026-09-02, SONNY-214) — no figure rather than a wrong one.** With the gateway container
      stopped, open Account. **The `Screen Control` line is absent entirely** — no zero, no
      placeholder, no error sentence — while the rest of the dialog behaves exactly as SONNY-216's
      rows describe. A failed read renders nothing rather than a number nobody served.
- [ ] **(new 2026-09-02, SONNY-214) — one account's figure never reaches the next.** With Account
      open and the figure showing, **sign out from inside that dialog and do not navigate anywhere**.
      The `Screen Control` line must go at once, alongside the subscription line. Then **sign in as a
      second account from that same screen**: no figure from the first account may appear at any
      point, and once the dialog has read for the new one it shows *that* account's numbers. Check
      the widget too — start a screen-control task as the second user and the in-task line must show
      the second account's figure or none, never the first's. **This row is worded to keep you on the
      screen on purpose**: the obvious version ("sign out, then open Account") cannot fail, because
      opening the dialog is itself what fetches the figure, so it would read green over a live defect
      (PR #188's F1).
- [ ] **(new 2026-08-31, SONNY-216) — the access token rotates without taking the portal down.**
      Follow `server/README.md`'s three steps in order: create a **second** Organization Access Token
      in the Polar dashboard, redeploy the gateway with `BILLING_PROVIDER_ACCESS_TOKEN` set to it,
      and only then revoke the old one. Press **Manage subscription** after each step; the portal
      must open all three times. Then, deliberately, do it the wrong way round on a throwaway token —
      revoke before deploying — and confirm the symptom the runbook names: `POST /v1/billing/portal`
      answers **502 `provider.rejected`** and logs at `error`, while subscriptions, webhooks and
      entitlements all keep working. **That asymmetry is the whole point of the row**: nothing else
      breaks, so nobody watching a dashboard would notice, which is why the order is written down.
- [ ] **(new 2026-08-30, SONNY-211) — the refusal, and this one needs no Polar account.** With the
      gateway running and billing configured, `curl -X POST` the webhook path with any JSON body and
      no signature headers. It must answer **401**, and `SELECT count(*) FROM sonny.billing_event`
      must be **unchanged** — an unauthenticated caller must not be able to write a row into that
      table by posting at it. Repeat with a plausible-looking but wrong `webhook-signature` header:
      same answer. If either one returns 200, or if the row count moves, stop and report it before
      the gateway is ever deployed anywhere reachable.
- [ ] **(new 2026-08-28, SONNY-135) — the clock row, and it is the one most likely to surprise.**
      Signed in, with the container running, open System Settings → General → Date & Time, turn off
      "Set time and date automatically", and move the Mac's clock **forward one day**. Then use the
      app normally for a minute: local commands, one backend command. **Nothing should change** — the
      claim is honoured for three days past its own expiry, so a day forward is well inside that.
      Then move the clock **back one week** and try again: local commands must still work, and the
      app must not start behaving as though a lapsed plan had become current again. Set the clock
      back to automatic afterwards. Anything that reads as a crash, a hang, or a sudden loss of a
      capability that was working is the finding.
      **The backward half is the one that changed** (2026-08-28, PR #152's review, F1): until that
      round the app judged expiry against a clock its owner could set, so rolling it back really did
      make a lapsed plan current again. It now remembers the latest time a server actually reported
      and carries it forward on a clock nothing on the Mac can move, so the rollback should do
      nothing at all. **Do this half offline** — with the container up, any request corrects the
      clock and there is nothing to see.

### How many screen-control runs are left this month (new 2026-08-31, SONNY-212)

**What changed:** the gateway now derives a per-account monthly allowance from row 12's metering and
serves it as `GET /v1/account/credits`. **Screen control is the only line that draws on it** —
everything else is free and uncapped against the pool, and watchers are free and *capped* by
SONNY-236's own cap rather than metered (founder decision, 2026-08-31). Nothing refuses on this
number yet (the gate is SONNY-213) and nothing renders it yet (the indicator is SONNY-214), so what
these rows check is that the figure the server derives is one a founder recognises.

**Every number is a release-time input and none of them is set.** That is the point of these rows
rather than a caveat on them: `CREDIT_PLANS` carries the tiers, the allowances, the credit weights
and what one run is worth, this repository supplies no default, and a gateway with auth mounted and
no `CREDIT_PLANS` **exits 78 naming it**. The values below are placeholders chosen so the arithmetic
is checkable by eye, not proposals.

**Setup.** The SONNY-135 section's container setup, plus one more variable, and it queues behind the
same deferred identity sitting that section names (SONNY-280's resume checklist, steps (1)–(5)):

```
export CREDIT_PLANS='{"runCredits":100,"defaultPlan":"free","weights":{"perSession":10,"perIteration":5,"perMegapixel":2},"plans":[{"key":"free","monthlyCredits":500},{"key":"pro","monthlyCredits":10000}]}'
./scripts/deploy.sh local
```

- [ ] **(SONNY-212)** With the container up and a signed-in session, ask it for the number before
      running anything: `curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/v1/account/credits`.
      **You get a 200 with `screen_control_runs_left` equal to `screen_control_runs_included`**, and
      `plan` reads `free` — an account nobody has provisioned is a free user, not a refusal.
- [ ] **(SONNY-212)** Run one real screen-control task, let it finish, and ask again. **The number
      has gone down**, and the `credits` block beside it explains by how much: `drawn` should be
      `10 + 5 x (iterations) + 2 x (megapixels sent)`. Compare `iterations` against what
      `npm run usage` prints for that session. **The finding is a `drawn` you cannot reconcile with
      the session `npm run usage` shows** — not a number you find surprising, which at these
      placeholder weights it will be.
- [ ] **(SONNY-212)** Run a *short* task and a *long* one and compare. **The long one costs more
      runs.** A twelve-step session and a two-step session must not cost the same; that is the whole
      of what "weighted by real cost" buys, and it is the property a later fixed-price-per-run change
      would silently remove.
- [ ] **(SONNY-212)** Ask Sonny to do something that is **not** screen control — a plan, a web
      research, a transcription — and ask again. **The number has not moved at all.** This is the
      one-paid-line decision, and it is the row most worth running twice.
- [ ] **(SONNY-212)** Put the account on the paid tier
      (`npm run entitlements -- grant <account-id> --plan pro`) and ask again. **The included figure
      jumps to the paid tier's** and runs-left rises with it — an upgrade takes effect immediately
      rather than next month.
- [ ] **(SONNY-212)** Now `npm run entitlements -- revoke <account-id>` and ask again. **The
      allowance falls back to the free tier's**, while the entitlement claim still reports `pro` as
      the plan. That split is deliberate: a cancelled subscription keeps its plan name so the app can
      say which plan ended, and does not keep its allowance.
- [ ] **(SONNY-212)** Restart the container with `CREDIT_PLANS` unset. **It exits 78 and names
      `CREDIT_PLANS`** in the message alongside anything else missing. A gateway that started and
      answered a run count from nothing would be the finding.
- [ ] **(SONNY-212)** Sanity-check the whole thing against a real cost, once `npm run usage` has
      sessions measured on the shipping capture path. **This is the row the ticket actually exists
      for**: pick numbers where one run is worth roughly what a session costs, and check that a
      month's allowance reads like a sensible month. The figures then go into `CREDIT_PLANS` on the
      real deployment and nowhere in the repository.
- [ ] **(SONNY-212)** **A choice to make while you are picking those numbers, not afterwards — two of
      the three weights are priced on figures the app declares about itself** (PR #182's review, F7).
      `perMegapixel` reads the pixel dimensions the request states, which the server checks are
      positive integers and never compares against the image it actually decoded; `perSession` counts
      session ids the app mints. A modified client can declare a tiny image while sending a large one,
      or reuse one session id all month. **`perIteration` is the one weight nothing the client sends
      can deflate**, because it counts requests the server logged whether the caller liked it or not.
      - **What is still bounded:** the spend cap, which counts *calls* and is deliberately unweighted,
        so a client doing all of that still gets at most `SPEND_CAP_UNITS` calls in a period.
      - **What is not:** the revenue. `SPEND_CAP_UNITS` is an anti-abuse ceiling set so no ordinary
        user ever reaches it, so it sits **far above any plan's allowance**, and under-declaring buys
        extra runs anywhere in that gap. It buys nothing today, because nothing refuses on this
        number yet; it becomes real the moment the gate lands (SONNY-213).
      - **How big is it — measured, because "buys extra runs" without a number reads as a footnote.**
        At **the placeholder weights in `server/.env.example`** (`perSession 10, perIteration 5,
        perMegapixel 2, runCredits 100`), a full 12-iteration session at a real capture's dimensions
        (2406 × 1354) costs **148.19 credits honestly and 60.00 deflated** — a **2.47× multiplier**,
        because `perIteration` carries only **40%** of the honest price and it is the only component
        a client cannot talk down. **The multiplier is one over whatever share `perIteration`
        carries, so it grows as your weights get more accurate**: `catalogue.ts` says `perMegapixel`
        is what vision cost actually tracks, so a well-calibrated set puts *more* weight on the
        deflatable component, and a calibration where `perIteration` carries 10% is a 10× multiplier
        on the paid line. That is the size of what you are choosing against.
      - **The decision:** if you want an allowance nothing can talk down, set `perSession` and
        `perMegapixel` to **0** and put the whole price on `perIteration`. That is a `CREDIT_PLANS`
        value and needs no code change. The cost of doing it is that a session sending huge images
        pays the same as one sending small ones, so the weighting stops tracking real cost as closely.
        Decide which you want here rather than meeting it later.

### Screen control stops when the allowance is gone (new 2026-08-31, SONNY-213)

**What changed:** screen control now has its one billing gate. A session is refused before it starts
when the account is out of screen-control runs **or** the cached entitlement cannot be confirmed,
and a session that runs out mid-way finishes the step it is on and stops at the next step boundary
with *"You've used your screen-control allowance — top up or wait."* **Nothing else is gated** —
every other capability runs with no network and no entitlement exactly as before, and that is the
direction most worth checking by hand.

**The stock-build symptom, named so it is not reported as a defect.** A packaged build with no
gateway to sign in against refuses every screen-control session at the door with **"Sign in to Sonny
to use this."** That is the gate failing closed exactly as designed, and it is not a finding.

*Which* sentence you get depends on how far the build gets, and all three are the same gate working
— worth knowing so none of them is filed either (this paragraph named the wrong one until PR #190's
F3, which is how a founder meeting the right one would have been handed a reason to file it):

| what you see | what it means |
|---|---|
| "Sign in to Sonny to use this." | **The stock case.** No gateway is deployed, so there is no session to restore; the entitlement check refuses at its first guard, before the key set is ever read. |
| "Connect once so Sonny can check your plan." | Signed in, but nothing cached yet — reachable once a container is running. |
| "Sonny couldn't check your plan. Try again in a moment." | Something is cached that this build cannot verify — the empty shipped key set, reachable if you still hold a session from an earlier local-gateway run. |

To test the allowed direction at all, the rows below need the
SONNY-135 section's container setup **plus the debug key override** that section uses
(`defaults write` of `SonnyEntitlementPublicKeys`, or `SONNY_ENTITLEMENT_PUBLIC_KEYS` for a
terminal-launched debug build), plus SONNY-212's `CREDIT_PLANS` on the container.

- [ ] **(SONNY-213) — the offline direction first, because it needs no setup and it is the one that
      breaks Sonny if it is backwards.** With the Wi-Fi **off** and no container running — signed
      out, no entitlement anywhere — run the everyday free things: a calculation in the widget, a
      snippet expansion, "open my writing workspace", a routine. **Every one of them works
      instantly.** Then ask for a screen-control task. **That one alone is refused, with a sentence
      about signing in or checking your plan — never a raw error.** The finding is any free
      capability hesitating, erroring, or mentioning plans/allowances/sign-in at all.
- [ ] **(SONNY-213)** With the container up, the key override set and a signed-in session on a plan
      with runs left: ask Sonny to control an app. **The session runs exactly as it did before this
      branch** — no new prompt, no new sentence, nothing about credits.
- [ ] **(SONNY-213)** Set `CREDIT_PLANS` so the account's tier includes **0 credits**
      (`"monthlyCredits":0` on the account's plan), restart the container, and ask for a
      screen-control session. **It is refused before anything happens** — no window activates, no
      HUD appears, nothing is captured — with *"You've used your screen-control allowance — top up
      or wait."* The finding is the app coming to the front, the HUD flashing, or a capture landing
      in the metering log (`npm run usage`) for a session that was refused.
- [ ] **(SONNY-213) — the mid-run halt.** Set the weights so a session exhausts partway — e.g.
      `"monthlyCredits":100` with `"perIteration":40, "perSession":0, "perMegapixel":0, "runCredits":100`
      — and start a screen-control task that needs several steps. **It performs its first steps
      normally, then stops between steps** with the same allowance sentence, and the task history
      row for the session says that is why it ended. **Never mid-click**: the finding is a session
      ending with a half-done action (a menu left open by a click that never got its follow-up), or
      an abrupt failure sentence instead of the allowance one.
- [ ] **(SONNY-213)** After any of the refusals above, run the free things again (calculation,
      snippet, workspace). **All still instant.** A refusal that leaks into the free capabilities is
      the finding this ticket's acceptance criterion is written in capitals for.
- [ ] **(SONNY-213)** Kill the container mid-session (simulating the gateway dropping out) during a
      multi-step screen-control task. **The session does not stop at the next boundary with the
      allowance sentence** — an unreachable allowance is not an exhausted one. (It will fail at the
      next *vision call* with a backend-failure sentence, which is SONNY-131's behaviour and not
      this ticket's; the finding here is only the allowance sentence appearing when nothing was
      counted.)

### A client too old is told so, and one warned before it (new 2026-09-03, SONNY-204)

**What changed:** the gateway can now tell an outdated app that it is outdated. `GET /v1/meta` exists
and says what this gateway speaks, which client versions it still serves, where to send someone whose
build it does not, its own clock, and the public keys an entitlement claim may be signed with. Below
the configured minimum, **every** route answers `410` with `code: "version.unsupported"` and an
upgrade URL in the body. At or above the minimum but below the recommended version, requests are
served normally with `Sonny-Deprecation: true` and `Sonny-Deprecation-Info: <url>` on the response.

**Nothing here is on by default, and no deployment refuses anyone today.** Both bounds default to
`0.0.0`, which no client can be below, so the gate adds no behaviour at all until somebody sets a real
minimum. That is deliberate — the contract makes raising the minimum past a version that never had a
deprecation period a breach, and a default has given nobody a deprecation period.

**The Mac did not call any of it when this section was written, and now it does** (corrected
2026-09-04, SONNY-402). Every row below is still `curl` against a local gateway rather than the app,
and each of them is still exactly right — they check the *gateway's* side. What the app now does is a
section of its own, "The app learns it needs an update", directly below this one. Read that one for
anything you expect to see in the product; nothing you see here is a finding about the Mac.

**Setup, once:** `cd server && ./scripts/deploy.sh local`, the same container the sign-in section
uses. **`deploy.sh` forwards names from the shell you launch it in — it does not read `server/.env`**,
so the rows that need an armed gate start it like this instead:

```
MINIMUM_SUPPORTED_CLIENT=2.0.0 RECOMMENDED_CLIENT=3.0.0 \
  UPGRADE_URL=https://example.test/download ./scripts/deploy.sh local
```

- [ ] **(new 2026-09-03, SONNY-204) — the endpoint answers, on a gateway told nothing.** With no
      version variables set at all, `curl -s localhost:8080/v1/meta`. It must answer 200 with six
      fields: `api_version` `"1.0"`, `minimum_supported_client` and `recommended_client` both
      `"0.0.0"`, `upgrade_url` `null`, a `server_time` that is the current UTC time to the second,
      and `entitlement_keys`. **`entitlement_keys` is `[]` unless you set `ENTITLEMENT_SIGNING_KEY`**
      — a gateway that signs nothing publishes nothing, which is honest rather than a defect. With
      that variable set it holds one entry whose `kid` is your `ENTITLEMENT_SIGNING_KEY_ID` and whose
      `public_key` matches what `npm run entitlements -- public-key` prints. **Those two disagreeing
      is the finding**, because the whole point of publishing the key is that a Mac can verify a
      claim against it.
- [ ] **(new 2026-09-03, SONNY-204) — no version header changes nothing, on the same gateway.**
      Still with nothing set, `curl -si localhost:8080/v1/health` — 200, and **no** `Sonny-Deprecation`
      header. Then `curl -si -H 'Sonny-Client-Version: 0.0+0' localhost:8080/v1/health` — also 200.
      A refusal here would mean the gate armed itself, which is the thing this default exists to
      prevent.
- [ ] **(new 2026-09-03, SONNY-204) — the wall, with the three variables set.** Restart with the
      setup above, then `curl -si -H 'Sonny-Client-Version: 1.5.0' localhost:8080/v1/health`. It must
      answer **410**, with a body whose `error.code` is `version.unsupported` and whose
      `error.upgrade_url` is the URL you configured. Then the same header against
      **`/v1/meta`** — also 410, deliberately: an app that old may not be able to read the meta
      document at all, so the refusal carries the URL instead. And against a path that does not
      exist, `/v1/nope` — also 410 rather than 404, because the useful answer to a stale client is
      "you are out of date", not "no such page".
- [ ] **(new 2026-09-03, SONNY-204) — it is refused before it is asked for a token, which is the row
      that matters most.** `curl -si -H 'Sonny-Client-Version: 1.5.0' -X POST localhost:8080/v1/plan`
      with no `Authorization` header at all. **410, not 401.** Then the same call with
      `Sonny-Client-Version: 3.0.0` — now **401**. If the old client gets 401 the whole feature is
      defeated: a six-month-old build's token has expired, 401 means "refresh and retry", and it
      would loop forever without ever being told the real reason.
- [ ] **(new 2026-09-03, SONNY-204) — the warning band, and the boundary.**
      `curl -si -H 'Sonny-Client-Version: 2.5.0' localhost:8080/v1/health` — **200**, served
      normally, with **both** `Sonny-Deprecation: true` and `Sonny-Deprecation-Info` carrying your
      URL. Then `2.0.0` (exactly the minimum) — 200 **with** the headers, because the minimum is
      served and warned. Then `3.0.0` (exactly the recommended) — 200 with **neither** header. The
      two boundaries being inclusive in opposite directions is the thing to check.
- [ ] **(new 2026-09-03, SONNY-204) — a bad configuration refuses to start rather than serving
      wrongly.** Four separate `./scripts/deploy.sh local` runs, each with one thing wrong in the
      launching shell. The container must **fail to come up**, with a message naming the variable,
      each time: (a) `MINIMUM_SUPPORTED_CLIENT=banana`; (b) `MINIMUM_SUPPORTED_CLIENT=3.0.0` with
      `RECOMMENDED_CLIENT=2.0.0`; (c) `MINIMUM_SUPPORTED_CLIENT=2.0.0` with no `UPGRADE_URL` at all;
      (d) `UPGRADE_URL=example.test/download` with no `https://`. A gateway that starts and serves on
      any of those is the finding — (c) especially, because it would tell users to update and give
      them nowhere to go. **The message is what to report if one of them fails differently**: a
      generic crash with no variable named is still a finding even though the container did stop.
### The app learns it needs an update (new 2026-09-04, SONNY-402)

**What changed:** the Mac now does contract §8's client half, which SONNY-204's own section says it
did not. On launch the app calls `GET /v1/meta` once and keeps what it says; on any `410
version.unsupported` it calls it again, and never once per request. It reads `Sonny-Deprecation` and
`Sonny-Deprecation-Info` on every response, successes and failures alike. Two new states render
through the surfaces that already exist — the floating widget's panel and the attention panel at the
top of every Command Center page — with no new window and no wireframe, so **what these rows are
really asking is whether the result looks right to you**.

**The packaged app reports version `1.0+1`** (`Packaging/Info.plist`: `CFBundleShortVersionString`
`1.0`, `CFBundleVersion` `1`), which the gateway reads as the marketing version **`1.0.0`** — build
metadata is not ordered, so the `+1` is ignored. Every bound below is chosen against that number.

**Setup, once, and it is smaller than the SONNY-204 section's.** No Supabase credentials are needed
for either row: the version gate is registered before the auth gate, so it answers a request that
carries no token at all, and `GET /v1/meta` is unauthenticated. You need the container and the app
pointed at it.

1. `cd server && ./scripts/deploy.sh local`, with the version variables set **in the launching
   shell** — `deploy.sh` forwards names from the shell you run it in and does not read `server/.env`.
2. `defaults write com.sonny.MacAgent SonnyBackendBaseURL http://127.0.0.1:8080`, once. Same pointer
   the sign-in section uses, and a `defaults` value rather than an environment variable because the
   relaunch after a Screen Recording grant loses an environment variable.
3. `./scripts/package-app.sh`, then open `.build/arm64-apple-macosx/debug/MacAgent.app`. A bare
   `swift run` has no bundle identity and reports version `0.0+0`, which is a different test.

- [ ] **(new 2026-09-04, SONNY-402) — the wall: a build this deployment refuses.** Start the gateway
      with exactly this, then launch the packaged app:
      ```
      cd server && MINIMUM_SUPPORTED_CLIENT=2.0.0 RECOMMENDED_CLIENT=2.0.0 \
        UPGRADE_URL=https://example.test/download ./scripts/deploy.sh local
      ```
      The app sends `1.0+1`, which is below `2.0.0`, so every route answers 410. **Expect, within a
      moment of launch:** the floating widget shows a panel headed **Update needed** reading *"This
      version of Sonny is too old. Update to carry on."* with an **Update Sonny** button and no
      dismiss control — the wall deliberately has no way out but updating. Open Command Center: the
      same title, sentence and button at the top of the page, on **every** page you visit. Press
      **Update Sonny** — your default browser must open `https://example.test/download` (it will not
      resolve; that the browser went there is the whole check).
      **Then check the two things that would be defects.** Run a command that needs the backend
      ("summarise what's on my screen", or anything that plans) — the update panel must stay up
      rather than being replaced by a "Sonny couldn't finish this one. Try again." failure, because
      trying again cannot work. And run a local one that does not need the backend ("what is 12 times
      31", "open Safari") — that must still work, and its result appears while the update panel
      steps aside for it. **What would be a finding:** a generic failure sentence instead of the
      update panel; the two surfaces saying different things; a Retry button anywhere on it; the
      widget refusing to shrink back to its capsule when you leave it alone; or the panel taking the
      screen away from an approval or a clarification the app is waiting on.
- [ ] **(new 2026-09-04, SONNY-402) — the warning: still working, but out of date.** Restart the
      gateway with the minimum **at** this build and the recommendation above it, then relaunch the
      app:
      ```
      cd server && MINIMUM_SUPPORTED_CLIENT=1.0.0 RECOMMENDED_CLIENT=2.0.0 \
        UPGRADE_URL=https://example.test/download ./scripts/deploy.sh local
      ```
      `1.0.0` is served (the minimum is inclusive) and warned (it is below the recommendation).
      **Expect:** everything works exactly as normal — sign-in, tasks, all of it — plus a panel
      headed **Update available** reading *"A new version of Sonny is out."* with **Update Sonny**
      and **Not now**. It must be the *last* thing that shows: start a task and its progress takes
      the panel, finish one and its result does, and the update panel comes back afterwards. Press
      **Not now** — it goes for the rest of this launch and the widget returns to its ordinary idle
      capsule. Quit and relaunch: it is back, which is correct. Press **Update Sonny** instead —
      the browser opens the same URL. **What would be a finding:** anything failing or refusing while
      this is showing; the panel sitting on top of a running task or a result; **Not now** not
      sticking for the rest of the launch; or the panel appearing at all once you restart the gateway
      with `RECOMMENDED_CLIENT=1.0.0` and relaunch the app, which is the row's own control.

**The rollback — a running app changing its mind — is deliberately not a row, and this is the second
thing on this page that a local gateway cannot produce** (corrected 2026-09-04 after PR #202's
cycle-3 verification measured it; the row that stood here is withdrawn rather than repaired).

What it would have asked for: leave the app open behind the wall, restart the gateway with the
warning's configuration, and — without relaunching — do something that reaches Sonny, expecting the
panel to change by itself to **Update available**. **The setup above cannot deliver that, and the row
would have reported correct code as broken.** A running app's only way out of the wall is a *served*
response, and on `./scripts/deploy.sh local` with no Supabase credentials there is none to be had:
the app builds exactly four unauthenticated requests — `/v1/auth/email/start`,
`/v1/auth/email/verify`, `/v1/auth/refresh` and `/v1/meta` — and that gateway answers `404` to the
first three because the auth routes are not mounted, while `/v1/meta` is called only at launch and
on a `410`, neither of which happens after a rollback. Everything else the app sends is
`Authorization`-bearing and comes back `401`, which is a *failing* response, so the wall correctly
stays up — and "the wall still showing after a successful command" was the first item in the
withdrawn row's own list of what would be a finding. Worse, a bearer request answered
`auth.unauthenticated` clears this Mac's session, so following the row would have signed the founder
out. Exporting the sign-in section's `SUPABASE_*` names is not enough either: the auth routes then
mount, but a plan needs a model credential to be *served* rather than answered `502`, which is
non-`2xx` again.

**On a real deployment this recovers by itself and needs no row**, which is why nothing in the app
was changed for it. Every served response clears the wall, and the token refresh is one:
`performRefresh` sends `/v1/auth/refresh` through the same path every other request takes, so a
walled app whose access token is expiring gets a served `200` and the wall comes down before the
user does anything. What is left unproven by hand is only the rollback *on this rig*, and it is held
by tests instead — `whatOneResponseDoesToAStandingWall` runs all four status/header combinations
from a standing wall, and `aServedResponseCarryingTheHeaderTakesTheWallDownToTheWarning` is the
rollback end to end.

**One case is deliberately not a row, because a correctly configured gateway cannot produce it.** If
the upgrade URL is not `http` or `https`, the app shows the message with no button — the founder's
decision of 2026-09-04. You cannot reach that from here: the gateway refuses to start with a
non-http `UPGRADE_URL` (SONNY-204's own configuration row (d) is that refusal), and refuses to start
with an armed minimum and no `UPGRADE_URL` at all (row (c)). It is held by tests instead —
`ClientVersionTests` over the rule and `ClientVersionSurfaceTests` over both surfaces.

### Buying more runs when they run out (new 2026-09-03, SONNY-215)

**What changed:** an **opt-in** setting, **off by default**, in Command Center's Account section
under the runs-left line: *"Buy more runs when these run out"*. With it **on**, a session that would
have hit SONNY-213's wall buys one more pack through the payment provider and carries on. With it
**off** — which is every account until somebody presses it — nothing is bought and SONNY-213's halt
happens exactly as it did before this branch.

**The one thing worth checking hardest is the negative**: *no charge occurs without the explicit
opt-in.* Every row below that says "nothing was charged" is checkable in the database
(`SELECT * FROM sonny.credit_topup`) and at the provider's own dashboard, and those two are the
evidence — not the absence of a sentence in the app.

**Setup.** These rows need everything the SONNY-213 section needs (the container, the debug
entitlement key override, `CREDIT_PLANS`) **plus two things of their own**:

- a `topUp` block on `CREDIT_PLANS` — `"topUp": {"credits": 500, "productId": "<a real one-time
  product at the provider>", "maxPerPeriod": 3}`. Without it the control does not render at all,
  which is the first row below.
- a Polar **one-time product** for the pack, a customer with a saved payment method, and
  `BILLING_PROVIDER_ACCESS_TOKEN` carrying the `orders:write` scope. **Nobody on this project has
  run an order against real Polar yet**, which is why **every row marked ⚠️** is one to run first and
  record verbatim. **A row marked 🚧 is one nobody can run yet**: it names the thing it waits on, and
  it is not a candidate for the first pass until that exists. (This sentence used to count the marked rows —
  "the two rows marked" — and was stale by two before SONNY-430 arrived. It is a description rather
  than a number now, deliberately: a legend that counts the population it introduces goes stale every
  time a row joins it, and no reader is told when. The figures are in the changelog entry, where they
  are a dated record instead of a live claim.)

- [ ] **(SONNY-215) — off by default, and this is the row that matters most.** On a fresh account
      with `topUp` configured, open Command Center › the account row › Account. The runs-left line is
      there and **the switch below it is off**. Do not touch it. Now drive the account to zero
      (`"monthlyCredits":0`, restart the container) and ask for a screen-control session. **It is
      refused with the same sentence as before — "You've used your screen-control allowance — top up
      or wait."** Then check `SELECT count(*) FROM sonny.credit_topup;` → **0**, and the provider's
      orders list → **nothing**. The finding is any row, any order, or any charge on the card.
- [ ] **(SONNY-215)** With `topUp` **absent** from `CREDIT_PLANS`, open Account. **There is no
      switch at all** — not a disabled one, not a greyed one. The runs-left line is unchanged. The
      finding is a control that appears and then fails when pressed.
- [ ] **(SONNY-215)** Press the switch on. It **stays on after the dialog is closed and reopened**,
      and after the app is relaunched — the setting lives on the gateway, not on this Mac, so it
      should also be on when you sign in to the same account on a second build.
      `SELECT opted_in_at FROM sonny.auto_topup_consent;` names the instant you pressed it.
- [ ] **(SONNY-215) ⚠️ the charge.** With the switch on and the account at zero runs, ask for a
      screen-control session. **It runs** rather than being refused, and the runs-left line afterwards
      shows the pack that was bought (e.g. *"50 of 50 runs left this month"* on a 500-credit pack at
      10 credits a run). `SELECT outcome, credits, provider_order_id FROM sonny.credit_topup;` shows
      one `granted` row. **Record the provider's order object verbatim on the ticket** — its
      `status` field is what `polar.ts` reads, and this is the first time anybody has seen one.
- [ ] **(SONNY-215) ⚠️ the mid-run purchase.** Set the weights so a session exhausts partway (the
      SONNY-213 section's shape), switch on, and start a multi-step screen-control task. **It does
      not stop between steps** — it buys and carries on. The finding is a halt with the allowance
      sentence while the switch was on and the period had purchases left.
- [ ] **(SONNY-215) — the bound.** With `"maxPerPeriod": 1`, drive the account to zero twice in one
      month. The **first** exhaustion buys; the **second** is refused with the ordinary allowance
      sentence and **no second order exists at the provider**. The finding is a second charge.
- [ ] **(SONNY-215) — a card that fails.** Put a declining test card on the customer, switch on, and
      run out. **The session is refused with the ordinary allowance sentence** — not a new sentence,
      not a raw error — and `sonny.credit_topup` holds a `declined` row. The finding is the app
      saying anything about cards, or a session running anyway.
- [ ] **(SONNY-215)** Switch it **off** again while the account has runs. Then run out. **Refused,
      nothing charged.** `opted_in_at` is `NULL` and `updated_at` names when you turned it off.
- [ ] **(SONNY-215) — the setting when the gateway is down.** Kill the container, then press the
      switch. **A line appears under it saying Sonny couldn't change that setting** and the switch
      goes back to what the server last said — it does not sit in the position you pressed. The
      finding is a switch that shows "on" when nothing agreed to it.
- [ ] **(SONNY-215) — the price is on the switch, and it is the right one.** With `topUp.price` set
      (e.g. `{"amount": 500, "currency": "usd"}`), open Account. **The switch reads "Buy more runs
      when these run out ($5.00)"** — the price in parentheses, no sentence beside it. Then open the
      Polar product the `productId` names and **check the two amounts are the same**. Nothing in the
      gateway can check this for you: it never reads the product, so a `price` that disagrees shows
      one number on the switch and takes another off the card. The finding is a mismatch, or a
      sentence appearing under the switch explaining what it costs.
- [ ] **(SONNY-215) — a currency with no minor unit.** Set `{"amount": 500, "currency": "jpy"}` and
      reopen Account. **The switch reads ¥500, not ¥5.** The finding is a hundredfold error, which is
      what dividing every currency by a hundred produces.
- [ ] **(SONNY-215) ⚠️ the record of a charge.** After the successful top-up above, reopen Account.
      **A "Last top-up" row sits under the switch showing the amount and the date** — and the amount
      is what Polar's order says, which is the figure to compare against the invoice rather than
      against `CREDIT_PLANS`. Then **turn the switch off** and reopen: **the record is still there.**
      A user who was charged is owed the record whatever the switch says now; the finding is a
      receipt that disappears.
- [ ] **(SONNY-215) — no record before a charge, and none for a decline.** On a fresh account there
      is **no "Last top-up" row at all**. After the declining-card row above, there is still none —
      a declined attempt took no money and must not appear as a charge.
- [ ] **(SONNY-215) ⚠️ the lost record, which is the one worth engineering for.** With the switch on
      and the account at zero, start a top-up and **kill the gateway container the moment the charge
      is placed** (watch `docker logs` for the finalize). Bring it back and ask for a screen-control
      session again. **No second order appears at Polar** and the account is granted the pack it
      already paid for — `SELECT outcome, provider_order_id FROM sonny.credit_topup` shows **one**
      row, moving from `attempted` or `unconfirmed` to `granted`. The finding is two paid orders, or
      an `attempted` row with a NULL order id after a charge that reached Polar.
- [ ] **(SONNY-215) — a pack that cannot buy a run does not deploy.** Set `topUp.credits` below
      `runCredits` and restart the container. **It refuses to start**, naming the pack. The finding
      is a gateway that boots and then charges for a pack that leaves the account exactly as unable
      to run as it was.
- [ ] **(SONNY-215) — nothing else moved.** With the switch **on** and the account **not** low, run
      the everyday free things and an ordinary screen-control session. **No purchase happens**
      (`sonny.credit_topup` stays empty) and nothing about the run changes.
- [ ] **(SONNY-430) 🚧 the charge that outruns the deadline.** The route now gives up after **30
      seconds** and answers `502 topup.unconfirmed`, not `504 provider.timeout`. Reproducing it needs
      a stalled provider, so this row **waits on a way to stall Polar** — the practical one is a
      proxy in front of `POLAR_API_BASE_URL` that accepts the finalize and never answers. With that:
      with the switch on and the account at zero, ask for a session. **The app gets an answer in
      about half a minute rather than hanging**, and the answer is not the retryable timeout code.
      Then bring the proxy back and ask again: **no second order appears at Polar**, and
      `SELECT outcome, provider_order_id FROM sonny.credit_topup` shows **one** row that keeps its
      order id and moves to `granted`. The finding is two paid orders, a row with a NULL order id, or
      a request that hangs past a minute.
- [ ] **(SONNY-430) 🚧 the read-back shares the finalize's budget.** Same proxy. **Hold the finalize
      for about ten seconds before answering it `412`**, then stall the order read that follows.
      **The whole charge ends about two seconds later — roughly twelve seconds in total, not
      twenty-two.** Then the attempt is recorded `unconfirmed` keeping its order id, never
      `declined`. **The ten-second hold is the whole row and is not a detail to trim**: answer the
      `412` immediately instead and the shipped code and the code it replaced both finish at about
      twelve seconds, because the replaced read-back minted a fresh twelve-second budget starting
      from zero — so a founder who runs it that way, sees twelve seconds and ticks it has checked
      nothing. The two only separate when the `412` lands late in the finalize's own budget, which is
      what the hold creates. This row waits on the same proxy as the one above; it is separate
      because it is the adapter's bound rather than the route's, and a single stall exercises only
      one of the two.

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

### `fix/three-small-client-defects` owes no rows, and here is why (2026-08-28, SONNY-264 / SONNY-218 / SONNY-259)

**No rows, stated rather than left as an absence** — and this section replaces one that was written
and then withdrawn, which is the more useful record (PR #157's review, F1). All three tickets on that
branch are internal-contract fixes with no surface a founder can read.

- **SONNY-264** refuses an output path that leads out of `~/Desktop`/`~/Documents` using the same
  sentence that has always been shown for a path the user named, and reaching it at all needs a
  symbolic link planted by hand. Nothing rendered changes.
- **SONNY-259** is test-only. `Sources/` is untouched.
- **SONNY-218** shipped with a row asking the founder to read the approval panel's "Will include:"
  lines before approving. **That row could not have detected anything, in either half, and it is
  withdrawn rather than reworded.** "Will include:" is written at one site, in
  `SaveRoutineCapabilityAdapter`, it interpolates a preview's *title* rather than a path, and the
  row's own scenario contains no `save_routine` step, so nothing produces the line. More
  fundamentally, no surface renders `ActionPreview` at all — `git grep -c "ActionPreview" --
  Sources/MacAgent` exits 1 — and what the approval panel does render, `RiskApprovalCopy`, builds
  its file line by walking the *outer* plan's steps, where a nested routine's destination can never
  appear. The half that is checkable, "both files exist afterwards", passes on `main` too: the
  on-disk behaviour was fixed by SONNY-190 and SONNY-220 and is held by tests at the cut point.

**An unrunnable row is worse than no row**, because a founder either files a false failure or ticks
something that checked nothing, and a ticked row suppresses re-checks. What SONNY-218 actually fixed
is that `previewChain` seeds each segment's nested preview from the paths the previous one reported,
so a wrong nested preview mis-seeds the next — held by tests, not by a human at the app.
### Tagged segment markers — screen control and web research (new 2026-08-28, SONNY-234)

The delimiters that separate what you told Sonny from what it merely observed now carry a random
tag, generated per prompt. Nothing about this is visible in the product, so what these two rows are
really asking is whether a longer, per-request marker changed how the models behave — which no test
here can answer, because no test calls a model.

- [ ] **(SONNY-234)** Run one ordinary screen-control task on any app — the same shape as the
      SONNY-231 row above. What should happen is exactly what happened before: the model clicks,
      types and finishes the goal. **The finding would be a model that has stopped following the
      goal**, that starts describing the prompt's own markers back at you in a rationale, or that
      asks about a "tag". Try one where a window on screen contains text pretending to be an
      instruction, if you can arrange it, and confirm Sonny still ignores it.
- [ ] **(SONNY-234)** Run one web-research task that fetches a real page ("summarize <url> and save
      it as Markdown"). The note should still be grounded in that page, name it as a source, and
      contain no marker text. **The finding would be a note that quotes a
      `UNTRUSTED_OBSERVED_CONTENT_...` line back at you**, or one that has stopped summarizing the
      page at all.

### Redaction stops blacking out line-range citations (new 2026-08-28, SONNY-278)

The one-time-code shape used to fire on every `File.swift:129-131` you had on screen, and a match
blacks out **the whole line** for the vision model. This is visible in the pre-send review panel, so
it is checkable rather than a claim.

- [ ] **(SONNY-278)** Put a window in front that is full of line-range citations — this repository's
      changelog, a GitHub diff, a review comment, an editor with a stack trace — and start a
      screen-control session on it in **Safe** mode so the pre-send review panel appears. Look at the
      thumbnail and at the "N possible secrets were blacked out" line. **The finding is a black bar
      over a line whose only digits are a `something:129-131` citation, or a thousands-separated
      number like `1 011 740`.** Before this change those painted; now they should not.
- [ ] **(SONNY-278, the other direction)** With a real six-digit code visible on screen — a
      verification code in a mail or messages window, however it is spelled: `483291`, `483 291`,
      `483-291`, **and a label pressed straight against its colon with no space, `PIN:483-291` or
      `token:483-291`** — start the same session. **The code must still be blacked out.** A code that
      reaches the thumbnail unpainted is the more serious finding of the two. (The fourth spelling is
      here because PR #158's review found the first version of this change had stopped painting it,
      and the three spellings originally listed all put a space or a context word beside the digits,
      so none of them could have caught that.)

### A routine can open a saved workspace (new 2026-08-30, SONNY-186)

Teaching a routine that opens a workspace used to fail — `open_workspace` was refused inside a
routine. The founders' 2026-08-30 decision allows it, binding at the step, and creating or editing a
workspace from inside a routine stays refused. The rows worth a human are the ones about what a user
sees when the workspace is no longer there.

- [ ] **(SONNY-186)** With a workspace saved (apps and at least one URL), say **"teach me a routine
      called morning setup that opens my research workspace"**. It should save, not refuse. Then
      **"run my morning setup routine"** — the workspace's apps and URLs open, and the widget's
      result names the workspace.
- [ ] **(SONNY-186, the refusal that stays)** Ask for a routine that **creates** a workspace, and one
      that **changes** an existing workspace. Both must still be refused.
- [ ] **(SONNY-186, the renamed workspace — the important one)** With that routine saved, rename the
      workspace it opens (or delete it and save one under a different name), then run the routine.
      **Sonny must say which routine wanted which workspace, and list the workspaces you do have** —
      the new name among them. It must not run the routine's other steps and it must not quietly do
      nothing. Check the sentence reads like something a person wrote.
- [ ] **(SONNY-186, nothing saved)** Delete every workspace, then run the routine. The answer should
      say you have not saved any workspaces yet, and still name the routine.
- [ ] **(SONNY-186, unattended)** Give that routine a schedule with unattended running on, let it
      fire with the workspace **missing**, and read the "did not run" notice — it must name the
      routine and the workspace. With the workspace **present**, it should run normally, including a
      step that touches something the workspace does not list: a scheduled run is deliberately not
      bound by the workspace it opens, so that step must not be blocked or silently skipped.
- [ ] **(SONNY-186, one browser — the workspace supplies it)** Save a workspace whose apps include
      Safari but whose URL list is empty, and a routine that opens that workspace and then opens a
      URL of its own. **The routine's URL should land in Safari**, not in your system default
      browser.
- [ ] **(SONNY-186, one browser — the workspace receives it. This is the round-2 fix, PR #177's F1,
      and the row above cannot see it because its workspace has no URLs of its own.)** Give that
      workspace **at least one URL**, and put an `open_app` for a *different* browser (Chrome, say)
      **before** the workspace step: "a routine that opens Chrome, then my research workspace, then
      github.com". **All three URLs — the workspace's own and the routine's — should land in
      Chrome.** Two browsers opening is the failure. Then reverse it: workspace step first, Chrome
      second — now everything should land in **Safari**, because the first browser in step order
      wins.
- [ ] **(SONNY-186, two workspaces, two browsers — the founders' call to confirm or overturn)** Save
      a second workspace whose apps name a different browser and which has URLs of its own, and a
      routine that opens both. **Both workspaces' URLs land in the first one's browser.** That is
      the founders' own 2026-08-04 tie-break applied inside a routine, and the cost is exactly what
      you are looking at: a workspace you deliberately gave its own browser does not get it here.
      If that reads wrong, say so — the alternative is each workspace keeping its own, and it is one
      line to change back.
- [ ] **(SONNY-186, the blast-radius guard)** Open that same workspace **on its own** — "open my
      research workspace", no routine. Its URLs must still open in **its own** browser. Nothing
      outside a routine was meant to move.
### A calculation phrased as a sentence (new 2026-08-30, SONNY-284)

`what is 2 + 2` used to reach the planner, which has no calculator, and came back "Calculation is
unsupported by the registered local tools". The resolver now takes the sentence's filler off before
it decides. Both directions are on this list, and the second one is the one that matters more — the
constraint on this ticket was that widening the calculator must not start swallowing commands that
are not calculations.

- [ ] **(SONNY-284, typed)** In the floating widget type each of these and press return:
      `what is 2 + 2`, `what's 2+2`, `how much is 5 times 5`, `convert 5 km to miles`,
      `5 km in miles please`, `please calculate 2 + 2`. **Each must answer instantly and locally —
      `4`, `4`, `25`, `3.1068559612 mi`, `3.1068559612 mi`, `4` — with no planner round trip.**
      The finding is any of them coming back "Calculation is unsupported by the registered local
      tools", or taking a visible moment to think.
- [ ] **(SONNY-284, typed, the comma and the politeness word)** `What is 5 times 5, please?` →
      **`25`**, and `calculate 2 + 2 please` → **`4`**. Both were broken when PR #176 opened — the
      first came back "Calculation is unsupported by the registered local tools" and the second
      answered "Could not calculate that expression: Unexpected token p." — so this row is the one
      most worth doing. Also check the card itself on `what is five times five, please`: the
      summary must read **`Calculate five times five.`** with no stray comma before the period.
- [ ] **(SONNY-284, spoken)** Hold the push-to-talk hotkey and say "what is two plus two" → **`4`**,
      then "how much is five times five" → **`25`**, then "convert ten centimeters to inches" →
      **`3.937007874 in`**. Same instant local path. Dictation writes a curly apostrophe in
      "what's" and puts a full stop or a comma on the end of a sentence; all three are handled, and
      this row is where they get seen for real, so **say one of them with a trailing "please" too**.
- [ ] **(SONNY-284, the direction that must NOT have changed)** Ask for things that merely *look*
      like the shapes above and confirm each still goes to the planner and does its real job:
      `what is the weather today`, `what's on my calendar`, `how much is left on my disk`,
      `remind me in 5 minutes`, and **`convert <a real file>.docx to pdf`** on a document you have.
      **The finding is any of these answering with a calculator error or a "Calculate ..." card.**
      (On the docx one: PR #176's review established this branch never moved it — it was five
      tokens and reached the planner before and after — so it is a regression check on the verb
      that became strippable, not a behaviour this branch changed.)
- [ ] **(SONNY-284, the direction that DID change, and the founders' call to make)** Type
      `10 gb to mb` and `2 hours to minutes`. Before this branch each reached the calculator and
      named the word Sonny did not understand — **"gb is not a supported conversion unit"** and
      **"hours is not a supported conversion unit"** respectively.
      Now they reach the planner and get its generic refusal instead. That is the accepted cost of
      the guard that keeps `5 docs to pdf` out of the calculator (the two are structurally
      identical), and it is recorded in the changelog. **Nothing here is a finding unless you
      disagree with the trade** — if you do, the fix is a wider unit table on its own ticket.

### Taking an app back off the allowed list (new 2026-08-30, SONNY-144)

Settings → Security & Access → **Screen Control** now lists the apps you have allowed Sonny to
control, each with its own Remove, plus a Remove All. Nothing here can be checked by an agent — the
list only fills up by answering the real per-app question in a real session.

- [ ] **(SONNY-144)** Approve two apps through the flow — start a screen task on each and answer the
      per-app question — then open Settings → Security & Access → Screen Control. **Both are listed**,
      each by its real name, with the bundle identifier and when you allowed it underneath.
- [ ] **(SONNY-144)** Press Remove on one of them. **It asks first** — like every other row delete
      in the app. Confirm. Then ask Sonny to use that app again: **it asks.** Ask it to use the
      other: **it does not.**
- [ ] **(SONNY-144)** Press Remove on a row and **cancel** at the dialog. **The app stays on the
      list**, and Sonny still controls it without asking.
- [ ] **(SONNY-144)** Press Remove All and confirm. The list is empty and the empty state reads
      sensibly — it should say how an app gets onto the list, not offer you a way to add one.
- [ ] **(SONNY-144)** Press Remove All again and **cancel** at the dialog. **Nothing is removed.**
- [ ] **(SONNY-144)** With nothing approved and the mode set to **Safe**, read the whole Screen
      Control section. **The finding is a section that looks broken rather than deliberate** — an
      empty block, or a stray control. In *this* scenario there are no grants at all, so Remove All
      should not be on screen; if it is, that is the finding. (A Remove All above a list with no rows
      is not always wrong — there is one state the app ships deliberately where it is correct, and it
      says so in its own words rather than "No allowed apps yet". You cannot reach that state by
      hand, so it is not a row here; it is described in the changelog under G2.)
- [ ] **(SONNY-144)** Narrow the Command Center window as far as it goes and re-read the list.
      **The finding is character-wrapping** — a name breaking one letter per line — **or a Remove
      button clipped off the right edge.** The rows should stack the button under the name rather
      than squeezing it.
- [ ] **(SONNY-144)** Start a screen session in an approved app and, **while it is running**, press
      Remove on that app in Settings. **A confirmation appears** — the same one any other Remove
      raises; nothing about a live session changes it. Confirm it. **The session then stops** at its
      next step, and it does not re-ask. (The dialog is new since the review round; a founder
      following the old wording would have met a step this row did not describe.)

### A standing watcher tells you something changed (new 2026-08-31, SONNY-236)

A watcher is the one feature in Sonny whose entire output is a notification, hours or days after you
asked. **No agent can verify that a banner fires** — the wiring is pinned by a source scan, and that
scan proves the code posts into the right category, not that macOS drew anything.

**Read this whole paragraph before you start, because two things make these rows expensive if you
don't.**

- **You must run a packaged build.** `swift run MacAgent` has no bundle identity, so
  `SonnyNotificationService.init?` returns nil and *no notification path exists at all* — you would
  see nothing and correctly conclude the feature was broken. Run `./scripts/package-app.sh` and open
  `.build/arm64-apple-macosx/debug/MacAgent.app`. This is CLAUDE.md's standing rule; it is repeated
  here because the symptom of ignoring it is silence, which looks exactly like a defect.
- **Shorten two constants in your local build first, and these two values are chosen so every row
  below fits one build.** A watcher checks every 15 minutes and reports a change only on the
  **second** consecutive matching reading, so unedited the shortest row is half an hour and the
  longest is two hours. Before packaging, in `Sources/MacAgentCore/StandingWatcher.swift`, edit
  `StandingWatcherLimits.standard`: `checkInterval: 15 * 60` → `checkInterval: 30`, and
  `maxLifetime: 7 * 24 * 60 * 60` → `maxLifetime: 600`.

  The arithmetic, so you can see nothing here is arbitrary and so a row that behaves differently is a
  real finding: at a 30-second interval a **change** needs 2 checks (about a minute), a **churning**
  page needs 4 (two minutes), an **unreachable** page needs 8 (four minutes), and the lifetime is ten
  minutes — comfortably longer than the longest row, which matters because expiry is checked *before*
  due-ness, so too short a lifetime retires a watcher before it can reach any other ending.
  **`maxLifetime: 120` does not work** and was what this section first said: the unreachable row needs
  210 seconds and the watcher would expire at 120.

  **Change both back to `15 * 60` and `7 * 24 * 60 * 60` before committing anything** —
  `theShippedCapIsTheOneRecordedOnTheTicket` fails if you don't, which is the backstop rather than the
  reminder.
- **What these rows cover, and one thing they deliberately do not.** A page that **fails fast** — a
  404, a refused connection, a blocked host — is covered by the unreachable row below: eight failures
  and the watcher stops saying so. A page that **hangs** — accepts the connection and never answers —
  is **not covered by any row, by decision**, and this is stated rather than left as an absence.

  That case was PR #184's F3, and it was blocking: one hanging page held the checker's single slot
  forever, stopping every other watcher with nothing reported. The fix abandons a check that has been
  in flight past `checkTimeout` and records it as a failed reading so the cap can still end it.
  **None of that is manually reachable**, because `SafeURL.isPrivateOrLocalHost` refuses `localhost`,
  `.local`, loopback, RFC1918, link-local and CGNAT — so the obvious arrangement, `nc -l 8080` and a
  watcher on `http://localhost:8080/`, never opens a socket. It throws before fetching, which is a
  *failed reading* and lands on the fast-failure path: a founder trying it would see the unreachable
  ending after eight checks and conclude the stall path works, having never touched it. That is worse
  than no coverage. Arranging a genuine hang needs a public host that accepts and never responds — a
  VPS or a tunnelling service — and that refusal in `SafeURL` is a security property that must not be
  weakened to make a test possible.

  Held instead by `onePageThatNeverAnswersIsAbandonedAndDoesNotStopTheOthers`,
  `aStalledCheckThatAnswersLateWritesNothing` and
  `theCheckTimeoutAndTheCheckIntervalComposeInTheShortenedBuild`.

- **One number interacts with your shortened build and it is worth knowing before you watch a slow
  page.** `checkTimeout` is 60 seconds and is *not* shortened, so in a build with
  `checkInterval: 30` a check may outlive two intervals. That is harmless and is asserted by the last
  test named above: a pulse while a check is in flight starts no second fetch, and the check is
  abandoned at 60 seconds.

  **The retry cadence of a hanging page is `checkTimeout + checkInterval`, which is 90 seconds in this
  build — not 60.** The abandonment stamps the watcher's last-checked time, and due-ness is measured
  from that, so the next check is one whole interval after the abandonment. Measured directly at the
  shipped numbers: fetches at t=0 and t=960, which is 60 + 900. So against a sluggish site you will
  see **two** 30-second pulses pass with nothing happening, not one; that is this and not a defect.
  (This bullet said "retried on the timeout rather than on the interval" until PR #184's cycle-3
  re-check measured it — the same class of defect as the row arithmetic F6 was filed for, in the fix
  for F6.)

- **There is deliberately no shipped override for this** — no environment variable, no debug menu.
  The cap is a founder decision and it should not ship with a documented bypass; and since a
  packaged build is required regardless, editing one constant before that build costs nothing.

**Seeding a watcher, and why that is the right way to test this half rather than a workaround.**
SONNY-236 builds a watcher that gets checked and fires; **SONNY-382** builds the part where a *user*
creates one by asking. So these rows deliberately start from a watcher that already exists — that is
this ticket's actual subject — and SONNY-382 adds its own row that starts from a spoken command.
**Both are worth having, and this row is worth re-running once SONNY-382 lands**, from the other end.

Seed it in the same local build where you shortened the two constants above. In
`Sources/MacAgent/AppDelegate.swift`, add `import MacAgentCore` at the top — **that file does not
import it today**, and without the import none of the four types below resolve — then paste this
immediately after `viewModel.startRoutineScheduling()` (line 153 at `e0dfa00`), setting the URL and
the subject to a page you can edit:

```swift
Task { @MainActor in
    let watched = URL(string: "https://example.com/the-page-you-can-edit")!
    let reading = try? await LiveStandingWatcherObserver().readableText(at: watched)
    try? ResumableTaskStore(fileURL: ResumableTaskStore.realFileURL()).saveWatcher(
        StandingWatcher(
            subject: "the page I am testing",
            url: watched,
            createdAt: Date(),
            baselineDigest: StandingWatcherEvaluator.digest(of: reading ?? "")
        )
    )
}
```

It reads the page once and uses that as the baseline, which is what SONNY-382's real creation path
will do. **Remove the line once you have a watcher** — it seeds a fresh one on every launch, and the
fifth is where the cap starts refusing.

**Do not try to write the store file by hand.** `resumable-tasks.json` is encrypted through
`LocalStorageEncryption` like every other local store, so hand-written JSON will not decrypt, and
what you will see is the storage banner rather than a watcher.

- [ ] **(SONNY-236)** With a watcher running against a page you can edit, **change the page once and
      leave it changed**. At the next check **nothing happens** — this is correct, not a bug. At the
      check after that, a notification appears reading **“<what you asked>” changed.** Confirm the
      one-interval delay is what you saw: a first difference is never reported.
- [ ] **(SONNY-236)** Click that notification. **Command Center comes forward.** It offers no button
      of its own — no Retry, no Allow. A watcher may not act, so a button here would be a defect
      rather than a nicety.
- [ ] **(SONNY-236)** Check the same page again after the notification. **Sonny has stopped watching
      it** — a watcher is one-shot, and a second notification for the same change is a finding.
- [ ] **(SONNY-236)** Point a watcher at a page whose content changes on **every** load — a site with
      a rotating advertisement, a visible clock, or a shuffled "related" strip. Leave it. Within
      two minutes a notification says Sonny **stopped watching it because the page reads differently
      every time**, and it must **not** say the page did not change.

      **A "changed" notification here is not automatically a finding**, and this row used to say it
      was. The two-reading rule is a filter, not an absolute: a page rotating over a small pool can
      supply two consecutive equal readings by chance, and a page that alternates between two
      readings reaches neither ending. Report what you saw and how many checks it took rather than
      pass/fail — the design permits this, and how often it happens in practice is the thing nobody
      has measured. A page with a *visible clock* or a per-load nonce is the case the filter really
      does defeat, and is the better one to try first.
- [ ] **(SONNY-390)** **An alternating page ends in "cannot watch" within four checks.** This is the
      row SONNY-390 exists for, and it needs a page you control: put a file on a local web server (or
      any page you can edit) and set a watcher on it. Then **alternate it** — edit it to a second
      version, and on the next check edit it back to exactly the first, and keep swapping. At the
      shortened `checkInterval: 30` a check is every thirty seconds, so swap the file every thirty
      seconds and give yourself four swaps, about **two minutes**. **Expected: one notification
      saying Sonny stopped watching it because the page reads differently every time** — the same
      sentence the rotating-advertisement row above produces. **What would be a finding:** silence
      (which is the bug this ticket fixes — before it, this page was never reported at all, for the
      watcher's whole life), or a notification saying the page *changed*, or one saying it did *not*
      change. Getting the timing exactly right is hard by hand; if you land a swap late and the same
      version is read twice in a row, you will get a "changed" notification instead, which is correct
      behaviour and not a finding — start again rather than reporting it.
- [ ] **(SONNY-390)** **A page that wobbles once is still watched.** The other half, and the one that
      would break if the forgiveness were wrong. Set a watcher on a page you control, leave it alone
      for a minute, then change it **once** and change it straight back on the next check — one swap,
      not a sequence. Then leave it alone for the rest of the ten minutes. **Expected: no
      notification at all until the lifetime runs out**, and then the expiry sentence. **What would
      be a finding:** a "reads differently every time" notification from that single wobble — that
      would mean an ordinary page that flickers once gets abandoned, which is the cost this ticket
      was required to avoid.

      **Make sure the wobble was actually seen, or this row cannot tell a pass from nothing
      happening** (PR #209 review, F13). "No notification" is also what you get if the watcher never
      observed the change at all — the page was edited and put back inside one 30-second interval,
      so no check ever read the changed version. **Leave the changed version up for a full 40
      seconds by the clock** before putting it back, which at `checkInterval: 30` guarantees at least
      one check saw it. If the expiry sentence at the end reads *"Nothing settled"* rather than
      *"It did not change"*, that is Sonny telling you the wobble was seen — and that is the sentence
      this row wants. Getting *"It did not change"* means the wobble was missed: re-run rather than
      recording a pass.

      **And a "changed" notification here is correct behaviour, not a finding** — expect it about one
      run in three (PR #209 cycle 2, N6). Forty seconds of hold at a 30-second interval guarantees one
      check sees the changed version, and lets **two** see it whenever the first lands in the window's
      opening ten seconds, which is 10 in 30. Two consecutive identical readings is a confirmed
      change, so Sonny notifies, stops watching, and the expiry sentence this row asks you to read
      never arrives. Start again rather than reporting it — the same as the mistimed swap in the
      alternating row above.
- [ ] **(SONNY-236)** Point a watcher at a URL that 404s. The first seven checks say **nothing**.
      After the eighth — about **four minutes** at a 30-second interval — one notification says
      *Sonny stopped watching “…”. The page could not be read.* A notification per failed fetch is a
      finding, and so is the watcher expiring first (that would mean `maxLifetime` is too short).
- [ ] **(SONNY-236)** Start a watcher on a page you leave alone and wait out the ten minutes. The
      notification reads, literally: *Sonny stopped watching “…” after **1 day**. It did not change.*
      **"1 day" is correct at this setting and is not a finding** — the sentence renders
      `max(1, round(maxLifetime / 86400))`, so any lifetime under about a day and a half floors to
      one. Seeing "7 days" would be the finding, because that would mean the constant is being read
      from somewhere other than the one you edited.
- [ ] **(SONNY-236)** While a watcher is running, start an ordinary task and let it run. The watcher
      **still checks** — a routine would refuse here, a watcher does not, because it starts no task.
- [ ] **(SONNY-236)** Do this one **within ten minutes of seeding**, or the watcher expires while you
      are reading the dialog. Command Center → Memory. With at least one unfinished task **and** one watcher,
      press **Delete** on the Unfinished tasks row and confirm. **The unfinished tasks go and the
      watcher keeps running.** The result line reads `Deleted unfinished tasks.` with **no file
      count**. A watcher silently disappearing here is the exact defect this branch was told to fix.
- [ ] **(SONNY-236)** Also within ten minutes of seeding. Settings → Data → the whole local-data wipe.
      Read the sentence **before** pressing. It names **watchers** among the things it deletes. Press it: the watcher is gone and
      stops notifying.

### A job over many items, and its progress (new 2026-08-31, SONNY-235; scenario reworked after PR #185 R2)

**Why these rows exist at all.** The founders decided on 2026-08-31 that a job over many items asks
**once**, for the whole job — "Rename all 40?" — rather than once per item, *on the condition* that
the user can see it moving and can stop it partway. The approval is the part no agent can verify; so
is whether the progress line is legible while it moves.

**Read this before the set-up, because the rows below are unrunnable without it.** A folder whose
Word document has *already* been converted is **skipped** — Sonny sees the PDF sitting there and does
not convert it again. So a second run of the same job over the same folders converts nothing and
finishes almost instantly. Three of the rows below need the job to still be *running* when you reach
for a control, and one of them needs it running when you quit. **Each of those rows therefore gets
its own untouched copy of the folders.** The first version of this section did not, and a founder
following it would have found no window to quit in, no offer to continue afterwards, and would have
filed a bug against working code.

**Set up (about three minutes).** Make a folder on your Desktop called `job-master`. Inside it make
**twelve** subfolders, each holding one `.docx` file — any Word file will do, the same one copied
twelve times is fine — and a **thirteenth** subfolder with nothing in it at all. Then select
`job-master` in Finder and press **⌘D three times**, so you end up with four folders side by side:

```
~/Desktop/job-master          <- rows 1, 2, 3, 7 and 8
~/Desktop/job-master copy     <- row 4 (Command Center)
~/Desktop/job-master copy 2   <- row 5 (Cancel)
~/Desktop/job-master copy 3   <- row 9 (quit and continue)
```

Each row below says which one to point at. **Do not reuse a folder a row has already run to
completion** — if you lose track, delete every `.pdf` under it and it is as good as new.

- [ ] **(SONNY-235)** In the widget, ask Sonny to **convert the Word documents in each of the folders
      in `~/Desktop/job-master`**. **One approval appears, not thirteen.** Read what it says. **The
      finding is an approval that lists thirteen rows, one per folder** — it should describe the work
      once and say how many folders it covers.
- [ ] **(SONNY-235)** Approve it and watch the widget while it runs. **A line under the job says how
      far it has got** — "1 of 13 folders done", climbing. **The finding is no line at all, a line
      that never changes, or a count that is wrong.** (It will not say "13 of 13" at the very end; the
      last unit of a run is deliberately not reported, so it stops one short and the summary settles
      it. That is expected, not a finding.)
- [ ] **(SONNY-235)** Read the final summary. **It names both halves** — how many folders were done
      *and* that one could not be, naming the empty folder. **The finding is a flat "Done" that says
      nothing about the thirteenth**, or a flat failure that hides the twelve that worked.
- [ ] **(SONNY-235)** Ask for the same work over **`~/Desktop/job-master copy`**, and open Command
      Center while it runs. **The running line there shows the same count as the widget**, and a
      **Cancel** beside it. **The finding is the two surfaces disagreeing**, or Command Center showing
      no count.
- [ ] **(SONNY-235)** Ask for the same work over **`~/Desktop/job-master copy 2`** and press
      **Cancel** part-way. **It stops.** **The finding is Sonny carrying on through the remaining
      folders**, or reporting the ones it never reached as failures. (If it finishes before you can
      press Cancel, you are pointing at a folder an earlier row already converted — use a fresh copy.)
- [ ] **(SONNY-235)** After cancelling, look at the widget when it next opens, and at
      **Command Center → Memory → Unfinished tasks**. **The cancelled job is not offered to continue**
      — cancelling means the user stopped it, and offering it back is the product arguing with them.
      (A job stopped by *quitting the app* is a different case and **is** offered; that is the last
      row in this section.)
- [ ] **(SONNY-235)** Point the request at a folder that contains **nothing at all** — make an empty
      one anywhere. **Sonny says there is nothing to work through, in plain words, and asks for no
      approval.** **The finding is a prompt to approve a job over nothing**, or a technical error.
- [ ] **(SONNY-235)** Ask for the same work over a folder holding **more than fifty** subfolders.
      **Sonny refuses and says how many it will take.** **The finding is Sonny starting anyway**, or
      quietly doing the first fifty without saying so.
- [ ] **(SONNY-235)** **The one this ticket is named for, and it needs its own untouched copy.** Ask
      for the work over **`~/Desktop/job-master copy 3`**, approve it, let the progress line reach
      two or three, then **quit Sonny outright** (menu bar → Quit, not Cancel). Relaunch it. **The
      widget offers to continue that job.** Press Continue. **The finding is any of these:** no offer
      at all; an approval prompt listing one row per remaining folder rather than describing the job
      once; no progress line while it runs; a progress line counting the *whole* job rather than what
      is left (say "0 of 13" instead of "0 of 10"); or a final summary claiming it worked through all
      thirteen when it only did the ones that were left. **Sonny should not redo the folders it
      already finished** — their PDFs' modified times should still be from before you quit.
- [ ] **(SONNY-235)** **Not a pass/fail row — tell us what you saw.** In that same resumed run, was
      the **empty folder** mentioned anywhere in the final summary? It was named in the first run's
      summary as one that could not be done; whether the *resumed* run should name it again is an
      open question the founders are deciding (PR #185's R1), and what a real run says is the input to
      that decision. Report the exact sentence either way.

### Starting and stopping a watcher yourself (new 2026-08-31, SONNY-382)

**These rows finish the section above, from the other end.** SONNY-236's rows start from a watcher
seeded by hand in `AppDelegate.swift`, because at that point nothing in the product created one.
This ticket builds the two halves that make a watcher a feature a person can use: **asking Sonny to
start one**, and **the Routines page's Watching card with its Stop control**. So delete that seeding
snippet before you start here — a watcher you asked for is the thing under test.

**Run these in the same build as the section above, with the same two constants shortened.** Nothing
here needs a third build:

- `checkInterval: 15 * 60` → `checkInterval: 30`
- `maxLifetime: 7 * 24 * 60 * 60` → `maxLifetime: 600`

and a packaged build for the same reason (`./scripts/package-app.sh`, then open
`.build/arm64-apple-macosx/debug/MacAgent.app`) — without bundle identity there is no notification
path at all, so the last row would look broken while being fine.

**Two numbers on screen come out of that shortened build looking odd, and neither is a finding.**
Both are stated here rather than left to be discovered, because the section above had two rounds of
manual rows whose arithmetic did not compose.

- **The approval says "Checks every 1 minute", not "every 30 seconds".** It renders
  `max(1, round(checkInterval / 60))`, exactly as the expiry notice renders
  `max(1, round(maxLifetime / 86400))` — the same rounding you were told about for "1 day" in the
  section above. At the **shipped** value it reads "every 15 minutes" and is exact. Seeing "every 15
  minutes" here **would** be the finding: it would mean the number is coming from somewhere other
  than the constant you edited.
- **The approval says "for up to 1 day", and the Routines row says "until \<today's date\>".** Both are
  the same ten-minute lifetime seen through different formatters — the notice rounds to days, the row
  prints the actual expiry date, which at ten minutes is today. They are not contradicting each
  other.

**One rule governs every row below, and it is the one thing that makes them composable.** In this
build a watcher **stops by itself ten minutes after you started it**, notifies you that it did, and
disappears from the card. That is row 7's whole subject and it is background noise in every other
row. So:

- **Start each row with the Watching card empty**, and press Stop on anything left over from the row
  before. A "Sonny stopped watching …" banner arriving in the middle of the Stop row or the
  three-minute wait is a *previous* row's watcher expiring on schedule, not a finding.
- **A row that starts a watcher is finished within a few minutes of starting it.** If you break off
  and come back later, the watcher is gone and the row is measuring nothing.
- **Sonny checks one watcher per pulse.** With one watcher alive it is looked at every 30 seconds;
  with five alive each one is looked at roughly every two and a half minutes. Every "wait n minutes"
  below assumes **one** watcher, which the first rule already gives you.

*(This paragraph is PR #187's F3. Row 8 used to ask for five watchers and then a sixth with no window
stated, and five ask-and-approve cycles take long enough that the first watcher can expire before the
sixth ask — the sixth is then accepted, correctly, and reads as the cap failing. That section's
arithmetic had already been wrong twice; this is the third and every row was re-derived, not just
that one.)*

- [ ] **(SONNY-382)** In the widget, ask Sonny in your own words to **tell you when a page changes** —
      "tell me when https://… changes", pointed at a page you can edit. **An approval appears before
      anything happens.** Read it: it names **the page**, a line beginning **Watching for:** with
      your own phrase after it, and the cadence line above. **The finding is no approval at all**, or
      an approval that does not say the page will be fetched repeatedly — a watcher's real cost is a
      week of requests to somebody else's server, and that is what the panel is for.
- [ ] **(SONNY-382)** Approve it, then open **Command Center → Routines**. **A second card headed
      "Watching" is below the routines card**, with one row: your own phrase on the first line, and
      **the page's host and the day it stops by itself** on the second. **The finding is a watcher
      listed among the routines** rather than in its own card, or a row that says only what is being
      watched — a row that never mentions the watcher ending would make Stop read as the only way out.
- [ ] **(SONNY-382)** Look at that card again with **no watcher running** (before this run, or after
      the Stop row below). **The card is not there at all** — no empty state, no explanation of what
      a watcher is. **The finding is a permanent "no watchers yet" panel** on a page most sessions
      will never start one from.
- [ ] **(SONNY-382)** Press **Stop** on that row, **within a few minutes of starting it**. **It goes
      immediately, with no confirmation dialog** — asking to confirm a Stop is friction on the one
      control this whole ticket exists to provide, and nothing is destroyed: you can ask for the
      watcher again. The card disappears with the last row. **No notification appears**: you pressed
      the button, so Sonny has no news for you. (If a banner does appear, check it is not a *ten
      minutes are up* notice for this same watcher — that is row 7, and it means you waited too long
      rather than that Stop is noisy.)
- [ ] **(SONNY-382)** **The row that proves Stop actually stopped it**, and it needs the edit to come
      *after* the press. Start a watcher, press **Stop**, and only then **change the watched page and
      leave it changed**. Wait **three minutes** — comfortably more than the two checks a change
      needs at a 30-second interval. **Nothing arrives, ever.** A notification here means the record
      is still being checked, which is the exact failure a Stop control that does not stop would have.
- [ ] **(SONNY-382)** Start a watcher by asking, then **change the page within a minute or two and
      leave it changed**, and this time let it run. Within about **a minute or two** of the edit (it
      takes two checks 30 seconds apart, and the first of them can be up to 30 seconds after you
      save) the notification arrives reading
      **“\<your phrase\>” changed.** Then open **Routines**: **the Watching card is gone** — the
      watcher fired and deleted itself. This is SONNY-236's first row re-run from the creation end,
      and the new half is the card agreeing with the notification.
- [ ] **(SONNY-382)** **The other ending, beside Stop.** Start a watcher on a page you leave alone and
      **do not touch anything for ten minutes** — allow it a minute over, since the lifetime is
      noticed on the next 30-second pulse rather than to the second. A notification says Sonny
      stopped watching it, and **the Routines card is gone without you pressing anything**. The point
      of this row is the pair: a user meets two ways a watcher ends, and the page has to be right
      about both.
- [ ] **(SONNY-382)** **The cap, from the user's side — and read the next sentence before you
      start.** Watchers stop by themselves after ten minutes in this build, so what this row needs is
      five alive **at the same moment**, not five started. Work briskly, and then **open Routines and
      count the rows in the Watching card immediately before the sixth ask: there must be five.**
      That count, not the clock, is what makes the row valid.
      Start **five** watchers by asking — any five public pages. Check the card says five. Then ask
      for a **sixth**. **Sonny refuses and says you already have five**, and **no approval appears
      for it** — the refusal must arrive *before* you are asked to approve something that is then
      declined underneath you. Routines still lists exactly five. **If the sixth is accepted, look at
      the card again before reporting it**: four rows there means one expired while you were working
      and the acceptance was correct — press Stop on the rest and run the row again, faster. Five
      rows there and a sixth accepted is the finding.
- [ ] **(SONNY-382)** **Not a pass/fail row — tell us what you saw.** Ask Sonny to **save a routine
      that watches a page** ("create a routine called price check that tells me when … changes").
      Sonny must not end up with a saved routine containing a watch step — a scheduled routine would
      start a new watcher on every run until the cap refused. What we want to know is *how* it
      declines: a clarifying question, a plain refusal, or something confusing. Report the exact
      words.
- [ ] **(SONNY-382)** **Not a pass/fail row — tell us what you saw.** The same question at the other
      repetition door (PR #187's F1). Ask for something like **"for each folder on my Desktop, show it
      in Finder, and tell me when https://… changes"**. Sonny must not start a watcher per folder —
      five identical watchers of one page would spend the whole cap on duplicates. It should either
      never build that shape, or refuse it saying to ask for the watcher on its own. Report which of
      the two happened and the exact words, because whether a planner ever produces this shape is the
      one thing no test can answer.


### SONNY-406 — the attribution refusal (no app build needed; these are terminal checks)

These are the only rows on this checklist that a founder runs in a terminal rather than in the
packaged app, and there is a reason they cannot be automated away: the selftest proves the two
hooks refuse what they are handed, and nothing it can do proves that Claude Code actually *invokes*
the PreToolUse hook. That is `.claude/settings.json`'s wiring plus the harness's own behaviour, and
a founder watching one commit be refused is the only evidence of it there is.

- [ ] **The git-level refusal fires in a real checkout** (SONNY-406). In any worktree, run
      `scripts/no-attribution selftest` — expect exit 0 and every line `ok`. Then make a throwaway
      commit whose message ends with a co-author line naming Claude (any address). Git must refuse
      it, print `commit-msg: REFUSED`, and **make no commit** — check `git log -1` is unchanged.
      Then commit the same change with an ordinary message and confirm it succeeds. The second half
      matters as much as the first: a guard that refuses everything looks identical to a working one
      on the first check alone.
- [ ] **The session-level refusal fires inside Claude Code** (SONNY-406). This is the row nothing
      else can cover. In a Claude Code session in this repository, ask it to make a commit with a
      co-author trailer naming Claude. The tool call must be **blocked before it runs**, with
      `REFUSED:` and the rule's wording, rather than the commit happening and git catching it
      afterwards. If it is git that refuses rather than the session, the PreToolUse wiring in
      `.claude/settings.json` is not live — report that, because the selftest cannot see it.
- [ ] **`core.hooksPath` is installed rather than remembered** (SONNY-406). In a **fresh** worktree
      (`git worktree add`), run `git config --get core.hooksPath` — it may print nothing. Let a
      Claude Code session make any ordinary commit there, then run it again: it must print
      `.githooks`. This is the answer to "a committed hook only works if something sets that
      config"; if it stays empty, the git layer is not armed in new worktrees and the whole guard is
      one layer thinner than it reads.
- [ ] **An ordinary commit is not slowed or blocked** (SONNY-406). Make three or four normal commits
      across a session and confirm none is refused and nothing new appears in the output. The class
      is a set of attribution shapes, not the word "Claude" — a commit message that *discusses*
      CLAUDE.md, Claude Code sessions, or this very rule must commit without complaint. If an
      ordinary commit is ever refused, say so immediately: a guard that cries wolf is one that gets
      switched off, which is how this rule failed the first time.

### Delete a task and the server's copy goes with it (new 2026-09-03, SONNY-333)

**What changed:** pressing *Delete task* used to remove the task from this Mac and leave the copy the
backend had kept. It now removes both. The founder rule of 2026-08-16 is that delete means deleted
everywhere; the endpoint has existed since SONNY-134 and nothing pressed it, so the rule was true of
the endpoint and not of the button.

**How it works, because two of the rows below only make sense with it.** The button never waits on
the network. Sonny writes the task's id to a small queue on disk *before* it deletes anything local,
deletes the local records, and then tries to send the delete in the background. If that fails — you
are offline, or signed out — the id stays in the queue and Sonny tries again the next time it
launches. **So a row below asks you to quit and reopen the app; that relaunch is the mechanism, not
a workaround.**

**Three of these four rows need a signed-in build against a running gateway**, which is the same gate
SONNY-134's rows above sit behind (SONNY-280's resume checklist, steps (1)–(5)). The first row needs
nothing but the app.

- [ ] **(new 2026-09-03, SONNY-333) — needs only the app. Do this one first.** In Command Center
      &rsaquo; Tasks, right-click any finished task and choose *Delete task*, then confirm. The row
      must disappear **immediately** — no spinner, no pause, no "deleting…" — and **no red error and
      no storage banner may appear anywhere**, in Command Center or on the floating widget. Do it
      again on a task that has a *What Sonny did on screen* section, using the delete inside the task
      detail sheet. **What would be a finding:** any delay you can feel between the press and the row
      going, or any message appearing that you did not press for. This row is the founders' own
      decision of 2026-08-30 being kept: the button is never blocked on the network, and a delete
      that could not reach the server is never reported as an error, because there is nothing you
      could do about it.

- [ ] **(new 2026-09-03, SONNY-333) — after SONNY-280's resume steps (1)–(5). The headline row.**
      Signed in, with the gateway running, run **one ordinary task** (a typed command that reaches
      the planner). Confirm the backend kept it: `npm run support -- account <your account id>` must
      show `content` with **at least one call retained**. Now delete that task from Command Center
      &rsaquo; Tasks and wait about five seconds. Re-run the account report: `content` must be back
      to **0 call(s) retained**, and `npm run support -- deletions` must show a `task` row naming
      that task. **What would be a finding:** content still retained a minute later, or no row in
      `deletions`.

- [ ] **(new 2026-09-03, SONNY-333) — after SONNY-280's resume steps (1)–(5). The offline row, and
      the one that tests the part you cannot see.** Run a task while signed in, as above, and check
      the account report shows it retained. Then **turn Wi-Fi off**, delete that task from Command
      Center, and watch what happens: the row must still disappear at once and there must still be
      no error and no banner. **Quit Sonny completely** (menu bar &rsaquo; Quit Sonny), **turn Wi-Fi
      back on**, and open Sonny again. Wait about ten seconds, then re-run
      `npm run support -- account <your account id>`. `content` must now be back to **0 call(s)
      retained** — the delete you made with no network reached the server at the next launch.
      **What would be a finding:** an error at any point, or content still retained after the
      relaunch.

- [ ] **(new 2026-09-03, SONNY-333) — after SONNY-280's resume steps (1)–(5). Signed out.** Sign out
      from the menu bar, then delete a task that ran **while you were signed in**. It must delete
      exactly as smoothly as the rows above — no error, no banner, no prompt to sign in. Sign back in
      as the same person, quit and reopen Sonny, wait about ten seconds, and re-run the account
      report: that task's content must be gone. **What would be a finding:** anything asking you to
      sign in in order to delete something, or content still retained after signing back in and
      relaunching.

**One thing deliberately not built, so no row asks you to look for it.** *Delete Sonny local data* in
Settings, the *Delete* on Command Center &rsaquo; Memory &rsaquo; Task history, and *Delete what
Sonny did on screen* all still stop at this Mac. They are SONNY-404's, and the first of them needs a
founder decision before it is even implementable — whether that wipe is a promise about this Mac or
about the whole account.
- [ ] **(SONNY-395)** **The suite no longer opens Finder windows — and this is the row that proves
      the fix did not simply switch the feature off.** Two halves, in this order.
      **First, the product still reveals.** In the packaged app, run a command that ends in a reveal
      ("zip the largest files on my Desktop and show me the zip in Finder", or anything with "show
      it in Finder" at the end). A real Finder window must open with the file selected — that is the
      whole feature, and this branch moved the line that performs it, so a founder pressing it is
      the only proof there is. The **Reveal in Finder** control in Command Center's task/result
      surfaces must still work too.
      **Second, a suite run must open nothing.** With the app quit, run the flagged test command
      from `CLAUDE.md` and watch the screen for the whole run. Before this branch a run opened
      **four** Finder windows on `$TMPDIR` — measured, not estimated — and a mutation battery
      multiplied that by the number of mutants, which is how they arrived dozens at a time. Zero
      windows now. **Report the count you saw, even if it is zero**, because a zero somebody
      watched for is worth more than a zero nobody looked at.

### The other three delete buttons reach the server too (new 2026-09-05, SONNY-404)

**What changed.** SONNY-333 made *one* button keep the founder rule that delete means deleted
everywhere. Three other deletions still stopped at this Mac, and the founders settled all three:

- **Settings &rsaquo; Data &rsaquo; Delete Sonny local data** is a promise about **the account**, and
  now says so. It deletes what this Mac holds *and* what Sonny's servers keep for the account, and
  **your account stays open**. *(This bullet said the opposite for part of 2026-09-05 — "stays a
  promise about this Mac" — under a reversal both founders undid the same day. Corrected 2026-09-05.)*
- **Command Center &rsaquo; Memory &rsaquo; Task history &rsaquo; Delete** now deletes every row's
  backend copy too, in **one** request naming all of them rather than one request per row.
- **Delete what Sonny did on screen** now deletes that task's screenshots from the backend — and
  only the screenshots. There is a new, narrower route for it, because the per-task delete would
  have taken the command text and the model's replies with them, which is more than that button
  says.

**All five rows below need a signed-in build against a running gateway**, the same gate SONNY-134's
and SONNY-333's rows above sit behind (SONNY-280's resume checklist, steps (1)–(5)). Reuse the same
gateway and the same account. One of them needs a gateway you can stop, and one needs a **second**
account you can sign in as.

- [ ] **(new 2026-09-05, SONNY-404) — needs a local gateway. Delete what Sonny did on screen.** Run a
      screen-control task so Sonny actually does something on screen, then open that task in Command
      Center &rsaquo; Tasks and check `npm run support -- account <your account id>` shows content
      for it. In the task's detail sheet press **Delete what Sonny did on screen**. **Read the
      confirmation before pressing Delete**: it must say the screenshots go from this Mac *and* from
      Sonny's servers, and that the task stays in your history. Confirm. Then look at the account
      report again: the screenshots for that task must be gone while the **task's own row, its
      command and the response are still there**. **What would be a finding:** the confirmation not
      mentioning the servers, the whole task disappearing from the report, or the *What Sonny did on
      screen* section still showing after the press.

- [ ] **(new 2026-09-05, SONNY-404) — needs a local gateway. Task history, one request.** Run two or
      three ordinary tasks so there are several rows, and confirm the backend kept them. Watch the
      gateway's log, then in Command Center &rsaquo; Memory press **Delete** on the **Task history**
      row and confirm. The log must show **one** `DELETE /v1/tasks` request, not one per task, and
      the account report must show nothing left for any of those tasks. **What would be a finding:**
      several delete requests instead of one, any task's content surviving, or a red error or storage
      banner appearing that you did not press for.

- [ ] **(new 2026-09-05, corrected 2026-09-05 after the fix round, SONNY-404) — needs a local
      gateway. The whole wipe is about the account, and says so.** *(This row asked the opposite for
      part of one day: the wipe was briefly built as a promise about this Mac, and both founders
      restored the account reading. Run the row as it stands below.)* Run two or three ordinary tasks
      and confirm the backend kept them with `npm run support -- account <your account id>`. Open
      Settings &rsaquo; Data. The line under **Delete Sonny local data** must end "**from this Mac and
      from Sonny's servers**". Press Delete and **read the confirmation before confirming**: it must
      say the same thing, then say what happens if Sonny can't reach the servers right now, and then
      name **your account** among the things it does *not* delete, beside generated files and API
      keys. Confirm it. The message that appears must say the copy on Sonny's servers is deleted
      too. Then check the account report: **nothing** the backend kept for those tasks may be left,
      and **you must still be signed in and able to run a task** — the account stays open. **What
      would be a finding:** either sentence still saying only "from this Mac", the confirmation not
      mentioning what happens when the servers are unreachable, any of the backend's copies
      surviving, or being signed out afterwards.

- [ ] **(new 2026-09-05, SONNY-404) — needs a local gateway you can stop. The wipe never fails
      silently.** Run one ordinary task and confirm the backend kept it. Now **stop the gateway** (or
      turn off Wi-Fi) and press **Delete Sonny local data**, confirming it. The message must say, in
      plain words, that Sonny couldn't reach its servers, that their copy is **still there**, and
      that Sonny deletes it the next time it can — never just "Deleted N local data files." Start the
      gateway again, quit Sonny and reopen it, then check the account report: that task's content
      must now be **gone**, deleted by the sweep at launch. **What would be a finding:** a message
      that says only how many local files went, or the backend's copy still being there after the
      relaunch.

- [ ] **(new 2026-09-05, SONNY-404) — needs a local gateway you can stop and a second account. The
      wipe never deletes somebody else's data.** Signed in as account **A** with the gateway running,
      run one ordinary task and confirm the backend kept it. **Stop the gateway**, press **Delete
      Sonny local data** and confirm it; the message must say the servers' copy is still there. Now
      **start the gateway**, sign out of A, and **sign in as a second account B** that has run at
      least one task of its own (confirm with the account report that B's content is there). Quit
      Sonny and reopen it. **B's content must still be there, untouched.** Then sign back in as A,
      quit and reopen, and A's content must now be gone. **What would be a finding:** any of B's
      content disappearing — that is one user's press deleting another user's everything, which is
      what this row exists to catch.

### The fourth unfinished-task control, and the words that told it apart (new 2026-09-06, SONNY-426)

**What changed, and what deliberately did not.** SONNY-404 made three delete buttons reach the
servers. A fourth control was filed as a candidate — Command Center &rsaquo; Memory &rsaquo;
Unfinished tasks &rsaquo; **Delete** — and the answer is that it reaches no server, because an
unfinished task's saved progress is not something Sonny's servers ever held under a name this Mac
still knows. Nothing about what any button sends changed. **What changed is one sentence.** The
confirmation on that Delete used to read *"Sonny stops offering to carry on with this task"*, which
is exactly what the widget's **&times;** promises — and the &times; deliberately keeps the task, so
the one control that throws an unfinished task's work away was describing the effect of the one that
does not.

**These rows need no gateway and no account** — nothing here talks to a server, which is half of what
they are checking.

- [ ] **(new 2026-09-06, SONNY-426) — needs only the app. The Delete says the work goes.** Start a
      task that will not finish (the easiest is to ask Sonny to open a page and quit the app while it
      is running), reopen Sonny, and go to Command Center &rsaquo; Memory &rsaquo; **Unfinished
      tasks**. Press **Delete** on the row and **read the confirmation before pressing anything
      else.** Expected: it says *"This deletes the unfinished task, so Sonny can't carry on with it.
      Anything it already did is not undone."* Confirm, and the task is gone from the list. **What
      would be a finding:** a confirmation that only says Sonny stops offering — that is the old
      wording, and it describes the &times; rather than this press.
- [ ] **(new 2026-09-06, SONNY-426) — needs only the app. The two controls still say different
      things, and still do different things.** Leave a second unfinished task in place. When the
      widget offers to carry it on, hover the **&times;** — the tooltip must read **"Don't ask
      again"** — and press it. Relaunch Sonny. Expected: the offer never comes back for that task,
      **and the task is still listed under Memory &rsaquo; Unfinished tasks**, where Continue and
      Delete both still work. **What would be a finding:** the &times; removing the task from that
      list. That would make it a delete with no undo, which is the thing the 2026-08-25 decision was
      taken to prevent.

### Renaming one file, and being asked first (new 2026-09-04, SONNY-385)

**Why these rows exist.** Renaming is destructive — it replaces a name the user chose, and nothing in
Sonny puts it back — so the consequence rule says Sonny asks, and an approval prompt is the one thing
no agent can see. The other two rows are decisions rather than plumbing: a rename onto a name already
in use **fails and says which file is in the way** rather than overwriting it, and "rename all of
these" **asks what the new names should be** rather than inventing a rule for a bulk rename that
cannot be undone (founder decision, 2026-09-03).

**Set up (under a minute).** In `~/Desktop`, make a folder called `rename-check`. Put three files in
it: `scan1.pdf`, `scan2.pdf` and `invoice-march.pdf` — any files will do, and the extensions matter
only so the third one collides with what row 2 asks for. Open the packaged app.

- [ ] **(SONNY-385)** **A single rename, and the ask.** Say or type: *"rename
      ~/Desktop/rename-check/scan1.pdf to march-scan"*. **Sonny must ask before doing it** — an
      approval prompt, not a run that has already happened. Read the reason it gives: it should say
      that renaming replaces the name the file is filed under and that Sonny cannot undo it, and it
      should name **both** the old name and the new one. Approve it. `scan1.pdf` is now
      `march-scan` in the same folder, with its contents intact, and nothing else in the folder has
      moved. **What would be a finding:** no prompt at all; a prompt that names neither name; the
      file landing in a different folder; or the file arriving empty.
- [ ] **(SONNY-385)** **A collision, which must not overwrite.** Say or type: *"rename
      ~/Desktop/rename-check/scan2.pdf to invoice-march.pdf"* — a name that folder already has.
      Sonny must **refuse**, and the message must name `invoice-march.pdf` as the thing already
      there and say it will not replace it. Then open `invoice-march.pdf` and confirm its contents
      are unchanged, and that `scan2.pdf` is still called `scan2.pdf`. **What would be a finding:**
      the original `invoice-march.pdf` being replaced by the other file's contents; a refusal whose
      message names no file; or a refusal that arrives only *after* an approval prompt, since there
      is nothing here to approve.
- [ ] **(SONNY-385)** **"Rename all of these" asks rather than guessing.** Say or type: *"rename all
      the files in ~/Desktop/rename-check"*. Sonny must come back with a **question you can answer**
      — the clarification panel, with a field to type into — asking what each one should be called
      and saying it renames one at a time. Confirm **nothing in the folder has been renamed**, and
      that the field really is there and typeable. Then answer it with a single rename, **spelling
      the whole path the way the two rows above do** — *"rename ~/Desktop/rename-check/scan2.pdf to
      scan-two"* — and confirm that goes through the ordinary approval above. A bare `scan2.pdf`
      here would be resolved against your home folder, land on `~/scan2.pdf`, and be refused for
      being outside the folders Sonny is allowed to touch, which is a refusal about the path and not
      about this feature. **What would be a finding:** the files being renamed to anything at all; a
      plain red error instead of a question; or a question with no way to answer it.

### Moving to a new Mac with Migration Assistant (new 2026-09-05, SONNY-422)

**Why these rows exist.** Sonny is not going to ship a backup-and-restore button in v1 (founder
decision 2026-09-05, on SONNY-253). The design that was going to do it needed a password, and
Sonny's sign-in — an email code, Google, Apple — never gives the app one. So moving to a new Mac is
Apple's Migration Assistant's job, and these rows are what turn "it should work" into "we watched it
work". Everything you have made in Sonny sits in two places: the files under
`~/Library/Application Support/Sonny/`, and one 32-byte key in your login keychain that those files
are encrypted with. **Both have to arrive, and the key is the one that matters** — without it every
file is unreadable noise, and there is no second copy of it anywhere.

**What the code says should happen, so you are confirming a prediction and not guessing.** Sonny
writes three things into the keychain, and it sets no attribute on any of them that would pin them
to one machine — nothing marked "this device only", nothing marked to sync through iCloud. They go
into the ordinary login keychain, which is exactly what Migration Assistant carries across. So the
expected result is the boring one: **everything is there, and you are still signed in.** If any row
below fails, that is a real finding and worth stopping on — it means something in that chain is not
what the code reads like.

**Set up (do the first part before you migrate — afterwards is too late).** On the **source Mac**,
open Sonny and make sure there is something of each kind to count: at least two routines, at least
one workspace, at least one snippet, and a handful of finished tasks in Task history. Be signed in.
Then go to **Command Center → Memory** and **write down the number on every row** — Routines,
Workspaces, Task history, Recent artifacts, Output locations, Clipboard history, Snippets, Allowed
apps, Unfinished tasks. Note the email address you are signed in as. Quit Sonny properly (not just
close the window). Then set up the **second Mac** and run **Migration Assistant on it**, pulling
from the source Mac, with the user account included. Install and open Sonny there.

- [ ] **(SONNY-422)** **The app opens on the new Mac with nothing broken.** Open Sonny on the new
      Mac and let it settle. There must be **no banner saying a local data file "could not be
      decrypted or decoded"**, and no Memory row reading **"Can't be read"**. Click through Tasks,
      Routines, Workspaces and Memory so each one actually loads its files rather than sitting
      unopened. **One thing that is not a finding but please tell me if it happens:** macOS may ask
      for your login password once, saying Sonny wants to use a key stored in your keychain. That is
      the operating system checking that this copy of the app is allowed to read the migrated key,
      not Sonny failing. Allow it and carry on — but write down that it happened, and which button
      you pressed, because it changes what we tell a real user to expect. **What would be a
      finding:** the "could not be decrypted or decoded" banner; any Memory row saying "Can't be
      read"; a page that stays empty when the source Mac had things on it; or the app refusing to
      open at all.
- [ ] **(SONNY-422)** **Your things are all there, and there are the same number of them.** On the
      new Mac, count what you can see: routines on the **Routines** page, workspaces on
      **Workspaces**, finished tasks in **Task history** on the Tasks page, and snippets on the
      **Memory** page's Snippets row. Every one of those must match what you wrote down on the
      source Mac. Open one routine and one workspace and check the inside of them too — the names,
      the steps, the apps they point at — not just that a row exists. **What would be a finding:**
      any count lower than the source Mac's; a routine or workspace that opens empty or with its
      steps missing; or anything present but renamed to something you did not choose.
- [ ] **(SONNY-422)** **The Memory section's own counts match, row for row.** Go to **Command Center
      → Memory** on the new Mac and compare all nine rows against the numbers you wrote down:
      Routines, Workspaces, Task history, Recent artifacts, Output locations, Clipboard history,
      Snippets, Allowed apps, Unfinished tasks. They are a separate reading from the pages in the
      row above — the pages show you the things, these rows count the files — so both are worth
      checking. A row reading **0 saved** where the source Mac had a number is a finding on its own,
      and so is a row that says **"Can't be read"**. **What would be a finding:** any row whose
      number is different from the source Mac's, in either direction.
- [ ] **(SONNY-422)** **You are still signed in — this is the prediction, please confirm or break
      it.** The reading of the code says the signed-in session travels with everything else, because
      it is held in the same login keychain with the same absence of any device-pinning attribute.
      **So the expected result is that Sonny opens already signed in, as the same email address you
      noted on the source Mac, with no sign-in screen.** Check the account menu shows that address.
      Your plan and your remaining screen-control runs should also be intact, since those are held
      the same way. **What would be a finding — and this one is genuinely useful either way:** being
      shown the sign-in screen and asked to sign in again. That would not be data loss and nothing
      would be broken, but it would mean the prediction above is wrong, and we would want to know
      before a real user meets it rather than after.

### Gateway hardening — two auth doors (new 2026-09-05, SONNY-311 and SONNY-322)

**Every row here waits on a deployed gateway (SONNY-192), and that is stated rather than left to be
discovered.** Both changes are server-side, in a gateway that runs nowhere yet: `./scripts/deploy.sh
staging` and `production` are still stubs that exit 3. Nothing in the packaged Mac app changed and
nothing about these rows can be checked by opening it, so **please do not attempt them until a host
exists** — an attempt now would either exercise nothing or exercise a local container, which is not
what these rows are asking about. They are written down now so that whoever runs the first real
deployment has them, rather than reconstructing them later from a ticket.

- [ ] **(SONNY-311, waits on SONNY-192)** **Signing out while the login service is unreachable says
      so, instead of blaming Sonny.** Against a deployed gateway whose Supabase project is
      unreachable (block it at the network, or point the gateway at a project reference that does not
      resolve), press **Sign out** in the app. Expected: you are signed out **on this Mac** — that
      half is unconditional and must still happen — and the failure is reported as Sonny not being
      able to reach the login service, not as something going wrong on Sonny's side. **What would be
      a finding:** being told an internal error occurred, or being left apparently signed in.
- [ ] **(SONNY-311, waits on SONNY-192)** **The same for a session refresh.** With the same gateway,
      leave the app running until it next refreshes its session (or force it by waiting out the
      access token's hour). Expected: the same "could not reach" character of message, and a retry
      that succeeds once the provider is reachable again. **What would be a finding:** the app
      signing you out and sending you to the sign-in screen — a temporary outage must not cost you
      your session.
- [ ] **(SONNY-322, waits on SONNY-192)** **A stalled upload gives up instead of hanging forever.**
      This one is a terminal check against the deployed gateway rather than an app action, because no
      app control can produce it. Open a request to `POST /v1/transcriptions` that sends its headers
      and then stops sending the body — `curl` with `--limit-rate 1` against a few megabytes will do
      it, or `nc` with a hand-written multipart preamble and no ending. Expected: the connection is
      refused after about **ninety seconds** with a `408`, the JSON body has the same shape every
      other Sonny error has — an `error` object with `code`, `message`, `retryable`,
      `retry_after_seconds` and `request_id` — and that `code` reads **`request.timeout`** with
      `retryable: true`. **What would be a finding:** the connection sitting open indefinitely; a
      reply whose body has a `statusCode` field at the top level, which would mean the framework
      answered rather than Sonny; or a `code` of `request.invalid`, which is the malformed-request
      code and the thing PR #208's review caught — it tells the app not to retry a condition a retry
      would clear.
- [ ] **(SONNY-322, waits on SONNY-192)** **A malformed request is not told it was too slow.** Same
      terminal, same deployed gateway. Send a request with a header name containing a space —
      `printf 'GET /v1/health HTTP/1.1\r\nHost: h\r\nBad Header: x\r\n\r\n' | nc <host> <port>`.
      Expected: `400 Bad Request` with `code` `request.invalid`. **What would be a finding:** a `408`,
      or the words "not delivered in time" — a statement about something that did not happen, which
      is what this answered before the fix round.
- [ ] **(SONNY-322, waits on SONNY-192)** **An ordinary voice command still works, and is not the
      thing that got cut off.** The bound above is 90 seconds for the upload itself — raised from 30
      by the founders on 2026-09-05, precisely so this row is unlikely to fail. On a normal
      connection, hold the push-to-talk hotkey, say a real command of a few seconds, and let it run.
      Expected: it transcribes and acts exactly as before. Then, if you can, try the same on a
      deliberately poor connection (macOS Network Link Conditioner, or a phone hotspot with one bar).
      **What would be a finding:** a normal-length command failing on a slow connection. That is the
      one way this change could hurt a real user, and it is the row worth spending the most care on.
### A slow database cannot hold a request open (new 2026-09-07, SONNY-427)

**Both rows wait on a deployed gateway (SONNY-192), for the same reason the gateway-hardening rows
above do**: this change is entirely server-side, `./scripts/deploy.sh staging` and `production` are
still stubs that exit 3, and nothing in the packaged Mac app changed. **Please do not attempt these
until a host exists** — trying now would exercise either nothing or a local container, which is not
what they ask about. They are written now so whoever runs the first real deployment has them.

- [ ] **(SONNY-427, waits on SONNY-192)** **A request behind a stuck database transaction gives up
      instead of hanging forever.** A terminal check rather than an app action, because no app
      control can produce it. Against the deployed gateway's database, open a `psql` session and run
      `BEGIN; LOCK TABLE sonny.identity IN ACCESS EXCLUSIVE MODE;` — and leave it open. Now make any
      signed-in request from the app, or `curl` any authenticated route with a valid token. Expected:
      an answer within roughly **ten seconds**, with the same JSON shape every other Sonny error has
      — an `error` object with `code`, `message`, `retryable` and `request_id` — and that `code`
      reading **`server.error`** with `retryable: true`. Then `ROLLBACK` in the `psql` session and
      make the same request again. Expected: it succeeds normally. **What would be a finding:** the
      request sitting open for as long as you leave the lock held, which is what happened before this
      change and is the whole thing it exists to stop; or the gateway still answering slowly after
      the `ROLLBACK`, which would mean a connection came back from the pool damaged.
- [ ] **(SONNY-427, waits on SONNY-192)** **A migration still gets as long as it needs, checked with a
      migration that actually takes long.** The bound above is deliberately *not* applied to the
      migration runner, and this is the row that says so. **Applying the migrations already in the
      tree proves nothing here** — every one of them finishes far inside ten seconds, so they would
      pass whether the bound reached the runner or not, which is a check that cannot fail. So make one
      that would trip it: add a scratch migration whose `up` is `SELECT pg_sleep(12);` and whose
      `-- @rollback` section is `SELECT 1;`, run `npm run build` and then `npm run migrate -- up`
      against staging, and afterwards `npm run migrate -- down` and delete the file. Expected: the
      `up` takes about twelve seconds and **succeeds**. **What would be a finding:** it failing after
      about ten seconds with a message about a statement being cancelled — that would mean the bound
      reached the runner, and a real backfill would be impossible to deploy.

### Sonny refuses to drive a window showing a shell, even when the recognizer misreads it (new 2026-09-05, SONNY-277)

**Needs a packaged build and screen control**, the same as every other screen-control row. What is
being checked is a *refusal*, so the pass condition is Sonny declining to act — and Sonny is not
allowed to explain why, so the only thing you will see is that it stops.

The reason this row exists: the check reads the text the on-device recognizer returns, and at small
font sizes that recognizer reads a terminal's `%` prompt sigil as a **section sign** (§). Measured on
rendered panels, that happened at three of seven realistic capture sizes, and it took the whole
refusal with it. The fix is measured against rendered text; **a real screen at your real font size is
the thing no session can produce**, which is what makes this row worth a person's time rather than a
formality.

- [ ] **(SONNY-277)** **Refuse a small-font terminal.** Open a terminal — Terminal.app, iTerm, or a
      VS Code panel — and **set its font as small as you comfortably can** (9–12 pt is the range
      where this was measured; the smaller the better for this test). Have a prompt visible with a
      command or two of scrollback above it. Then ask Sonny to do something that needs screen
      control in that window. **Expected: Sonny does not act inside it.** **What would be a
      finding:** Sonny going ahead and clicking or typing in that window.

      **A pass here does not by itself confirm the fix, and the row says so rather than implying
      otherwise** (PR #209 review, F13). The misread this change is about may simply not happen on
      your screen — a Retina display captures a 12 pt font at 2×, so the recognizer may read the
      prompt perfectly and the panel then refuses through the ordinary path exactly as it did before
      this branch. Sonny is not allowed to say which of the two happened. So please **write down the
      font size, the display, and whether it is Retina** beside your result: a refusal at 9 pt on a
      non-Retina external monitor is evidence, and one at 12 pt on a built-in Retina screen is
      consistent with the fix never being exercised. Either is worth having; they are not the same
      reading.
- [ ] **(SONNY-277)** **The same terminal at a normal font size.** Repeat the row above with the font
      back at its usual size. **Expected: the same refusal.** This is the control — if the small-font
      case refuses and this one does not, something is wrong in the opposite direction from the bug.
- [ ] **(SONNY-277)** **An ordinary page still works.** Open a documentation page that *shows* shell
      commands — any install guide with `$ npm install` in it — and ask Sonny to do something needing
      screen control there. **Expected: Sonny acts normally.** **What would be a finding:** Sonny
      refusing, which would mean the check has started reading pages *about* shells as shells. A
      legal or academic page full of **§** section marks is the sharpest version of this test if you
      have one to hand, because the section sign is exactly what this change taught the check to
      read.

- [ ] **(SONNY-425, waits on SONNY-192)** **A sign-in whose provider stalls gives up in about
      fifteen seconds, not two minutes.** Against a deployed gateway whose Supabase project is
      unreachable — block it at the firewall, or point `SUPABASE_JWT_ISSUER` at a host that accepts
      a connection and never answers. From a terminal, time a refresh:
      `time curl -sS -i -X POST https://<host>/v1/auth/refresh -H 'content-type: application/json'
      -d '{"refresh_token":"anything"}'`. Expected: an answer inside roughly **fifteen seconds**
      carrying `504` and `code` **`provider.timeout`** with `retryable: true` — or `502`
      `provider.unavailable` at about ten seconds, which is the same wiring answering one layer
      earlier and is equally correct. **What would be a finding:** the request sitting for a minute
      or more before anything comes back, which is the 120-second delivery bound doing it instead;
      or a `500`, which would mean the answer never reached the deadline arm at all.
- [ ] **(SONNY-425, waits on SONNY-192)** **Asking for a sign-in code still says nothing when the
      provider stalls.** Same unreachable gateway. `curl -sS -i -X POST
      https://<host>/v1/auth/email/start -H 'content-type: application/json'
      -d '{"email":"you@example.com"}'`, then the same for an address that has never signed in.
      Expected: **both answer `200`**, with the same fields and the same `expires_in`, inside roughly
      fifteen seconds. **What would be a finding:** a `504` or any other status here — this route
      must answer identically whatever happens behind it, or it becomes a way to ask whether an
      address has an account.
- [ ] **(SONNY-425)** **Ordinary sign-in is untouched.** In the real packaged app, against a working
      gateway: sign out, sign in with an emailed code, let the session sit until it refreshes, and
      sign out again. Expected: exactly the behaviour you are used to, at the speed you are used to.
      **What would be a finding:** any sign-in step that now takes visibly longer, or a sign-in that
      fails where it used to work — the deadlines added here sit in front of every one of these
      calls, so this row is what says they bound only the failures.

- [ ] **(SONNY-425, waits on SONNY-192)** **Deleting an account still finishes, and still answers,
      when the provider is unreachable.** Against a deployed gateway whose Supabase project is
      blocked, sign in on a throwaway account and delete it from the app. Expected: the deletion
      completes and the app signs you out; the account is gone. It may take up to about fifteen
      seconds, which is the point — this route now waits for its own clean-up rather than answering
      early. **What would be a finding:** an error where the deletion used to succeed, or the app
      hanging for a minute or more. (The defect behind this row is invisible from the app: the route
      used to answer early and leave its clean-up writing to a database connection it had already
      handed back, which shows up as another request's data going wrong rather than as anything on
      this screen. PR #212's F1.)

- [ ] **(new 2026-09-06, SONNY-232; method corrected 2026-09-06, PR #216's review F4)** **A scheduled
      routine whose recent-artifacts note cannot be saved says so, and is not reported as a failed
      run.** **Lock exactly one file, not the folder** — the reason is below, and it decides whether
      this test can pass at all.
      1. Let a routine that **writes a file** run once normally, so the store exists. A routine with
         a *"create a local draft"* step is the easy one; a routine that only does arithmetic writes
         nothing, never asks this store to save anything, and cannot exercise this at all.
      2. Make that one store's file unwritable, leaving every other store alone:
         `chflags uchg ~/Library/Application\ Support/Sonny/recent-artifacts.json`
      3. Let the routine run on schedule again.

      **Expected:** the routine runs, the file it was asked to write is on disk, the scheduled-run
      notice still says *"… ran on schedule"*, **and** the storage notice in the app reads
      *"Sonny could not update its recent-artifacts list: …"*. **What would be a finding:** silence —
      no notice of any kind, which is exactly what this ticket fixes — or the opposite, the run being
      reported as *failed* when it did what it was asked. Undo with
      `chflags nouchg ~/Library/Application\ Support/Sonny/recent-artifacts.json`.

      **Why not `chmod 500` on the whole `Sonny` folder, which is what this row said until the
      correction:** the scheduled path has **four** bookkeeping write channels and they all publish
      through one property that keeps only the last value written. In order they are recent artifacts,
      output locations, this routine's run history, and the scheduled run's task-history row — every
      one of them a file in that same folder. Locking the folder fails all four, and the sentence
      left on screen is the **last** one, *"Sonny could not save this scheduled run to task
      history: …"*, not the one this row is about. (Outside the app you would get a burst of
      notifications, the first of which is the right one — so the old step could pass or fail on
      nothing but where you happened to be looking.) Locking the single file is what the automated
      test does for the same reason, and it is what lets the sentence above mean something.
- [ ] **(new 2026-09-06, SONNY-336)** **The Sonny account row reports your plan as well as your
      session.** Signed in, with the gateway up and reachable at least once so a claim has been
      cached: open **Settings → Permission Readiness**. **Expected:** the first row is **Sonny
      account**, it reads **Ready**, and its sentence is *"Signed in, and your plan is confirmed."*
      **What would be a finding:** the row saying **Ready** while its sentence says nothing about the
      plan, which is the state this ticket replaced.
- [ ] **(new 2026-09-06, SONNY-336; headline corrected 2026-09-06, PR #216's review F3)** **A plan
      that cannot be confirmed reads "Check when used" — grey, never the amber "Needs action".**
      Signed in, then take the Mac fully offline and leave it long enough that the cached claim is
      past its grace (or sign in on a build that has never been online). Press **Refresh** on the
      readiness page. **Expected:** the row reads **Check when used** — not *Needs action* — and its
      sentence still begins *"Signed in."* while saying Sonny could not check your plan. On screen
      that is the **grey** question-mark row, the same look every "Check when used" row on that page
      already has. **What would be a finding:** **Ready** with an unconfirmed plan, which is the row
      claiming something it did not check; or **Needs action** — the amber triangle — which would be
      telling you to fix something that is not stopping you from doing anything, since nothing in
      Sonny is gated on a plan yet. **Two colour notes so nothing here reads as a regression:** the
      **Ready** state on this page is **blue**, not green, and nothing on this page is ever red — so
      "never red" in the founders' decision means "never Needs action", which is the amber one. (The
      headline said *amber* until this correction, which named the colour of the one state this row
      exists to rule out; the states themselves are unchanged and so is the decision.)
- [ ] **(new 2026-09-06, SONNY-336)** **Signed out is unchanged.** Sign out and press **Refresh**.
      **Expected:** exactly what it said before this branch — **Needs action**, *"Sign in to Sonny in
      Command Center."*, with no second sentence about a plan. **What would be a finding:** the row
      mentioning a plan at all while signed out, which would be two rows' worth of advice about one
      problem.
- [ ] **(new 2026-09-06, SONNY-336)** **Ask Sonny itself.** Type *"check my permissions"* (the
      `show_permission_readiness` tool). **Expected:** the account line it reports matches the
      Settings page exactly — same state word, same sentence. **What would be a finding:** the two
      disagreeing, which would mean the tool and the page are reading different answers.
- [ ] **(SONNY-237, waits on SONNY-192)** **Signing out on one Mac really ends that session.** Against
      a deployed gateway, sign in on two Macs with the same account. On the first Mac press Sign out.
      Expected: the first Mac is signed out as usual, and the **second Mac keeps working** — its own
      session is untouched. **What would be a finding:** the second Mac being signed out too, or
      asking you to sign in again, which would mean one sign-out is ending every session.

- [ ] **(SONNY-237, waits on SONNY-192)** **Sign out, then sign back in, and nothing is stuck.**
      Against a deployed gateway: sign out, then immediately sign in again with an emailed code and
      run one ordinary command. Expected: it all works, at the speed you are used to. **What would be
      a finding:** the new session being refused, or anything answering "sign in again" straight
      after you did. (This row is here because the gateway now keeps a short-lived record of every
      signed-out session, and a record that outlived the session it named would lock the user out of
      the account they just signed back into.)

- [ ] **(SONNY-237, waits on SONNY-192)** **Signing out while the login service is unreachable still
      signs you out of the Mac, and the retry works.** Against a deployed gateway whose Supabase
      project is blocked, sign in and then press Sign out. Expected: the Mac signs you out; the app
      may tell you the server-side half did not happen. Unblock the project and sign out again from a
      fresh sign-in. Expected: that one succeeds. **What would be a finding:** the second sign-out
      failing, or the app getting stuck on a sign-out it can never complete.

- [ ] **(SONNY-428, waits on SONNY-192)** **A deletion that cannot finish gives up in about fifteen
      seconds and says so, instead of holding the request.** Against a deployed gateway, hold a lock
      the delete needs and then ask for one: from a `psql` on the gateway's database run
      `BEGIN; LOCK TABLE sonny.retained_content IN ACCESS EXCLUSIVE MODE;` and leave that session
      open, then from a terminal time a delete —
      `time curl -sS -i -X DELETE https://<host>/v1/tasks/<a task id you own>
      -H 'authorization: Bearer <your access token>'`. Expected: an answer inside roughly **fifteen
      seconds** carrying `504` and `code` **`provider.timeout`** with `retryable: true`. Release the
      lock with `ROLLBACK` afterwards. **What would be a finding:** the request sitting for a minute
      or more, which is the 120-second delivery bound answering instead of §12's deadline; or a
      `500`, which would mean the cancellation never reached the timeout arm.
- [ ] **(SONNY-428, waits on SONNY-192)** **The gateway is still healthy after that timeout — this
      is the half worth checking, and the reason the deadline is not a race.** Immediately after the
      row above, with the lock now released, run ten ordinary authenticated calls in a row (any
      `GET /v1/account/entitlements` will do). Expected: all ten answer normally. **What would be a
      finding:** any of them failing with `current transaction is aborted`, or a spread of odd
      failures that clears up on its own — either would mean a connection went back to the pool in a
      state the next request inherited, which is the defect this ticket's mechanism exists to avoid.
- [ ] **(SONNY-428)** **Ordinary deletion is untouched.** This is the one of the three you can run
      today, because it needs no staging host: use the local gateway that *Setup for every section
      behind the gateway* already documents — `./scripts/deploy.sh local`, then
      `defaults write com.sonny.MacAgent SonnyBackendBaseURL http://127.0.0.1:8080` so the debug
      build points at it (`SonnyBackendEnvironment.productionBaseURL` is `nil`, so only a debug build
      can be pointed anywhere at all). Then, in the app, use **Command Center › Memory › Task history
      › Delete** and, separately, **Delete what Sonny did on screen** on a single task. Expected:
      both finish as they did before, with the same confirmation and the same counts. **What would be a finding:** either press becoming slower,
      failing, or reporting a different number than it used to.

- [ ] **(SONNY-238, waits on SONNY-192)** **Rotating the login service's signing secret does not sign
      you out.** Against a deployed gateway, with the app signed in and left alone: follow
      `server/README.md`'s "Rotating the Supabase JWT secret with no sign-out" — deploy step 1, then
      rotate the JWT secret in the Supabase dashboard, then deploy step 3. Do not touch the Mac at any
      point. **Set the step-1 deadline for the whole rotation, not for the leg you are on** — it is
      the time by which steps 2 and 3 must both have happened, and a lapse before step 2 signs
      everyone out. Expected: the Mac keeps working throughout, with no sign-in prompt and no
      interruption to a command run at any stage. **What would be a finding:** the app asking you to sign in again at
      any of the three steps — which is the exact failure this work exists to remove.

- [ ] **(SONNY-238, waits on SONNY-192)** **The overlap really ends, and only the retired secret ends
      with it.** After the rotation above, leave the gateway running with the retired secret still in
      `SUPABASE_JWT_SECRET_2` and let its `..._ACCEPTED_UNTIL` instant — an ISO-8601 instant carrying
      an offset, e.g. `2026-09-14T00:00:00Z` — pass without deploying
      anything. Expected: the Mac is still working normally on tokens signed with the *current*
      secret. **What would be a finding:** the app being signed out when that instant passes, which
      would mean the ending is reaching the current secret and not only the retired one. (Set a
      deadline a few minutes out for this one rather than waiting days; the maximum is seven days, and
      there is no minimum.)

- [ ] **(SONNY-238, waits on SONNY-192)** **A gateway told to hold a secret it would ignore refuses to
      start rather than starting quietly.** Deploy with `SUPABASE_JWT_SECRET_3` set to a **non-empty**
      value (an empty one is deliberately not a refusal — nobody setting the variable), or with
      `SUPABASE_JWT_SECRET_2` set and no `..._ACCEPTED_UNTIL` beside it, or with that deadline
      written without a zone (`2026-09-14T00:00:00`) or as a bare year. Expected: the container
      exits at startup naming the variable, and `/v1/health` never comes up. **What would be a
      finding:** it starting and serving — because an ignored signing secret means every token signed
      with it is refused, which is the sign-out this work removes, arriving silently.

### The modernized Command Center and widget (new 2026-09-08, branch `ui-ux-claude`)

Every row here is visual or interaction fidelity on the packaged app; nothing behavioural changed
on this branch, so a press that does something different from before is a defect, not a design
choice. Compare against `main` at `6d7bf058` where a row says "as before".

**Window and sidebar**
- [ ] At the default size and at 900x620: the sidebar is 220pt on a darker level than the canvas, "Ask Sonny" sits under the wordmark as the one filled accent button, five nav rows read at 30pt with a flat fill (no border) on the selected one, and the account row sits at the bottom with an up/down chevron.
- [ ] ⌘N opens the widget focused with any draft kept; ⌘1 to ⌘5 switch pages in sidebar order; the selected row's icon and label read brighter than the rest.
- [ ] Hovering any nav row, the account row or a button shows a faint lift; pressing a button darkens it; a disabled button reads at 40% with no hover.
- [ ] Tab through a page with full keyboard access on: the focus ring follows each button's rounded shape.

**Tasks**
- [ ] The greeting is still the page title; the search field is 220pt with a magnifying glass, ⌘F focuses it, typing does not shift the field, Escape clears a non-empty query, and the clear control vanishes without moving anything.
- [ ] Group headers show the count in a chip and the chevron turns as sections fold (and does not animate with Reduce Motion on); rows are 36pt with a status glyph (green filled check for done, hollow cross for canceled, red filled cross for failed), a hairline between rows and none after the last, and a hover pill inset from the edges.
- [ ] Right-click delete on a row still asks first (as before). The task detail sheet opens at the shared size with a close control that Escape also triggers; a very short receipt and a very long one both read well inside it (the long one scrolls). Its buttons: Run again and Follow up neutral, the two deletes red.
- [ ] Empty history and a no-results search both show the icon, title and message state, not a bare line.

**Insights**
- [ ] The page is a bento: a wide first stat spanning two columns, two single stats, the chart and the workspace breakdown side by side, recent activity full width, no empty cell at 900x620. Numbers line up (monospaced digits). Hovering a chart column swaps its label to the count and resting shows a tooltip with the same words.
- [ ] Titles read "Tasks completed this week", "Breakdown by workspace", "Recently completed".

**Routines**
- [ ] Rows carry a real glyph tile (repeat for a routine, eye for a watcher), the streak in a chip, the next-run time in an accent chip, "Paused" in an amber chip, and a native switch for the schedule that still flips the schedule (as before). The Watching card reads as a card inside the panel with Stop in red.
- [ ] Routine detail: the sheet opens on the shared chrome with the routine name as title and its cadence as subtitle; steps read as a log (icon slot, title, trailing text); Run now is the one filled button and shows a spinner while a task is running; Save schedule, Remove schedule and Delete routine are neutral, quiet and red respectively; the confirmation reads "Delete routine"; native pickers for cadence, weekday, day of month and time are tinted blue and dark.

**Workspaces**
- [ ] Cards fill adaptive columns (no fixed 356pt width), lift on hover, show real app icons bare with the fallback tile the only one outlined, and carry Open (filled), New task (neutral), Delete (red, text only). The delete dialog title has no curly quotes and its button reads "Delete workspace".
- [ ] The detail sheet and the scope-add sheet open on the shared chrome and size; a workspace with many scope entries scrolls rather than clips; Remove on an entry is quiet, Add is neutral.

**Memory and Settings**
- [ ] Memory: the master switch and Preferences row sit in one card with native switches; rows are 44pt with a tinted icon tile, count, View and Delete; a damaged store still says "Can't be read" with Delete live (as before).
- [ ] Settings: the sheet is 860x600 with its own darker sidebar, Escape closes it, rows separate with hairlines, toggles are native switches, the theme control is a native menu offering Dark with Light and System disabled (no "(Soon)"), Refresh is quiet, Set up is neutral, "Delete local data" and "Delete set-aside files" are red and say what they delete, and Remove on an approved app stays live during a run (as before).

**Widget**
- [ ] Nothing about the material, colours or state order changed. Every circular control is larger (28pt) with the same glyph; Return accepts and Escape declines on the permission, capture review, delegation, paused, resume and update panels; Return sends a clarification answer.
- [ ] With VoiceOver: Allow and Deny are named, the mic is named and reports whether it is recording, the send arrow says "Send answer", the retry says "Retry task". Long results, long errors and long step titles show the full text on hover.
- [ ] The notice strip (a scheduled run or a storage problem) renders on the same glass as the panel beside it. With Reduce Motion on, panel transitions do not animate.

**Sign-in and screen access**
- [ ] Both sheets open on the shared chrome; fields have the raised fill with a blue hairline when focused; Send code, Verify and Sign out show a spinner while busy; Sign out is red; the plan name is an accent chip.
- [ ] Screen access: each grant reads as a green "Granted" or amber "Not granted" chip beside its glyph; the relaunch guidance panel still appears after a Screen Recording request and "Couldn't restart Sonny." still appears only when the restart failed (as before).

**Appearance**
- [ ] Settings › Preferences › Interface theme offers Dark, Light and System, all selectable. Choosing Light repaints Command Center, the Settings sheet, the account menu popover and every dialog at once with no relaunch; choosing System follows a change made in System Settings › Appearance while Sonny is running; the choice survives a relaunch.
- [ ] In Light: text is dark on paper, the sidebar is a shade darker than the canvas, cards and buttons keep their hairlines, the accent reads a step darker than in Dark, the mode segmented control's track and dividers read as greys rather than vanishing, and no white-on-white text or invisible control appears on any page or sheet.
- [ ] The floating widget stays dark in Light and in System-on-light, its glass and its buttons unchanged.

**Account menu, shortcuts and About**
- [ ] The account row's menu reads Account (or Sign in), Settings, a divider, Keyboard shortcuts, About Sonny, and nothing is disabled. ⌘, opens Settings from anywhere in the window and from the app menu's "Settings…" item; ⌘/ opens the shortcuts sheet; both close on Escape.
- [ ] The Keyboard shortcuts sheet lists three groups (Command Center, Widget, Anywhere); every chord it names works as listed, the key caps read as keys, and the Anywhere chords match the widget's mic hint.
- [ ] About Sonny shows the mark, "Sonny", "Version 1.0 (1)" from the packaged bundle (or "development build" under `swift run`), and the copyright line; nothing else.

**Settings: Notifications and Usage**
- [ ] Notifications lists six switches (Approval needed, Task finished, Task failed, Routine ran, Watcher fired, Storage problem), all on by default. Switch "Task finished" off, run a task from the widget while another app is in front: no banner; switch it back on: the banner returns. The choice survives a relaunch.
- [ ] Usage: signed out, Plan reads "Signed out" and the screen-control and top-up rows are absent; signed in, the plan chip, the screen-control line and the last top-up match the Account dialog. With nothing running the This-task section shows its empty state; run a task and it shows requests and tokens (an estimate is labelled "estimated"); a voice command adds a Voice row.

**Jump to and the sidebar**
- [ ] ⌘K opens the palette with the field focused. Empty, it lists the five pages then recent routines, workspaces and tasks; typing filters across all groups; ↑ and ↓ move one selection across groups; Return on a page switches to it, on a routine opens its detail on the Routines page, on a workspace its detail on the Workspaces page, on a task its receipt on the Tasks page; a query with no match shows "Nothing matches"; Escape closes.
- [ ] ⌘⌥S and the toggle above the account row collapse the sidebar to icons with tooltips (mark, plus, five pages, avatar) and back, animating unless Reduce Motion is on; the state survives a relaunch; every icon still navigates and ⌘1 to ⌘5 still work collapsed.
- [ ] Insights: clicking a recently-completed row opens that task's receipt on the Tasks page; clicking a workspace row in the breakdown opens that workspace's detail on the Workspaces page.

**Empty states**
- [ ] With no task history, the Tasks page's empty state offers "Ask Sonny" and pressing it opens the widget focused; with a search that matches nothing, or an unreadable task store, it offers no button. With no routines, Routines offers "New routine"; with no workspaces, Workspaces offers "Create workspace"; each opens the widget with the same draft its toolbar button does.

**Menu bar and window**
- [ ] The menu-bar glyph is the untinted inverse wand when idle, the filled wand in blue while a task runs, in amber while Sonny waits for an approval, and in red after a failure until it is dismissed; its tooltip says which. The status menu reads Ask Sonny, Open Command Center, Settings…, Quit Sonny; Ask Sonny opens the widget focused and Settings… opens Settings over Command Center.
- [ ] The Command Center window shows no centred title; the sidebar's wordmark is the only "Sonny"; the traffic lights sit clear of it; the Window menu still names the window.
- [ ] The app menu reads About Sonny, Settings… (⌘,), Hide Sonny (⌘H), Hide Others (⌥⌘H), Show All, Quit Sonny (⌘Q); About Sonny opens the About sheet over Command Center; ⌘H hides the app and Show All brings it back; the Keyboard shortcuts sheet lists ⌘H.
- [ ] The menu bar ends with Help: it carries Keyboard shortcuts (⌘/) and the system's search field; typing "hide" in that field finds Hide Sonny; with the widget key and Command Center closed, ⌘/ brings Command Center forward with the shortcuts sheet open.
- [ ] With Command Center closed and Sonny still running, opening Sonny again from Spotlight or Launchpad shows Command Center; with it already on screen, the same brings it forward without a second window.

**Copy and system**
- [ ] Settings › Screen control: the "Terminals, never" detail reads "...outside every permission Sonny has, so this is not something you can turn on." with a comma; in Memory, a row whose file is partly unreadable confirms with "Part of this can't be read. Sonny keeps that file instead of deleting it." as two sentences; a screen session paused by the lock screen summarises as "Sonny paused: your Mac was locked." with a colon.
- [ ] The push-to-talk chord reads ⌃⌥Space in the widget's mic hint, the voice status line, the readiness rows and the registration error, never spelled out; the emergency stop reads ⌃⌥⎋.
- [ ] Notifications are titled by kind ("Approval needed", "Task finished", "Task failed", "Routine ran", "Watcher fired", "Storage problem") with bodies as before.
- [ ] No button anywhere reads in Title Case except proper nouns ("Open System Settings"); no user-visible string carries an em dash.

**The founders' first round (2026-09-09)**
- [ ] Widget: press the mic (or hold ⌃⌥Space). A countdown appears leading the mic, starting at 2:57, in faint text; the text field does not shift as the digits change. At 0:30 it turns amber. At 0:00 Sonny stops listening on its own and transcribes what it heard, with no refusal. Stopping early cancels the countdown; VoiceOver on the mic reads "Stop, 2 minutes 57 seconds left".
- [ ] Tasks: the page is a list beside a pane. A row press selects it (the row fills, the receipt fills the pane); ↑ and ↓ move through every open section as one list and stop at the ends; ⌫ on a selected row asks before deleting; Esc clears the selection; with nothing selected the pane says "No task selected".
- [ ] Tasks: the receipt shows the command, a status badge (green done, red failed, grey cancelled), when it started, how long it took, the workspace and "Scheduled" where they apply; Run again (blue), Edit and run, Follow up; the … menu holds Delete task with the same confirmation as before. Result is the full text and can be selected; "What Sonny planned" shows the plan's summary; "What Sonny did on screen" reads as it did in the old sheet, with its delete in the section's … menu.
- [ ] Tasks: Edit and run opens the widget with the command already in the field and, if the task ran in a workspace, runs the edited command there; Run again re-runs at once; both are greyed out while a task is running. Right-click a row: Run again, Edit and run, Follow up, then Delete task.
- [ ] Tasks: ⌘K to a task, an Insights row, and clicking a finished-run notification each select that task in the pane, opening its section if it was collapsed. Shrink the window to 900 wide with the sidebar open: list and pane both stay usable.
- [ ] Workspaces: each card shows Open and New task, and a … menu at the trailing edge with Mark as team (solo cards only) and Delete workspace in red; the delete still asks with the same sentence. Memory: each row shows View, the toggle and a … menu with Delete; the entries sheet's rows show Continue and a … menu with Delete. Hovering a … shows the highlight; VoiceOver names it "More actions for <name>".
- [ ] Settings › Preferences: a Density slider sits under the interface theme with Compact, Default and Comfortable beneath it. Dragging it changes row heights, list gaps and card insets on every page, in the sidebar, in the ⌘K palette, in the shortcuts sheet and in the Settings sidebar itself, live, without closing Settings or changing the page; text and buttons keep their size; the widget does not change. Default looks exactly as before. The choice survives a relaunch.

**The founders' second round (2026-09-09)**
- [ ] Tasks: on arrival nothing is selected and the list fills the page; pressing a row opens the pane beside it; the × at the receipt's top right (or Esc) closes it and the list is full width again; ⌘K to a task, an Insights row and a finished-run notification still open the pane on that task.
- [ ] Tasks: a "Show" menu leads the search field with 10, 25, 50, 100 and All (25 to begin with); the sections and the ↑↓ walk cover only the shown rows; under the last section a line reads "25 of 69 shown" with a Show all beside it, absent when nothing is hidden; the choice survives a relaunch; opening a task from ⌘K that is beyond the shown rows still shows it, and the next change of the menu or leaving the page goes back to the chosen size.
- [ ] Insights: the chart card and the "Breakdown by workspace" card share one top edge and one height, with the same gap between them as between the stat cards, at the window minimum and wide. Hovering a day keeps the day name in place and shows "30 tasks" (or "1 task") in a small pill above that bar, on one line, never covering the bar.
- [ ] Memory: each row reads icon, name and detail, the toggle, then the … menu at the end; the menu holds View then Delete, both naming the row for VoiceOver; the entries sheet's rows keep Continue as their one button and their menu last.
- [ ] Workspaces: each card shows New task as its one button (blue); the card's face opens the detail; the … menu holds Open (which opens the widget for that workspace), Mark as team on solo cards, then Delete workspace in red with the same confirmation.
- [ ] Settings › Preferences: Density is a two-way choice, Default and Comfortable, with no Compact; a Mac that had chosen Compact opens on Default; Comfortable still spreads rows, gaps and card insets everywhere and Default is unchanged.

## 8. How to report back

For each real finding, give me:
**[page/component] — [what you did] — [what you expected] — [what actually happened]**, plus a
screenshot if it's visual. Per this project's own rule, anything found during a branch's own testing
gets fixed in that branch before merge — nothing gets backlogged.
