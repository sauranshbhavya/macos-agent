### Branch: feature/more-than-one-run-at-once
Status: complete — the first layer of SONNY-456 only; the ticket stays In Progress, and the feature is its own branch after this merges
Date: 2026-09-18
Tickets: **SONNY-456** (more than one task at once: a pill per task, the single-run state made a list). This branch is its foundation and nothing more, **by founder decision on 2026-09-18**: the lane stopped at the ninety-minute mark at a green point, and the founder split the work — this refactor and the bug fix it carries merge on their own, and the feature goes to a fresh lane cut from a `main` that already has the slots. The founders' decisions recorded on the ticket that day also apply to that lane: a cap of three runs at once, a second command starts a second run rather than queueing, screen control stays one session at a time. **SONNY-535** (filed by this branch, 2026-09-19, from its review's F1): a push-to-talk shortcut that fails to register at launch is said only in the widget. **SONNY-533** (filed by the review's coordinator): the "Task failed" banner's Retry has the same defect this branch removes from Allow.
Reviewed by: **cycle 1 — a fresh session, deep adversarial pass, at the branch's pre-hop head that its comment on PR #279 names, posted there in full: six findings, five taken in one round and one filed.** The review reproduced the suite (3479 in 252, exit 0, on its second run; its first run was red in two MacAgentCore backend-stub suites this diff does not touch, which passed alone), `scripts/warnings` (0) and every gate. By hand it traced the fix, the token in both directions, and every door that approves, and found the sixth mutant equivalent. **F1**, a second behaviour change the entry did not mention: the founders decided to keep it, and it is recorded below. **F2**, the approval-announcement test ran with one run, so it could not tell "its run" from "the run on screen" (SONNY-388's shape), and the failure channel had no behavioural test at all: both are now held with two runs. **F3**, nothing ran the banner's round trip: it is one tested type now. **F4**, record corrections: made, below. **F5**, the token rule was kept by convention: the types enforce it now. **F6**, the Retry banner: filed as SONNY-533, outside this branch. The review also found that the fix closes three more stale-banner routes than this entry first claimed. They are under *Behavior changed* now. **Cycle 2 — the same reviewer's scoped delta pass on that round, posted on PR #279: nothing blocking.** It confirmed each fix can fail, and it recorded three things, all written into this entry rather than taken as a round. The delegate's hold call is pinned by no test, and `RunSlot.parkedApproval` has no reader, both under *Known limitations*. The launch-time failure is not said "only in the widget", which is corrected under *Behavior changed* and on SONNY-535. **Then one hop onto `main` at `7b89cfd9`**, after #276, #278 and #277 merged. Every figure below was re-measured after it.

Spec sections covered: none in full. The founders' "Multi-agent mode" text, bullet two ("More than one task can run at once. Each running task has its own pill") is what SONNY-456 delivers, and this branch builds only the state underneath it. No second run can exist in the product yet.

**Two behaviour changes, both around notifications, and nothing else a person can see.** First, a fix: an "Approval needed" notification's Allow now answers only the question it was posted for. Second, on purpose: an error that already exists when Sonny launches no longer produces a "Task failed" banner. Everything else in the diff is a refactor that changes no behaviour. Both changes are described in full under *Behavior changed*.

Files changed:
- `Sources/MacAgent/RunSlot.swift` (new):
  - `RunID`.
  - `ApprovalTarget`, one parked approval's address: its run and its token.
  - `RunSlot`, holding the properties `AgentViewModel` used to declare for its one run, with the same names, types and defaults, plus `approvalToken`. The approval pair is `private(set)` and is written only through `setApprovalRequest(_:)`. Its doc names what stayed one per view model.
  - `RunScope`, a `@TaskLocal` naming the run whose work is executing. Its doc lists the code known to run outside any run.
- `Sources/MacAgent/AgentViewModel.swift`:
  - `runSlots` (never empty) and `focusedRunID`.
  - The run's properties become computed properties forwarding to the slot of the run in scope: **45** (`git grep -c 'get { runSlotInScope\.' fb5cde29 -- Sources/MacAgent/AgentViewModel.swift` → 45). Slots are written only through `updateRunSlotInScope`, which is `private`.
  - `RunScope` is bound where a run's work begins: `start`, `approvePendingRun` and the scheduled routine.
  - `approvalRequest`'s setter parks through the slot and announces `(ApprovalTarget, request)` on `approvalParked`.
  - Also new: `errorMessageRaised`, `approveParkedRun(_:token:)`, `markOutcomeAsNotified(for:)` and `addRunSlotForTests()`.
- `Sources/MacAgent/AppDelegate.swift`:
  - The notification's Allow reads the notification's `ApprovalTarget` and calls `approveParkedRun`.
  - The approval and failure notifications listen on `approvalParked` and `errorMessageRaised`.
  - The menu-bar glyph reads every slot.
- `Sources/MacAgent/SonnyNotificationService.swift`: `ApprovalTarget.notificationUserInfo` and `init?(notificationUserInfo:)` are the notification's only encoder and decoder. The permission notification is posted with a target, and `onAllow` is handed one.
- `Tests/MacAgentTests/ConsequenceRuleDispatchTests.swift`: the dispatch fixture takes a planner. New suites `RunAttributedApprovalTests` (four tests) and `ApprovalNotificationRoundTripTests` (three), both described below.
- `Tests/MacAgentTests/ProductShellTests.swift`: the wipe classifier's population includes a slot's properties, and the classifier classifies the container.
- `Tests/MacAgentTests/ResumeOfferPresentationTests.swift`: the count of routes into `start(` is six, not seven. The notification's Allow was the seventh.
- `Tests/MacAgentTests/StandingWatcherRunTests.swift`: the notification-gate scan reads the two new channel names.
- `mutation/plans/feature/more-than-one-run-at-once.txt`, `docs/manual-tests/feature/more-than-one-run-at-once.md`, this entry.

Tests:

**Every figure here was measured at `fb5cde29`, this branch's head after its one hop onto `main` at `7b89cfd9`, with a clean tree.** This entry's last commit adds only record files, so `git diff --stat fb5cde29 HEAD -- Sources Tests Package.swift` prints nothing, and each figure is the head's.

**The hop.** `git rebase --onto 7b89cfd9 8f3d1d02 feature/more-than-one-run-at-once` replayed this branch's nine commits with no conflict.
- Its range is `git diff --name-only 8f3d1d02 origin/main` → **42** files, from #276, #278 and #277. That is 18 under `Sources/MacAgent` (fourteen of them skill packs), 14 under `Tests/` (three in `Tests/MacAgentTestSupport`, `HangBackstop.swift` among them), plus records.
- Two of those files bear on this branch. **`AppDelegate.swift`**, which #276 edits in a region apart from this branch's. **`HangBackstop.swift`**, whose `waitOrAbandon` this branch's tests call; it only gained a function (`waitRecordingAStuckWait`).
- None of `main`'s added lines in the range names anything this branch removed or reshaped. `git diff 8f3d1d02 origin/main -- Sources Tests`, reduced to its `+` lines, was searched with `grep -cE` for the pattern `\$(isRunning|approvalRequest|errorMessage)\b|postPermissionNotification|onAllow|markOutcomeAsNotified|approvalParked|errorMessageRaised|updateRunSlotInScope|runSlots|focusedRunID|RunScope|approvalToken` → **0**. That zero is controlled three ways:
  - the same pipeline over this branch's own `git diff 7b89cfd9 fb5cde29` → 133;
  - `\b` works in that `grep`: it matches `$isRunning,` and not `$isRunningX`;
  - the removed publishers are found in this branch's removed lines → 6.
- Nothing carried across the hop. Every figure below, and every mutant, was measured again.

**The flagged suite.** The command from `CLAUDE.md`, redirected to a file with `echo "SWIFT_TEST_EXIT=$?"` on the next line → **3506 tests in 256 suites passed after 99.737 seconds with 16 known issues, exit 0.**
- It started with no other Swift process running. `ps -axww -o command | grep -cE '(^| )/[^ ]*(swift-frontend|swift-driver|swiftpm-testing-helper|xctest)'` → 0, and its control `launchd` → 1.
- Load was `8.41` at the start and `7.04` at the end.
- **The known issues went from 8 to 16 across the hop, and none of the new ones is this branch's.** The extra eight are all in `CanaryBackstopTests.swift`, a file #277 added (3 + 2 + 3 known-issue lines across three of its tests), and the other eight are the same tests that recorded them before the hop.
- Every one of this branch's seven new or rewritten tests is named `passed` in the log, so none was skipped.

**Warnings: 0.** `scripts/warnings` exits 0, and its header reads `measured at : fb5cde29 (clean)` and `compiled : every file`. It too started with no other Swift process running, at load `7.04` rising to `15.20`.

**Before the hop, kept as history and not as figures.** Every commit those runs measured was replaced by the rebase, so no SHA is cited for them.
- The refactor alone measured 3475 in 251, exit 0, and with its first tests 3479 in 252, exit 0.
- At round one's head, three full runs were recorded. One was red: all 25 failing tests were in MacAgentCore's `SonnyBackendClientTests`, timed out at load ~39, and that suite alone passed, 37 in 1. One was green but started beside another lane's Swift processes, so it does not count. One was green with the start condition met: 3482 in 253, exit 0.
- `scripts/warnings` was 0 each time it ran.
- `server/` is untouched, so none of its commands is owed.
Mutation plan: `mutation/plans/feature/more-than-one-run-at-once.txt` (founder-triggered, not run on this branch). **Ten** mutants. Each was applied by hand at `fb5cde29`, after the hop, built, and killed by the tests named here, then put back from `HEAD`. The hop moved R3's target file and a helper every killer calls, so none of the round-one proofs was carried:

| Mutant | What it breaks | Killed by |
|---|---|---|
| R1 | one run's token answers another run's question | `anApprovalNamedForOneRunRunsThatRunAndLeavesTheOtherParked`, `aTokenFromBeforeTheQuestionWasAskedAgainAnswersNothing` |
| R2 | a named approval approves the run on screen | the first of those |
| R3 | the banner's Allow goes back to `start()` | `theBannersAllowAnswersTheRunAndApprovalItWasPostedFor` |
| R4 | the banner is written without its run | `anAddressWrittenIntoANotificationReadsBackAsTheSameAddress`, `theRunAndTheTokenAreReadFromTheirOwnKeys`, the two-run approval test |
| R5 | asking again keeps the old token | `aTokenFromBeforeTheQuestionWasAskedAgainAnswersNothing` |
| R6 | a park is announced as the run on screen's | the two-run approval test |
| R7 | a failure is announced as the run on screen's | `aFailureIsAnnouncedWithTheRunItBelongsToAndItsHoldLandsThere` |
| R8 | a failure is never announced | the same |
| R9 | the notification's hold lands on the run on screen | the same |
| R10 | the decoder reads the token from the run's key | four tests, both round-trip suites among them |

`scripts/mutate mutation/plans/feature/more-than-one-run-at-once.txt --check` → ten mutants, each `1 match`, at `fb5cde29`. **Three more are owed by the next layer and are not in the plan.** They are listed under *Architectural decisions* below.

Behavior changed:
- **A notification's Allow answers only the question it was posted for (the fix).** Before this branch the banner's Allow called `viewModel.start()`, and `start()` acts on whatever is in front of it when the banner is pressed. So a banner pressed after its own question had gone did one of four wrong things, depending on what was there:
  - **approved a different question**, when another had been asked since (the case this branch set out to fix);
  - **started a new task from whatever text sat in the composer**, when nothing was parked and something had been typed;
  - **put "Enter a natural-language command first." onto whatever the widget was showing**, when nothing was parked and nothing was typed. That included a clarification waiting for its answer, and a task that was running;
  - **approved a question from a later launch**, when the notification was left over from a previous one. Notifications outlive the app, so this could happen after any relaunch.

  Now the notification carries its run and a token minted for that one asking of that one question. Its Allow answers that question or does nothing, and "does nothing" leaves only a log line. The last three routes were found by PR #279's review. They close because a refused banner no longer reaches `start()` at all, and a notification from a previous launch names a run that no longer exists.
- **An error already set when Sonny launches no longer posts a "Task failed" notification (on purpose, founder decision 2026-09-19).** The old failure channel was `viewModel.$errorMessage`, and `@Published` sends its current value to every new subscriber. So an error set before `AppDelegate` subscribed was replayed into the notification. The new channel, `errorMessageRaised`, sends only errors that happen after it is subscribed.
  - **The known instance is the push-to-talk shortcut failing to register at launch.** `markVoiceHotKeyUnavailable` runs at `AppDelegate.swift:187`, before `observeNotificationTriggers()` at `:209`. Both lines come from `git grep -nE 'markVoiceHotKeyUnavailable|observeNotificationTriggers\(\)$' fb5cde29 -- Sources/MacAgent/AppDelegate.swift`. The same command answered `176` and `198` before the hop, because #276's edit to that file moved them: a line number a command answered is a reading at a commit. The old build turned that into a "Task failed" banner whenever the user was not working in Sonny, though no task had failed. This build does not. **The failure is still visible in three places.** The widget shows the reason, because the error is persistent. Settings › Security & Access › Permission Readiness reads "Another app is using ⌃⌥Space." (`PermissionReadinessService.swift:190`). And the menu-bar icon turns to its failure colour.
  - **The founders chose not to restore the replay.** It would re-ship a banner whose title is wrong. The right shape is a launch-time surface that says what actually happened, and SONNY-535 carries it.
  - **What is lost is the only *pushed* signal**: nothing now arrives unasked. What is left is text the user has to go and look for, plus a red icon with no words. SONNY-535 carries that narrower question: should a problem Sonny finds at launch push anything, and in what words? This entry and that ticket first said the reason was shown "only in the widget". PR #279's delta review found the other two surfaces, and a correcting comment on SONNY-535 records it. A manual row checks the new behaviour.

Behavior preserved (required, no blanket claims):
- **Every run is still the one run.** Nothing in `Sources/` creates a second slot: `addRunSlotForTests()` is called only from `Tests/`, and `focusedRunID` is written only in `init`. So the run in scope is always the only slot, and every forwarded property reads and writes exactly what its stored predecessor did. The evidence is the full suite passing with no test's expected behaviour edited. The only existing tests this branch touches are three source scans, each updated to name what moved: the wipe classifier's population, the count of routes into `start(` (seven to six, the notification's Allow leaving), and the notification-gate scan's two channel names.
- The widget's ✓ and ✗, the composer's Send-as-Allow, and Command Center's Allow and Deny still reach `start()` and `cancelCurrentRun()` exactly as before, and act on the one run. The dispatch-door test counts them.
- A failure that happens while Sonny runs, which is every failure except the launch-time one above, still posts "Task failed" only while the user is not working in Sonny. It still marks the outcome as notified, so SONNY-121's hold keeps it on the widget, now on the run that failed. With one run that is the same run.
- The menu-bar glyph shows running, waiting and failed exactly as before with one run. It reads "any slot", which is that slot, and `$runSlots` still replays its current value to a new subscriber, so the glyph is right from launch.
- Screen-control sessions, clarifications, the scheduled routine path, task history, the resumable-task record and the local-data wipe are unchanged in behaviour. Each writes the same properties it wrote, now forwarded. The wipe classifier still partitions every property the wipe could meet, including the ones that moved into the slot.

Architectural decisions / pitfalls discovered (required, write "none" if true):

**A task-local names the run, rather than a `RunID` parameter threaded through every function.** There were 153 write sites of the run's state in the app target before this branch. The count comes from `git grep -nP '\b(isRunning|approvalRequest|clarificationQuestion|plan|stepStatuses|finalSummary|errorMessage|preparedRun|runner|currentTask|activeTaskOrigin|suggestions|clarificationAnswer|visionSessionProgress|visionCapturePreview|visionDelegationRequest|visionSessionPause|activeTaskScope|currentTaskID|pendingTaskHistoryStartedAt|activeResumableTask|lastCommand)\s*(=[^=]|\[)' 8f3d1d02 -- Sources/MacAgent | grep -vE ':[0-9]+:\s*//' | wc -l` → 153. It uses `-P` because `git grep -E` does not honour `\b`: the same pattern under `-E` answers 0.

The deciding question was which way a missed site fails:
- With a parameter, a missed site still compiles and writes to the focused run, which is a different run whenever two exist.
- With the scope, the only way to miss is to run outside the run's task (a timer, a notification, a `DispatchQueue` hop, a cancellation handler), and that also falls back to the focused run.

Both designs share that one failure. The scope removes every other, and it let the pipeline keep its spelling. `RunScope`'s doc comment carries this, and lists what is known to run outside a run.

**Outside any run the answer is the focused run, and that is right, not a fallback.** A view drawing a panel, a control pressed on that panel and a test reading state all mean the run on screen. What is *not* right is anything drawn for a run and pressed later. The notification's Allow is one, and this branch fixes it. The notification's Retry is another, and SONNY-533 carries it.

**An answer names a run and a token, never a request, and the types hold the token rule.** `RiskApprovalRequest` is a value, so two runs asking the same thing park requests that compare equal, and a question asked twice parks an equal request both times. So the token is minted on every park and cleared on every clear. Two things now enforce that rather than rely on convention (the review's F5):
- `RunSlot`'s approval pair is `private(set)` and written only by `setApprovalRequest(_:)`, which writes both halves at once.
- `updateRunSlotInScope` is `private`, so no file but `AgentViewModel.swift` can write a slot at all.

`runSlots` itself is still readable module-wide, which exposes `runner` and `preparedRun` to reading. Nothing reads them there, and the next layer reshapes that API anyway.

**A test that runs one run cannot tell "its run" from "the run on screen" (the review's F2, SONNY-388's shape).** With one slot, `runIDInScope` always equals `focusedRunID`, so a channel that announced the focused run passed every test that listened.
- The approval announcement is now asserted inside the two-run test, with the widget on the other run.
- The failure channel is held by a two-run test of its own. It had no behavioural test at all, because `@Published` used to supply it and nothing replaced the test that supply never needed.
- R6 to R9 are those four shapes, each killed.

**The banner's two halves live side by side in one type (F3).** The service cannot be built in a test process, and a mismatch between writing and reading turns every Allow into a silent refusal with nothing else noticing. So encoding and decoding are `ApprovalTarget`'s two members, next to each other, and the round trip is tested directly. The run is written from its UUID, never from `RunID.description`, which exists for logs and is free to change. The two-run test answers its second question with an address that went through both halves, so the wiring is exercised end to end short of the service itself.

**A trapped test costs a mutant its evidence, and hand-proving the plan is what found one here.** The first version of the swapped-keys test expected two keys and then subscripted `keys[1]`. Under R4, which writes the banner without its run, it trapped, and the whole test process died. The run named no killing test, and a first reading took it for a build failure. It now uses `try #require` for the count, as CLAUDE.md's gotcha asks. All ten mutants were then proved again at the head that carries the fix, not carried from the one before it.

**An unstructured `Task` inherits its creator's task-local, so all three `Task` bindings are untestable on this branch, not one.** This entry first said "one of the three". The review's F4(b) showed it is all three:
- The binding inside the `Task` of `start()`, of `approvePendingRun()` and of the scheduled routine is each equivalent to no binding.
- The `Task` inherits whatever scope created it.
- With no scope, every read resolves to `focusedRunID`, and that is written only in `init`.

`approveParkedRun`'s own binding is different. It wraps the synchronous reads, and R2 kills its removal. The next layer, which makes focus movable, owes three mutants, one per `Task` binding, each with a test that moves focus mid-run.

**A full run on a loaded machine measures the machine, not the branch.** Two full runs were red before the first green one, for two different reasons, and neither was a defect in the refactor.
- **The first** took 284 s, with **90** failing tests.
  - **88** were in `VisionSessionRunTests`, and every one of those carries `HangBackstop`'s own verdict of main-actor starvation: it looked at its condition between **2 and 9** times in roughly three minutes, against a floor of 500. The same suite's **137** tests passed alone in **8.896 s**.
  - The other **2** were the source scans below.
  - The run's log is a session scratch file, so the counts are recorded with their commands:
    - `grep -E 'Test [A-Za-z0-9_]+\(.*\) failed after' | sort -u | wc -l` → 90. A first count of 91 had included the run's own summary line.
    - Each name looked up with `grep -l "func <name>(" Tests/MacAgentTests/VisionSessionRunTests.swift` → 88 there and 2 elsewhere.
    - `grep -oE 'evaluate the condition only [0-9]+ times'` → 2 at least and 9 at most.
- **The second** took 107 s on a quiet machine. It was the two scans the refactor was expected to move, the wipe classifier and the start-route count, which the first commit updates.

The review met the same thing independently: its first full run was red in two MacAgentCore backend-stub suites at load ~28 to 65, and passed alone. That is why every figure below carries the load it was taken at.

**What stayed one per view model** (F4(c); this entry first said every per-run property moved):
- **`taskUsageRecorder`.** It stayed shared while `currentTaskID` and `taskUsageSummary` moved, so `beginNewTaskIdentity()` now resets one shared recorder beside two per-run values that were written as one lifetime.
- `widgetWasExpandedForThisRun`. Any run starting resets it for all of them.
- `completedRunNotice`. The next finished run overwrites it.
- `taskRecordingPolicy`.
- The screen-control session's `visionSessionEnvironment`, `visionUserPauseMonitor` and `visionEmergencyStopHotKey`.

With one run each is exactly what it was. With two, each is a decision still to make. `RunSlot`'s doc names them.

Known limitations / deferred scope:

**The feature is deferred to the rest of SONNY-456**, by the founder's decision of 2026-09-18. The ticket's comments hold each item in full. In order:
1. **The four screen-control cancellation hops, first** (found by PR #279's review). Each is a `Task` started inside `withTaskCancellationHandler`'s `onCancel` in `AgentViewModel+VisionSession.swift`. `onCancel` runs in the context of whoever cancelled, so the hop reads the continuation of the run *that* context names. Once focus can move, stopping run B while the widget shows run A goes wrong one of two ways:
   - B's continuation is never resumed, so B never finishes and holds its slot against the cap for good;
   - or, if A has a screen-control question parked, A is declined instead.

   The direction for the fix is to capture the run before the handler and bind it inside the hop.
2. **The voice path.** It runs outside any run. It writes `errorMessage` and `errorIsPersistent` (through `setError`), clears `errorMessage` and `finalSummary`, writes `currentTaskID` and `taskUsageSummary` (and resets the shared recorder), sets `preserveUsageForNextStart`, and writes `clarificationAnswer` after reading `clarificationQuestion`. It hands its transcript to `dispatch`, so the run it starts begins in whichever slot is focused when the transcript lands. (This entry and `RunScope`'s doc first said it wrote `clarificationQuestion` and two others. It reads that one, and writes the rest listed here.)
3. Slots for new runs, and the cap of three.
4. Focus: a summon opens an idle slot, and a pill opens its own run.
5. One pill per run, stacked down from the top-right.
6. Screen control one session at a time. Stop and Pause act on the session's own run, and `⌃⌥⎋` stops every run.
7. "Don't save this task" held per run, and the other shared state listed above decided one by one.
8. The scheduler, the whole wipe and `clearInMemoryLocalDataState` read every slot. Nothing removes a slot yet, so the rule that a slot with work in flight is never removed arrives with whatever removes one.
9. Two runs landing in task history, and the three equivalent mutants above.
10. Command Center's attention panel, running indicator and Tasks group over the list.

**Two tickets sit beside it:**
- **SONNY-533**, the Retry banner re-running whatever was last submitted rather than the task it was about. It is live on `main` today, and it starts work rather than merely failing to answer.
- **SONNY-535**, a launch-time error surface.

**Recorded rather than fixed, for the next layer to settle** (PR #279's delta review):
- **The delegate's hold call is pinned by no test.** `AppDelegate`'s failure sink calls `viewModel.markOutcomeAsNotified(for: runID)`. Changing it to `viewModel.markOutcomeAsNotified()` passes the suite: the test calls the view model's method directly, and no scan reads the delegate's line. While one run exists, the change makes no difference. The layer that adds runs should pin it, the way R3 pins Allow's line.
- **`RunSlot.parkedApproval` has no reader.** `git grep -nE 'parkedApproval' fb5cde29 -- Sources Tests` → the declaration alone, at `RunSlot.swift:161`. The next layer either uses it or removes it.

`addRunSlotForTests()` ships in the release binary with no production caller. When a stale banner's Allow is refused, the only trace is a log line, which fits the no-explanatory-copy rule.

Open questions (required, write "none" if true): none.

Next branch: the rest of SONNY-456, cut from `main` after this merges.
