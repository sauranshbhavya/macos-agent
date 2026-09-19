### Branch: feature/more-than-one-run-at-once
Status: complete — the first layer of SONNY-456 only; the ticket stays In Progress, and the feature is its own branch after this merges
Date: 2026-09-18
Tickets: **SONNY-456** (more than one task at once: a pill per task, the single-run state made a list). This branch is its foundation and nothing more, **by founder decision on 2026-09-18**: the lane stopped at the ninety-minute mark at a green point, and the founder split the work — this refactor and the bug fix it carries merge on their own, and the feature goes to a fresh lane cut from a `main` that already has the slots. The founders' decisions recorded on the ticket that day also apply to that lane: a cap of three runs at once, a second command starts a second run rather than queueing, screen control stays one session at a time. **SONNY-535** (filed by this branch, 2026-09-19, from its review's F1): a push-to-talk shortcut that fails to register at launch is said only in the widget. **SONNY-533** (filed by the review's coordinator): the "Task failed" banner's Retry has the same defect this branch removes from Allow.
Reviewed by: **cycle 1 — a fresh session, deep adversarial pass, at `6b8e30f2`, posted in full on PR #279: six findings, five taken in one round and one filed.** The review reproduced the suite (3479 in 252, exit 0, on its second run; its first run was red in two MacAgentCore backend-stub suites this diff does not touch, which passed alone), `scripts/warnings` (0) and every gate. By hand it traced the fix, the token in both directions, and every door that approves, and found the sixth mutant equivalent. **F1**, a second behaviour change the entry did not mention: the founders decided to keep it, and it is recorded below. **F2**, the approval-announcement test ran with one run, so it could not tell "its run" from "the run on screen" (SONNY-388's shape), and the failure channel had no behavioural test at all: both are now held with two runs. **F3**, nothing ran the banner's round trip: it is one tested type now. **F4**, record corrections: made, below. **F5**, the token rule was kept by convention: the types enforce it now. **F6**, the Retry banner: filed as SONNY-533, outside this branch. The review also found that the fix closes three more stale-banner routes than this entry first claimed. They are under *Behavior changed* now.

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
  - The run's properties become computed properties forwarding to the slot of the run in scope: **45** (`git grep -c 'get { runSlotInScope\.' 943b1f49 -- Sources/MacAgent/AgentViewModel.swift` → 45). Slots are written only through `updateRunSlotInScope`, which is `private`.
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

Every figure below was measured at `943b1f49`. This entry's own commit adds only the two record files, so `git diff --stat 943b1f49 HEAD -- Sources Tests Package.swift` prints nothing, and each figure is the head's.

The flagged command from `CLAUDE.md` was redirected to a file with `echo "SWIFT_TEST_EXIT=$?"` on the next line. **Three full runs at this one head, all recorded:**

| Run | Result | Start condition and load |
|---|---|---|
| 1 | red: 3482 in 253, **44 issues** (52 with the 8 known), exit 1, 136.073 s | started with no other Swift process running, at load `38.97`, from other work on the machine. All **25** failing tests are in MacAgentCore's `SonnyBackendClientTests`, mostly `.timedOut(after: 20.0)`: the review's first run met the same. This diff touches nothing under `Sources/MacAgentCore` or `Tests/MacAgentCoreTests` (`git diff --stat 8f3d1d02 HEAD --` on both → nothing), and that suite alone → **37 in 1, exit 0, 0.472 s** |
| 2 | green: 3482 in 253, 8 known issues, exit 0, 139.812 s | **did not meet the start condition.** A 25-minute wait for no Swift process gave up and started it beside another lane's **15**. Load `32.95` → `27.82`. Kept as a record, not as the figure |
| 3 | **green: 3482 tests in 253 suites passed after 179.416 seconds with 8 known issues, exit 0** | started with **no** other Swift process running (`ps -axww -o command \| grep -cE '(^\| )/[^ ]*(swift-frontend\|swift-driver\|swiftpm-testing-helper\|xctest)'` → 0, its control `launchd` → 1). Load `34.14` at the start and `69.21` at the end, a figure that includes this run's own work. **This is the figure** |

Every one of the seven new or rewritten tests is named `passed` in run 3's log, so none was skipped.

**Warnings: 0** (`scripts/warnings`, exit 0). Its header reads `measured at : 943b1f49 plus 2 uncommitted file(s)` (the two records, which no build reads) and `compiled : every file`. It was started with no other Swift process running, at load `23.14` rising to `24.88`.

The refactor alone measured **3475 in 251**, exit 0, at `18780e34`, and the first layer with its tests **3479 in 252**, exit 0, at `7cc9d989`. Those are records of those trees, not of this one. `server/` is untouched, so none of its commands is owed.
Mutation plan: `mutation/plans/feature/more-than-one-run-at-once.txt` (founder-triggered, not run on this branch). **Ten** mutants. Each was applied by hand at `943b1f49`, built, and killed by the tests named here, then put back from `HEAD`:

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

`scripts/mutate mutation/plans/feature/more-than-one-run-at-once.txt --check` → exit 0, ten mutants, each `1 match`, at `943b1f49`. **Three more are owed by the next layer and are not in the plan.** They are listed under *Architectural decisions* below.

Behavior changed:
- **A notification's Allow answers only the question it was posted for (the fix).** Before this branch the banner's Allow called `viewModel.start()`, and `start()` acts on whatever is in front of it when the banner is pressed. So a banner pressed after its own question had gone did one of four wrong things, depending on what was there:
  - **approved a different question**, when another had been asked since (the case this branch set out to fix);
  - **started a new task from whatever text sat in the composer**, when nothing was parked and something had been typed;
  - **put "Enter a natural-language command first." onto whatever the widget was showing**, when nothing was parked and nothing was typed. That included a clarification waiting for its answer, and a task that was running;
  - **approved a question from a later launch**, when the notification was left over from a previous one. Notifications outlive the app, so this could happen after any relaunch.

  Now the notification carries its run and a token minted for that one asking of that one question. Its Allow answers that question or does nothing, and "does nothing" leaves only a log line. The last three routes were found by PR #279's review. They close because a refused banner no longer reaches `start()` at all, and a notification from a previous launch names a run that no longer exists.
- **An error already set when Sonny launches no longer posts a "Task failed" notification (on purpose, founder decision 2026-09-19).** The old failure channel was `viewModel.$errorMessage`, and `@Published` sends its current value to every new subscriber. So an error set before `AppDelegate` subscribed was replayed into the notification. The new channel, `errorMessageRaised`, sends only errors that happen after it is subscribed.
  - **The known instance is the push-to-talk shortcut failing to register at launch.** `markVoiceHotKeyUnavailable` runs at `AppDelegate.swift:176`, before `observeNotificationTriggers()` at `:198`, both at `943b1f49`. The old build turned that into a "Task failed" banner whenever the user was not working in Sonny, though no task had failed. This build does not. The widget still shows the reason, because the error is persistent.
  - **The founders chose not to restore the replay.** It would re-ship a banner whose title is wrong. The right shape is a launch-time surface that says what actually happened, and SONNY-535 carries it.
  - SONNY-535 exists because the message is now said *only* in the widget, which someone who has not opened the widget never sees. That may not be fine, and the ticket says so. A manual row checks the new behaviour.

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

**Recorded rather than fixed:** `addRunSlotForTests()` ships in the release binary with no production caller. When a stale banner's Allow is refused, the only trace is a log line, which fits the no-explanatory-copy rule.

Open questions (required, write "none" if true): none.

Next branch: the rest of SONNY-456, cut from `main` after this merges.
