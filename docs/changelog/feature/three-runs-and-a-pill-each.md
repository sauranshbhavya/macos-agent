### Branch: feature/three-runs-and-a-pill-each
Status: in progress — SONNY-533 is done. Of SONNY-456's second layer, everything that has to be true *before* a second run can exist is done, and nothing that lets one exist is built: no code in `Sources/` creates a second slot, so the product still runs one task at a time. The lane stopped at a green point, as `WORKFLOW.md` step 5 asks. *Known limitations* has what is left, in order.
Date: 2026-09-19
Tickets: **SONNY-533** (the "Task failed" banner's Retry re-runs the latest command, not the one that failed): fixed, with the run-and-token treatment PR #279 gave Allow. **SONNY-456** (more than one task at once, a pill per task), second layer, in four parts. Done: the four screen-control cancellation hops read the run that parked them; a voice recording writes to the run it started on; the cap of three refuses a fourth command; `⌃⌥⎋` stops every run; and two runs in flight together each land in task history, which needed a test and no code. **Not built: slots for new runs, focus, and the pill per run.** The ticket stays In Progress.
Reviewed by: not yet reviewed. This is approval-visibility and notification code, so `WORKFLOW.md` step 7 gives it a deep review.

Spec sections covered: none in full. The founders' "Multi-agent mode" text is what SONNY-456 delivers, and nothing on this branch lets a second run exist yet.

Files changed:
- `Sources/MacAgent/RunSlot.swift`:
  - `FailureTarget`, one failed task's address: its run and its retry token.
  - `RaisedFailure`, what `errorMessageRaised` sends: the run, the message, and the `FailureTarget` when there is a failed task to retry.
  - `RunSlot.errorMessage` and `RunSlot.lastCommand` are `private(set)`. `setErrorMessage(_:ofTheRunsOwnTask:)` writes the failure and its `retryToken` in one write. `setLastCommand(_:)` writes the command and retires the token. `failedTask` is the slot's current address.
- `Sources/MacAgent/AgentViewModel.swift`:
  - `publishFailure(_:ofTheRunsOwnTask:)`, the one writer of a run's failure and the one place it is announced.
  - `setRunFailure(_:)`, called where a run's own task fails. `setError` is every other failure, as before.
  - `retryFailedRun(_:token:)`, the one door by which a Retry reaches a named run.
  - `errorMessageRaised` sends a `RaisedFailure`. It is still a `PassthroughSubject`.
- `Sources/MacAgent/SonnyNotificationService.swift`:
  - `SonnyNotificationContent` builds the two notifications that carry a control. `SonnyNotificationResponse` decides where a press lands. The delegate callback builds one and hands it to `land(_:)`.
  - `FailureTarget.notificationUserInfo` and `init?(notificationUserInfo:)`, beside `ApprovalTarget`'s, both over one shared pair of functions.
  - A new category, `SONNY_ERROR_NO_RETRY`, with no actions. `SonnyNotificationAction` is no longer `private`, so a test can press a button by name.
- `Sources/MacAgent/AppDelegate.swift`: the Retry closure calls `retryFailedRun`. The failure sink hands the announcement's own address to the post.
- `Sources/MacAgent/AgentViewModel+VisionSession.swift`: `afterCancellation(ofAQuestionParkedOn:_:)`, and the four questions hop through it. `stopEveryRun()`, which the `⌃⌥⎋` handler calls.
- `Sources/MacAgent/AgentViewModel.swift`, for SONNY-456: `voiceRecordingRunID`, with `startVoiceRecording`'s task moved into `beginRecordingOncePermitted(trigger:)` and the stop bound to that run; `maximumConcurrentRuns`, `tooManyRunsMessage`, `runsInFlight`, and the cap's guard in `start()`.
- `Tests/MacAgentTests/RunAttributedRetryTests.swift` (new): suites `RunAttributedRetryTests` (five tests) and `NotificationRoundTripTests` (five).
- `Tests/MacAgentTests/RunAttributedCancellationTests.swift` (new): three tests.
- `Tests/MacAgentTests/RunAttributedVoiceTests.swift` (new): three tests.
- `Tests/MacAgentTests/ConcurrentRunTests.swift` (new): three tests.
- `Tests/MacAgentTests/ConsequenceRuleDispatchTests.swift`: the dispatch fixture and `slot(_:in:)` are no longer `private`, so the four new files drive the same fixture. Two tests follow the new shapes.
- `Tests/MacAgentTests/ProductShellTests.swift`: the wipe classifier names `retryToken` and `voiceRecordingRunID`.
- `Tests/MacAgentTests/AgentViewModelLocalStorageTests.swift`, `ScheduledRoutineRunTests.swift`, `StandingWatcherRunTests.swift`: one scan each follows the default click's landing, which is two steps now.
- `mutation/plans/feature/more-than-one-run-at-once.txt`: four of the first layer's mutants re-anchored. `mutation/plans/feature/three-runs-and-a-pill-each.txt`, `docs/manual-tests/feature/three-runs-and-a-pill-each.md`, this entry.

Tests:

**Every figure here was measured at `075424d5`, with a clean tree.** That is the last commit on this branch that touches `Sources/` or `Tests/`. The commit after it adds only record files, so `git diff --stat 075424d5 HEAD -- Sources Tests Package.swift` prints nothing, and each figure is the head's.

**The flagged suite.** The command from `CLAUDE.md`, redirected to a file with the exit written on the next line → **3530 tests in 261 suites passed after 128.434 seconds with 16 known issues, exit 0.**
- It did not start on a quiet machine, and that is said rather than hidden: `ps -axww -o command | grep -cE '(^| )/[^ ]*(swift-frontend|swift-driver|swiftpm-testing-helper|xctest)'` → 11 at the start, another lane's build. The one-minute load average was `7.58` at the start and `12.78` at the end. It passed anyway.
- Every one of this branch's nineteen new tests is named `passed` in the log, so none was skipped.
- `server/` is untouched, so none of its commands is owed.

**Two earlier full runs on this branch, kept as history.** The commits they measured are beneath the head, so their SHAs are cited.
- At `628218d1`: 3524 tests in 259 suites passed, 16 known issues, exit 0.
- At `49a245f7`: 3530 tests in 261 suites passed, 16 known issues, exit 0. The head differs from it by comments in one source file.
- Before either, on uncommitted work: red, 117 failing tests of 3521. *Architectural decisions* has what that run measured.

**Warnings: 0.** `scripts/warnings` exits 0, and its header reads `measured at : 075424d5 (clean)` and `compiled : every file — the build directory was emptied first`. It ran straight after the suite.

Mutation plan: `mutation/plans/feature/three-runs-and-a-pill-each.txt` (founder-triggered, not run on this branch). **Fourteen** mutants: S1 to S9 for the Retry, H1 for the cancellation hop, V1 and V2 for voice, C1 for the cap, K1 for the key. `scripts/mutate mutation/plans/feature/three-runs-and-a-pill-each.txt --check` → 14 mutants, each `1 match`, exit 0, at `075424d5`.

**Five were proved by hand, in two builds, and nine were not.** Each build applied several mutants together and read them per killer, which is sound here because their killers are disjoint. Each was put back from a byte copy and not with `git checkout`, because the tree held uncommitted work both times.
- H1 was killed by all three cancellation tests. The capture-review test took 30 s to fail, which is its backstop's deadline.
- S2 was killed by `aBannerForABackgroundRunRetriesThatRunAndNotTheOneOnScreen`.
- V1 was killed by `aStopThatFailsSaysSoOnTheRunTheRecordingStartedOn` and by the scan beside it.
- C1 was killed by `aFourthCommandIsRefusedWhileThreeRunsAreInFlightAndStartsOnceOneFinishes`.
- K1 was killed by `theEmergencyKeyStopsEveryRunWhicheverOneTheWidgetShows`.
- **An earlier form of S1 found a test that could not fail.** It dropped the token check and left a second guard, `slot.errorMessage != nil`. `aBannerPressedAfterAnotherTaskWasRunRetriesNothing` stayed green under it, because in that test the later task had succeeded, so the second guard refused on its own. `aBannerPressedWhileItsFailureStandsRetriesThatTaskOnce` did kill it. Two things changed. The second guard is gone, because the slot holds a token only beside the failure it was minted for, so no test could tell that guard from its absence. And the first test now also presses the old banner while a *different* task's failure is showing, which is the one state only the token tells apart. S1 as written in the plan is the door with no guard at all. It has not been run in that form.
- S3 to S9 and V2 are written and not run.
- **`twoRunsInFlightTogetherBothLandInTaskHistory` has no mutant, and that is recorded rather than hidden.** It passed the first time it ran, with no code written for it. The mutants that would break it are the three the first layer named, which drop the `RunScope` binding inside a `Task`. They are still equivalent: a `Task` inherits its creator's scope, and nothing can move focus yet.

The first layer's plan: R4, R7, R8 and R10 targeted text this branch moved. Each is re-anchored on the new text and breaks the property it broke before. `scripts/mutate mutation/plans/feature/more-than-one-run-at-once.txt --check` → 10 mutants, each `1 match`, exit 0, at `075424d5`. None was re-proved.

Behavior added:
- **A "Task failed" notification's Retry re-runs the task it was posted for, or nothing.** The notification carries its run and a retry token. `retryFailedRun` refuses unless that token is still the run's. Three things retire it: the failure being cleared, a newer failure on the same run, and a new submission on the run. The third is synchronous, in `RunSlot.setLastCommand`: `start()` writes the command a main-actor turn before `performStart` clears the old failure, and the token must not outlive the command it was raised beside.
- **A failure that is nobody's task offers no Retry.** `errorMessage` carries two kinds of failure. A run's own task failing is published at 4 sites, in `performStart` and `performApproval` (`git grep -cP '^\s+setRunFailure\(' 075424d5 -- Sources/MacAgent` → 4). Everything else is published at 34: a control that could not do what it was pressed for, a recording that would not start, a command that was never submitted, and the cap's own refusal, which this branch adds (`git grep -cP '^\s+setError\(' 075424d5 -- Sources/MacAgent` → 33 in `AgentViewModel.swift` and 1 in `AgentViewModel+VisionSession.swift`). The pattern can match: the same command with `(private )?func setRunFailure\(` in place of the call → 1. Only the first kind mints a token. The second kind posts in a category with no button. Before, "Microphone permission was denied" arrived with a Retry that re-ran whatever had been asked before it.
- **A screen-control question's cancellation resumes the run that parked it.** Nothing a person can see with one run. *Architectural decisions* has the mechanism.
- **A voice recording writes to the run it started on.** The run is captured once, where the recording starts, beside its origin and its purpose. The recording task, the stop and the transcription all run inside it. Nothing a person can see with one run.
- **The cap of three.** `start()` refuses when three runs are in flight. It says "Sonny is already working on three tasks. Try again when one finishes." on the run the command was typed into, and leaves the typed words in the composer. The number is spelled from `maximumConcurrentRuns`. It cannot be reached in the product yet, because no second run can start.
- **`⌃⌥⎋` stops every run.** The handler walks every slot and stops what is in flight there, in that slot's own scope, through `cancelCurrentRun`.

Behavior preserved (required, no blanket claims):
- The widget's Retry and Command Center's failure row still call `retryLastCommand()` on the run they are drawn on. They are controls on that run's own panel, so the run on screen is the right run. Neither file is touched.
- `retryLastCommand()` keeps every guard it had: nothing to retry, anything in flight on the run, the workspace binding carried from `lastAssessedScope`, and `armRestartOfTaskInFlight()`. The named door calls it inside the run's scope and adds only the token check in front.
- A failure still posts "Task failed" only while the user is not working in Sonny, and still records SONNY-121's hold on the run that failed. That line is pinned now (`theBannersRetryNamesTheFailedTaskAndTheHoldNamesTheRunThatFailed`). PR #279's delta review had found that `markOutcomeAsNotified()` bare passed the suite.
- `errorMessageRaised` is a `PassthroughSubject` and does not replay, by the founders' ruling of 2026-09-19. An error already set when Sonny launches still posts nothing.
- The "Approval needed" notification, its Allow and `approveParkedRun` behave exactly as PR #279 left them. The content it posts is built by `SonnyNotificationContent.approvalNeeded`, with the same title, body, category and `userInfo`.
- A click on a notification's body lands where it did for every category: the finished task's dialog, Command Center for a scheduled, storage or watcher notice, and the widget for everything else. The decision moved into `SonnyNotificationResponse` with the same `case` lines. The three scans that pinned a closure call follow the two steps it takes now.
- **`⌃⌥⎋` with one run does what it did**, with one difference at the edge. The key is registered on a session's first progress report and released when the session ends, so whenever it can fire there is a session on the one run, and stopping "every run with something in flight" is stopping that run. The difference: `emergencyStopVisionSession()` does nothing unless a session is live, and the new handler also stops a run that is in flight with no session. That can only be met in the moment between a session ending and the key being released. Stopping is the right answer there. The four Stop *controls* still call `emergencyStopVisionSession()`, and none of their files is touched.
- **Every existing voice test passes unedited.** With no recording's run on record, the stop falls back to the run in scope, which is what it read before. The two scans that read `stopVoiceRecordingAndTranscribe`'s body as one block still do: the binding wraps the body and moves nothing out of it.
- A command typed with fewer than three runs in flight starts exactly as before. With one slot, `runsInFlight` can be at most 1.
- A screen-control question cancelled with one run behaves as before. With one run, the run that parked and the run on screen are the same run, so the bound hop reads the continuation the unbound one read. `VisionSessionRunTests` passes unchanged.
- Command Center's attention panel, running indicator and Tasks group, the consequence rule and the pill's System B tokens are untouched: `git diff --stat 856bb7ee 075424d5 -- Sources/MacAgent/CommandCenterView.swift Sources/MacAgent/FloatingWidgetView.swift Sources/MacAgent/RunPillView.swift Sources/MacAgent/RunPillPresentation.swift Sources/MacAgent/RunPillWindowController.swift Sources/MacAgent/SonnyWidgetTheme.swift Sources/MacAgentCore server` prints nothing, and the same command over `Sources/MacAgent/AppDelegate.swift` prints a line, so it can.

Architectural decisions / pitfalls discovered (required, write "none" if true):

**A Retry is tied to a failed task, not to a failure message, and the difference was the second defect.** The ticket names one defect: the banner is pressed late, and re-runs a newer command. Writing the fix found another of the same kind. Most sites that publish a failure are not a task failing, and their banner's Retry re-ran an unrelated earlier command. "Which failures can be retried" was never stated anywhere. `hasRetryableCommand` answers "does this run hold any last command", which is a different question. The answer is now at the publishing site: `setRunFailure` or `setError`. It is a named call and not a rule derived from `isRunning` or from `RunScope`. A control's failure can land on a run that happens to be running. And the voice path, which this ticket still owes a binding, would make a derived rule wrong the day it is bound to a run.

**The token is cleared by the submission, not only by the clear.** `start()` writes `lastCommand` and sets `isRunning` synchronously, and `performStart` clears the old failure one main-actor turn later. In that turn the run holds the old failure, the old token and the *new* command. `retryLastCommand`'s own in-flight guard covers that window today. The token rule should not rest on a guard somewhere else, so `setLastCommand` retires it.

**What a notification carries and where a press lands are two pure types, because the service cannot exist in a test process.** `UNUserNotificationCenter.current()` raises without a bundle identity. That is why PR #279's review (F3) found the whole trip from a parked question to its pressed Allow held by source scans. `UNMutableNotificationContent` builds fine in a test process, so `NotificationRoundTripTests` builds the real content, reads its real `userInfo` and category, and asks the real decision where a named button lands. What is left outside a test is only `center.add` and the delegate callback's three property reads.

**`onCancel` runs in the context of whoever cancelled.** A `Task` started there inherits the canceller's task-locals, not the parked run's. `RunScope`'s doc listed the four hops as owed. `RunAttributedCancellationTests` parks real questions on two slots and cancels from outside any run, which is where a pill's Stop, the hotkey and `start()`'s own `currentTask?.cancel()` all cancel from. The approval and the delegation questions cannot be parked from a test without a live session (`RedactedPayload`'s initialiser is `fileprivate`), so a scan holds all four sites to the one helper.

**A full run beside another lane's suite measures the machine.** The first full run on this branch was red with 117 failing tests, 113 of them in `VisionSessionRunTests`, at a one-minute load average of 139 with another lane's `swift-test` running. That suite alone then passed. The other four were source scans this branch had moved, which are fixed. The figures above are from a later run and carry the load they were taken at.

Known limitations / deferred scope:

**SONNY-456's feature is not switched on.** What is left, in order, with what this lane learned about each. Items 1 to 3 are what lets a second run exist, and they belong together: a second run with no pill is a task the user cannot see.
1. **Slots for new runs.** A design this lane reached and did not build. `dispatch()`, called outside any run, picks the slot: the focused one if it is free, then another free slot, then a new one. It keeps the composer's draft, which it overwrites today. A run starting should minimise the widget only when it is the focused run; today any run starting resets `widgetWasExpandedForThisRun` for all of them. Slots then need a rule for going away: an idle, unfocused slot with no outcome and no task is pruned, and a slot with work in flight, or a `Task` still holding its scope, never is (`runSlotInScope`'s doc).
2. **Focus.** A summon keeps the focused run when it is parked on a question or free. Otherwise it goes to the newest parked question, and otherwise to a free slot. A pill's click focuses its own run. Every summon goes through `widgetPresentationRequest`'s `didSet`, the pill's click included, so the pill needs a door of its own that sets focus first. The "Approval needed" notification's body click should land on its own run; it carries the run already.
3. **One pill per run**, stacked down from the top-right with the widget's spacing. `RunPillWindowController` hosts one `RunPillView` today, which reads the focused run. A pill's Pause and Stop need their run: `emergencyStopVisionSession` and `pauseVisionSession` act on the run in scope.
4. **Screen control one session at a time.** A session starts two ways, `startVisionSession` and any plan the planner writes with a `.visionSession` step, so the refusal belongs where a prepared plan is about to execute, in `performStart` and `performApproval`. The session's environment, pause monitor and hotkey are still one per view model.
5. **"Don't save this task" per run**, and the other state `RunSlot`'s doc lists as still one per view model.
6. **The scheduler, the five run guards and the in-memory clear read every slot.** `checkScheduledRoutines` starts its run in the focused slot and restores that slot's origin afterwards; the reading that changes no behaviour is to refuse while any slot is in flight. The whole wipe, the set-aside files, memory, a routine and a workspace each refuse on the focused run alone (`deleteLocalData`, `deleteSetAsideFiles`, `deleteMemory`, `deleteRoutine`, `deleteWorkspace`). `clearInMemoryLocalDataState` mixes per-run and global state and clears the focused slot only. It was left for a session of its own on purpose: it is a privacy wipe, and `ProductShellTests`' classifier reads that function's text.
7. **The three `Task`-binding mutants**, each needing a test that moves focus mid-run. They arrive with item 2.

**Not on this branch by instruction:** Command Center's attention panel, running indicator and Tasks group over the list of runs. That is SONNY-540.

**Recorded rather than fixed:**
- `RunSlot.parkedApproval` still has no reader (`git grep -nE 'parkedApproval' 075424d5 -- Sources Tests` → the declaration alone, at `RunSlot.swift:206`). `RunSlot.failedTask`, its twin, does: `publishFailure` reads it.
- `addRunSlotForTests()` still ships with no production caller. The feature's own slot creation replaces it.
- A refused Retry leaves only a log line, "Not retried: that failure is no longer showing.", like a refused Allow. That fits the no-explanatory-copy rule.

Open questions (required, write "none" if true): **one, for the founders.** A failure that is not a task now posts a "Task failed" notification with no button. The title is still wrong for it: "Microphone permission was denied" is not a task failing. SONNY-535 already asks what a problem found at launch should say. Should these failures share that answer?

Next branch: the rest of SONNY-456, continuing on this branch or on one cut after it merges, as the founders decide.
