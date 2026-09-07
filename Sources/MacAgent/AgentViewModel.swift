import AppKit
import Foundation
import MacAgentCore

@MainActor
final class AgentViewModel: ObservableObject {
    @Published var command: String = ""
    @Published var isRunning: Bool = false
    @Published var plan: AgentPlan?
    @Published var finalSummary: String = ""
    @Published var errorMessage: String?
    /// Whether the current `errorMessage` is a persistent configuration problem (missing API key,
    /// denied mic permission, unavailable hotkey) that will keep being true until the user actually
    /// fixes their setup — as opposed to a transient, one-off outcome (a failed task, an empty
    /// transcription, a validation nudge) that's fully resolved by simply trying again. Only the
    /// latter auto-clears (see `FloatingWidgetView`'s failure-timeout) — the widget is a permanent,
    /// undismissable overlay, so a persistent problem needs to keep saying so, but a transient one
    /// sitting there forever after the moment has passed is exactly as stale as the bug this was
    /// built to fix. Set via `setError(_:persistent:)`, never assigned directly.
    @Published private(set) var errorIsPersistent: Bool = false
    @Published var clarificationQuestion: String?
    @Published var clarificationAnswer: String = ""
    @Published var suggestions: [RunSuggestion] = []
    @Published var stepStatuses: [String: AgentStepStatus] = [:]
    @Published var isPreparingVoiceRecording: Bool = false
    @Published var isRecordingVoice: Bool = false
    @Published var isTranscribingVoice: Bool = false
    @Published var voiceHotKeyStatus: String = "Hold Ctrl-Opt-Space"
    @Published var voiceHotKeyReady: Bool = true
    @Published var permissionItems: [PermissionReadinessItem] = []
    /// Whether a Sonny session is held on this Mac, as the readiness row reads it (SONNY-136).
    ///
    /// Starts `.undetermined` and is answered by `refreshModelAccessReadiness()`. It is not derived
    /// on demand because the read is an actor hop and every reader of it is synchronous.
    @Published private(set) var modelAccessReadiness: ModelAccessReadiness = .undetermined

    // MARK: - Version (contract §8, SONNY-402)

    /// What the deployment has said about this build — §8.3's wall, §8.4's warning, or neither.
    ///
    /// **One value on the shared view model, because both surfaces render it and they must not be
    /// able to disagree.** `.claude/rules/macagent-ui-conventions.md` makes that the rule for every
    /// attention state; this one has a sharper reason than most, since a build that is too old fails
    /// every backend call and a user looking at the wrong surface would see only the failures.
    ///
    /// Written by ``clientVersionDidChange(_:)`` alone, from the client's own stream.
    @Published private(set) var clientVersionState: ClientVersionState = .current
    /// Whether §8.4's warning has been waved away for this state.
    ///
    /// **The warning is dismissible and the wall is not**, which `ClientVersionCopy.dismissLabel`
    /// argues at the copy: a band a user sits in for weeks would otherwise park a banner on the
    /// widget over every idle moment and hold the resume offer off screen for the whole time.
    /// Cleared whenever the state changes, so the next thing the deployment says is heard.
    @Published private(set) var hasDismissedUpdateAvailablePrompt = false
    /// Injected so a test can assert the URL that would have opened without a browser launching on
    /// the machine running the suite — `SonnyAccountModel.openPortalURL`'s pattern exactly, and for
    /// the same reason. `main.swift` leaves it at the default.
    ///
    /// **Nothing reaches this without passing ``ClientUpgradeLink``** — the state's `link` is `nil`
    /// unless the server-supplied string parsed as `http` or `https`, which is the founder's
    /// decision of 2026-09-04 and the reason there is no scheme check at the press.
    var openUpgradeLink: @MainActor @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var clientVersionObservation: Task<Void, Never>?

    /// §8.3's wall: nothing that needs the gateway can succeed until the app is updated.
    var isTooOldForThisBackend: Bool {
        if case .tooOld = clientVersionState { return true }
        return false
    }

    /// §8.4's warning, as a surface should ask it — the state *and* whether it has been waved away.
    var showsUpdateAvailablePrompt: Bool {
        if case .updateAvailable = clientVersionState { return !hasDismissedUpdateAvailablePrompt }
        return false
    }

    /// Start reading the client's version stream, then make §8.3's launch call.
    ///
    /// **The observation is installed before the fetch, and the order is deliberate**: the stream
    /// yields the state it already holds as its first element, so an observer that arrives late is
    /// merely late rather than wrong — but installing it first means the launch fetch's own result
    /// cannot fall between the two.
    ///
    /// Called once, from `AppDelegate.applicationDidFinishLaunching`. §8.3's "on any `410`" half
    /// needs no call site at all: it lives inside `SonnyBackendClient.send`, which is the one place
    /// every route's refusal passes through.
    func beginWatchingClientVersion() async {
        clientVersionObservation?.cancel()
        let client = backendClient
        clientVersionObservation = Task { [weak self] in
            for await state in await client.clientVersionUpdates() {
                guard let self else { return }
                self.clientVersionDidChange(state)
            }
        }
        await backendClient.refreshMetaDocument()
    }

    /// Stops the observation. For a test fixture, which is discarded while the shipping app's view
    /// model lives as long as the process does.
    func stopWatchingClientVersion() {
        clientVersionObservation?.cancel()
        clientVersionObservation = nil
    }

    /// Internal rather than `private` so a surface test can put the view model into either state
    /// without a stub gateway — the same reason `AppDelegate.decideFirstRunAfterRestoringTheSession`
    /// is internal. What the *client* derives from real responses is
    /// `ClientVersionClientTests`' subject; what the two surfaces do with the result is this one's,
    /// and driving the second through the first would make every precedence assertion depend on a
    /// round trip it is not about.
    func clientVersionDidChange(_ state: ClientVersionState) {
        guard state != clientVersionState else { return }
        clientVersionState = state
        // A dismissal answers the state it was pressed on. When the deployment says something
        // different — a new link, or the wall after the warning — the user has not seen it yet.
        hasDismissedUpdateAvailablePrompt = false
    }

    func dismissUpdateAvailablePrompt() {
        hasDismissedUpdateAvailablePrompt = true
    }

    /// Opens the upgrade link in the default browser, and does nothing when there is none.
    ///
    /// Both surfaces call this and neither renders a control unless `clientVersionState.link` is
    /// non-`nil`, so the guard here is the belt: a link that did not parse as `http` or `https`
    /// never became a `URL` in the first place.
    func openClientVersionLink() {
        guard let link = clientVersionState.link else { return }
        openUpgradeLink(link)
    }
    @Published var savedRoutines: [StoredRoutine] = []
    /// What Sonny is currently waiting on — the Routines page's Watching list (SONNY-382).
    ///
    /// **On Routines rather than in Memory, by founder decision** (recorded on SONNY-236 and
    /// SONNY-109): Memory is what Sonny remembers, and a live watcher is what Sonny is doing.
    ///
    /// Loaded beside `savedRoutines` in `refreshSavedItems()` so the page's two lists are always as
    /// fresh as each other, and so every path that already refreshes after a run, a delete or a wipe
    /// refreshes this one too rather than needing to learn about it.
    @Published var standingWatchers: [StandingWatcher] = []
    @Published var savedWorkspaces: [StoredWorkspace] = []
    @Published var approvalRequest: RiskApprovalRequest?
    /// The Safe-mode capture preview waiting for an answer, or `nil`. Safe mode only — founder
    /// decision 2 (2026-08-14) has Safe show each capture before it is sent.
    @Published var visionCapturePreview: VisionCapturePreview?
    /// What the running vision session is doing, for the HUD. `nil` when no session is live.
    @Published var visionSessionProgress: VisionSessionProgress?
    /// The delegation waiting for a Safe-mode answer, or `nil`. Safe mode only — founder decision 4
    /// (2026-08-14) has Safe ask before a delegation fires while Normal and Power never do.
    @Published var visionDelegationRequest: VisionDelegationRequest?
    /// A session paused because the user stopped being at the Mac, or `nil`. Resuming is an explicit
    /// action (SONNY-94): nothing here resolves on a timer or on the screen simply unlocking.
    @Published var visionSessionPause: VisionSessionPause?
    /// The ran-without-asking trace for the last completed run (SONNY-99, reshaped by the
    /// consequence rule 2026-08-13), or `nil` when the run's silence was ordinary — tier 0/1, a
    /// prompt that was answered, or a routine covered by its own trust toggle. The sentence itself
    /// comes from `AgentActivityPresentation.ranWithoutAskingLine` — pure and tested, because no
    /// SwiftUI inspection harness exists to pin what a view renders. Set only after a silent run
    /// actually executed (a run that drifted to a prompt was disclosed by the prompt), cleared at
    /// the start of every task, and untouched by the scheduled path, which never writes it.
    @Published private(set) var ranWithoutAskingTrace: String?
    @Published var clipboardHistoryEnabled: Bool = true
    /// The Memory section's switches, composed from the user's own choices and the enterprise
    /// policy (SONNY-208). `private(set)` because every write goes through `setMemoryEnabled(_:)`
    /// or `setMemoryCategoryEnabled(_:to:)`, which persist first and then republish — a settable
    /// property would let a surface show a switch the store never recorded.
    @Published private(set) var memorySettings: MemoryRecordingSettings = .recordEverything
    /// Snippets, recent artifacts, clipboard items, allowed apps and output locations as the Memory
    /// section lists them. Loaded by `refreshMemoryEntries()`; empty until it runs, and emptied
    /// rather than left stale when a store will not read — the same choice `refreshTaskHistory`
    /// makes, so a list can never show entries the notice beside it says are unreadable.
    @Published private(set) var savedSnippets: [StoredSnippet] = []
    @Published private(set) var recentArtifacts: [RecentArtifact] = []
    @Published private(set) var clipboardHistoryItems: [ClipboardHistoryItem] = []
    @Published private(set) var approvedApps: [ApprovedApp] = []

    /// How many grants the file holds, **before** the deny-list filter `approvedApps` applies.
    ///
    /// The two differ only when the store holds a grant no surface will render, which is the whole
    /// reason this exists: Settings' Remove All is offered on this rather than on the rendered list,
    /// so the one control that reaches such a grant is present exactly when there is one to reach
    /// (PR #175 review, F1). Written by `refreshMemoryEntries()` from the same load, so it cannot
    /// disagree with `approvedApps`; zero when that load fails, like every other list here.
    @Published private(set) var storedApprovedAppCount: Int = 0
    @Published private(set) var outputLocations: [OutputLocation] = []
    /// Runs that began and did not finish (row 13, SONNY-210), newest activity first.
    ///
    /// Published rather than read on demand because two surfaces render it and they must agree: the
    /// Memory section's "Unfinished tasks" row and the floating widget's own offer to carry one on.
    /// Reloaded from the store after every write this view model makes to it, so the offer can never
    /// name a record the file no longer holds.
    @Published private(set) var resumableTasks: [ResumableTask] = []
    /// How far the running job over many items has got, or `nil` when the run in flight is not one
    /// (row 13, SONNY-235).
    ///
    /// **Published from the run rather than read off the checkpoint, and that is deliberate.** The
    /// obvious source is `activeResumableTask`, which already carries the plan, the completed step
    /// ids and the failures — and it is `nil` whenever the user has unfinished-task memory switched
    /// off, so a job would then run with no progress shown at all. Progress is the founder's own
    /// condition on approving a whole job in one press ("visible progress and a stop control while it
    /// runs", 2026-08-31); it is what the user watches, not something Sonny remembers, so it must not
    /// be gated on a memory switch. The two are computed by the same `ItemJobProgress.of` from the
    /// same three inputs, so they cannot disagree about what they both cover.
    @Published private(set) var itemJobProgress: ItemJobProgress?
    /// Every store whose file will not read, as of the last probe (SONNY-239).
    ///
    /// **The one source both the Memory page's words and its Delete read**, which is the whole of
    /// this property's history (PR #110 fix-round review). The row's copy used to come from
    /// `localStorageLoadFailures` — what something had *happened* to load and fail on — while the
    /// delete came from a probe. They disagreed in both directions: a confirmation promising to
    /// delete a file the press then kept, and the mirror case. Worse, that dictionary has eleven
    /// sources against fourteen stores, so the Task history row could never report damage from the
    /// vision journal or Shortcut run history, `canDelete` collapsed to `count > 0`, and an empty
    /// task history beside an unreadable `shortcuts-run-history.json` was the founder's original
    /// dead end reproduced inside the fix for it.
    ///
    /// **Published rather than computed on demand, because the row asks on every render.** Probing
    /// is a file read per store; a view body cannot do that. So it is refreshed at the moments that
    /// can change it — the Memory page appearing, a run terminating, and a delete about to act.
    ///
    /// **Still `Set<LocalStore>` rather than `Set<MemoryCategory>`**: Task history covers four
    /// stores and the delete has to act per store, so collapsing to the row would throw away the
    /// distinction the split depends on.
    @Published private(set) var unreadableStores: Set<LocalStore> = []
    /// Outcome of the Memory section's per-type Delete, rendered by the same
    /// `LocalDataDeletionStatusMessage` view Settings' whole-wipe uses. Separate from
    /// `localDataDeletionStatusMessage` so a per-type delete does not post its result onto the
    /// Settings page, and vice versa.
    @Published var memoryDeletionStatusMessage: String?
    /// What the Memory page's last per-row Delete did — which row, how many files it deleted, where
    /// it put the files it could not read, and whether a step failed — or `nil` when the last one
    /// kept nothing.
    ///
    /// **A record rather than the bare list of kept files, because the sentence beside the Reveal
    /// control has to follow the files** (PR #117 review, F1). Settings' narrower control and the
    /// whole wipe can each remove *some* of those files and fail on the rest; "The 2 files Sonny
    /// could not read are still on your Mac" then names a file that is gone, and a control that
    /// reveals it selects nothing. The list alone could be pruned but the sentence could not be
    /// rewritten — it needs the row and the deleted count — so both are kept together, and
    /// `MemoryDeletionCopy.perRowDeleteReport` derives the sentence from the record in one place,
    /// at the press and again after a prune.
    ///
    /// Published because the Reveal in Finder control renders off it, and replaced by every per-row
    /// Delete — one that keeps nothing sets it to `nil` — so the control cannot outlive the message
    /// it sits beside.
    @Published private(set) var lastPerRowDelete: LastPerRowDelete?

    /// Where the last per-row Delete put the files it could not read, or empty — the record's list,
    /// read through the name the Reveal in Finder control and its tests already use.
    var setAsideFilesFromLastDelete: [URL] {
        lastPerRowDelete?.keptFileURLs ?? []
    }
    /// How many files are set aside across the fourteen stores and how much space they hold — the
    /// line Settings' Data page shows, with the control that removes them (SONNY-266, founder
    /// decision 2026-08-24).
    ///
    /// Published rather than computed, for the reason `unreadableStores` gives: a view body cannot
    /// list a directory. Refreshed at the moments that change it — the Data page appearing, a
    /// per-row Delete that keeps a file, the whole wipe, and the control itself — and read from the
    /// same `LocalDataDeletionService` the control deletes through, so the count the user sees and
    /// the files the press removes are one listing.
    @Published private(set) var setAsideFilesSummary: SetAsideFilesSummary = .none
    @Published var priorTaskContext: PriorTaskContext?
    @Published var taskUsageSummary: TaskUsageSummary = .empty
    @Published var taskHistoryRecords: [CompletedTaskRecord] = []
    /// The Tasks page's search query.
    ///
    /// On the view model rather than local to the view, per `.claude/rules/macagent-ui-conventions.md`'s
    /// shared-state rule: both surfaces observe this one instance, and new page state lives here even
    /// when it feels surface-local. It also outlives a page switch, so a query survives a trip to
    /// Insights and back rather than silently clearing.
    ///
    /// Deliberately not persisted. A search is a thing the user is doing now, not a preference —
    /// reopening Sonny to a filtered task list with no memory of having typed anything would read as
    /// a bug.
    @Published var taskHistoryQuery: String = ""

    /// "Don't save this task" — whether the next run leaves traces (SONNY-120).
    ///
    /// **Per task, and reachable only before dispatch.** A Settings switch that stays on was
    /// declined by the founder on 2026-08-16: it is easy to forget and silently loses weeks of
    /// history for unrelated tasks. Flipping it mid-run is refused for a harder reason — it would
    /// promise to un-write records already on disk, which it cannot do. The widget enforces that by
    /// not offering the control while a task is in flight; `finishRecordingPolicyIfSettled()` is
    /// what puts it back to `.record` afterwards.
    ///
    /// Never applies to scheduled runs. A scheduled run passes through no composer, so there is no
    /// switch to have been left on — stated here so its absence does not read as a gap.
    @Published var taskRecordingPolicy: TaskRecordingPolicy = .record

    /// A finished run's summary, published for the notification fallback (SONNY-56).
    ///
    /// **Written only for a successful run whose origin is Command Center**, and that narrowness is
    /// the design rather than an oversight:
    ///
    /// - *Widget-origin runs* already show their result in the widget's own panel, which is a
    ///   permanent overlay and therefore on screen even while the user works elsewhere. Notifying
    ///   would be the duplicate the origin gate exists to prevent.
    /// - *Scheduled runs* have `scheduledRunNotice`, which already carries their summary and already
    ///   has its own notification subscription.
    /// - *Failures* already reach the user through `errorMessage`, which has its own subscription.
    ///   Publishing them here too would notify twice for one run.
    ///
    /// That leaves exactly the case the founder resolved on 2026-08-06: a run started from a Command
    /// Center row action, which reports its outcome on no surface at all.
    ///
    /// Transient — set at the moment a run succeeds and not persisted. SONNY-121 owns making a
    /// notified outcome survive until the user acknowledges it, and this is the signal it builds on.
    @Published var completedRunNotice: CompletedRunNotice?

    /// A request to open one task's detail dialog, set when the user clicks a finished-run
    /// notification (PR #67 review, F4). `CommandCenterView`'s Tasks page observes it and presents
    /// the same sheet a click on a history row opens.
    ///
    /// Published state rather than a direct call because the sheet is driven by view-local state the
    /// app delegate cannot reach, and `.claude/rules/macagent-ui-conventions.md`'s shared-state rule
    /// puts new cross-surface state on the one view model.
    @Published var taskDetailRequest: TaskDetailRequest?

    /// Opens a task's detail dialog by id, if that task is still in history.
    ///
    /// Returns `false` when the id resolves to nothing — a task deleted between the notification
    /// arriving and the click, or a suppressed run that never wrote a row. The caller decides what
    /// to do with that; this does not invent a fallback of its own.
    @discardableResult
    func requestTaskDetail(taskID: String) -> Bool {
        guard taskHistoryRecords.contains(where: { $0.id == taskID }) else {
            return false
        }
        taskDetailRequest = TaskDetailRequest(taskID: taskID)
        return true
    }

    /// Whether the outcome currently on screen is one the user was **notified** about (SONNY-121).
    ///
    /// The founder's decision of 2026-08-04: a notified outcome persists until acknowledged. The
    /// widget is a permanent overlay, so an outcome nobody acknowledged used to auto-collapse after
    /// six seconds and then be wiped by `clearStaleTaskOutcome()` — which is fine for an outcome the
    /// user watched happen, and wrong for one they were pulled away from. Clicking the notification
    /// after that landed on a compact capsule with nothing in it.
    ///
    /// **Why this is a flag and not a rule the view model can derive.** Being notified is a fact
    /// about the *user's attention* — Sonny was not the app they were working in — and only
    /// `AppDelegate` knows that, because the answer lives in `NSApp.isActive` and the widget panel's
    /// key state (see `SonnyAttention`). So the delegate that posts the notification is what records
    /// that it happened.
    ///
    /// **Acknowledged means the user acted**, not that the widget came forward: it clears when they
    /// retry or submit another command, and deliberately *not* when the panel is merely fronted.
    /// Being on screen is not the same as being read, which is this ticket's whole premise.
    @Published private(set) var outcomeWasNotified: Bool = false

    /// Records that the outcome now on screen reached the user as a notification. Called by
    /// `AppDelegate` immediately after it posts one, because the gate that decided to post is its
    /// to evaluate.
    func markOutcomeAsNotified() {
        outcomeWasNotified = true
    }
    /// Local-storage health, kept deliberately separate from `errorMessage`: a corrupt store or
    /// a failed save is about Sonny's own data, not about the task the user just ran, and must
    /// never make a successful task read as failed. Rendered as its own notice on both surfaces.
    @Published var localStorageNotice: String?
    /// What the scheduler did while nobody was watching — a routine ran, or was skipped and why.
    ///
    /// Its own channel rather than `errorMessage` or `localStorageNotice`, following the split this
    /// project already draws: `errorMessage` means "the task *you ran* failed", and a scheduled run
    /// is not one; `localStorageNotice` means "something ambient needs your attention", which is the
    /// right shape but the wrong subject. A user has to be able to tell "my 9am routine didn't run"
    /// apart from "your snippets file is corrupt", because the two need different actions.
    ///
    /// Carries successes too, not just skips: an action taken with nobody watching should be
    /// visible after the fact, which is the whole reason unattended execution needs a surface.
    @Published var scheduledRunNotice: String?
    /// What a standing watcher has to say — it fired, or it stopped and why (SONNY-236).
    ///
    /// **A fifth channel rather than a reuse of `scheduledRunNotice`, and the shapes are genuinely
    /// different.** That one reports what the *scheduler* did with a routine the user set up, and its
    /// notification click lands on the Routines page where a paused schedule is switched back on. A
    /// watcher notice reports a fact about the outside world, and the thing a user does with it is
    /// go and look at the page — there is nothing in Sonny to fix. Sharing the channel would also
    /// share the notification category, and a category is where the difference would become visible
    /// as the wrong action on a banner, which is how SONNY-113 and SONNY-187 each ended up with a
    /// Retry button on something that could not be retried.
    ///
    /// **Not `errorMessage`, ever.** A watcher that gives up on an unreachable page has not made the
    /// user's task fail — there is no task. `errorMessage` outranks `.result` in the widget, so a
    /// notice routed there would replace the result of whatever the user actually ran.
    @Published var watcherNotice: String?
    /// **`plannerFallbackNotice` stood here and is gone** (SONNY-132), along with the widget strip
    /// that rendered it. It said which planner had actually planned a task when the configured
    /// selection could not be honored, and every state it could describe has stopped existing.
    /// Enumerated rather than asserted, because "nothing reaches this any more" is exactly the
    /// class of claim that needs the enumeration:
    ///
    /// 1. **An unknown selection id.** There is no selection: `SONNY_PLANNER` is deleted and
    ///    `PlannerProviderRegistry.resolve(selection:)` with it.
    /// 2. **A selected provider that would not construct.** There is one planner and
    ///    `OpenAIPlanner.init` cannot fail — `PlannerFactory` does not throw, which is why the
    ///    construction site no longer has a `try`.
    /// 3. **The server failing over between providers.** Deliberately invisible.
    ///    `docs/sonny-backend-api-contract.md` §4.2 states it — "The response names no provider and
    ///    no model" — and the no-explanatory-copy rule says the same thing from the product side:
    ///    the task ran, nothing the user asked for failed, and a strip announcing that a different
    ///    vendor was used would explain an internal to somebody who cannot act on it.
    /// 4. **Every provider in the chain failing.** That is a failed task, and it has always gone to
    ///    `errorMessage` through `PlannerError.backend` and `SonnyBackendCopy.sentence(for:)`,
    ///    whose every branch names what happened and what to do next and no vendor at all.
    ///
    /// So there is nothing left to replace it with, which is the ticket's sixth requirement
    /// answered rather than dodged: the user is still told when something did not work, by the
    /// surface that has always told them, in words that name no vendor.
    @Published var localDataDeletionStatusMessage: String?
    /// Set on every `start()`. Approving a pending run genuinely does not touch it —
    /// `performApproval` reuses the existing prepared run. A clarification answer *does* go back
    /// through `start()` and reassign this, but `submitClarification()` passes the preserved
    /// original origin, so the observable value still doesn't change across the pause. See
    /// `TaskOrigin`.
    @Published private(set) var activeTaskOrigin: TaskOrigin = .commandCenter
    /// Bump counter every hand-driven "bring the widget forward and take focus" entry point goes
    /// through — Command Center's "New routine"/"Create workspace" quick actions (which pre-fill
    /// `command` with a starting phrase and need somewhere for the user to finish typing it, now
    /// that Command Center has no composer of its own), the status menu's "New Task" item, and the
    /// push-to-talk hotkey (both via `AppDelegate.requestWidgetPresentation()`). `AppDelegate`
    /// observes this to call `widgetController.show()`; `FloatingWidgetView` observes it to focus
    /// its text field — every caller reacting through the same shared state rather than reaching
    /// into AppKit/the widget directly, since `show()` alone cannot move keyboard focus.
    @Published var widgetPresentationRequest: Int = 0
    @Published var usePointerCursors: Bool = true {
        didSet {
            userDefaults.set(usePointerCursors, forKey: UserDefaultsKeys.usePointerCursors)
        }
    }
    @Published var displayFullNames: Bool = false {
        didSet {
            userDefaults.set(displayFullNames, forKey: UserDefaultsKeys.displayFullNames)
        }
    }
    /// Gates the widget's one-time first-approval explainer copy (branch 9 checkpoint 8, split
    /// 2026-07-24 — see `docs/sonny-founder-design-decisions.md`). Flips permanently the first time
    /// the user resolves *any* approval, allow or deny — "shown once, ever," not "shown until
    /// dismissed." `private(set)`: only `performApproval`/`cancelCurrentRun`'s deny branch, the two
    /// real resolution points, should ever flip it — plus `markFirstApprovalCompleted()`, the third,
    /// added by row I for a mid-loop vision approval. The setter stays `private(set)` and that third
    /// point is a named door rather than a widened setter, so the list of things that may flip this
    /// is still enumerable by reading this comment.
    @Published private(set) var hasCompletedFirstApproval: Bool = false {
        didSet {
            userDefaults.set(hasCompletedFirstApproval, forKey: UserDefaultsKeys.hasCompletedFirstApproval)
        }
    }

    let logStore = AgentLogStore()

    private var preparedRun: PreparedAgentRun?
    private var runner: AgentRunner?
    private var currentTask: Task<Void, Never>?
    /// The parked mid-loop vision approval, and the parked Safe-mode capture preview.
    ///
    /// `var` rather than `private var` so the vision extension in
    /// `AgentViewModel+VisionSession.swift` can reach them — Swift's `private` is file-scoped, and
    /// the alternative was putting 200 lines of vision code in this 2,600-line file.
    var visionApprovalContinuation: CheckedContinuation<RiskApprovalDecision?, Never>?
    var visionCaptureContinuation: CheckedContinuation<Bool, Never>?
    var visionDelegationContinuation: CheckedContinuation<Bool, Never>?
    var visionResumeContinuation: CheckedContinuation<Bool, Never>?
    /// The wrapper the HUD's Pause writes to, held so the resume path can clear it. Set when the
    /// vision environment is built; `nil` in a build with no screen-control wiring.
    var visionUserPauseMonitor: UserPausableAttentionMonitor?
    /// Registered only while a session is live — a permanently-held global shortcut is a key
    /// combination taken from every other app forever, in exchange for a control that matters for
    /// the seconds Sonny is actually moving the cursor.
    var visionEmergencyStopHotKey: (any EmergencyStopHotKeyRegistering)?
    /// How the emergency-stop hotkey is built. Injected so a test can pin the *wiring* — that a live
    /// session really registers one and every exit releases it — without any test taking a real
    /// global shortcut. Defaults to the real Carbon registration.
    var visionEmergencyStopHotKeyFactory: (@MainActor (@escaping @MainActor () -> Void) throws -> any EmergencyStopHotKeyRegistering) = { onStop in
        try EmergencyStopHotKey(onStop: onStop)
    }
    /// The journal id of the session this task is running, or `nil`. Read once when the task's
    /// history row is written, then cleared with the rest of the per-task state.
    var activeVisionSessionID: String?
    /// The grants file's contents for the iteration currently running, or `nil` outside one.
    ///
    /// Non-`nil` only between `visionIterationWillBegin()` and the run teardown that clears it, so
    /// the three-to-four gate reads inside one iteration cost one decrypt instead of three or four
    /// (SONNY-202). Deliberately not a session-long cache: `visionAppControlState`'s contract is
    /// that a grant revoked mid-session ends the session at the *next* iteration, and a cache that
    /// outlived an iteration would defer that to the next launch.
    private var approvedAppsForThisVisionIteration: (apps: [ApprovedApp], failure: String?)?
    private let audioRecorder: AudioCommandRecorder
    private let permissionReadinessService: PermissionReadinessService
    private let routineStore: RoutineStore
    private let workspaceStore: WorkspaceStore
    private let snippetStore: SnippetStore
    private let recentArtifactStore: RecentArtifactStore
    private let shortcutCatalog: any ShortcutCatalogProviding
    // Every seam `AgentActionExecutor` exposes that reaches the real machine. Held here and
    // forwarded in `makeExecutor()` so a test can supply fakes: before this, `makeExecutor` passed
    // none of them, so each fell to its production default and any view-model test that *executed*
    // a plan drove the real system — a user watching the suite run saw Safari launch and real URLs
    // open in their browser. `AgentActionExecutor` already had every one of these as an injectable
    // parameter; only this construction path was skipping them.
    private let browserOpener: any BrowserOpening
    private let appOpener: any AppOpening
    private let fileOpener: any FileOpening
    private let mediaOpener: any MediaOpening
    private let runningAppSwitcher: any RunningAppSwitching
    private let shortcutInvoker: any ShortcutInvoking
    private let finderContextReader: any FinderContextReading
    private let documentConverter: any DocumentConverting
    private let zipArchiver: any ZipArchiving
    private let shortcutRunHistoryStore: ShortcutRunHistoryStore
    private let taskHistoryStore: TaskHistoryStore
    /// What each finished task planned (row E, SONNY-147) — the heavy half of a task's record, kept
    /// beside `task-history.json` rather than inside it so the file that is read on every list
    /// render, search and Insights pass stays small. Not `private`: SONNY-150's follow-up reads it
    /// back to rehydrate a `PriorTaskContext`, and the tests read it to assert what was written.
    let taskPlanDetailStore: TaskPlanDetailStore
    /// The action journal (row I, SONNY-96). Injected like every other store so a test writes to its
    /// own file rather than the user's.
    let visionSessionJournalStore: VisionSessionJournalStore
    private let clipboardHistorySettingsStore: ClipboardHistorySettingsStore
    /// Row J's per-app control grants (SONNY-140). Injected like every other store so a test writes
    /// to its own file rather than the user's. Nothing gates on it yet — SONNY-143 is what reads it
    /// — so the only thing this view model does with it today is probe it for load failures, which
    /// is the same wiring the other silently-read stores get.
    private let approvedAppStore: ApprovedAppStore
    /// Row 13's common output locations (SONNY-209) — which folders this Mac's work comes out into.
    /// Injected like every other store so a test writes to its own file rather than the user's.
    private let outputLocationStore: OutputLocationStore
    /// Row 13's unfinished runs (SONNY-210). Injected like every other store so a test writes to its
    /// own file rather than the user's.
    private let resumableTaskStore: ResumableTaskStore
    /// How `checkStandingWatchers` reads a watched page. See the initializer for why it has no
    /// default.
    private let standingWatcherObserver: any StandingWatcherObserving
    /// The check in flight, or `nil`. The pulse fires every 30 seconds and a fetch takes longer than
    /// that on a slow page, so without this a stalled request would have a second check start on top
    /// of it, and a third — one watcher, N concurrent fetches at somebody else's server.
    private var standingWatcherCheck: Task<Void, Never>?
    /// The watcher that check is about, and when it started — the two facts that make the slot
    /// recoverable instead of permanent (PR #184 review, F3). Written and cleared together with the
    /// task handle; `standingWatcherCheckIsInFlight` is the one predicate that reads all three.
    private var standingWatcherCheckSubject: StandingWatcher?
    private var standingWatcherCheckStartedAt: Date?
    /// Bumped whenever a check is abandoned, so a stalled task that answers later cannot write back.
    ///
    /// **Cancelling the task is not enough on its own**, which is the half of F2's fix that is not in
    /// `clearInMemoryLocalDataState`: a cancelled `Task` still runs its continuation, and
    /// `observeStandingWatcher` awaits an observer that may ignore cancellation entirely. This is
    /// what makes a late answer inert rather than merely discouraged.
    private var standingWatcherCheckGeneration = 0
    /// The watchers already notified about, so a record whose deletion keeps failing says its
    /// sentence once rather than on every pulse (PR #184 cycle 3, N1).
    ///
    /// **`finishStandingWatcher` publishes and then deletes, and a delete can keep throwing** — a
    /// read-only directory, a full disk, a permissions change. The record then survives, the expired
    /// branch re-decides `.stopped` on the *next pulse* rather than at the next check interval, and
    /// the notice fires again: measured at 11 notices across 11 pulses, one banner every 30 seconds,
    /// indefinitely. Nothing downstream coalesces them — `AppDelegate`'s sink has no
    /// `removeDuplicates()` and `deliver` mints a fresh `UUID()` per request — and PR #184's F1
    /// removed the gate that had been damping it, correctly and for reasons that still hold.
    ///
    /// **This is the guard `recordLocalStorageLoadFailure` already has**, for the identical shape
    /// recorded at PR #110's F1: republish only when it is new, or a caller on a timer turns one
    /// damaged store into a notification per tick. Chosen over deleting before publishing, which
    /// would invert an ordering argued for at `finishStandingWatcher` — publishing first means the
    /// worst case is a repeat rather than a watcher that says nothing at all.
    ///
    /// Ids rather than a count, so two different watchers stuck at once still get one sentence each.
    private var notifiedWatcherIDs: Set<String> = []
    private let clipboardHistoryMonitor: ClipboardHistoryMonitor
    /// The fourteenth store, and the one this view model never reads for a surface (SONNY-333):
    /// task deletions this Mac owes the gateway. Held so `refreshStoreReadability()` has a read door
    /// for it and so the wipe's population and this initializer's population stay the same list.
    private let pendingServerDeletionStore: PendingServerDeletionStore
    /// The other half of "delete means deleted everywhere" (SONNY-333, founder 2026-08-16 via
    /// SONNY-14). Built here from the store above and the one `backendClient`, the same way
    /// `screenControlAllowanceService` is built from that client — a second `SonnyBackendClient`
    /// would be a second token cache and a second refresh guard, which contract §3.3 reads as theft.
    private let taskDeletionService: SonnyTaskDeletionService
    /// The delivery pass in flight, if one is.
    ///
    /// **Chained rather than replaced, and what that buys is narrower than this comment used to
    /// claim** (PR #194 review, F2). Two passes running at once would each load the queue and each
    /// send a DELETE for the same entry; the chain makes a pass load *after* the previous one has
    /// finished removing what it delivered, so an entry is sent once. What the chain does **not**
    /// close is press-versus-pass: `enqueue` runs synchronously on this actor while a pass, being a
    /// nonisolated `async` method, has released it — so a press landing inside a pass's `remove`
    /// window used to lose its own entry outright. That is the file's problem rather than the
    /// scheduler's, and it is closed where it belongs, by the per-file lock inside
    /// `PendingServerDeletionStore`. The chain and the lock are both load-bearing and neither
    /// substitutes for the other.
    ///
    /// Held rather than fire-and-forgotten so a test can await the pass instead of racing it, the
    /// same reason `standingWatcherCheck` is a stored handle.
    ///
    /// **What the chain costs, since it is N passes for N presses rather than one.** Online, each
    /// pass finishes in well under a second and the queue is empty after the first, so a burst
    /// costs a file read apiece. Offline it costs one *attempt* per press, not one per queued
    /// entry — the pass stops at its first transport failure — which is a retry per press, roughly
    /// the shape a burst of deletes should have anyway. Coalescing later presses onto a single
    /// follow-up pass was the alternative and was not taken: it needs two more pieces of scheduling
    /// state and leaves a test unable to await the pass its own press produced, to save background
    /// work that is already serialized and bounded.
    private var pendingServerDeletionDelivery: Task<Void, Never>?
    /// Settings' whole wipe in flight (SONNY-404). Chained the way the delivery pass is, and for the
    /// same reason: both write the queue file.
    private var localDataWipe: Task<Void, Never>?
    private let localDataDeletionService: LocalDataDeletionService
    private let memorySettingsStore: MemorySettingsStore
    /// Row 19's seam. `UnmanagedMemoryPolicyProvider` is the only implementation that ships, so this
    /// answers `.unmanaged` in every shipping path — the hook is present and inert, exactly as
    /// SONNY-17's ratification asked.
    private let memoryPolicyProvider: any MemoryPolicyProviding
    private let priorTaskContextStore: PriorTaskContextStore
    private let taskUsageRecorder: TaskUsageRecorder
    private let backendClient: SonnyBackendClient
    /// How this view model builds the planner for a run (SONNY-132). The shipping app passes
    /// `OpenAIPlanner.throughSonnysBackend(client:)`; tests pass a stub. One seam, because there is
    /// one planner — which provider actually serves a request is `MODEL_ROUTE_PLAN` on the server,
    /// and this side is not allowed to know.
    private let makePlanner: PlannerFactory

    /// §5.1's `task_id` for the run in flight — **minted when a task starts, not when its record is
    /// written** (SONNY-130).
    ///
    /// `CompletedTaskRecord` is written at completion, so an id that only appeared in that
    /// initializer's default would arrive after every request the task made: the backend's retained
    /// content and the local row would be filed under different keys, and SONNY-134's delete would
    /// have nothing to join them on. `beginNewTaskIdentity()` is the one place it moves, and it
    /// moves with the usage recorder's reset — the two have exactly the same lifetime, which is why
    /// they are one function rather than two lines that have to be remembered together.
    private(set) var currentTaskID = UUID().uuidString
    private let userDefaults: UserDefaults
    /// The one whitelist every path this view model owns reasons with. Injectable so the
    /// ProductShell suite can drive the *real* dispatch path against a temp directory — the class
    /// of end-to-end coverage whose absence let a mapping-level green suite coexist with a live
    /// app that behaved differently (the 2026-08-13 manual-pass finding). `makeExecutor()` and
    /// `resolveTaskScope` both read it, so the assessment and the scope agree on what a path is.
    private let whitelist: PathWhitelist
    private var clipboardHistoryTimer: Timer?
    private var routineScheduleTimer: Timer?
    /// Label for the currently-running scheduled routine. Separate from `lastCommand` so a
    /// background run can drive the running indicator without becoming the retry or follow-up
    /// target — see `performScheduledRun`.
    private var scheduledRunDisplayCommand: String?
    private var wakeObserver: (any NSObjectProtocol)?
    private var clarificationAutoExecute = false
    /// Preserves the original task's origin across the clarification pause, same pattern as
    /// `clarificationAutoExecute` — `submitClarification()`
    /// re-calls `start()`, which would otherwise silently reset origin to its default.
    private var clarificationOrigin: TaskOrigin = .commandCenter
    /// The workspace this **in-flight task** is bound to, and the value handed to both
    /// `AgentRunner.approvalRequest` and `AgentRunner.execute`.
    ///
    /// Per task, never a mode. The persistent "active workspace" concept was considered and
    /// rejected (see the changelog's task-to-workspace-association entry, and the note at
    /// `CommandCenterView.swift:381-384`) because it silently mis-tags unrelated one-off tasks and
    /// leaks across surfaces — a voice command in the widget inheriting whatever workspace was last
    /// open in Command Center. **The entire difference between this and the rejected design is
    /// lifecycle**, so the lifecycle is written down rather than implied: set once per task in
    /// `performStart` after the plan exists, held across an approval or clarification pause because
    /// those are the same task resuming, and cleared at every terminal state.
    /// `private(set)` internal rather than fully private, matching `activeTaskOrigin`: the lifecycle
    /// *is* the feature here, so it has to be assertable. Nothing outside this type may set it.
    /// `@Published` because the widget's binding chip renders off it through `boundWorkspaceName`.
    /// It was `private(set) var` alone, and the chip's disappearance at task end worked only because
    /// every `activeTaskScope = .unscoped` site happens to sit in the same synchronous scope as some
    /// other published write (`isRunning`, `approvalRequest`). Nothing in the type system held that
    /// pairing, so the chip's correctness was incidental.
    @Published private(set) var activeTaskScope: TaskWorkspaceScope = .unscoped
    /// The scope the most recent task was *assessed* under, kept after `activeTaskScope` is cleared.
    ///
    /// `activeTaskScope` is the live binding and is `.unscoped` again the moment a task terminates,
    /// which is correct but makes the value unobservable exactly when a test wants to check it. This
    /// records what the run actually used. Not consumed by any view — it exists so the binding's
    /// behaviour is assertable rather than inferred from a side effect.
    private(set) var lastAssessedScope: TaskWorkspaceScope = .unscoped

    /// The workspace the composer is currently bound to, for the widget's indicator — the in-flight
    /// binding once a task is running, otherwise the one a card dispatch queued for the next
    /// command. `nil` means unbound, and the indicator disappears.
    var boundWorkspaceName: String? {
        if case .scoped(let scope) = activeTaskScope {
            return scope.workspaceName
        }
        return pendingWorkspaceBinding
    }
    /// A binding supplied by a dispatch that already knows its workspace — B4's workspace-card
    /// action. Wins over the free-text path when both are present.
    ///
    /// `nil` means "no dispatch named one", which is honestly the case for every caller today and is
    /// why this default is safe where a defaulted `scope:` would not be: `nil` does not switch a
    /// check off, it hands the question to `WorkspaceTaskTagging` instead.
    private var explicitWorkspaceBinding: String?
    /// Preserves the explicit binding across a clarification pause, exactly as
    /// `clarificationOrigin` preserves the origin — `submitClarification()` re-enters `start()`,
    /// which would otherwise drop it.
    private var clarificationWorkspaceBinding: String?
    /// What the paused run was submitted with, held across a clarification pause so that answering
    /// the question continues the user's **request** rather than replacing it (SONNY-248).
    ///
    /// **It cannot be read back off `command`, and that is the whole reason this exists.** `start()`
    /// clears that field centrally the instant it captures a dispatch — deliberately, because
    /// leaving each call site to do it was itself the defect that centralisation fixed — so by the
    /// time the question is on screen `command` is empty, and the widget's composer is disabled
    /// behind `isTaskInFlight` besides, so nothing can put text back in it. `submitClarification`
    /// interpolated that empty field anyway, and the continuation therefore began with the question
    /// Sonny had asked: the planner re-planned from a question and an answer with the request
    /// missing, and `lastCommand`, the task-history row and the resume offer's label each named the
    /// question back to the user instead of the task.
    ///
    /// **Not `lastCommand`, which looks like it would serve and would compound the loss.** That
    /// holds the original only until the clarification's own `start()` overwrites it with what
    /// *that* dispatch submitted, so a second question on the same task would compose from a string
    /// which had already lost the request.
    ///
    /// Holds whatever the paused run was submitted with rather than the first thing the user ever
    /// typed, which is what makes a second question accumulate instead of overwrite: the first pause
    /// stores the request, answering composes request + Q&A, the second pause stores *that*, and
    /// answering appends the second pair after it.
    ///
    /// Cleared at the same three sites as the three values above — answering, abandoning, and the
    /// local-data wipe — because its lifecycle is exactly theirs.
    private var clarificationSubmittedCommand: String?
    /// The workspace a card dispatch named for the **next** command, before one has been typed.
    ///
    /// A pre-dispatch slot, not a second lifecycle: `start()` consumes it into SONNY-38's
    /// `explicitWorkspaceBinding` — the same slot the free-text path already loses to — and clears
    /// it in the same breath, after which the binding is the in-flight one and clears where every
    /// other terminal clear happens. `boundWorkspaceName` reads whichever of the two is live, so the
    /// widget's indicator survives the hand-off without either value having to know about the other.
    ///
    /// Published because the widget renders it; deliberately *not* persisted and deliberately not
    /// readable anywhere outside the in-flight composer — the rejected persistent-active-workspace
    /// design is exactly what this must not become.
    @Published var pendingWorkspaceBinding: String?
    /// Which surface's mic button started the in-progress recording, set explicitly by the caller
    /// rather than inferred. Read back when voice transcription auto-submits, so that submission is
    /// attributed correctly.
    ///
    /// **There is one mic button, the widget's.** This used to say `toggleVoiceRecording()` "is
    /// called identically from both Command Center's composer and the floating widget's own mic
    /// button"; that composer was deleted on 2026-07-21 and the sentence outlived it. Corrected by
    /// PR #73's review (F3), which caught it precisely because SONNY-173 had corrected the *same*
    /// claim at the method's own doc comment 1200 lines below and left this copy standing — a
    /// compiler probe enumerates call sites, and no probe reads prose. A repo-wide sweep at that
    /// point found no third copy: every other mention of that composer already says it is gone.
    ///
    /// The `.commandCenter` initial value is never observed — `startVoiceRecording` assigns this
    /// before the single read in `stopVoiceRecordingAndTranscribe`'s completion — and is kept only
    /// to match `toggleVoiceRecording(origin:)`'s own default, which is documented there as the
    /// direction that consumes no pending workspace-card binding.
    private var voiceRecordingOrigin: TaskOrigin = .commandCenter
    /// What the in-progress recording is *for* — a command, or the answer to a parked clarification
    /// — decided when the recording starts and read back when its transcript arrives (SONNY-283).
    ///
    /// **Decided at the start and not at the end, because the two can differ and the difference is
    /// not safe to guess at.** A transcription takes a few seconds, and a question can be cancelled
    /// or can arrive inside them. A transcript recorded *as an answer* whose question has since gone
    /// must not run as a command — voice commands auto-execute, and "the Downloads folder" spoken in
    /// reply to a question is not a task anybody asked for. A transcript recorded *as a command*
    /// while a question has since arrived — a scheduled routine can raise one — must not land in the
    /// answer field of a question the user never saw when they spoke. So the purpose is captured with
    /// the origin, beside it, and `deliverTranscript` refuses both mismatches rather than routing on
    /// the state it happens to find.
    ///
    /// The `.command` initial value is never observed, for the same reason `voiceRecordingOrigin`'s
    /// is not.
    private var voiceRecordingPurpose: VoiceRecordingPurpose = .command
    /// The last command text actually submitted for real execution — tracked on the shared view
    /// model (not as widget-local UI state) so both the widget's own retry button and a system
    /// notification's "Retry" action, which fires from outside SwiftUI entirely, can resubmit it.
    /// `private(set)` rather than `private`: the setter stays inside this type, but the getter is
    /// readable so a test can assert what a dispatch actually *submitted*. `start` clears `command`
    /// synchronously right after capturing it, so the live property is empty by the time any caller
    /// returns — this is the only observable record of the text a run was started with.
    private(set) var lastCommand = ""
    private var isPushToTalkHotKeyDown = false
    private var pendingCommandForPriorTaskContext: String?
    private var pendingTaskHistoryStartedAt: Date?
    /// The unfinished-run record this task is checkpointing into, or `nil` when it has none —
    /// because memory is off for it, because "Don't save this task" is on, because the plan was too
    /// large to keep, or because the run never reached a plan (row 13, SONNY-210).
    ///
    /// Held whole rather than as an id: the unit-progress callback appends to `completedStepIDs`,
    /// `executePreparedRun` reads `chainedArtifactPath` to seed a resumed chain, and a settle needs
    /// the id. One slot answers all three, and the alternative — an id plus a re-read per unit — is
    /// a decrypt on the hot path to recover something this object already had.
    private var activeResumableTask: ResumableTask?
    /// The three inputs `itemJobProgress` is computed from, for the run in flight (SONNY-235).
    ///
    /// Reset by `initializeStepStatuses(for:)`, which is the single site every dispatch passes with
    /// the plan it is about to run — so a run that is not a job clears what the last one left, and a
    /// finished job's final "38 of 40" stays readable beside its result until the next dispatch
    /// rather than blanking the moment the run returns.
    private var activeItemJobPlan: AgentPlan?
    private var activeItemJobCompletedStepIDs: [String] = []
    private var activeItemJobFailures: [ItemJobFailure] = []
    /// The record the **next dispatch** carries on, or `nil` when that dispatch is a task of its
    /// own (row 13, SONNY-210; the second kind added by PR #105 review F1).
    ///
    /// **Spent by `start()` itself, before its own guards**, and handed to `performStart` as a
    /// parameter rather than read back off this property. That is deliberate: an arm that survives a
    /// *refused* dispatch would be inherited by the next unrelated one, which would then overwrite a
    /// record it has nothing to do with. Read once, cleared once, and the lifetime is one call.
    private var pendingResumableContinuation: ResumableTaskContinuation?

    /// What a dispatch inherits from a record that is already in flight.
    ///
    /// **Two kinds, because two doors mean different things by "the same task".** A *resume* picks
    /// up what is left of an interrupted run, so it inherits the file an earlier unit produced. A
    /// *restart* runs the same task again from the top — an answered clarification, or a retry after
    /// a failure — so there is no earlier unit and nothing to carry from one.
    ///
    /// Both inherit the id and the start time, which is what keeps one user-intent task to one
    /// record: `aTaskInterruptedTwiceStaysOneRecordWithItsOriginalStartTime` asserts it for the
    /// resume door and `anAnsweredClarificationKeepsOneRecordRatherThanOrphaningTheFirst` for the
    /// restart door.
    private struct ResumableTaskContinuation {
        let id: String
        let startedAt: Date
        /// The file an already-finished unit produced. `nil` for a restart, which has none.
        let chainedArtifactPath: String?

        /// Carrying on with what is left of an interrupted run.
        static func resuming(_ task: ResumableTask) -> ResumableTaskContinuation {
            ResumableTaskContinuation(
                id: task.id,
                startedAt: task.startedAt,
                chainedArtifactPath: task.chainedArtifactPath
            )
        }

        /// Running the same task again from the top.
        static func restarting(_ task: ResumableTask) -> ResumableTaskContinuation {
            ResumableTaskContinuation(id: task.id, startedAt: task.startedAt, chainedArtifactPath: nil)
        }
    }

    /// Offers the user has declined in this app session — the in-memory half of a decline, beside
    /// the persisted half on the record itself.
    ///
    /// **This used to be the whole mechanism, and it was session-scoped on purpose: "not now"**
    /// (SONNY-210). The founder's lifecycle is that a record lives until its task completes, the
    /// user deletes it, or it goes idle, and a dismissal was none of those — so the offer came back
    /// at the next launch, and the next, until the founder pressed the cross three times across
    /// three relaunches and stopped testing to ask what was broken (SONNY-282). Nothing was; that
    /// was the design, and the design was wrong. The cross now writes `ResumableTask.declinedAt`
    /// through `declineResumeOffer()`, which is what survives a relaunch.
    ///
    /// **Why this set still exists.** It takes the offer off the widget the instant the cross is
    /// pressed, whatever the disk says. The persisted write can fail — a full disk, a store that
    /// will not encrypt — and a widget that kept re-raising the offer while `errorMessage` said the
    /// decline could not be saved would loop the user through the same press. So the decline is
    /// honoured for this session unconditionally, the error says it may return after a relaunch, and
    /// the record on disk is the truth about the launches after that.
    ///
    /// **`@Published`, and that is a fix rather than decoration** (PR #105 review F2). It was a
    /// plain `private var`, so dismissing mutated it, `resumeOffer` went `nil`, and
    /// `objectWillChange` fired zero times — SwiftUI never re-evaluated `FloatingWidgetView.state`
    /// and the panel stayed on screen. The user pressed the cross and watched nothing happen until
    /// the six-second collapse took the whole widget instead. **Every input to `resumeOffer` must
    /// publish**; the other one, `resumableTasks`, already does, and
    /// `decliningTheOfferPublishesSoTheWidgetRepaints` holds this one.
    @Published private var declinedResumeOfferIDs: Set<String> = []
    private var preserveUsageForNextStart = false
    private let finderRevealer: @MainActor @Sendable ([URL]) -> Void
    private var localStorageLoadFailures: [LocalStorageLoadFailureSource: String] = [:]
    /// Last clipboard-poll failure text, so a repeating 1s failure is reported once, not 60×/min.
    private var clipboardHistoryPollFailure: String?

    private enum LocalStorageLoadFailureSource: CaseIterable, Hashable {
        case savedRoutines
        case savedWorkspaces
        case clipboardHistorySettings
        case clipboardHistoryItems
        case taskHistory
        case taskPlanDetails
        case snippets
        case recentArtifacts
        case approvedApps
        case outputLocations
        case resumableTasks

        var label: String {
            switch self {
            case .savedRoutines:
                return "saved routines"
            case .savedWorkspaces:
                return "saved workspaces"
            case .clipboardHistorySettings:
                return "clipboard history settings"
            case .clipboardHistoryItems:
                return "clipboard history"
            case .taskHistory:
                return "task history"
            case .taskPlanDetails:
                // Named for what the user would notice if it will not read: a follow-up on a past
                // task with less to go on. "Task plan details" is the file's name, not theirs.
                return "what past tasks planned"
            case .snippets:
                return "snippets"
            case .recentArtifacts:
                return "recent artifacts"
            case .approvedApps:
                return "allowed apps"
            case .outputLocations:
                // Named for what a person would notice going wrong — Sonny stops offering the folder
                // they always save into — rather than for the file.
                return "where your outputs usually go"
            case .resumableTasks:
                // Named for what the user would notice if it will not read: Sonny stops offering to
                // carry on with what they were partway through. "Resumable tasks" is the type's
                // name, not theirs.
                return "unfinished tasks"
            }
        }

        /// The store this source reports on.
        ///
        /// Exhaustive with no `default`, so a new case does not build until somebody says which
        /// store it speaks for.
        ///
        /// **This enum is the *banner's* population, and no longer the Memory row's** (PR #110
        /// fix-round review). It has fewer cases than `LocalStore` has stores — the vision session
        /// journal, Shortcut run history and the pending-deletion queue have none — and while a
        /// row's damaged state was derived from here, the Task history row could never leave
        /// `.readable` on their account.
        /// `canDelete` collapsed to `count > 0`, so an empty task history beside an unreadable
        /// `shortcuts-run-history.json` reproduced the founder's original dead end exactly, inside
        /// the branch whose whole outcome is that an unreadable memory is clearable. The row and its
        /// Delete now both read `unreadableStores`, which is probed over all fourteen.
        ///
        /// **What this comment used to say, and why it was wrong twice over.** It said "Neither is
        /// loaded by this view model at all", which is false: `deleteTask` and `deleteScreenRecord`
        /// both call `visionSessionJournalStore.delete(id:)`, whose first statement is `loadAll()`.
        /// The conclusion — that a case for either would be a case nothing ever sets — happens to
        /// survive, for a reason the false premise hid: **both of those loads sit inside a write the
        /// user pressed a control for**, so their failures correctly go to `errorMessage` rather than
        /// to a load-failure source, per CLAUDE.md's channel rule. Giving those two stores a source
        /// would therefore mean adding a *health probe* as a new recording site, and a banner
        /// sentence naming them that the founder has not seen. That is available and deliberately
        /// not taken here; the probe closes the reachable dead end without it.
        var store: LocalStore {
            switch self {
            case .savedRoutines:
                return .routines
            case .savedWorkspaces:
                return .workspaces
            case .clipboardHistorySettings:
                return .clipboardHistorySettings
            case .clipboardHistoryItems:
                return .clipboardHistory
            case .taskHistory:
                return .taskHistory
            case .taskPlanDetails:
                return .taskPlanDetails
            case .snippets:
                return .snippets
            case .recentArtifacts:
                return .recentArtifacts
            case .approvedApps:
                return .approvedApps
            case .outputLocations:
                return .outputLocations
            case .resumableTasks:
                return .resumableTasks
            }
        }

        /// The Memory row this source's failure shows up on, or `nil` when its store has no row.
        ///
        /// `nil` for `clipboardHistorySettings` alone — the clipboard switch's own file, which the
        /// Memory section deliberately does not list as a memory type. It is still recoverable
        /// without leaving that page: the Clipboard history row's switch commits through
        /// `applyClipboardHistoryNoticeChoice`, which writes without loading first and therefore
        /// overwrites a file it could not read.
        var memoryCategory: MemoryCategory? {
            store.memoryCategory
        }
    }

    private enum VoiceRecordingTrigger {
        case button
        case hotKey
    }

    /// What a voice recording's transcript is delivered to (SONNY-283). Internal rather than
    /// private so a test can drive `deliverTranscript` with each — the live path needs a real
    /// transcriber and an API key to reach it.
    enum VoiceRecordingPurpose: Equatable {
        /// Dispatched as a task of its own, the way every voice command always has been.
        case command
        /// Placed in the clarification panel's answer field, for the user to send. Recorded while
        /// *this* question was parked on them — the text is carried so delivery can check it is
        /// still the question on screen, not merely that some question is (PR #119 review, F3): a
        /// second question can arrive inside the transcription's round trip, and the answer to the
        /// first must not land in the second one's field.
        case clarificationAnswer(question: String)

        /// The purpose a recording started now would have.
        static func forRecordingStarted(clarificationQuestion: String?) -> VoiceRecordingPurpose {
            clarificationQuestion.map { .clarificationAnswer(question: $0) } ?? .command
        }
    }

    /// Which surface actually submitted the currently-relevant task — the shared `AgentViewModel`
    /// has no such concept until now, which was the real cause of the floating widget rendering
    /// its own duplicate progress/result panel for tasks submitted through Command Center's own
    /// composer: both surfaces observe the exact same `isRunning`/`finalSummary`/etc. with no way
    /// to tell which one actually initiated the current activity.
    enum TaskOrigin {
        case commandCenter
        case widget
        /// Started by the routine scheduler with nobody watching. Deliberately its own case rather
        /// than borrowing `.commandCenter`: the widget gates its working/result panel on
        /// `.widget`, so a scheduled run correctly shows no progress panel there while its
        /// permission/clarification/failure states — the ones that actually need a human — still
        /// surface on both surfaces. It also drives the `.scheduled` task-history trigger, which
        /// keeps automated runs out of the Insights streak.
        case scheduled
    }

    private enum UserDefaultsKeys {
        static let usePointerCursors = "com.sonny.preferences.usePointerCursors"
        static let displayFullNames = "com.sonny.preferences.displayFullNames"
        static let hasCompletedFirstApproval = "com.sonny.state.hasCompletedFirstApproval"
        static let interactionMode = "com.sonny.preferences.interactionMode"
    }

    /// The view model the shipping app runs on: every local store at its real location under
    /// `~/Library/Application Support/Sonny/`.
    ///
    /// **The one place those locations are named, which is the point** (SONNY-240). They used to be
    /// named by the initializer's own defaults, where every call site inherited them by saying
    /// nothing — including fifteen test fixtures that meant to say something else. Here they are a
    /// call, made from `main.swift` and nowhere else, and a store added later has to be added to
    /// this list before anything compiles.
    ///
    /// **Naming it is not enough on its own, which took a review round to learn** (PR #109 review
    /// F4). `AppDelegate.init` defaulted its `viewModel:` to this call for one round, which put the
    /// name in `AppDelegate.swift` and left every `AppDelegate()` call site saying nothing — the
    /// same invisibility, one level up. `AppDelegate` takes the view model now, and
    /// `LocalStoreInjectionScanTests.onlyMainAsksForTheRealStoreLocations` holds the population: in
    /// `Sources/`, exactly two files mention this method — the one declaring it and `main.swift` —
    /// and **each mentions it exactly once**, because the file set alone would permit a second
    /// factory written inside *this* file (PR #109 re-check). A wrapper that builds the stores
    /// **inline**, naming this method not at all, is a third door that check cannot see — and
    /// it is not hypothetical: the reviewer wrote one and passed every check in that suite. It is
    /// closed by `theOnlyViewModelConstructionInSourcesIsTheRealStoreFactory`, which holds that
    /// `Sources/` constructs an `AgentViewModel` in exactly one place, the function below, and that
    /// this file spells it by name rather than as `Self(…)` or `.init(…)`.
    ///
    /// The whitelist is built once and handed to both the view model and the output-location store,
    /// because that store answers "is this an output location?" by asking it — see the
    /// `outputLocationStore:` parameter. The clipboard monitor likewise gets the same settings store
    /// the view model does, so the switch the user sees and the switch the monitor obeys are one
    /// object.
    /// **`accountIdentity` is the shipping app's synchronous read of who is signed in**
    /// (SONNY-404, PR #207's F1), and it reads the Keychain directly rather than the client actor
    /// because the enqueue it serves must stay synchronous. `SonnyTaskDeletionService.init` carries
    /// the whole argument.
    static func atItsRealStoreLocations(
        backendClient: SonnyBackendClient,
        accountIdentity: @escaping @Sendable () -> String?
    ) -> AgentViewModel {
        let whitelist = PathWhitelist()
        let clipboardHistorySettingsStore = ClipboardHistorySettingsStore(
            fileURL: ClipboardHistorySettingsStore.realFileURL()
        )
        let clipboardHistoryStore = ClipboardHistoryStore(fileURL: ClipboardHistoryStore.realFileURL())
        return AgentViewModel(
            routineStore: RoutineStore(fileURL: RoutineStore.realFileURL()),
            workspaceStore: WorkspaceStore(fileURL: WorkspaceStore.realFileURL()),
            snippetStore: SnippetStore(fileURL: SnippetStore.realFileURL()),
            recentArtifactStore: RecentArtifactStore(fileURL: RecentArtifactStore.realFileURL()),
            // The real thing, named here for the same reason the fourteen store locations are: this
            // is the one place the shipping app asks for something that reaches the machine
            // (SONNY-239). It sits in this list rather than defaulting on the initializer because a
            // default nobody writes is a default nobody can see — SONNY-240's whole argument,
            // applied to a parameter that opens Finder rather than one that writes a file.
            finderRevealer: { NSWorkspace.shared.activateFileViewerSelecting($0) },
            shortcutRunHistoryStore: ShortcutRunHistoryStore(fileURL: ShortcutRunHistoryStore.realFileURL()),
            taskHistoryStore: TaskHistoryStore(fileURL: TaskHistoryStore.realFileURL()),
            taskPlanDetailStore: TaskPlanDetailStore(fileURL: TaskPlanDetailStore.realFileURL()),
            visionSessionJournalStore: VisionSessionJournalStore(fileURL: VisionSessionJournalStore.realFileURL()),
            clipboardHistorySettingsStore: clipboardHistorySettingsStore,
            approvedAppStore: ApprovedAppStore(fileURL: ApprovedAppStore.realFileURL()),
            outputLocationStore: OutputLocationStore(
                fileURL: OutputLocationStore.realFileURL(),
                whitelist: whitelist
            ),
            resumableTaskStore: ResumableTaskStore(fileURL: ResumableTaskStore.realFileURL()),
            pendingServerDeletionStore: PendingServerDeletionStore(
                fileURL: PendingServerDeletionStore.realFileURL()
            ),
            // The real page fetch, named here for the same reason `finderRevealer` is: this is the
            // one place the shipping app asks for something that reaches outside the process.
            standingWatcherObserver: LiveStandingWatcherObserver(),
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                store: clipboardHistoryStore,
                settingsStore: clipboardHistorySettingsStore
            ),
            localDataDeletionService: LocalDataDeletionService.acrossEveryLocalStore(),
            // The one client the process holds, built in `main.swift` beside the real Keychain and
            // passed to `SonnyAccountModel` as well — one client, one session, one refresh guard.
            backendClient: backendClient,
            accountIdentity: accountIdentity,
            whitelist: whitelist
        )
    }

    /// **No local store on this initializer has a default, and that is enforcement rather than
    /// style** (SONNY-240).
    ///
    /// A defaulted store parameter is invisible to every call site that predates it: adding one
    /// compiles fourteen fixtures unchanged and silently points the new store at
    /// `~/Library/Application Support/Sonny/`. A test process writes there under the deterministic
    /// key `LocalStorageEncryption` substitutes for tests, so the file it leaves behind is one the
    /// packaged app cannot decrypt — and per SONNY-239 cannot recover from either, because every
    /// path into these stores loads before it writes. That is not hypothetical: it reached the
    /// founder's Mac as a storage banner on his first manual item, with 50 test temp directories
    /// inside his real `output-locations.json`, and it happened a second time a day later.
    ///
    /// **So the convenience is gone, deliberately.** Every construction site names every store, and
    /// a store added later does not compile until each of them has been told about it. The shipping
    /// app's own site is `atItsRealStoreLocations()` below — one named place where the real
    /// locations are allowed, rather than every other construction site inheriting them by silence.
    /// (**The numeral this sentence carried is gone on purpose** — SONNY-326. It said "fifteen
    /// places", which was behind the tree by the time anyone read it and would be behind again
    /// after the next fixture file landed; the count moves with ordinary work and never carried the
    /// argument. The sentences above and below that still spell fifteen are dated records of what
    /// SONNY-240 *found*, and stay as written.)
    ///
    /// **The rejected alternative, on the record:** making the store types' *default paths*
    /// test-aware, the way `LocalStorageEncryption.defaultKeyManager()` already makes the key
    /// test-aware. It would stop the corruption and leave the wiring gap exactly where it is — a
    /// fixture would still be reaching a store nobody meant it to reach, and the next thing that
    /// needs the fixture's own store would find the same hole with none of the symptoms that made
    /// this one findable. The root cause is a call site that never named a store; the guard clause
    /// would make that call site harmless instead of absent.
    ///
    /// **What this does not prevent**, stated rather than left to be discovered: a call site is now
    /// forced to *pass* a store, not to pass a sensible one. That used to mean `taskHistoryStore:
    /// TaskHistoryStore()` — a store that named no location and silently resolved the real one.
    /// **SONNY-350 closed that spelling**: `fileURL` is a required parameter of all fourteen store
    /// initializers, so the only way to reach `~/Library/Application Support/Sonny/` is to write
    /// `TaskHistoryStore(fileURL: TaskHistoryStore.realFileURL())`, in words, where a reader and a
    /// sweep can both see it. The residue is now that sentence rather than silence, and
    /// `LocalStoreInjectionScanTests.onlyTheShippedConstantsTestsNameAStoresRealLocation` holds the
    /// four tests permitted to write it.
    ///
    /// Nor does any of this touch the non-store seams below (`browserOpener`, `shortcutCatalog`,
    /// `zipArchiver` and the rest), which default to real implementations that shell out and open
    /// real applications; that is a different hazard with a different blast radius, and every
    /// fixture passes hermetic ones today.
    init(
        audioRecorder: AudioCommandRecorder = AudioCommandRecorder(),
        permissionReadinessService: PermissionReadinessService = PermissionReadinessService(),
        routineStore: RoutineStore,
        workspaceStore: WorkspaceStore,
        snippetStore: SnippetStore,
        recentArtifactStore: RecentArtifactStore,
        shortcutCatalog: any ShortcutCatalogProviding = ProcessShortcutCatalog(),
        browserOpener: any BrowserOpening = WorkspaceBrowserOpener(),
        appOpener: any AppOpening = WorkspaceAppOpener(),
        fileOpener: any FileOpening = WorkspaceFileOpener(),
        // Injected rather than called directly, in the shape `ScreenAccessOnboarding` already uses
        // for its `settingsOpener` (SONNY-239, founder decision 2026-08-23). The one existing reveal
        // in this class called `NSWorkspace` inline and was therefore untestable; giving it a seam
        // makes the new control testable and the old one testable as a side effect.
        //
        // **Undefaulted, for SONNY-240's reason applied to something that is not a store.** It
        // landed with `= { NSWorkspace.shared.activateFileViewerSelecting($0) }`, which is a default
        // that reaches the developer's own machine and is invisible at every call site that predates
        // it — the exact shape SONNY-240 removed from the twelve stores beside it. Nothing here
        // writes or deletes, so the damage is smaller: a suite run that reached it would steal focus
        // and open Finder windows mid-test. The argument for keeping the default was that it is not
        // a store; the argument against is that "a test that predates the parameter cannot know to
        // pass it" does not care what the parameter is for.
        // **Spelled out rather than written as `RevealInFinderCapabilityAdapter.Reveal`**, which is
        // the same type. This is the only closure-typed parameter on this initializer, and
        // `LocalStoreInjectionScanTests`' parameter parser exists because a `->` here once took its
        // bracket depth to -1 and silently parsed 11 parameters instead of 34. Behind an alias the
        // arrow leaves the real signature, that parser's real-tree coverage goes with it, and the
        // two doc comments citing `finderRevealer: @escaping ([URL]) -> Void` start describing a
        // shape the tree no longer has (SONNY-395).
        finderRevealer: @escaping @MainActor @Sendable ([URL]) -> Void,
        mediaOpener: any MediaOpening = NativeMediaOpener(),
        runningAppSwitcher: any RunningAppSwitching = WorkspaceRunningAppSwitcher(),
        shortcutInvoker: any ShortcutInvoking = ProcessShortcutInvoker(),
        finderContextReader: any FinderContextReading = AppleScriptFinderContextReader(),
        documentConverter: any DocumentConverting = AutoDocumentConverter(),
        zipArchiver: any ZipArchiving = ProcessZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore,
        taskHistoryStore: TaskHistoryStore,
        taskPlanDetailStore: TaskPlanDetailStore,
        visionSessionJournalStore: VisionSessionJournalStore,
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore,
        approvedAppStore: ApprovedAppStore,
        // **This one was already `nil`-defaulted for a second reason, and the reason survives at the
        // caller** (SONNY-209). The store decides what counts as an output location by asking a
        // whitelist, so it has to be built with the *same* whitelist the view model runs under; a
        // store carrying its own would answer that question against different roots than the run
        // that produced the file. It used to be built here to guarantee that. Now the caller passes
        // both, which makes the pairing visible at the one place that can get it wrong instead of
        // implicit in a body nobody reads — `atItsRealStoreLocations()` names the whitelist once and
        // hands it to both.
        outputLocationStore: OutputLocationStore,
        resumableTaskStore: ResumableTaskStore,
        // **The fourteenth store, undefaulted like the thirteen above it** (SONNY-333, SONNY-240's
        // rule). Its file is the only thing that remembers a deleted task's id after the row is
        // gone, so a fixture that inherited a default would write the test process's deletions into
        // the developer's own queue — and the delivery pass would then send them to whatever
        // session that Mac holds.
        pendingServerDeletionStore: PendingServerDeletionStore,
        // **How a standing watcher reads its page, and undefaulted for SONNY-240's reason applied to
        // a network call** (SONNY-236). This is driven by a 30-second timer rather than by anything
        // the user pressed, so a fixture that has never heard of watchers must not be one tick away
        // from the real internet — and "a test that predates the parameter cannot know to pass it"
        // does not care that this one fetches rather than writes. `UnreachableStandingWatcherObserver`
        // is what a fixture with no interest in watchers passes; the shipping app's live one is named
        // in `atItsRealStoreLocations()` beside the fourteen store locations.
        standingWatcherObserver: any StandingWatcherObserving,
        // **The clipboard-history store arrives inside this**, which is why it is required too even
        // though it is a service rather than a store: `ClipboardHistoryMonitor`'s own defaults are
        // the real `clipboard-history.json` *and* the real system pasteboard, so a fixture that left
        // this out had a monitor that would have copied the developer's actual clipboard into the
        // developer's real file. Six of the fifteen fixtures left it out (SONNY-240).
        clipboardHistoryMonitor: ClipboardHistoryMonitor,
        // Not a store, and required for a worse reason than the stores are: its default is the real
        // file list, and this service *deletes* what it is given. All fifteen fixtures already
        // passed it, so this costs nothing and closes the one door on this initializer where a
        // silent default would have erased the developer's data rather than corrupted it.
        localDataDeletionService: LocalDataDeletionService,
        // **No default, for SONNY-240's reason one step further out** (SONNY-130). This client holds
        // the Keychain session, and every packaged build on a Mac shares one Keychain — so a
        // defaulted one would let a fixture read and delete the founder's own sign-in. It is also
        // the single-flight refresh guard: two clients in one process is two rotations where the
        // server's overlap rule allows one, which §3.3 reads as theft. `SonnyAccountModel` states
        // the same rule for the same object, and `main.swift` builds the one instance both share.
        backendClient: SonnyBackendClient,
        // Who is signed in, read synchronously (SONNY-404, PR #207's F1).
        //
        // **Defaulted to "nobody", and that direction is the safe one** — the opposite of the store
        // parameters SONNY-350 stripped their defaults from. A defaulted store resolved to the
        // user's real files; this resolves to *no account*, under which nothing is owed to any
        // server and the wipe records no obligation at all. A fixture that inherits it behaves as a
        // signed-out Mac, which is what a fixture with no session is.
        accountIdentity: @escaping @Sendable () -> String? = { nil },
        memoryPolicyProvider: any MemoryPolicyProviding = UnmanagedMemoryPolicyProvider(),
        priorTaskContextStore: PriorTaskContextStore = PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder = TaskUsageRecorder(),
        // Resolved from `backendClient` when absent, which a default value cannot do — Swift default
        // expressions cannot name another parameter. The shipped factory builds a planner that
        // talks through the backend, so it needs the client the line above requires.
        makePlanner: PlannerFactory? = nil,
        userDefaults: UserDefaults = .standard,
        whitelist: PathWhitelist = PathWhitelist()
    ) {
        self.userDefaults = userDefaults
        usePointerCursors = userDefaults.object(forKey: UserDefaultsKeys.usePointerCursors) as? Bool ?? true
        displayFullNames = userDefaults.object(forKey: UserDefaultsKeys.displayFullNames) as? Bool ?? false
        hasCompletedFirstApproval = userDefaults.object(forKey: UserDefaultsKeys.hasCompletedFirstApproval) as? Bool ?? false
        // Missing or unrecognized raw value falls to Normal — the ratified product default, so
        // the missing-key default and the product default agree (the reason the boolean
        // predecessor deviated from the `?? true` preference convention, carried forward).
        interactionMode = AgentInteractionMode(
            rawValue: userDefaults.string(forKey: UserDefaultsKeys.interactionMode) ?? ""
        ) ?? .normal
        self.audioRecorder = audioRecorder
        self.permissionReadinessService = permissionReadinessService
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.snippetStore = snippetStore
        self.recentArtifactStore = recentArtifactStore
        self.shortcutCatalog = shortcutCatalog
        self.browserOpener = browserOpener
        self.appOpener = appOpener
        self.fileOpener = fileOpener
        self.finderRevealer = finderRevealer
        self.mediaOpener = mediaOpener
        self.runningAppSwitcher = runningAppSwitcher
        self.shortcutInvoker = shortcutInvoker
        self.finderContextReader = finderContextReader
        self.documentConverter = documentConverter
        self.zipArchiver = zipArchiver
        self.shortcutRunHistoryStore = shortcutRunHistoryStore
        self.taskHistoryStore = taskHistoryStore
        self.taskPlanDetailStore = taskPlanDetailStore
        self.visionSessionJournalStore = visionSessionJournalStore
        self.clipboardHistorySettingsStore = clipboardHistorySettingsStore
        self.approvedAppStore = approvedAppStore
        self.outputLocationStore = outputLocationStore
        self.resumableTaskStore = resumableTaskStore
        self.pendingServerDeletionStore = pendingServerDeletionStore
        self.taskDeletionService = SonnyTaskDeletionService(
            client: backendClient,
            store: pendingServerDeletionStore,
            // **The synchronous account read** (SONNY-404, PR #207's F1). Every obligation carries
            // the account it was pressed under, and the enqueue runs before the local deletes, so
            // this cannot be an `await` on the client actor — `SonnyTaskDeletionService.init` says
            // why in full. It reads the token store the client itself was built over, which is the
            // same Keychain answer without the actor hop.
            accountIdentity: accountIdentity
        )
        self.standingWatcherObserver = standingWatcherObserver
        self.clipboardHistoryMonitor = clipboardHistoryMonitor
        self.localDataDeletionService = localDataDeletionService
        self.memoryPolicyProvider = memoryPolicyProvider
        self.memorySettingsStore = MemorySettingsStore(userDefaults: userDefaults)
        self.priorTaskContextStore = priorTaskContextStore
        self.taskUsageRecorder = taskUsageRecorder
        self.backendClient = backendClient
        self.screenControlAllowanceService = ScreenControlAllowanceService(client: backendClient)
        self.makePlanner = makePlanner ?? OpenAIPlanner.throughSonnysBackend(client: backendClient)
        self.whitelist = whitelist
        // Loaded here rather than on the Memory page's `onAppear`, because the switches gate
        // *recording*, not a view: an executor built before anything opened Command Center would
        // otherwise run with the defaults instead of with what the user chose.
        memorySettings = memorySettingsStore.load(policy: memoryPolicyProvider.currentPolicy())
    }

    /// **`hasAPIKey`, `modelName` and `transcriptionModelName` were here and are gone**
    /// (SONNY-136). All three read `ProcessInfo.processInfo.environment`, which is what SONNY-106
    /// section E forbids a user's build from needing: the packaged app is launched from Finder,
    /// which inherits no shell environment, so every one of them answered for a world the shipping
    /// app is never in. `hasAPIKey` fed the Settings readiness row, which now reports the session
    /// (`modelAccessReadiness`); the other two named a model, and which model answers a route has
    /// been the gateway's `MODEL_ROUTE_*` configuration since SONNY-130 — nothing had read either
    /// for several branches.
    ///
    /// `ClientNamesNoProviderScanTests` is what stops one coming back.

    /// True while a task occupies the app: running, waiting on an approval, or **paused on a
    /// clarification the user has not answered**.
    ///
    /// The third term is the one that keeps getting left out. A clarification pause looks idle from
    /// the outside — `performStart`'s defer sets `isRunning = false` and `approvalRequest` is nil —
    /// so a gate written as `isRunning || isAwaitingApproval` is live during exactly the state where
    /// a second dispatch destroys the first task's continuation.
    ///
    /// `FloatingWidgetView` computes this same expression privately. It is not consolidated here as
    /// part of this change because that file is on SONNY-41's never-touch list; hoisting the
    /// widget's copy onto this property is that file's owner's call, and the two agree today.
    var isTaskInFlight: Bool {
        isRunning || isAwaitingApproval || clarificationQuestion != nil
    }

    /// Hands `start` a command on behalf of a *programmatic* caller, and guarantees that a refused
    /// dispatch leaves no text behind.
    ///
    /// **The invariant: after any refused dispatch, a subsequent `submitClarification` interpolates
    /// only the question and the answer.** `submitClarification` wraps its Q&A around whatever
    /// `command` currently holds, so any caller that writes `command` and *then* gets refused turns
    /// the next continuation into a hybrid — re-planned, under the paused task's own captured
    /// binding, against the wrong workspace's boundary. Adding the clarification term to `canSubmit`
    /// fixed the discard at every door and moved this residue to three of them.
    ///
    /// **One mechanism, chosen over moving each assignment above its guard.** A caller cannot
    /// evaluate the real guard before assigning: `canSubmit`'s own emptiness term reads `command`,
    /// so a pre-assignment check would have to be a *partial* copy of the rule at every call site —
    /// the per-surface duplication that let this class reach the assembled head twice already.
    /// Detecting the outcome needs no copy of the rule at all, and it covers refusal reasons nobody
    /// has enumerated yet: `start` clears `command` synchronously the instant it accepts a dispatch,
    /// so finding the text still there means the guard refused and the text is residue.
    ///
    /// **A programmatic dispatch is never an approval.** `start()`'s first branch turns a call made
    /// while `isAwaitingApproval` into `approvePendingRun()` — correct for the composer's Send
    /// button, which is the control the widget relabels for exactly that job, and wrong for every
    /// caller here, none of which is that button.
    ///
    /// **The five doors, enumerated, because a guard in a shared helper is a claim about all of
    /// them** — and the first version of this comment named two:
    /// - `dispatchTranscribedCommand` — **the one with the most at stake.** `canUseVoice` blocks
    ///   *starting* a recording while an approval is pending, but an approval can land during the
    ///   recording or the transcription, and the finished transcript then went straight into
    ///   `start()`. A sentence the user spoke about something else would have landed as a silent
    ///   *allow* on whatever tier-3 action was waiting.
    /// - `openWorkspaceWidget`, `runRoutineWidget` — behaviour-changed, neither gated for this
    ///   before. `runRoutineWidget`'s button lives in `RoutineDetailView`, a different file.
    /// - `dispatchWorkspaceScopeEdit` — the sheet's door, the one this ticket built.
    /// - `retryLastCommand` — **unaffected.** Its own `!isTaskInFlight` guard is a strict superset
    ///   of this one and fires before `dispatch` is reached.
    ///
    /// **What makes it reachable is timing, not an unattended run.** An earlier telling of this said
    /// a scheduled routine raises approvals with nobody watching; it does not. `performScheduledRun`
    /// executes with `approvalDecision: .approved(.tier2)` and routes every `RiskApprovalError` to
    /// `pauseSchedule` plus a notice — SONNY-31's ratified notify-and-pause design — so it never
    /// writes `approvalRequest` at all. The real routes are both in the foreground: any run a user
    /// started pausing at its approval (`performStart`), and `performApproval`'s stale-approval
    /// re-arm when a re-assessment lands higher than the tier already approved. Either can arrive
    /// between a render and a tap, which is all this needs — a cheap structural guard on a trust
    /// boundary does not need an exotic trigger, and claiming one it does not have made the guard
    /// look better-motivated than the evidence supports. (PR #40 review, F4.)
    ///
    /// The guard is here, at the one helper every programmatic caller shares, rather than as a
    /// fifth copy on a fifth button.
    ///
    /// - Returns: whether the dispatch was accepted, so a caller can tell a refusal apart from a
    ///   submission without re-deriving `canSubmit`'s rule.
    @discardableResult
    private func dispatch(
        command commandText: String,
        autoExecute: Bool = false,
        origin: TaskOrigin = .commandCenter,
        workspaceBinding: String? = nil,
        fromComposer: Bool = false,
        prebuiltPlan: AgentPlan? = nil,
        prebuiltPlanSource: PreparedPlanSource = .directUserAction
    ) -> Bool {
        guard !isAwaitingApproval else {
            logStore.append(.observe, "Not started: an approval is still waiting for your answer.")
            return false
        }
        command = commandText
        start(
            autoExecute: autoExecute,
            origin: origin,
            workspaceBinding: workspaceBinding,
            fromComposer: fromComposer,
            prebuiltPlan: prebuiltPlan,
            prebuiltPlanSource: prebuiltPlanSource
        )
        guard command == commandText else {
            return true
        }
        command = ""
        // Every refused dispatch leaves a trace, at the one place every programmatic door passes
        // through. Three of the five doors logged a refusal of their own and two did not — voice
        // being the one that mattered, since it discards this result and its caller had already
        // announced that Sonny was about to act. A per-door copy is what produced that gap; this is
        // the same choke-point argument the clarification term is placed by.
        //
        // Cause-neutral on purpose. `canSubmit` refuses for a running task, an open clarification, a
        // transcription in flight, and an empty command — and the last of those already has its own
        // user-facing error from `start`. A line naming one cause would be wrong for the others,
        // which is the defect the sheet's own removed message had. (PR #40 review, F5.)
        logStore.append(.observe, "Not started: Sonny was not ready to begin another task.")
        return false
    }

    /// Fills the widget composer with a ready-made command and brings the widget forward, refusing
    /// while a clarification is open.
    ///
    /// The compose half of the same invariant. These callers never reach `start`, so `dispatch`
    /// cannot cover them — but they write `command` just the same, and a partial command
    /// ("Create a workspace called ") left in a live pause corrupts the continuation exactly as a
    /// refused dispatch would. Guard first, assign second — the ordering the sheet's own
    /// `composeWorkspaceScopeEdit` had, which was the one door genuinely closed at the time. That
    /// function is gone as of SONNY-64 (the sheet dispatches now), so this is the last door of that
    /// shape left, and the ordering is its own reason rather than a sibling's precedent.
    func composeCommand(_ commandText: String) {
        guard clarificationQuestion == nil else {
            logStore.append(.observe, "Composer prefill ignored while a clarification is open.")
            return
        }
        command = commandText
        widgetPresentationRequest += 1
    }

    /// **The clarification term lives here, at the dispatch choke point, rather than on each
    /// surface's button gate.**
    ///
    /// `start(...)` is the only route into `performStart`, and it is the only caller — so one term
    /// here refuses every dispatch that would otherwise discard an unanswered clarification:
    /// `openWorkspaceWidget`, `runRoutineWidget` (whose button lives in a different file entirely),
    /// the composer submit, and any dispatch added later. The alternative — a term on each card gate
    /// — is one copy per surface and a silent gap the first time a fourth card action is added,
    /// which is how this reached the assembled head with the voice half closed and the card half
    /// open.
    ///
    /// The clarification term does not break the continuation: `submitClarification` clears
    /// `clarificationQuestion` *before* re-entering `start`, so *that* term passes for an answer.
    /// **The `!isTranscribingVoice` term is a different matter, and `submitClarification` has to
    /// honour it before it tears anything down** (PR #119 review, F1). Everything that function
    /// clears — the question, the answer, the origin, the binding, the request — is cleared before
    /// `start` runs this guard, and a refusal here puts none of it back: the pause is gone, nothing
    /// runs, the composed Q&A sits in `command`, and the record of the task just abandoned is left
    /// to be *offered*. That window used to need a transcription already in flight when a question
    /// arrived; with voice answering a clarification it is the ordinary case — the user speaks,
    /// the field already holds text, and Return lands inside the round trip. So
    /// `canSendClarificationAnswer` refuses first, on the same terms, and both Send controls are
    /// disabled off it. And it is what makes `performStart`'s unconditional
    /// `clarificationQuestion = nil` unreachable by bypass rather than merely unreached — every path
    /// to it now passes this guard.
    var canSubmit: Bool {
        if isAwaitingApproval {
            return !isRunning && preparedRun != nil && runner != nil
        }
        return !isRunning && clarificationQuestion == nil && !isTranscribingVoice
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a voice recording, or the transcription of one, is in flight — the three flags the
    /// widget already reads as one (`FloatingWidgetView.isVoiceActive`), stated here so the answer
    /// gate and the view read the same thing.
    var isVoiceInputInFlight: Bool {
        isPreparingVoiceRecording || isRecordingVoice || isTranscribingVoice
    }

    /// Whether the clarification answer can be sent right now — the one predicate
    /// `submitClarification` refuses on and both Send controls are disabled off, so the state and
    /// the control cannot disagree (PR #119 review, F1).
    ///
    /// **All three voice terms, not only transcribing, and each for its own reason.**
    /// *Transcribing* is the one that destroys state: `canSubmit` refuses the dispatch on it, and
    /// by then the pause has been torn down (see `canSubmit`). *Recording* and *preparing* do not
    /// reach that refusal — `canSubmit` has no term for either — so a Return during them would run
    /// the continuation and the words the user is still speaking would arrive to a question that
    /// has gone, and be dropped (F3's guard). Those words are part of *this* answer; the user
    /// pressed Return with the mic live, which is not an instruction to discard them. And a
    /// recording is a transcription a moment later, so allowing the send during one and refusing it
    /// during the other would be the same press answered two ways a second apart. The mic's own
    /// control follows the same rule from the other side: it stays pressable while recording so
    /// the user can *stop*, which is the way to make the answer sendable.
    ///
    /// Silent, like every transient refusal: the transcript lands in a second and the field says
    /// so, and neither panel shows `.failure` while a question stands anyway.
    var canSendClarificationAnswer: Bool {
        clarificationQuestion != nil && !isVoiceInputInFlight
            && !clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether `cancelCurrentRun()` would actually end something — true in exactly the states it
    /// has a branch for, so the predicate and the function cannot disagree.
    ///
    /// **The clarification term is SONNY-166's, and its absence was the bug's sharpest edge.** A
    /// clarification pause has `isRunning == false` (`performStart`'s defer has fired) and
    /// `approvalRequest == nil`, so the old two-term expression was false throughout it: the view
    /// model did not merely fail to *offer* a way out, it reported that there was none. The exit now
    /// exists, so the predicate says so.
    ///
    /// **This adds no control to Command Center's running indicator, deliberately.**
    /// `CommandCenterRunningIndicator` is the only reader, and all four of its call sites are
    /// wrapped in `if viewModel.isRunning || viewModel.isAwaitingApproval` — both false during a
    /// clarification — so the indicator does not render at all in this state and its Cancel button
    /// cannot appear. That is the right outcome twice over: the indicator would otherwise say
    /// "Running: …" about a task that is not running, and the clarification's own exit lives on the
    /// panel that is asking the question, on both surfaces. Pinned by
    /// `theRunningIndicatorStaysAbsentDuringAClarification`.
    var canCancel: Bool {
        isAwaitingApproval || clarificationQuestion != nil || (isRunning && currentTask != nil)
    }

    /// **`missingAPIKeyVoiceMessage` was here and is gone** (SONNY-136). It read "No API key is set
    /// up. Add one, then relaunch Sonny.", and by the time this ticket ran it was the default answer
    /// of a property whose live answer is `nil` — a shipped constant for a sentence nothing in
    /// `Sources/` could produce, describing a condition that can no longer occur. SONNY-177's rule
    /// that produced it stands and has simply moved to the copy the user does see:
    /// `SonnyBackendCopy`, `SignInCopy` and the readiness row name no provider and no variable.
    ///
    /// **The `voiceConfigurationBlocker` seam below is untouched**, which is the distinction worth
    /// keeping — SONNY-173's rule is about which *kind* of reason may disable a control, and that
    /// rule outlives every particular reason. The tests that need a configuration failure state one
    /// through `voiceConfigurationBlockerOverride` with a literal of their own, which is how
    /// SONNY-173 wrote them so that this deletion would not cost their meaning.

    /// What the mic's hover hint says when voice actually works. It lives here, rather than as a
    /// literal in `FloatingWidgetView`, so that *choosing* between this and the configuration
    /// message happens in one place — see `micHoverHintPresentation`.
    ///
    /// **The founder's own wording, given verbatim on SONNY-179, 2026-08-19.** It replaces "Speak
    /// your command — or hold Ctrl-Opt-Space anywhere". The em dash goes, and no comma takes its
    /// place: two clauses this short do not need one. Copy is his, so this string is not a sentence
    /// to improve on session judgment.
    static let micHoverShortcutReminder = "Click to speak or hold Ctrl-Opt-Space."

    /// How long the shortcut reminder stays, and nothing else. The configuration message has no
    /// delay at all rather than a longer one, which is why this is not a general "hint duration".
    ///
    /// Three seconds since SONNY-179, down from the four SONNY-177 shipped — the founder's pass at
    /// the packaged app, and his call to make.
    static let micHoverReminderDismissDelay: Duration = .seconds(3)

    /// The mic's hover hint, resolved: the sentence to render and whether it clears itself.
    ///
    /// **Resolved here for the same reason `isVoiceControlDisabled` is.** A view may read neither
    /// half of voice readiness, so it cannot pick between these two messages for itself; it receives
    /// the answer already made. The guard is `theCompositeVoiceReadinessIsReadInOneFileOnly`.
    ///
    /// **The unconfigured variant renders the very text the mic press shows, rather than a second
    /// string of its own.** One condition on one control must not speak with two voices, and taking
    /// the words from the same place the press takes them makes that structural instead of a
    /// convention someone has to keep remembering — a rewrite cannot leave the hover and the press
    /// disagreeing, because there is only one sentence. That prediction is what SONNY-136 found:
    /// removing the message was one deletion here, and all three surfaces followed.
    var micHoverHintPresentation: MicHoverHintPresentation {
        if let blocker = voiceConfigurationBlocker {
            return MicHoverHintPresentation(message: blocker, autoDismissDelay: nil)
        }
        return MicHoverHintPresentation(
            message: Self.micHoverShortcutReminder,
            autoDismissDelay: Self.micHoverReminderDismissDelay
        )
    }

    /// Lets a test state what the *configuration* half of voice readiness should answer, instead of
    /// inheriting whatever the process that launched the test suite happened to export.
    ///
    /// **It was built for a live answer that read the process environment through `hasAPIKey`**,
    /// which a test cannot set for itself: `setenv` is process-global and the suite runs its tests in
    /// parallel. The same reason `visionSessionEnvironment` is a seam — a test must be able to
    /// describe the world rather than hope for it. Before this existed the repo's own comment on
    /// `voiceCannotConsumeAnArmWhileAClarificationIsPending` recorded the consequence plainly: "that
    /// half is readable, not testable, and its proof is the declaration."
    ///
    /// **That reason is gone and the seam stays** (SONNY-136). There is no environment read left to
    /// be untestable, and the live answer is unconditionally `nil` — so what this now exists for is
    /// the *rule*: SONNY-173's split between an actionable refusal and a transient one is the thing
    /// the tests below hold, and holding it needs a way to state an actionable refusal. Deleting the
    /// seam would delete the only way to state one, and the rule would go back to being a
    /// declaration nothing checks.
    ///
    /// `nil` in the shipping app, and nothing in `Sources/` assigns it. Deliberately not
    /// `@Published`: a test sets it once before reading, and production never changes it, so there
    /// is no view to invalidate.
    var voiceConfigurationBlockerOverride: (() -> String?)?

    /// **The actionable half of voice readiness** — something the user can go and fix, and the
    /// message that says so. `nil` when configuration is fine.
    ///
    /// Actionable failures are the ones a control may never swallow. That is the whole of
    /// SONNY-173: the mic button was `.disabled` on the *composite* `canUseVoice`, a disabled
    /// SwiftUI button never runs its action, and so the guard that already had the right message
    /// was unreachable from the one surface most people press. The hotkey, gated by no SwiftUI
    /// state at all, reached its copy of the guard and explained itself. Same failure, two answers.
    ///
    /// **This split outlives its current contents**, and SONNY-130 is the first time the contents
    /// changed: the rule it exists to state — an actionable refusal explains itself, a transient one
    /// stays quiet, and only the transient half is ever allowed into a `.disabled` predicate — is
    /// untouched, while the one thing it used to report is gone.
    ///
    /// **The live answer is `nil`, because no local configuration blocks voice any more.** It read
    /// `hasAPIKey` until SONNY-130, and leaving it that way would have made that ticket's own
    /// headline outcome unreachable: transcription now goes through Sonny's backend under the user's
    /// session, and the founder's manual item launches the packaged app **from Finder**, where no
    /// shell environment exists and `OPENAI_API_KEY` was therefore never set. The mic would have been
    /// blocked, with a message telling the user to export a variable nothing reads.
    ///
    /// **The seam stays and its old message is gone** (SONNY-136). `missingAPIKeyVoiceMessage` was
    /// kept here unreachable until the ticket owning the environment-variable surface could remove
    /// it; that ticket has run, and a constant for a sentence nothing can produce went with the
    /// variable it was about. What a *signed-out* user is told is unchanged and is not this
    /// property's business: they record, and the transcriber answers "Sign in to Sonny to run this."
    var voiceConfigurationBlocker: String? {
        if let voiceConfigurationBlockerOverride {
            return voiceConfigurationBlockerOverride()
        }
        return nil
    }

    /// **The transient half of voice readiness** — the app is busy, and refusing in silence is the
    /// correct answer. Nothing here is something the user could go and fix; each clears on its own.
    ///
    /// **A parked clarification is no longer a term here** (SONNY-283, founder decision 2026-08-25:
    /// voice answers a clarification). It was one, and for a real reason: a clarification pause
    /// holds `activeTaskScope`, so the chip shows the *paused* task's workspace while a card arm
    /// sits invisible behind it — and a transcript dispatched as a *command* during the pause
    /// consumed that arm, ran scoped to a workspace the chip never named, and discarded the
    /// unanswered question through `performStart`'s per-task reset. What made that reachable was
    /// the transcript being *dispatched*. A recording started during a clarification is now recorded
    /// for the answer field (`VoiceRecordingPurpose`), and `dispatchTranscribedCommand`'s own guard
    /// still refuses a command transcript while a question stands — so the gate this term provided
    /// moved to the delivery, where it can tell the two apart, and the mic and the hotkey are live
    /// at the one moment the founder most wants to speak.
    var isVoiceTransientlyBusy: Bool {
        isAwaitingApproval || isRunning || isPreparingVoiceRecording || isTranscribingVoice
    }

    var canUseVoice: Bool {
        voiceConfigurationBlocker == nil && !isVoiceTransientlyBusy
    }

    /// The mic control's whole `.disabled` predicate, **the transient half only** — and it lives
    /// here, not in the view, so it is something a test can hold.
    ///
    /// A view cannot be asked what it renders, so a `.disabled` expression written inline in
    /// `FloatingWidgetView` is enforced by nothing but a reader noticing. That is how the
    /// configuration term got into it. Stated as a property, the rule "only transient reasons
    /// disable a control" has one address, one doc comment, and a test that fails when it moves.
    ///
    /// `!isRecordingVoice` is the stop half, carried over unchanged: once a recording is running the
    /// button is Stop, and it stays pressable even if something transient arrives mid-recording —
    /// an approval landing while the user is mid-sentence must not trap them in a live microphone.
    var isVoiceControlDisabled: Bool {
        isVoiceTransientlyBusy && !isRecordingVoice
    }

    var isAwaitingApproval: Bool {
        approvalRequest != nil
    }

    /// Where the plan of the **most recently prepared** run came from, or `nil` when there is none.
    /// SONNY-64's origin signal, as the rest of the app sees it.
    ///
    /// "Most recently prepared", not "in flight": `performStart` clears `preparedRun` when the next
    /// run begins and `cancelCurrentRun` clears it on cancel, but a run that *completes* leaves it
    /// set, so this keeps describing that run until another starts. Stated exactly because the
    /// reader who matters is row C, which will consult it while a run is being assessed — where the
    /// two readings coincide — and a doc claiming a narrower lifetime than the property has is the
    /// kind of thing that gets believed at the one call site where it is false.
    ///
    /// Derived from `preparedRun` rather than kept in its own slot, deliberately. A second stored
    /// property would need adding to `performStart`'s per-task reset, to the terminal `defer`, and
    /// to `clearInMemoryLocalDataState`'s hand-written enumeration — and that enumeration has been
    /// missed twice on this class already (`explicitWorkspaceBinding`, then `pendingWorkspaceBinding`
    /// one ticket later). A slot that cannot go stale is worth more here than a saved property read.
    ///
    /// Read-only on purpose: row C will consume this, and nothing may set it. The only writer is
    /// `AgentRunner.prepare`. (SONNY-281 briefly read it to decide whether a clarification answer
    /// completes a resolver command, and PR #118's review found the Continue door replays a paused
    /// plan as `.resumedTask` — so that decision is read off the question now, not off this.)
    var activeTaskPlanSource: PreparedPlanSource? {
        preparedRun?.source
    }

    var activeTaskCount: Int {
        isRunning || isAwaitingApproval ? 1 : 0
    }

    // MARK: - Screen-control allowance (SONNY-214)

    /// How many screen-control runs the gateway says this account has left this period, or `nil`
    /// when no figure has been read.
    ///
    /// **Read, never derived here.** `ScreenControlAllowanceService` states the rule this property
    /// obeys — the number is the server's and this side renders it — and SONNY-212 derives it from
    /// row 12's metering at read time rather than from a ledger, so it is a forward-looking estimate
    /// that re-prices when the founders change a weight. `server/src/credit/balance.ts` records that
    /// trade in full, including why it is fine for a number a user reads and not for a refusal.
    ///
    /// **`nil` after a failed read, and that is the same call the service makes**: there is no
    /// fallback figure, because zero locks a user out of something they have paid for and any
    /// positive number promises runs the server never granted. A surface with no figure shows no
    /// line at all — not a placeholder, not a stale number, and not a sentence about why.
    @Published private(set) var screenControlAllowance: ScreenControlAllowance?

    /// Built in `init` over the one backend client this process holds, the same client every other
    /// authenticated read goes through. Not an initializer parameter of its own, because it carries
    /// no state, no location and no configuration: threading a fourteenth argument through every
    /// fixture would say nothing the one assignment in `init` does not, and a test that wants to
    /// script the read scripts the client — which is the seam the service is one request wide over.
    private let screenControlAllowanceService: ScreenControlAllowanceService

    /// Ask the gateway for the allowance and publish it; a failure clears the figure.
    ///
    /// **Called by the two surfaces that show it and by nothing else** — Command Center's Insights
    /// page when it appears, and the widget when a screen-control task goes in flight. Deliberately
    /// not called from `performStart`: a run must never wait on a usage read, and a request issued
    /// from inside the run path would also land in the middle of every scripted backend fixture that
    /// counts what a session put on the wire.
    func refreshScreenControlAllowance() async {
        // **A successful read clears the setting's failure sentence** (PR #196's F10). That sentence
        // is about a write that did not land, and a read that lands says the gateway is answering
        // again — leaving it up means a user who pressed the switch during an outage, closed the
        // dialog and reopened it reads a complaint about a request made minutes ago, under a row
        // that is now correct. It is cleared on success only: a read that *fails* clears the whole
        // allowance and the row goes with it, so there is nothing left for the sentence to sit
        // under either way.
        do {
            screenControlAllowance = try await screenControlAllowanceService.fetch()
            screenControlAutoTopUpFailure = nil
        } catch {
            // Swallowed on purpose, and this is the one place that decision lives. A usage line is
            // ambient: the user did not press anything to get it, so a failure to read it is not an
            // outcome they are owed a sentence about. `errorMessage` means the task failed and
            // `localStorageNotice` means a file would not open; neither is true here.
            screenControlAllowance = nil
        }
    }

    /// Forget the figure, because the session it was read over is no longer the session on screen.
    ///
    /// **An account-scoped number must not outlive its account** (PR #188's F1). Nothing else
    /// re-reads it when a session changes: the two surfaces ask when they appear, and neither
    /// signing in nor signing out re-fires an `onAppear` — signing in is a sheet over Command Center
    /// and signing out is a menu item, which is the same fact `sessionDidChange` exists for. Left
    /// alone, a user who signed out went on reading their own figure on the page they were already
    /// on, and the next user to sign in on that Mac read it too. `SignInView.signOut()` clears
    /// `subscription` synchronously for exactly this reason (PR #183's F13); this is the same class
    /// of datum, arriving later.
    ///
    /// **Clearing, and deliberately not re-reading.** A cleared figure renders no line at all, which
    /// is the rule a failed read already follows here — so the surfaces are correct from the instant
    /// the session changes, and the next one to appear asks for the new account's number.
    func forgetScreenControlAllowance() {
        screenControlAllowance = nil
        screenControlAutoTopUpFailure = nil
    }

    // MARK: - Auto top-up (SONNY-215)

    /// Why the auto-top-up setting could not be changed, or `nil`.
    ///
    /// **Its own channel, and not `errorMessage`.** That property means *the task failed*, and the
    /// widget picks `.failure` ahead of `.result` — so a setting that would not save, routed there,
    /// would replace the result of a task that ran and succeeded. This is the same distinction
    /// `recordLocalStorageWriteFailure` draws for a bookkeeping write, applied to a network one:
    /// what the user pressed did not happen, so they are owed a sentence, and it belongs beside the
    /// control they pressed. `SonnyAccountModel.portalFailure` is the shape this follows.
    @Published private(set) var screenControlAutoTopUpFailure: BillingSettingFailure?

    /// Whether the setting is being written right now, so the control can be held while it is.
    @Published private(set) var isSettingScreenControlAutoTopUp = false

    /// Turn automatic top-ups on or off (SONNY-215).
    ///
    /// **The gateway is the one that holds this**, so the published figure is replaced with whatever
    /// it answers rather than with what was asked for — a control that showed the requested state
    /// before the server agreed would be a switch that lies about whether a charge can happen.
    ///
    /// **A failure leaves the previous figure in place**, which is deliberately not what
    /// `refreshScreenControlAllowance` does with a failed read. That method is reading an ambient
    /// number and `nil` means "no line"; this is a write the user pressed for, and clearing the row
    /// they were looking at would take the setting off screen instead of telling them it did not
    /// change.
    func setScreenControlAutoTopUp(_ enabled: Bool) async {
        isSettingScreenControlAutoTopUp = true
        screenControlAutoTopUpFailure = nil
        defer { isSettingScreenControlAutoTopUp = false }
        do {
            screenControlAllowance = try await screenControlAllowanceService.setAutoTopUp(enabled)
        } catch let error as SonnyBackendError {
            screenControlAutoTopUpFailure = BillingSettingFailure(error)
        } catch {
            screenControlAutoTopUpFailure = .cannotBeChanged
        }
    }

    /// Whether the task in flight — or the one waiting on an approval — is a screen-control run.
    ///
    /// **Every term is `@Published`, which is what makes this observable from a view.** The obvious
    /// spelling reads `preparedRun`, which is not published and would leave a view showing the wrong
    /// answer until something else happened to redraw it. `plan` is the same prepared plan, assigned
    /// from it one line later in `performStart` and cleared at the top of every run.
    var isScreenControlTaskInFlight: Bool {
        // **A scheduled routine run is not the user's task, and `plan` does not describe it** (PR
        // #188's F3). `performScheduledRun` sets `isRunning` for re-entrancy and deliberately leaves
        // every property that reads as "your last task" alone — its own doc comment lists `plan`
        // among them — so a routine firing after a screen-control run inherited that plan, and the
        // two terms below answered `true` for the whole of it. `activeTaskOrigin` is the property
        // that method names as the one keeping widget surfaces off a task the user never started,
        // and this is a widget surface; it is now set beside `isRunning` at the scheduled door
        // rather than a main-actor turn later, so the pair cannot disagree.
        guard activeTaskOrigin != .scheduled else {
            return false
        }
        guard isRunning || isAwaitingApproval else {
            return false
        }
        return plan?.steps.contains { $0.operation == .visionSession } ?? false
    }

    /// The figure the widget shows beside a screen-control run, or `nil`.
    ///
    /// **The ticket's gate, stated as a property rather than as an expression inside the widget** —
    /// the same reason `isVoiceControlDisabled` is one: a rule written inline in a view is enforced
    /// by nothing but a reader noticing, and this rule is the whole of SONNY-214's second half.
    /// Both halves are required, and each fails in the direction it should: an ordinary free task
    /// shows nothing whatever the allowance says, and a screen-control run whose read failed shows
    /// nothing rather than a number nobody served.
    var screenControlRunsLeftForTaskInFlight: Int? {
        guard isScreenControlTaskInFlight else {
            return nil
        }
        return screenControlAllowance?.runsLeft
    }

    /// Whether the floating widget currently has real content to show — one of row I's parked
    /// Safe-mode questions, a permission/clarification/failure state, a live screen-control session,
    /// or row 13's offer to carry on with an unfinished run (all of those regardless of which
    /// surface submitted the task), or a working/result state for a task the widget itself
    /// submitted. Single source of truth for both
    /// `FloatingWidgetView`'s own panel rendering and its `isMicHintSlotFree` gate. Mirrors
    /// `FloatingWidgetView`'s `state`/`showsPanel` precedence exactly — keep both in sync if either
    /// changes. (That property stopped being `private` in SONNY-255, so a test could read the panel
    /// the widget resolved to; this sentence went on calling it private until PR #132's review, F4.)
    ///
    /// **"Mirrors exactly" was a requirement this property did not meet until SONNY-299.** `state`
    /// has had a `.controlling` branch since row I and this had no session term at all, so a screen
    /// session started anywhere but the widget fell through to the origin-gated running branch and
    /// the widget rendered nothing — the one state whose entire purpose is to be seen was the one
    /// the panel gate could refuse. The opening sentence is written out branch by branch for the
    /// same reason: it used to name the permission, clarification, failure, working and result
    /// states and stop, saying nothing about row I's parked questions or row 13's resume offer, and
    /// the branch that was missing was one it had never mentioned. **The rewrite then dropped the
    /// resume offer from its own enumeration and had to be completed** (PR #140 review, F2) — the
    /// same class of omission, in the sentence written to fix it, which is worth leaving on the
    /// record rather than quietly repairing: an enumeration is only as good as the moment someone
    /// last counted it against the branches below.
    ///
    /// **Two stale claims removed here, both on 2026-08-21.** This said the widget was "the only
    /// place either is actionable at all": `CommandCenterAttentionPanel` has rendered those three
    /// states on four Command Center pages since branch 10 and wires Deny/Allow to the same
    /// `cancelCurrentRun()`/`start()` entry points (SONNY-183). And it named the second reader as
    /// `FloatingWidgetWindowController`'s decision to composite into Command Center; that mode was
    /// superseded on 2026-07-21 and the controller has one positioning mode now (SONNY-189).
    ///
    /// The warning underneath both is kept, because it is the part that is still live: this
    /// predicate is read in more than one place, and the widget once vanished silently right after
    /// launch because a second reader disagreed with it — Command Center took key-window focus
    /// first, the widget composited in while still idle, and an idle+composited render drew
    /// literally nothing (no compact capsule, no pill), with no way to click back into it.
    var hasVisibleWidgetPanel: Bool {
        // Row I's two Safe-mode questions, first for the same reason the permission, clarification
        // and failure branches below them are unconditional: each is a parked continuation waiting
        // on a human, and a session whose question the widget declined to render would simply hang.
        // (Named rather than counted since SONNY-299 put a fourth unconditional branch between them
        // and those three.)
        if visionCapturePreview != nil || visionDelegationRequest != nil || visionSessionPause != nil {
            return true
        }
        if approvalRequest != nil {
            return true
        }
        // **A live screen-control session, unconditionally — below the parked questions and above
        // the origin-gated running branch, which is where `state` puts `.controlling`** (SONNY-299).
        // This term did not exist at all, so a session started anywhere but the widget fell through
        // to that branch, was answered `activeTaskOrigin == .widget`, and rendered nothing: `state`
        // resolved to `.controlling` and the HUD that would have drawn it was never on screen.
        // Reachable rather than theoretical — `runTaskAgain` dispatches `origin: .commandCenter` and
        // a screen task run again from its Command Center row really does re-plan into a fresh
        // session. **That is the only reachable door today, and this said there was a second one**
        // (PR #140 review, F1). It named `continueResumableTask(_:origin:)` from the Memory sheet,
        // which is precisely the door that is closed: `.visionSession` is `.mustNotRepeatSilently`,
        // `mayBeOfferedForResume` requires *every* remaining step to be `.safeToRepeat`, the Memory
        // row's Continue is gated on that same property, and `continueResumableTask` asks it again
        // as a belt and refuses with a log line. So no `ResumableTask` carrying a screen session can
        // reach a dispatch through it at all. The claim came verbatim from SONNY-299's description
        // and was the one adjacent claim not re-derived from the code — which is the reachability
        // half of this repository's enumerate-before-you-subtract rule, and it fails the same way.
        //
        // **Unconditional is the answer here, not an origin gate left off.** The gate below exists
        // because a Command-Center-origin *working* run already reports itself in
        // `CommandCenterRunningIndicator`, so a widget progress panel would be a second one. The HUD
        // is not that kind of progress: `WidgetControllingPanel`'s own doc comment calls it a
        // product requirement rather than a courtesy — a program moving someone's cursor with no
        // visible statement of what it is doing is the shape this feature must never take — and the
        // running indicator is a compact line that names no app and carries neither Pause nor Stop.
        // There is no second HUD for this one to duplicate; `CommandCenterAttentionPanel`
        // deliberately has none (`.claude/rules/macagent-ui-conventions.md`).
        //
        // So `.scheduled` gets no term of its own, and why is worth stating rather than leaving to
        // be re-derived: unattended screen control is refused three independent ways —
        // `StoredRoutine.forbiddenStepOperations` rejects `.visionSession` at the routine store's
        // write door, `performScheduledRun`'s explicit belt checks the routine's steps, its nested
        // steps and the prepared plan and pauses the schedule, and its fixed `.approved(.tier2)`
        // ceiling cannot satisfy a tier-3 vision assessment. A `.scheduled` session is unreachable
        // today; were one of those three ever to move, rendering the HUD is the answer this term
        // should give anyway, which is why it is written to cover every origin rather than to
        // enumerate the two that can reach it.
        if visionSessionProgress != nil {
            return true
        }
        if clarificationQuestion != nil {
            return true
        }
        // **§8.3's wall, above the failure branch and below every parked question** (SONNY-402).
        // Above `.failure` because a build the gateway refuses cannot succeed at anything that needs
        // it, so the sentence a failed run shows — "try again" — is an invitation to repeat a
        // refusal that is defined as permanent. Below the four parked questions, `.controlling` and
        // the clarification for the reason those are unconditional in the first place: each is a
        // continuation nothing but the user resolves, a local capability parks them without touching
        // the gateway at all, and a widget that declined to render one would simply hang the run.
        if isTooOldForThisBackend {
            return true
        }
        if errorMessage != nil && !isRunning {
            return true
        }
        if isRunning {
            return activeTaskOrigin == .widget
        }
        if !finalSummary.isEmpty {
            return activeTaskOrigin == .widget
        }
        // Row 13's offer to carry on with an unfinished run (SONNY-210) — **last, and above nothing
        // but the idle state.** Every branch above describes the task the user is doing *now*: a
        // question waiting on them, a run in flight, the outcome of the one that just ended. This
        // describes a task from before, so it yields to all of them.
        //
        // That placement is the deliberate answer to the hazard CLAUDE.md records about this
        // surface. The widget picks `.failure` ahead of `.result`, and the cost of getting that
        // precedence wrong has been paid twice: a bookkeeping write failure routed to `errorMessage`
        // replaced the result of a task that had actually succeeded. A fifth thing competing here
        // must not be able to do the same, and the only way to guarantee it cannot is to put it
        // below every state that reports the current task — including `.failure`, so that a run
        // which failed partway shows *why* it failed rather than an offer to try again with the
        // reason hidden. The offer is still there the moment that outcome clears.
        if resumeOffer != nil {
            return true
        }
        // **§8.4's warning, last of all, above nothing but the idle state** (SONNY-402). Everything
        // still works in this band, so this must not take the surface from anything that reports the
        // task the user is doing — nor from the resume offer, which is already the lowest thing here
        // and would otherwise be held off screen for as long as the band lasts.
        if showsUpdateAvailablePrompt {
            return true
        }
        return false
    }

    /// The unfinished run the widget offers to carry on with, or `nil` when there is none to offer.
    ///
    /// **`!isTaskInFlight`, not `!isRunning`.** A run paused at an approval or an unanswered
    /// clarification is still the user's live task, and it is exactly the state whose own record is
    /// sitting in `resumableTasks` — so without the wider guard Sonny would offer to continue the
    /// task whose question is on screen. `isTaskInFlight` is the three-term superset this file
    /// already uses for that.
    ///
    /// Newest activity first, which is `ResumableTaskStore.loadAll`'s order: the thing they were
    /// doing most recently is the thing to raise.
    ///
    /// `mayBeOfferedForResume` filters two things: a record with nothing left to do, which a settled
    /// record never is and a hand-written one can be; and a record whose remaining work contains
    /// something Sonny must not do twice on its own (PR #105 review F5) — a Shortcut, a routine, a
    /// screen session. Those stay listed under Memory, where the user can see and delete them; what
    /// is withheld is Sonny volunteering to finish them.
    ///
    /// **The Memory switch gates this read as well as the write, and the asymmetry with the Memory
    /// list is the whole decision** (founder, 2026-08-22, from PR #105's review F9). With
    /// "Unfinished tasks" off Sonny raises no offer — *including* for records written before the
    /// switch was flipped — while the records themselves are untouched: still on disk, still listed
    /// under Memory, still deletable, and the offer returns the moment the switch does.
    ///
    /// The two surfaces differ because of who initiates. **Listing an existing record under Memory
    /// is the user going to look**, and it has to show them, or a store they switched off becomes
    /// one they cannot clear. **Raising a panel on the widget is Sonny initiating, unasked, from
    /// memory the user has just said to stop keeping** — and a switch that is off while the product
    /// still proactively acts on what it recorded reads as a switch that did not work.
    ///
    /// **Exactly this one guard, and deliberately not a rule.** Nothing about what is written, what
    /// is stored, what Memory lists or what deletion does changes, and this is not generalised into
    /// "a memory switch gates every read path": it is about a *proactive* surface, and the next
    /// store that grows one is decided on its own terms.
    ///
    /// `isMemoryCategoryEnabled(_:)` rather than `allowsRecording(to:)`, on two counts. It is the
    /// effective answer the row's own switch displays, so the panel and the control cannot disagree
    /// — which is the founder's framing above. And it leaves out `taskRecordingPolicy`, which has no
    /// business here: "Don't save this task" is a per-run composer switch about the run being
    /// composed, not a standing statement about records already on disk. It reads `memorySettings`,
    /// which is `@Published`, so flipping the switch republishes and the widget re-evaluates — the
    /// rule F2 cost this branch to learn, that every input to this property must publish.
    ///
    /// **A declined record is skipped, not removed** (SONNY-282). `isDeclined` is read off the
    /// record the store loaded, so a decline written at a previous launch is honoured at this one —
    /// the whole of what the founder asked for — and the session set beside it is the same answer
    /// for the launch the cross was pressed in, disk or no disk. Neither touches
    /// `mayBeOfferedForResume`, the safety rule; a declined task is still one the user can continue
    /// from Memory, and the next record after it is the one offered instead.
    var resumeOffer: ResumableTask? {
        guard !isTaskInFlight else {
            return nil
        }
        guard isMemoryCategoryEnabled(.resumableTasks) else {
            return nil
        }
        return resumableTasks.first {
            $0.mayBeOfferedForResume && !$0.isDeclined && !declinedResumeOfferIDs.contains($0.id)
        }
    }

    var voiceButtonTitle: String {
        if isPreparingVoiceRecording {
            return "Starting"
        }
        if isRecordingVoice {
            return "Stop"
        }
        if isTranscribingVoice {
            return "Transcribing"
        }
        return "Speak"
    }

    var voiceButtonIcon: String {
        isRecordingVoice ? "stop.circle" : "mic"
    }

    /// - Parameter origin: Which surface is submitting this — see `TaskOrigin`. Defaults to
    ///   `.commandCenter`; the floating widget's own call sites pass `.widget` explicitly.
    /// - Parameter workspaceBinding: A workspace named by the dispatch itself rather than by the
    ///   command text — B4's workspace-card action. Wins over the free-text match.
    /// - Parameter fromComposer: Whether this dispatch is the widget composer submitting what the
    ///   user typed or spoke into it. **Only a composer dispatch may consume a pending card
    ///   binding**; every other entry point kills it instead. Defaults to `false` so a call site
    ///   added later inherits the safe direction — a new dispatch that forgets to say anything
    ///   drops the arm rather than silently scoping itself with it.
    /// - Parameter prebuiltPlan: An exact plan a screen already constructed — SONNY-64. Supplying it
    ///   replaces *planning only*: the run skips both the instant resolver and the planner and
    ///   executes this plan verbatim, then rejoins the identical path at `prepare`, so the
    ///   assessment, the gate, the approval prompt, the events, and the history row are the ones the
    ///   equivalent typed command would have produced. It is not a way past anything, and there is
    ///   nowhere in this function or the next where it could become one — the only thing it changes
    ///   is who wrote the plan.
    /// **The wipe's claim is read here, not in `dispatch`** (SONNY-404, PR #207's F3). This is where
    /// `isRunning` is set, so it is the door every caller passes through — `dispatch`, the widget,
    /// the row actions, the clarification resume and the approval path all end here. Settings' whole
    /// wipe deletes every store and clears the in-memory state a run holds, and it now spans a
    /// server round trip, so a run started inside that window loses its files under it.
    func start(
        autoExecute: Bool = false,
        origin: TaskOrigin = .commandCenter,
        workspaceBinding: String? = nil,
        fromComposer: Bool = false,
        prebuiltPlan: AgentPlan? = nil,
        // Which surface built `prebuiltPlan`. Defaulted to `.directUserAction` so SONNY-64's
        // existing callers read unchanged; a vision session passes its own case, because
        // `PreparedPlanSource`'s own rule is that a surface needing to be told apart adds a case
        // rather than overloading one. See `PreparedPlanSource.visionSession` for why the two are
        // different claims, and for what happened to the second, stronger reason SONNY-81 gave.
        prebuiltPlanSource: PreparedPlanSource = .directUserAction
    ) {
        // **Spent here, before every guard below** (PR #105 review F1). A dispatch either carries on
        // the record in flight or is a task of its own, and which it is was decided by the caller —
        // so the arm is read once and cleared once, and a *refused* dispatch drops it rather than
        // leaving it for the next, unrelated one to inherit.
        let continuation = pendingResumableContinuation
        pendingResumableContinuation = nil

        if isAwaitingApproval {
            approvePendingRun()
            return
        }

        guard canSubmit else {
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setError("Enter a natural-language command first.")
            }
            return
        }

        // Captured now, synchronously, rather than re-read from `command` inside `performStart`.
        // `performStart` is the body of an unstructured `Task` — it only actually begins running on
        // a later main-actor turn, not synchronously with this call — and a caller is free to clear
        // `command` immediately after calling `start()`. Reading the live property from inside
        // `performStart` meant every widget text submission ran with an already-cleared empty
        // command: a silently dropped real command, an "Enter a natural-language command first"
        // failure, and a blank "Untitled task" history record instead of what was typed.
        let submittedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDeletingLocalData else {
            // Refused rather than raced, and it says so rather than doing nothing (PR #207's F3).
            logStore.append(.observe, "Not started: Sonny is deleting your data.")
            return
        }

        // Set here, synchronously, not inside `performStart` — `CommandCenterRunningIndicator`
        // needs a correct "what's actually running" label the instant `isRunning` flips true, not
        // a render or two later once the scheduled `Task` catches up.
        lastCommand = submittedCommand
        // Cleared centrally, for every caller, rather than leaving each call site (voice, routine/
        // workspace quick actions, retry, clarification-resume) responsible for remembering to do
        // it themselves — that inconsistency was the actual bug: voice and the quick actions never
        // cleared it, so a stale command sat in the widget's own field (and got misread as "what's
        // running" by the display below) long after the real submission had already moved on.
        command = ""

        // **A pending card binding may bind exactly one task: the next composer dispatch.**
        //
        // It used to be consumed by *any* `start()`, which meant an armed-but-never-submitted chip
        // was inherited by the next Command Center row action — click "New task" on Drafting, get
        // distracted, then click Open on Research, and Research opened under Drafting's boundary
        // and raised a scope prompt naming a workspace the user never mentioned. A slot with one
        // setter, two death paths and no abandonment path outlives the dispatch that created it.
        //
        // Now: a composer dispatch consumes it; every other dispatch kills it without inheriting.
        // Either way it dies here, so it can never reach a second task. An explicit
        // `workspaceBinding:` argument still wins over both, which is what keeps SONNY-38's
        // precedence rule (card beats a workspace named in the command text) a single slot.
        explicitWorkspaceBinding = workspaceBinding ?? (fromComposer ? pendingWorkspaceBinding : nil)
        pendingWorkspaceBinding = nil
        currentTask?.cancel()
        // **Cleared here, synchronously, and not in `performStart` where the rest of the previous
        // run's state is cleared** (PR #188's F3), for the reason `lastCommand` two blocks above is
        // assigned here: `performStart` is the body of an unstructured `Task` and first runs a
        // main-actor turn later, so anything it clears is still the *previous* run's for one render.
        // `plan` is read beside `isRunning` — `isScreenControlTaskInFlight` pairs exactly those two
        // — and in that window the pair described two different runs: a free task dispatched after a
        // screen-control one answered the gate `true`, and the widget offered a runs-left figure
        // beside a calculation. A published pair that is read together is assigned together.
        plan = nil
        isRunning = true
        currentTask = Task {
            await performStart(
                submittedCommand: submittedCommand,
                autoExecute: autoExecute,
                origin: origin,
                prebuiltPlan: prebuiltPlan,
                prebuiltPlanSource: prebuiltPlanSource,
                continuing: continuation
            )
        }
    }

    /// `currentTask?.cancel()` doesn't guarantee the in-flight work throws Swift's own
    /// `CancellationError` — a cancelled `URLSession` request (the planner/transcriber's network
    /// calls) can surface as `URLError(.cancelled)` instead, depending on exactly where the
    /// cancellation lands. Catching only `CancellationError` meant a cancel that happened mid-network-
    /// call fell through to the generic failure path: styled red, a Retry button, "cancelled" as the
    /// error text — a deliberate user cancellation rendered as if it were a real failure.
    /// **Delegated rather than declared, since SONNY-131.** It used to test two shapes —
    /// `CancellationError` and `URLError(.cancelled)` — which was the whole population while every
    /// client held its own provider key. The moment a route moved behind the gateway, a stop that
    /// reached a request already in flight started arriving as `SonnyBackendError.cancelled` wrapped
    /// in the calling client's own error type, and this answered `false`: the user who pressed stop
    /// was told something went wrong. `SonnyBackendError.isCancellation` is the one predicate now,
    /// and its own doc comment says which wrappers it does not yet reach.
    func isCancellationError(_ error: Error) -> Bool {
        SonnyBackendError.isCancellation(error)
    }

    private func performStart(
        submittedCommand: String,
        autoExecute: Bool,
        origin: TaskOrigin,
        prebuiltPlan: AgentPlan? = nil,
        prebuiltPlanSource: PreparedPlanSource = .directUserAction,
        continuing: ResumableTaskContinuation? = nil
    ) async {
        activeTaskOrigin = origin
        // Submitting anything is an acknowledgement of whatever was on screen — this one line covers
        // both "the user retried" and "the user typed something else", because `retryLastCommand`
        // reaches here through `dispatch` like every other submission.
        outcomeWasNotified = false
        errorMessage = nil
        finalSummary = ""
        // `plan` is cleared by `start()` rather than here, a main-actor turn earlier — see the
        // comment at that assignment for why the pair it belongs to cannot be split across turns.
        suggestions = []
        clarificationQuestion = nil
        clarificationAnswer = ""
        preparedRun = nil
        approvalRequest = nil
        stepStatuses = [:]
        // Both halves of the pause carry-over, not just one. These two are always written together
        // (an approval pause sets both, and as of SONNY-166 so does a clarification pause) and read
        // together, so clearing only the date left the command able to outlive the run that set it.
        // Nothing read the stale value on any live path — every reader is inside a branch that
        // rewrites both first — but a pair whose reset covers one member is the shape a later reader
        // gets wrong, and the clarification exit's whole correctness argument is that the pair
        // describes *this* run.
        pendingCommandForPriorTaskContext = nil
        pendingTaskHistoryStartedAt = nil
        // **The handle on the previous run's checkpoint, dropped — and dropping it is not the same
        // as abandoning the record** (corrected by PR #105 review F1).
        //
        // What this line used to claim: that the worst a missed settle could leave behind is "one
        // stale entry under Memory". That was wrong, and the wrongness was the bug. The same
        // published list `resumableTasks` is what `resumeOffer` reads, so a record left behind here
        // is a live **offer** — Sonny volunteering to carry on with something that has finished.
        //
        // What is correct is the rule this line enforces: a run appends units only to its own
        // record. Whether the record it is dropping should have been *carried* is `continuing`'s
        // question, decided by the caller, and there are exactly three doors that say yes —
        // `continueResumableTask`, `submitClarification` and `retryLastCommand`. Every other
        // dispatch is a different task, and leaving that record on disk is the founder's lifecycle
        // rather than a leak: an unfinished task survives the user doing something else.
        activeResumableTask = nil

        if preserveUsageForNextStart {
            // **The `task_id` is preserved with the usage, and for the same reason** (SONNY-130).
            // This branch is a run continuing something that already spent something — a
            // transcription that produced this command, or a clarification answer — so it is the
            // same task, and its requests belong under the same key.
            preserveUsageForNextStart = false
            publishTaskUsageSummary()
        } else {
            beginNewTaskIdentity()
        }

        activeTaskScope = .unscoped
        // A new task starts with no trace: the line describes the run it completed with, and a
        // previous task's trace surviving into this one would claim a silence that has not
        // happened yet.
        ranWithoutAskingTrace = nil
        // Same reasoning as the trace: the HUD line describes a session that is live, and a
        // previous session's line surviving into a new task would claim Sonny is controlling an app
        // it is not.
        visionSessionProgress = nil

        // Clipboard history pauses for the whole of a suppressed run, and the cost was chosen
        // knowingly by the founder on 2026-08-16: anything the user copies *by hand* during the task
        // is not saved either. It cannot be avoided by being cleverer — `ClipboardHistoryMonitor` is
        // a pasteboard poller watching `changeCount`, so it cannot tell text Sonny copied from text
        // the user copied.
        //
        // A run that ends by crash or quit never reaches the resume in `finishRecordingPolicyIfSettled()`.
        // That is survivable rather than silent: monitoring is restarted from settings at launch by
        // `refreshClipboardHistoryNotice()`, so the worst case is clipboard history staying off until
        // the next launch, never a setting silently rewritten.
        if taskRecordingPolicy.suppressesTraces {
            stopClipboardHistoryMonitoring()
        }

        defer {
            publishTaskUsageSummary()
            isRunning = false
            currentTask = nil
            // Cleared on *every* exit of this function, unlike the scope below — a paused vision
            // session does not reach here at all (the loop is still suspended inside `execute`), so
            // reaching this line always means the session is over, however it ended.
            visionSessionProgress = nil
            visionCapturePreview = nil
            visionDelegationRequest = nil
            visionSessionPause = nil
            // The one place a session ends, whatever ended it — so the combination goes back to the
            // user's own apps on every exit, including the ones nobody planned for.
            releaseEmergencyStopHotKey()
            // And the iteration's cached grants go with it, on the same "whatever ended it"
            // reasoning: the cache is scoped to an iteration, and outside a session there is no
            // iteration for it to belong to (SONNY-202).
            approvedAppsForThisVisionIteration = nil
            visionUserPauseMonitor?.clearPause()
            // Cleared *after* the history row is written by `recordTaskHistoryIfTerminal`, which
            // runs earlier in this same exit path — so the row carries the link and the next task
            // starts with none.
            activeVisionSessionID = nil
            // Per-task, cleared at every terminal exit — and deliberately *not* when the task is
            // merely paused. An approval or a clarification is the same task waiting on the user,
            // and it has to resume under the scope it was assessed with; clearing here would let
            // `performApproval` execute unscoped after the user approved a scoped assessment, which
            // is the stale-approval mismatch scoped requirement 4 exists to prevent. Every other
            // exit — completed, failed, cancelled, refused, preview-only — is terminal and clears.
            if approvalRequest == nil && clarificationQuestion == nil {
                activeTaskScope = .unscoped
                explicitWorkspaceBinding = nil
            }
            // Guarded internally on the same pause-versus-terminal test, so it is safe to call
            // unconditionally here and at every other terminal point.
            finishRecordingPolicyIfSettled()
        }

        let taskHistoryStartedAt = Date()
        let priorContextForPlanner = priorTaskContextStore.currentContext()
        // Arm, use once, gone (SONNY-150). Spent here, at the read, rather than left to the
        // `record(...)` that overwrites it at the end of every terminal path — "usually overwritten
        // later" is a different promise from "spent now", and the gap between them is a follow-up
        // silently attaching itself to the command after this one. A no-op for an ordinary context.
        priorTaskContextStore.consumeArmedContext()
        priorTaskContext = priorContextForPlanner

        // The decision this run will execute under when the user's standing per-routine trust
        // grant covers it (SONNY-54). Hoisted out of the `do` so the drift catch below can tell a
        // trusted execution apart from the ordinary auto-run path, whose failure behavior it must
        // not change.
        var routineTrustApproval = RiskApprovalDecision.notRequested

        do {
            let executor = makeExecutor()
            let runner: AgentRunner
            let prepared: PreparedAgentRun

            // **First, and it has to be first.** The two branches below both start from
            // `submittedCommand` — the resolver pattern-matches it, and anything it does not match
            // falls through to the registry-selected planner. A pre-built plan's command text is a
            // *label* for history and the running indicator, not an instruction, and the resolver
            // has no pattern for a workspace edit anyway; letting it reach either branch would send
            // a plan the screen already built to the planner to be re-derived from a sentence — the
            // exact round-trip this ticket removes, reintroduced one layer down and invisible,
            // because the run would still work. Ordering is the enforcement: there is no path from
            // here to a planner while `prebuiltPlan` is non-nil.
            if let prebuiltPlan {
                runner = AgentRunner(
                    planner: InstantOnlyFallbackPlanner(),
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStoreForThisRun,
                    outputLocationStore: outputLocationStoreForThisRun
                )
                prepared = try runner.prepare(plan: prebuiltPlan, source: prebuiltPlanSource)
            // **A clarified command is not an instant command, and the first term is what says so**
            // (SONNY-248). The resolver matches on prefixes and it is the surface that raised
            // several of these questions in the first place — so once the request is restored to the
            // front of the continuation, `=` answered with "2 + 2" resolves here a second time, as a
            // calculator expression whose expression is the transcript of the conversation about it.
            // The resolver has already had its turn on this command and asked for more; reading the
            // more is a planner's job. Reachable through the answer and through a retry of the
            // answered run alike, which is why the term is a property of the command rather than of
            // this dispatch. **When the resolver asked, it gets the answer first** (SONNY-281):
            // `submitClarification` completes the command with the answer and dispatches the plain
            // result, so a command carrying an exchange that reaches this line is one the resolver
            // either did not ask about or could not complete.
            } else if !ClarifiedCommand.carriesExchange(submittedCommand),
                      let resolution = makeInstantCommandResolver().resolve(command: submittedCommand) {
                runner = AgentRunner(
                    planner: InstantOnlyFallbackPlanner(),
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStoreForThisRun,
                    outputLocationStore: outputLocationStoreForThisRun
                )
                switch resolution {
                case .plan(let localPlan), .clarify(let localPlan):
                    prepared = try runner.prepare(plan: localPlan, source: .instantResolver)
                }
            } else {
                // **This site does not decide which provider plans the task, and since SONNY-132
                // neither does anything else on this Mac.** It used to be a registry call carrying
                // a selection; the selection is `MODEL_ROUTE_PLAN` on the server now, and the
                // response is forbidden from naming which provider answered (contract §4.2). What
                // is left here is the one thing the client still owns: which *run* the planner is
                // built for — this task's id and its retention answer.
                runner = AgentRunner(
                    planner: makePlanner(
                        backendTaskContext(recordingPolicy: taskRecordingPolicy),
                        taskUsageRecorder
                    ),
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStoreForThisRun,
                    outputLocationStore: outputLocationStoreForThisRun
                )
                prepared = try await runner.prepare(
                    command: submittedCommand,
                    priorTaskContext: priorContextForPlanner
                )
            }
            self.runner = runner

            preparedRun = prepared
            plan = prepared.plan
            initializeStepStatuses(for: prepared.plan)

            // Resolved once, after the plan exists and before the first assessment, so that both
            // `approvalRequest` below and `execute` inside `executePreparedRun` see the same value.
            // The plan matters: `WorkspaceTaskTagging` reads `open_workspace`/`create_workspace`
            // steps' own `workspaceName` before it ever looks at the command text, which is how a
            // workspace-card dispatch resolves without needing the explicit binding at all.
            activeTaskScope = resolveTaskScope(command: submittedCommand, plan: prepared.plan)
            lastAssessedScope = activeTaskScope

            // **The one place a run becomes resumable, and it is deliberately before the gate**
            // (SONNY-210). The founder's first shape is a task Sonny is partway through when the
            // user walks away — "asks something or the laptop closes" — and the asking half is a
            // clarification or an approval, which is a pause this function returns on a few lines
            // below. A checkpoint written after the gate would cover the laptop and miss the
            // question. Written here, both are one rule with one write site.
            beginResumableTask(
                command: submittedCommand,
                plan: prepared.plan,
                startedAt: taskHistoryStartedAt,
                continuing: continuing
            )

            if let question = prepared.clarificationQuestion {
                clarificationQuestion = question
                clarificationAutoExecute = autoExecute
                clarificationOrigin = origin
                clarificationWorkspaceBinding = explicitWorkspaceBinding
                // The request the question is about, so that answering it continues that request
                // rather than replacing it with the question (SONNY-248). `submittedCommand` rather
                // than anything read off `command`, which `start()` emptied on the way in — see
                // `clarificationSubmittedCommand` for why every other candidate source is worse.
                clarificationSubmittedCommand = submittedCommand
                // The same two values the approval pause below preserves, for the same reason and
                // now for a second one (SONNY-166). A pause is not a terminal state, so no history
                // row is written here — `recordPriorTaskContext` is called without `startedAt:`
                // just below, and `recordTaskHistoryIfTerminal`'s own guards refuse a
                // `.clarificationNeeded` status anyway. But abandoning the question *is* terminal,
                // and a row needs the instant the run began and the text the user actually
                // submitted. Neither survives the pause otherwise: `command` was cleared
                // synchronously by `start()`, and `taskHistoryStartedAt` is local to this call.
                pendingCommandForPriorTaskContext = submittedCommand
                pendingTaskHistoryStartedAt = taskHistoryStartedAt
                finalSummary = "Clarification needed before I can act."
                logStore.append(.summarize, "Clarification needed: \(question)")
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .clarificationNeeded,
                    summary: finalSummary
                )
                return
            }

            let request = try runner.approvalRequest(
                for: prepared,
                logAssessment: true,
                scope: activeTaskScope,
                // `nil`: no per-app question is asked at plan time. §4.3 puts it after the
                // session's first capture, so this gate answers only for the plan.
                context: approvalContext(visionTarget: nil)
            )
            switch request.requirement {
            case .autoRun:
                break
            case .lightweightConfirmation, .explicitApproval:
                // SONNY-54: a routine the user marked trusted carries the same `.approved(.tier2)`
                // decision on a manual run that its scheduled runs already carry — the toggle was
                // always a per-routine trust grant, and presence is the safer case, not the riskier
                // one. This asks `AgentRunner.execute`'s own gate the same question rather than
                // restating it — before SONNY-62 it was a hand-written copy of the tier comparison,
                // and a copy of a gate is a gate that drifts. `execute` still re-assesses and
                // enforces it structurally; this check only decides pause-versus-proceed, so a
                // tier-3+ assessment pauses at this prompt exactly as it did before trust covered
                // manual runs. A standing grant is a tier ceiling, so the reason half of that gate
                // is vacuous here by construction.
                //
                // Safe mode gates this shortcut (SONNY-90): the dial is the user's opt-back-in to
                // being asked about every attended action, and a per-routine convenience grant
                // must not quietly override the global caution dial while the user is present to
                // answer. The unattended scheduled path is deliberately untouched — its standing
                // tier-2 ceiling and notify-and-pause are the ticket's "no new unattended prompt
                // class", and a schedule that Safe mode silently suspended would be one.
                let trustDecision = manualRoutineTrustDecision(for: prepared.plan)
                if interactionMode != .safe, trustDecision.authorizes(request) {
                    routineTrustApproval = trustDecision
                } else {
                    approvalRequest = request
                    pendingCommandForPriorTaskContext = submittedCommand
                    pendingTaskHistoryStartedAt = taskHistoryStartedAt
                    finalSummary = "Approval needed before Sonny can act."
                    logStore.append(.confirm, "Approval required for \(request.assessment.effectiveTier.displayName)")
                    recordPriorTaskContext(
                        command: submittedCommand,
                        preparedRun: prepared,
                        status: .approvalNeeded,
                        summary: finalSummary
                    )
                    return
                }
            case .previewOnly:
                // Unreachable today: no path in the mapping produces `.previewOnly` since the
                // policy dials were deleted (2026-08-14) — the requirement enum keeps the case
                // as public API and the consent rank still orders it. It reports
                // through `errorMessage` rather than `finalSummary` so that *if* a policy
                // control ever makes it reachable, the outcome is actually visible — the widget
                // and Command Center both surface errors, but neither renders a `.prepared`
                // prior-task-context status.
                markAllSteps(.complete)
                setError("The current approval policy limits this action to a preview, so Sonny did not run it.")
                logStore.append(.summarize, "Preview-only approval policy")
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .prepared,
                    summary: errorMessage ?? "Preview-only approval policy",
                    startedAt: taskHistoryStartedAt
                )
                return
            case .refuse:
                markAllSteps(.failed)
                setError("Sonny refused this action under the current approval policy.")
                logStore.append(.summarize, "Refused by approval policy")
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .failed,
                    summary: errorMessage ?? "Refused by approval policy",
                    startedAt: taskHistoryStartedAt
                )
                return
            }

            let autoApprovalMessage: String
            if routineTrustApproval == .notRequested {
                // Read off the prepared run's own source rather than off `autoExecute`, which
                // describes how the *text* arrived and says nothing true about a run that had no
                // text to arrive. The `.directUserAction` branch below is the workspace sheet's
                // ordinary confirmation message — under the consequence rule every sheet edit
                // auto-runs (tier 2, or tier 3 with only advisory escalations), so every
                // screen-built dispatch passes through here. The vision envelope remains the next
                // *caller*; it is no longer the first.
                if prepared.source == .directUserAction {
                    autoApprovalMessage = "Screen-built action auto-approved execution"
                } else {
                    autoApprovalMessage = autoExecute ? "Voice command auto-approved execution" : "Typed command auto-approved execution"
                }
            } else {
                autoApprovalMessage = "Manual run approved by this routine's trust setting"
            }
            let result = try await executePreparedRun(
                preparedRun: prepared,
                runner: runner,
                approvalDecision: routineTrustApproval,
                confirmationMessage: autoApprovalMessage,
                logRiskAssessment: false
            )
            // Only after the run really executed: an auto-run that drifted to a prompt was
            // disclosed by the prompt, and tracing it as silent would be false. The line is nil
            // for the trust path (its requirement was an ask the toggle answered, not `.autoRun`)
            // and nil for tiers that always ran silently; the pure function owns both rules, and
            // it names the advisory reasons — the sentences the approval panel used to carry.
            ranWithoutAskingTrace = AgentActivityPresentation.ranWithoutAskingLine(
                requirement: request.requirement,
                effectiveTier: request.assessment.effectiveTier,
                advisoryReasons: request.assessment.escalations
                    .filter { $0.consequence == .advisory }
                    .map(\.reason)
            )
            finalSummary = result.summary
            suggestions = result.suggestions
            let recordedTaskID = recordPriorTaskContext(
                command: submittedCommand,
                preparedRun: prepared,
                status: .completed,
                summary: result.summary,
                // Carried from the adapter that authored the text (SONNY-147) rather than assumed
                // here — a run that resolved to a screen-control session comes back
                // `.modelAuthored`, and so does a chain or a routine that contained one.
                resultProvenance: result.summaryProvenance,
                startedAt: taskHistoryStartedAt
            )
            // `refreshSavedItems()` used to sit here, and `recordPriorTaskContext` above now reaches
            // it through `refreshMemoryRowsAfterRun()` on every terminal outcome rather than on this
            // one branch — which is the F6 fix. Leaving it would load routines and workspaces twice
            // for every successful run.
            publishCompletedRunNoticeIfUnreported(result.summary, taskID: recordedTaskID)
        } catch RiskApprovalError.approvalRequired(let request) {
            // Whatever let this run proceed without a prompt — a routine's trust grant, or the
            // consequence rule mapping it to `.autoRun` — stopped covering it in the window
            // between the assessment above and `AgentRunner.execute`'s own re-assessment: the
            // state-drift class `performApproval` re-arms on ("the zip already exists" landing
            // mid-flight turns an advisory-only or escalation-free run into a destructive one).
            // Every dispatch through this function has a user present, so it prompts exactly as an
            // ordinary run would rather than failing. The `where routineTrustApproval !=
            // .notRequested` clause that used to scope this to the trust path is gone
            // deliberately: a plan that reached `.autoRun` on its own carries `.notRequested`, and
            // hard-failing the one drift a user could simply answer was the gap SONNY-97's
            // contract named. The unattended path is unaffected — it dispatches through
            // `performScheduledRun`, whose own `RiskApprovalError` catch pauses the schedule
            // instead (SONNY-31).
            markAllSteps(.pending)
            approvalRequest = request
            pendingCommandForPriorTaskContext = submittedCommand
            pendingTaskHistoryStartedAt = taskHistoryStartedAt
            finalSummary = "Approval needed before Sonny can act."
            logStore.append(.confirm, "Approval required for \(request.assessment.effectiveTier.displayName)")
            if let preparedRun {
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: preparedRun,
                    status: .approvalNeeded,
                    summary: finalSummary
                )
            }
        } catch {
            if isCancellationError(error) {
                markAllSteps(.canceled)
                finalSummary = "Canceled."
                logStore.append(.summarize, "Canceled by user")
                if let preparedRun {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        preparedRun: preparedRun,
                        status: .canceled,
                        summary: finalSummary,
                        startedAt: taskHistoryStartedAt
                    )
                } else {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        status: .canceled,
                        summary: finalSummary,
                        startedAt: taskHistoryStartedAt
                    )
                }
            } else {
                markAllSteps(.failed)
                setError(error.localizedDescription)
                logStore.append(.summarize, "Stopped: \(error.localizedDescription)")
                if let preparedRun {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        preparedRun: preparedRun,
                        status: .failed,
                        summary: error.localizedDescription,
                        startedAt: taskHistoryStartedAt
                    )
                } else {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        status: .failed,
                        summary: error.localizedDescription,
                        startedAt: taskHistoryStartedAt
                    )
                }
            }
        }
    }

    func cancelCurrentRun() {
        // **One press ends the run** — the experiment's Option A, ratified by the founder on
        // 2026-08-14 and inherited here as the semantics of the stop control. The continuation is
        // cleared and resumed *before* the cancel, so `requestVisionActionApproval`'s own handler
        // guards on the same property, finds nothing, and there is exactly one resume; the
        // `Task.checkCancellation()` after that await then turns this into the same
        // `CancellationError` a cancelled clarification throws, so the run ends with the same honest
        // "Stopped." rather than reading the `nil` as "the user declined this one action, carry on".
        //
        // A stop control that visibly fails to stop is the most expensive surprise a program moving
        // the user's real cursor can produce, which is why decline-and-continue is not folded in
        // here. The founder wants that capability back as a *labelled* "deny this step" control
        // beside a labelled stop (SONNY-80's standing note); when it lands it is a second, narrower
        // entry point that resumes `nil` without cancelling — not a change to this one.
        if let continuation = visionApprovalContinuation {
            visionApprovalContinuation = nil
            approvalRequest = nil
            markFirstApprovalCompleted()
            continuation.resume(returning: nil)
            currentTask?.cancel()
            return
        }
        // The Safe-mode capture preview is the other parked question a session can hold. Cancelling
        // it means "do not send this", which ends the session — there is no next step that does not
        // begin with sending a capture.
        if let continuation = visionCaptureContinuation {
            visionCaptureContinuation = nil
            visionCapturePreview = nil
            continuation.resume(returning: false)
            currentTask?.cancel()
            return
        }
        // The third parked question a session can hold. Cancelling it stops the run rather than
        // declining the delegation and carrying on, for the same reason the two above it do: a stop
        // control has to stop. Declining without stopping is `resolveVisionDelegation(allowing:)`,
        // which is a *different control* — the labelled deny SONNY-80's standing note asks for,
        // arriving here first because a delegation is the one place declining-and-continuing is
        // obviously useful and has an obvious label.
        if let continuation = visionDelegationContinuation {
            visionDelegationContinuation = nil
            visionDelegationRequest = nil
            continuation.resume(returning: false)
            currentTask?.cancel()
            return
        }
        // Stopping a paused session ends it, which is the only thing stop can honestly mean here:
        // the alternative reading — "stop pausing" — is what Resume is for, and it has its own
        // control.
        if let continuation = visionResumeContinuation {
            visionResumeContinuation = nil
            visionSessionPause = nil
            continuation.resume(returning: false)
            currentTask?.cancel()
            return
        }

        if isAwaitingApproval {
            if let preparedRun, let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .canceled,
                    summary: "Approval canceled. No action was taken.",
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            approvalRequest = nil
            hasCompletedFirstApproval = true
            preparedRun = nil
            runner = nil
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
            markAllSteps(.canceled)
            finalSummary = "Approval canceled. No action was taken."
            logStore.append(.summarize, "Approval canceled by user")
            // The pause ends here rather than resuming, so the binding dies with it. Without this
            // the next command would inherit the cancelled task's workspace — the exact leak the
            // rejected persistent-active-workspace design was rejected for.
            activeTaskScope = .unscoped
            explicitWorkspaceBinding = nil
            // This function has no `defer`, and this branch returns without ever re-entering
            // `performStart` — so without this call a task cancelled at its approval prompt would
            // leave the switch on and clipboard history paused indefinitely.
            finishRecordingPolicyIfSettled()
            return
        }

        // **The fourth exit (SONNY-166): a clarification the user does not want to answer.**
        //
        // Before this, the only three ways out of a clarification pause were answering it, wiping
        // all local data, and quitting — `clarificationQuestion` had exactly those three clearing
        // sites. The pause looks idle from outside (`isRunning` is false, `approvalRequest` is nil),
        // so nothing that gates on those two could offer a way out, and the composer is disabled by
        // the in-flight term besides.
        //
        // **Cancelled, not failed, and "no action was taken" is literal.** A clarification is raised
        // inside `AgentRunner.prepare` and `performStart` returns on it before `executePreparedRun`
        // is reached at all, so every step is still `.pending` and nothing has executed. This is the
        // one pause where that is true of the whole plan rather than of the remaining steps.
        //
        // Placed after the approval branch for reading order only — it mirrors the two surfaces'
        // permission-over-clarification precedence. The two states are mutually exclusive by
        // construction: `performStart` returns on the clarification before it ever builds an
        // approval request, and `submitClarification` clears the question before re-entering
        // `start()`, so neither branch can shadow the other whichever came first.
        if clarificationQuestion != nil {
            // The row the Tasks list owes the user, on the founder's decision of 2026-08-20: the
            // same `.canceled` disposition cancelling at an approval prompt already writes, so the
            // two exits from a paused run leave the same trace. Both values were preserved across
            // the pause by `performStart`'s clarification branch — without them there is no
            // `startedAt`, and `recordTaskHistoryIfTerminal` refuses to write a row at all.
            // "Don't save this task" still suppresses it: that check lives inside
            // `recordTaskHistoryIfTerminal`, so this path inherits it rather than restating it.
            if let preparedRun, let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .canceled,
                    summary: ClarificationPresentation.canceledSummary,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            clarificationQuestion = nil
            clarificationAnswer = ""
            // The values the pause held so that answering could resume the task the user actually
            // started. Nothing is going to resume, so they die with it — an origin, a binding or a
            // request surviving into the next run is the leak `explicitWorkspaceBinding`'s own
            // lifecycle rules exist to prevent. (No count in this sentence on purpose: it said
            // "three" and SONNY-248 made it four, which is how a comment starts describing a
            // neighbouring line instead of the one below it.)
            clarificationAutoExecute = false
            clarificationOrigin = .commandCenter
            clarificationWorkspaceBinding = nil
            clarificationSubmittedCommand = nil
            preparedRun = nil
            runner = nil
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
            markAllSteps(.canceled)
            // `submitClarification` sets "Enter an answer before continuing." when Send is pressed
            // on an empty field, and that error outlives the question it was about. The widget's
            // and Command Center's shared precedence puts `.failure` above `.result`, so leaving it
            // would show the user a stale validation nudge where the cancellation belongs.
            errorMessage = nil
            finalSummary = ClarificationPresentation.canceledSummary
            logStore.append(.summarize, "Clarification canceled by user")
            // Same reason the approval branch clears these: the pause ends here rather than
            // resuming, so the boundary the paused task was assessed under must not be inherited by
            // whatever the user types next.
            activeTaskScope = .unscoped
            explicitWorkspaceBinding = nil
            // **The ticket's own requirement, and the reason it is the last line.** This function
            // has no `defer`, and `finishRecordingPolicyIfSettled` guards on
            // `approvalRequest == nil, clarificationQuestion == nil, !isRunning` — so calling it
            // before the clear above would return without doing anything, leaving "Don't save this
            // task" on and clipboard history paused until the next launch. That is the exact
            // consequence SONNY-120 recorded as a known limit and this ticket exists to close.
            //
            // **No `currentTask?.cancel()`, and the honest reason is the scheduler guard rather
            // than the defer.** This used to read "`performStart`'s defer set it to `nil` on the way
            // into the pause, so there is no task here to cancel", which was false in exactly one
            // window: `checkScheduledRoutines` could start a routine during the pause, and
            // `currentTask` was then that run — so cancelling a clarification would have killed a
            // scheduled run the user never started, and the reset below would have been refused
            // anyway because `isRunning` was true. `checkScheduledRoutines` now refuses to start
            // anything while a clarification is open (PR #80 review, F1), which is what makes the
            // claim true rather than the defer: no other path can put a task here while the question
            // stands. Pinned by `aPendingClarificationStopsTheSchedulerFromStartingAnything`.
            finishRecordingPolicyIfSettled()
            return
        }

        // Everything below is a *running* task being cancelled, which unwinds through
        // `performStart`'s defer and is settled there.
        currentTask?.cancel()
    }

    /// Whether `retryLastCommand()` would actually do anything. `errorMessage` also carries
    /// pre-flight errors that never reached a real submission (an empty-command validation
    /// message, a voice-transcription failure) — those leave `lastCommand` empty, so a UI that
    /// shows a Retry button for *any* `errorMessage` would show one that's silently a no-op for
    /// exactly those cases. Exposed as a bool here since retry-eligibility callers only need the
    /// yes/no, not the text — see `runningCommandDisplayText` below for the text itself.
    var hasRetryableCommand: Bool {
        !lastCommand.isEmpty
    }

    /// The real command driving the current/last run — `command` itself is cleared the instant
    /// `start()` captures it (see `start()`), so by the time a task is visibly `isRunning`, `command`
    /// is already empty again. A surface showing "what's actually running" (Command Center's
    /// running indicator) needs this instead of `command`, or it reads every task as "Untitled
    /// task" regardless of what was actually submitted.
    var runningCommandDisplayText: String {
        // A scheduled run needs a label for Command Center's running indicator without claiming
        // `lastCommand`, which belongs to whatever the user last submitted themselves.
        //
        // **The request, not the prompt** (SONNY-248). `lastCommand` is two things at once: the text
        // a retry resubmits, and the text this indicator shows. A clarified run's prompt carries the
        // exchange that clarified it, which the retry needs and a sentence reading "Running: …" does
        // not — so the split happens here, at the display half, and `lastCommand` itself stays the
        // whole prompt.
        scheduledRunDisplayCommand ?? ClarifiedCommand.request(in: lastCommand)
    }

    /// Called by the widget after a `.result` (including a clean "Canceled.") or a genuinely
    /// transient `.failure` has sat unacknowledged for a while (see `FloatingWidgetView`'s
    /// auto-clear timer) — the widget is a permanent, undismissable overlay, so with no timeout
    /// either would otherwise sit there indefinitely; merely collapsing to the small capsule
    /// doesn't help, since re-expanding it would show the exact same stale content again (this was
    /// a real, reported bug — a cancellation's "Canceled." banner survived collapsing the widget
    /// multiple times, because collapsing was the only thing this used to do). Clears both
    /// `errorMessage` and `finalSummary`/`suggestions`/`ranWithoutAskingTrace` unconditionally —
    /// whichever pair wasn't actually active is already empty, so clearing it too is harmless
    /// (see the trace's own note in the body). Deliberately scoped here,
    /// not a broader `reset()`. `FloatingWidgetView`'s timer only ever calls this for `.result`, or
    /// for `.failure` when `errorIsPersistent` is false, so a real configuration problem never gets
    /// silently cleared out from under the user.
    func clearStaleTaskOutcome() {
        // The marker describes the outcome, so it cannot outlive it — a stale `true` would make the
        // *next* outcome un-collapsible for a notification that was never sent about it.
        outcomeWasNotified = false
        errorMessage = nil
        finalSummary = ""
        suggestions = []
        // The trace rides on `finalSummary` and has no independent lifetime: `WidgetResultPanel` is
        // its only reader, and that panel exists only while `finalSummary` is non-empty. Clearing
        // one and not the other leaves a value that can never be shown with the run it describes and
        // can only reappear paired with someone else's summary — which is exactly how it reached
        // `deleteLocalData`'s deletion message (PR #48, F1).
        ranWithoutAskingTrace = nil
    }

    /// The one place `errorMessage` should be set (never assign it directly) — forces every call
    /// site to make an explicit, visible choice about `persistent` rather than silently inheriting
    /// whatever the last call happened to leave behind. Defaults to `false` (transient) since most
    /// errors in this app are one-off task/validation outcomes, not environment problems; the small
    /// number of genuinely persistent cases (missing API key, denied mic permission, unavailable
    /// hotkey) pass `persistent: true` explicitly.
    func setError(_ message: String, persistent: Bool = false) {
        errorMessage = message
        errorIsPersistent = persistent
    }

    /// Resubmits the last real command as-is. Used by the floating widget's task-level-failure
    /// retry button (§3.3.6), the error notification's "Retry" action, and Command Center's own
    /// failure row.
    ///
    /// - Parameter origin: Which surface's retry control this is. Defaults to `.widget` so the
    ///   two pre-existing call sites keep their original behavior. This used to be hardcoded
    ///   `.widget` on the reasoning that Command Center had no retry control — true until branch
    ///   10 checkpoint 1 gave it one. The retry action is a fresh interaction on whichever surface
    ///   the user pressed it, not an inheritance of the failed task's origin, so the caller states
    ///   it rather than it being inferred — same convention as `toggleVoiceRecording(origin:)`.
    func retryLastCommand(origin: TaskOrigin = .widget) {
        // `clarificationQuestion == nil` for the same reason every other in-flight term here exists:
        // a pause is a task the user has not finished answering, and retry is a *new* dispatch.
        // Without it, the notification's Retry — which fires from outside SwiftUI, so no view gate
        // can cover it — wrote the old command straight into a live pause.
        guard !lastCommand.isEmpty, !isTaskInFlight else {
            return
        }
        // Carries the original run's workspace. `lastAssessedScope` is the post-terminal record of
        // what the last task was assessed under and is deliberately never cleared, which is exactly
        // what makes it readable here — by retry time the live binding is long gone. Without this a
        // retry of a bound task runs unscoped, so a run whose first pass surfaced an out-of-scope
        // fact (once a prompt; an advisory trace line under the consequence rule) would repeat with
        // that fact silently missing — the two passes must be assessed under the same boundary.
        // Inherited from SONNY-38 rather than introduced here; fixed in-branch per fix-in-branch.
        //
        // Not `fromComposer`: a retry is a re-dispatch, so it still kills any card arm rather than
        // consuming it — the explicit binding below wins over the arm either way.
        var retryBinding: String?
        if case .scoped(let scope) = lastAssessedScope {
            retryBinding = scope.workspaceName
        }
        // **The second restart door, and it has F1's shape too** (found by the re-enumeration that
        // finding asked for, not by the finding itself). A failed run's record is kept, and
        // `activeResumableTask` still points at it — so a retry that minted a new id would leave the
        // failed attempt behind as a live offer even after the retry succeeded. Continuing it keeps
        // one record for one task, which is the same invariant the other two doors hold.
        armRestartOfTaskInFlight()
        dispatch(command: lastCommand, origin: origin, workspaceBinding: retryBinding)
    }

    /// Runs a past task again by **re-asking Sonny with the same words**, never by replaying the
    /// plan the first run produced (row E, SONNY-149).
    ///
    /// **The reason replay is not on the table is the risk gate, not the stale coordinates.** Sonny's
    /// gate is pre-execution and whole-plan: `AgentRunner.execute` assesses once, up front, and
    /// `executeChain` runs every segment with no re-gating. So re-executing a previously approved
    /// plan would carry an approval granted for a world that has since changed — the file that did
    /// not exist then exists now, so the destructive escalation that should fire would not.
    /// Re-asking through the planner keeps every gate honest by construction rather than by anyone
    /// remembering. Two secondary reasons agree with it: nothing in this codebase replays a stored
    /// plan today, and a screen-control replay would click at coordinates that have moved.
    ///
    /// **What that means for the user, which reads like a regression and is not.** The workspace
    /// binding is re-resolved and any approval is re-requested, so a task that asked for permission
    /// the first time asks again. That is the same property that makes replay unsafe, seen from the
    /// other side. A run-again of a screen-control task starts a *fresh* session and never replays
    /// the journal's recorded actions — the journal is a record of what happened, not a script.
    ///
    /// **No `isTaskInFlight` guard of its own, deliberately.** `dispatch` refuses every in-flight
    /// state already — `isAwaitingApproval` at its own first line, and `isRunning`, an open
    /// clarification and a transcription in flight through `canSubmit` — and it logs the refusal at
    /// the one place every programmatic door passes through. A copy of that rule here would be a
    /// second place for it to drift, and a second refusal message for the same event, which the
    /// choke point's own comment rules out. The detail sheet disables the control while a task is in
    /// flight, the same way the workspace card does, so this path is the backstop rather than the
    /// user's experience of it.
    ///
    /// **A sibling of `retryLastCommand`, not a change to it.** That mechanism is the single-slot
    /// most-recent-command retry and keeps its own `lastCommand` and `lastAssessedScope`; this takes
    /// an arbitrary historical record and reads the binding off the record itself.
    ///
    /// - Returns: whether the dispatch was accepted, so the sheet can close on a real start and stay
    ///   open on a refusal rather than hiding the fact that nothing happened.
    @discardableResult
    func runTaskAgain(_ record: CompletedTaskRecord) -> Bool {
        // **The fourth continuation door** (PR #105 re-check, F1). Running a failed task again from
        // its own row is the same task starting over, so it continues that task's record rather than
        // minting a second one and leaving the first as a live offer for something the user has just
        // re-run to completion.
        armRestartOfRecordedTask(record)
        let started = dispatch(
            command: record.command,
            // Stated rather than defaulted, per `.claude/rules/macagent-ui-conventions.md`: a new
            // task-submitting entry point passes its own real origin. This one is pressed in
            // Command Center's task detail, so `.commandCenter` is the true answer and `dispatch`'s
            // default happening to match it is not a reason to leave it out.
            origin: .commandCenter,
            // The record's own stored workspace, which degrades safely on its own:
            // `resolveTaskScope` returns `.unscoped` for a name that no longer resolves to a stored
            // workspace, so running again a task whose workspace was deleted or renamed runs
            // unscoped rather than erroring or binding to an empty boundary.
            workspaceBinding: record.workspaceName
        )
        // **`dispatch` can refuse before `start()` ever runs** — its `isAwaitingApproval` guard
        // returns without calling it — and this door has no in-flight guard of its own, unlike
        // `retryLastCommand`. So the arm is dropped here rather than left for the next, unrelated
        // dispatch to spend. Same reason and same shape as `continueResumableTask`'s.
        guard started else {
            pendingResumableContinuation = nil
            return false
        }
        return true
    }

    /// Reopens a past task into the widget so the user can say the next thing about it (row E,
    /// SONNY-150) — "use the other folder instead", "do that again but for March" — without
    /// restating the whole command.
    ///
    /// **What it installs, and why it is built rather than assembled.** A `PriorTaskContext` from
    /// what that task stored: its command, the plan summary and steps `TaskPlanDetailStore` kept,
    /// and an outcome built from the row's status and stored result. Built through
    /// `PriorTaskContext`'s own initialiser, so every field reaches the planner through
    /// `plannerContextText` and inherits `escapeForPlanner` structurally. **No prompt string is
    /// assembled from a stored record anywhere, here or elsewhere** — that is the row I lesson this
    /// row is most exposed to, since persistence removes the ten-minute bound that made the original
    /// omission survivable.
    ///
    /// **A task with no stored plan still works, with less to go on.** Every record written before
    /// row E is in that case, and it is the common one on day one: the context carries the command
    /// and the outcome, and `plannerContextText` says the plan was not recorded rather than
    /// inventing a cause for its absence.
    ///
    /// **The arm is a live intention, not a stored one.** It is exempt from the ten-minute expiry
    /// because the user pointed at this task on purpose, and it is consumed by the next dispatch —
    /// `performStart` spends it the moment it reads it. Nothing persists it across launches.
    ///
    /// The widget comes forward with an **empty** composer, through the same
    /// `command` + `widgetPresentationRequest` mechanism `composeCommand` uses: the user is about to
    /// say the new thing, not re-edit the old one.
    ///
    /// - Returns: whether the task was armed, so the sheet can close on success and stay open on a
    ///   refusal.
    @discardableResult
    func followUpOnTask(_ record: CompletedTaskRecord) -> Bool {
        // Refused for the same reason `composeCommand` refuses a prefill during a clarification, and
        // then some: a partial command left in a live pause corrupts the continuation, and this
        // leaves a *trusted block* behind as well, which is worse. `isTaskInFlight` is the superset —
        // running, awaiting approval, or paused on an unanswered clarification.
        guard !isTaskInFlight else {
            logStore.append(.observe, "Follow-up ignored while a task is in flight.")
            return false
        }

        let detail = storedPlanDetail(for: record)
        let context = PriorTaskContext(
            armedFollowUpOn: record.command,
            planSummary: detail?.planSummary ?? "",
            steps: detail?.steps ?? [],
            outcome: PriorTaskOutcome(
                status: record.outcomeStatus,
                // The stored result, or nothing. `PriorTaskOutcome.plannerText` already falls back
                // to the bare status for an empty summary, so a record from before row E reads as
                // "completed" rather than as "completed - " with a dangling separator.
                summary: record.result?.text ?? "",
                // And who wrote it, which used to be dropped here while sitting on the same
                // expression (SONNY-197). A record with no stored result has no text either, so
                // `.codeAuthored` is the only honest answer for the empty case rather than a guess.
                provenance: record.result?.provenance ?? .codeAuthored
            ),
            completedAt: record.completedAt
        )
        priorTaskContextStore.replace(with: context)
        priorTaskContext = context

        // The follow-up runs inside the same workspace the original did, through the plumbing the
        // workspace card already uses — `start()` consumes this on a composer submit, and
        // `resolveTaskScope` degrades a name that no longer resolves to `.unscoped` on its own.
        pendingWorkspaceBinding = record.workspaceName

        // Empty, deliberately. `composeCommand("")` is not called directly because its own
        // clarification guard would be a second, weaker copy of the one above — this uses the same
        // two lines it does.
        command = ""
        widgetPresentationRequest += 1
        return true
    }

    /// Drops an armed follow-up. The chip's dismiss affordance, and nothing else.
    ///
    /// Clears the store as well as the published copy: leaving the context installed while the chip
    /// disappeared would be the invisible trusted block the chip exists to prevent, arrived at from
    /// the other direction.
    func clearArmedFollowUp() {
        guard priorTaskContext?.isArmed == true else {
            return
        }
        priorTaskContextStore.clear()
        priorTaskContext = nil
    }

    /// The plan this task ran, or `nil` — for a task recorded before row E, for one whose run never
    /// reached a plan, and for a store that will not read.
    ///
    /// **A load failure is reported and then treated as "no plan".** It goes to the same
    /// load-failure channel every other unreadable store uses, so the user sees the banner naming
    /// it; the follow-up still arms, with the command and the outcome. Refusing to arm because a
    /// side store would not decode would trade a degraded feature for no feature, and the founder's
    /// objection to a shorter-lived detail store was precisely that follow-ups must not quietly get
    /// weaker — a visible banner is the opposite of quietly.
    private func storedPlanDetail(for record: CompletedTaskRecord) -> StoredTaskPlanDetail? {
        guard let id = record.id else {
            return nil
        }
        do {
            let detail = try taskPlanDetailStore.detail(forTaskID: id)
            clearLocalStorageLoadFailure(.taskPlanDetails)
            return detail
        } catch {
            recordLocalStorageLoadFailure(.taskPlanDetails, error: error)
            return nil
        }
    }

    /// Submits the clarification answer as a **new** run, not a resume: this appends the Q&A to
    /// the command — or, for a question the instant resolver asked, completes the command with the
    /// answer (SONNY-281, `locallyCompletedCommand`) — and calls `start()`, which clears
    /// `plan`/`stepStatuses`/`preparedRun` and re-plans from scratch. (Approval is the real resume — it reuses the existing prepared
    /// run.) The auto-execute flag and origin are carried across the pause deliberately so the
    /// continuation behaves like the task the user actually started.
    func submitClarification() {
        guard let question = clarificationQuestion else {
            return
        }
        // **Before anything is torn down** (PR #119 review, F1). Every line below this clears a
        // piece of the pause and then calls `start()`, which refuses while a transcription is in
        // flight — and puts nothing back. `canSendClarificationAnswer` is the rule and says why all
        // three voice terms are in it; the Send controls are disabled off the same predicate, so
        // this is reached only by Return on the field, and it refuses the same way the button does.
        guard !isVoiceInputInFlight else {
            logStore.append(.observe, "Answer not sent: voice input is still in flight.")
            return
        }

        let answer = clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            setError("Enter an answer before continuing.")
            return
        }

        // **The request the question was asked about, not whatever `command` holds** (SONNY-248).
        // This used to interpolate `command`, which `start()` had already emptied when it accepted
        // this task's own dispatch — so the continuation began with Sonny's question and the user's
        // request was gone from all three of the places it flows to. `clarificationSubmittedCommand`
        // is where the request lives across the pause. `nil` there means the question was not raised
        // by a real run, and the composition degrades to the Q&A alone — which is precisely what
        // this produced for *every* clarification before the fix.
        //
        // **Request + Q&A, rather than the answer substituted into the request — for a question the
        // planner asked.** Substituting means rewriting the user's own sentence: a planner's job, and
        // a fragile string edit here. It also discards that Sonny asked and what it asked, which
        // leaves a second question nothing to build on. Appending keeps the request whole and
        // accumulates in the order the exchange happened, so a task clarified twice reaches the
        // planner as the request and both pairs.
        //
        // **For a question the resolver asked, the answer is the rest of the command** (SONNY-281).
        // The resolver's questions are raised on a bare prefix — `=` asks what to calculate — and
        // the planner cannot act on the answer: it has no calculator, and every other answer would
        // reach it as prose about a command it never saw the resolver's reading of. So the resolver
        // gets the answer first, as the command it was missing an operand for, and the plain result
        // goes through the same door typed text does. `locallyCompletedCommand` says how it knows the
        // resolver asked and what makes a completion workable.
        if let completed = locallyCompletedCommand(request: clarificationSubmittedCommand, answer: answer, question: question) {
            command = completed
        } else {
            command = ClarifiedCommand.composed(
                request: clarificationSubmittedCommand ?? "",
                question: question,
                answer: answer
            )
        }
        let shouldAutoExecute = clarificationAutoExecute
        let shouldUseOrigin = clarificationOrigin
        let shouldUseBinding = clarificationWorkspaceBinding
        clarificationAutoExecute = false
        clarificationOrigin = .commandCenter
        clarificationWorkspaceBinding = nil
        clarificationSubmittedCommand = nil
        clarificationQuestion = nil
        clarificationAnswer = ""
        // **Answering a question continues the task that asked it** (PR #105 review F1). Without
        // this the answered run minted a second record, settled only that one, and left the paused
        // run's record on disk for the full idle period — so after the task finished, Sonny offered
        // to carry on with it and Continue re-asked a question the user had already answered.
        armRestartOfTaskInFlight()
        start(autoExecute: shouldAutoExecute, origin: shouldUseOrigin, workspaceBinding: shouldUseBinding)
    }

    /// The plain command a clarification answer completes, or `nil` when the answer is the
    /// planner's to read (SONNY-281).
    ///
    /// **Who asked decides which door the answer goes through, and the question is what says who
    /// asked.** The founder typed `=`, was asked what to calculate, answered `2 + 2`, and was told
    /// calculation is not supported by the registered local tools — which is true of the planner,
    /// and the planner is who got the answer. SONNY-248 made every clarified command skip
    /// `InstantCommandResolver`, correctly for the case it was looking at: a request restored to
    /// the front of an exchange re-matched the resolver's own prefix and would have calculated the
    /// transcript. But the resolver raises questions of its own, on a bare prefix, and the planner
    /// cannot act on those answers — `CalculatorCapabilityAdapter` registers no planner tool at all,
    /// so a calculation that reaches the planner is refused by design, and every other such answer
    /// arrives as prose about a command the planner never saw the resolver's reading of. The two
    /// prompts were captured rather than reasoned about (`ClarificationAnswerRoutingTests`): typed
    /// directly, `2 + 2` never reaches a planner; answered, it reached one as the whole exchange.
    ///
    /// **"The resolver asked this" is read off the question, not off the run that raised it** (PR
    /// #118 review, F1). The first version gated on `activeTaskPlanSource == .instantResolver`, and
    /// the Continue door replays a paused plan under `.resumedTask`: quit while Sonny is asking what
    /// to calculate, relaunch, press Continue, answer `2 + 2`, and the answer took the planner path
    /// this exists to close — the founder's refusal one door over, reproduced at runtime. So the
    /// request is resolved again here, and the answer is the resolver's to complete exactly when
    /// that resolution is a `.clarify` carrying the pending question. That is a property of the
    /// request and the question, true through every door that can re-ask one — the widget, Continue,
    /// and the second Continue PR #119 adds under Memory — with nothing for a later door to remember.
    /// A question with no run behind it has no request and degrades to the exchange alone, as
    /// `composed` does; a question the *planner* asked is never completed, even when the completion
    /// would resolve — "morning" asked about by the planner and answered "routine" names a saved
    /// routine exactly, and a bare saved name is an instant command; running it would act on a guess
    /// about what the planner's question meant.
    ///
    /// **Each candidate is tried in `ClarifiedCommand.completions`' order and the first workable one
    /// is dispatched** (PR #118 review, F2 — the founder's direction). Workable means the resolver
    /// answers it with a plan **and** the executor prepares that plan without throwing: resolution
    /// alone is not a check, because the resolver builds a calculator plan for any non-empty
    /// expression and a running-app plan for any name of the right shape, and only `prepare` —
    /// the dry run every dispatch performs first — evaluates the sum and looks the app up among the
    /// running ones. `=` answered `= 2 + 2` joins to `= = 2 + 2`, which resolves and does not
    /// prepare, so the restatement `= 2 + 2` is taken and answers 4; `focus` answered `Focus Writer`
    /// joins to `focus Focus Writer`, which resolves and prepares whenever that app is running, so
    /// Sonny switches to the app the user named rather than to one called Writer. The dry run is
    /// built with no vision environment: a resolver plan never carries a vision step, and the live
    /// environment's construction assigns `visionUserPauseMonitor`, a side effect a routing decision
    /// must not have. The resolver then runs once more on the chosen command inside `performStart`,
    /// as the dispatch; the two agree because resolution is deterministic over the same stores.
    ///
    /// **When candidates resolved and none prepared, the first that resolved is dispatched — not
    /// the exchange** (PR #118 re-check, R-b). `calc` answered `banana` joins to `calc banana`, which
    /// resolves, does not evaluate, and has no restatement to fall back to; composing the exchange
    /// there sent it to a planner with no calculator, which is this ticket's own symptom returning
    /// one door over — "Calculation is unsupported" where typing `calc banana` gets the calculator's
    /// own "Could not calculate that expression". The dispatch shows that real error, as the typed
    /// command would. This acts only when nothing prepared, so it cannot reorder a candidate that
    /// did: with Writer and Focus Writer both running the join prepares and still wins (F2). A
    /// prepare that comes back with a clarification is not workable either (R-c). **That guard
    /// decides something only when the Shortcuts catalog or a store changes between the resolver's
    /// read and the executor's** — the two read the same sources with the same keys, the routine and
    /// workspace stores through the same `normalized()` so they cannot deterministically disagree,
    /// and the catalog through a process read that `InvokeShortcutCapabilityAdapter` repeats at
    /// prepare. When it does decide, it is not "the candidate is dispatched either way" — that held
    /// only for a sole or last resolved candidate, and this comment said it for one round: with a
    /// join whose prepare clarifies and a restatement that prepares, the join is passed over and the
    /// restatement runs (`aCandidateWhosePrepareClarifiesIsPassedOverForOneThatPrepares`, over a
    /// catalog scripted to answer consecutive reads differently, which no fixture had done before).
    ///
    /// **What falls through, on purpose.** "I could not find a Shortcut named Foo. Which Shortcut
    /// should I run?" wants a replacement, and `run shortcut Foo Send Report` resolves to the same
    /// question again rather than to a plan — so nothing resolves and the exchange goes to the
    /// planner, where a question that needs reading gets read. **Recorded, not closed (R-a, founder
    /// decision 2026-08-26):** `focus` answered `Focus Writer` with only Writer running — the join
    /// fails prepare, the restatement prepares, and Sonny switches to Writer, where typing
    /// `focus Focus Writer` would say no running app matched. R-b does not reach it, since something
    /// prepared; its neighbour with *neither* app running does change under R-b — the join is
    /// dispatched and fails naming Focus Writer, where before the exchange went to the planner.
    /// **What is stated as not closed:** a
    /// snippet request that already carries part of its body — `snippet save ;sig`, asked for the
    /// format — joins an operand answer onto that partial body, and a user who retypes the whole
    /// command joins the prefix onto itself; either plan carries a trigger nobody meant, the store
    /// allows a space in a trigger, and a new snippet is tier 2, which the consequence rule
    /// auto-runs — so the snippet is **saved**, under a trigger the user can see and delete on the
    /// Memory page, and no card is shown first. (The first version of this comment said it was
    /// approval-gated; the test that pins it found otherwise.) Nothing at the string level tells the
    /// two shapes apart — `Focus Writer` begins with `focus` exactly as `snippet save ;sig` begins
    /// with `snippet save` — so the join wins the trade: the alternative is the Writer case above, a
    /// wrong action with nothing to delete. The snippet question now asks for the body alone, so the
    /// retype is a user overriding the format they were just given.
    private func locallyCompletedCommand(request: String?, answer: String, question: String) -> String? {
        guard let request else {
            return nil
        }
        let resolver = makeInstantCommandResolver()
        guard case .clarify(let asked)? = resolver.resolve(command: request),
              asked.steps.first(where: { $0.operation == .clarify })?.question == question else {
            return nil
        }
        let dryRun = makeExecutor(recordingPolicy: nil, visionSession: nil)
        var firstResolved: String?
        for candidate in ClarifiedCommand.completions(request: request, answer: answer) {
            guard case .plan(let plan)? = resolver.resolve(command: candidate) else {
                continue
            }
            if firstResolved == nil {
                firstResolved = candidate
            }
            guard let prepared = try? dryRun.prepare(plan: plan), prepared.clarificationQuestion == nil else {
                continue
            }
            return candidate
        }
        return firstResolved
    }

    /// - Parameter origin: Which surface's mic button this is.
    ///
    /// **One call site today**, `FloatingWidgetView.micButton`, which passes `.widget` explicitly.
    /// The Command Center composer this method was written to also serve was deleted in
    /// `feature/ui-ux-wireframe-fidelity` (2026-07-21), and the doc comment kept describing it until
    /// SONNY-173 checked — a deprecation probe over the compiled package, since grep cannot resolve
    /// a receiver. The count is the compiler's, not a search's.
    ///
    /// The `.commandCenter` default therefore has no caller and is kept on purpose, as the *safe*
    /// direction for a call site added later: the origin reaches `dispatchTranscribedCommand`, where
    /// `fromComposer: origin == .widget` decides whether the dispatch may consume a pending
    /// workspace-card binding. A new caller that forgets to say which surface it is gets the answer
    /// that consumes nothing — the same reasoning `dispatch(fromComposer:)` states for its own
    /// default. A caller that really is the widget composer says so, exactly as this one does.
    func toggleVoiceRecording(origin: TaskOrigin = .commandCenter) {
        if isRecordingVoice {
            stopVoiceRecordingAndTranscribe()
        } else {
            startVoiceRecording(trigger: .button, origin: origin)
        }
    }

    func beginPushToTalkVoice() {
        guard !isPushToTalkHotKeyDown else {
            return
        }
        guard canUseVoice else {
            reportVoiceRefusal()
            return
        }

        isPushToTalkHotKeyDown = true
        // The global hotkey always brings the floating widget forward first (see
        // `AppDelegate.handlePushToTalkPress()`), so a hotkey-triggered recording is always a
        // widget interaction regardless of which surface happened to be focused.
        startVoiceRecording(trigger: .hotKey, origin: .widget)
    }

    /// Says an *actionable* refusal out loud and says nothing about a transient one — the single
    /// copy both voice entry points call, so the mic button and the hotkey cannot answer the same
    /// question differently again.
    ///
    /// Called after the `canUseVoice` guard has already failed, so it is only ever reached on a
    /// refusal; it stays silent when the refusal was transient.
    private func reportVoiceRefusal() {
        guard let blocker = voiceConfigurationBlocker else {
            return
        }
        setError(blocker, persistent: true)
    }

    func endPushToTalkVoice() {
        guard isPushToTalkHotKeyDown else {
            return
        }

        isPushToTalkHotKeyDown = false
        guard isRecordingVoice else {
            return
        }

        stopVoiceRecordingAndTranscribe()
    }

    func markVoiceHotKeyUnavailable(_ message: String) {
        voiceHotKeyReady = false
        voiceHotKeyStatus = "Hotkey unavailable"
        setError(message, persistent: true)
        refreshPermissions()
    }

    /// Recompute the Settings readiness rows, and ask the Keychain whether a session is held.
    ///
    /// **Two steps rather than one, because one of the two inputs is behind an actor** (SONNY-136).
    /// The permission checks are synchronous reads of TCC state; the account check is
    /// `SonnyBackendClient.restoredIdentity()`, and the client is an actor because its single-flight
    /// refresh guard is shared mutable state. So the rows are rendered immediately from what is
    /// already known — `.undetermined` on the very first pass, which reads *"Check when used"* and
    /// is the honest answer before anything has asked — and recomputed the moment the account
    /// answers. Making this whole function `async` was the alternative and it is worse: every caller
    /// is a SwiftUI action or an `onAppear`, so it would have put a `Task` at each of the four call
    /// sites instead of one here, and a page would have shown *no* rows until the Keychain answered
    /// rather than seven of eight.
    func refreshPermissions() {
        recomputePermissionItems()
        Task { [weak self] in
            await self?.refreshModelAccessReadiness()
            self?.recomputePermissionItems()
        }
    }

    private func recomputePermissionItems() {
        permissionItems = permissionReadinessService.currentStatus(
            modelAccess: modelAccessReadiness,
            hotKeyReady: voiceHotKeyReady
        )
    }

    /// Read the Keychain and publish whether a session is held.
    ///
    /// **The client, not `SonnyAccountModel`.** Both would answer the same today — `main.swift`
    /// hands this view model the very client the account model built, so there is one token cache
    /// for the process — but the client is the Keychain's own answer while the account model holds a
    /// copy refreshed at launch and after a sign-in. Reading the copy would make this row a mirror
    /// of a mirror, and a stale one exactly when the session changed underneath.
    ///
    /// **A throw is `.undetermined`, never `.signedOut`.** Bytes this build cannot decode are not
    /// evidence that nobody is signed in, and `SonnyAccountModel.restore()` already refuses to
    /// delete a credential store on the strength of a decode failure. `.signedOut` here would put a
    /// red "sign in" row in front of a user whose session is fine and whose next sign-in would be
    /// the one thing that overwrites the bytes.
    func refreshModelAccessReadiness() async {
        do {
            modelAccessReadiness = try await backendClient.restoredIdentity() == nil
                ? .signedOut
                : .signedIn
        } catch {
            modelAccessReadiness = .undetermined
        }
    }

    func refreshSavedItems() {
        do {
            savedRoutines = try routineStore.loadAll().values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            clearLocalStorageLoadFailure(.savedRoutines)
        } catch {
            recordLocalStorageLoadFailure(.savedRoutines, error: error)
        }

        do {
            savedWorkspaces = try workspaceStore.loadAll().values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            clearLocalStorageLoadFailure(.savedWorkspaces)
        } catch {
            recordLocalStorageLoadFailure(.savedWorkspaces, error: error)
        }

        // **Emptied on a failure, unlike the two above** (SONNY-382). Those two leave their last
        // good value in place; this list is the Routines page's answer to "what is Sonny watching",
        // and a stale row offering a Stop for a record nothing can read is a control that cannot do
        // what it says. Empty is the honest answer, and the banner this records says why. It is the
        // rule `refreshResumableTasks` already follows for the other half of the same file.
        do {
            standingWatchers = try resumableTaskStore.loadWatchers()
            clearLocalStorageLoadFailure(.resumableTasks)
        } catch {
            standingWatchers = []
            recordLocalStorageLoadFailure(.resumableTasks, error: error)
        }

        refreshSilentlyReadStoreHealth()
    }

    /// Snippets, recent artifacts, clipboard items and row J's allowed apps are otherwise only read
    /// through `try?` paths, or through no product path at all (the instant resolver's
    /// trigger/artifact lookups, the 1s clipboard poll), so a corrupt file there is invisible: the
    /// feature just silently stops working. These stores have no UI list of their own to surface a
    /// load failure, so probe them here.
    private func refreshSilentlyReadStoreHealth() {
        checkStoreHealth(.snippets) { _ = try snippetStore.loadAll() }
        checkStoreHealth(.recentArtifacts) { _ = try recentArtifactStore.loadAll() }
        checkStoreHealth(.clipboardHistoryItems) { try clipboardHistoryMonitor.verifyHistoryReadable() }
        // Row J's grants belong here for a sharper version of the same reason: a store nothing can
        // read is a store whose grants have all silently vanished, and the visible symptom is Sonny
        // asking about apps the user already allowed — which reads as the feature working badly
        // rather than as a file that will not open. It has no list of its own to fail in until the
        // revocation surface lands, so this probe is the only place it can say so.
        checkStoreHealth(.approvedApps) { _ = try approvedAppStore.loadAll() }
    }

    private func checkStoreHealth(
        _ source: LocalStorageLoadFailureSource,
        load: () throws -> Void
    ) {
        do {
            try load()
            clearLocalStorageLoadFailure(source)
        } catch {
            recordLocalStorageLoadFailure(source, error: error)
        }
    }

    /// Whether this run may write new memory into `store` — both switches, one question.
    ///
    /// **The conjunction is written once, here, and once in `CapabilityExecutionContext`** (SONNY-208).
    /// `TaskRecordingPolicy` answers "does this one run leave traces"; `MemoryRecordingSettings`
    /// answers "may Sonny remember this kind of thing at all". Every writing site on this view model
    /// asks through this, so a site that consulted only one of the two would be a site that ignored
    /// a switch the user had flipped — which is precisely how the per-store guard this replaces
    /// would have gone quietly wrong.
    func allowsRecording(to store: LocalStore) -> Bool {
        taskRecordingPolicy.allowsWriting(to: store) && memorySettings.allowsRecording(to: store)
    }

    /// Whether a **scheduled** run may write new memory into `store` — the standing switches only.
    ///
    /// **Not `allowsRecording(to:)`, and the difference is a bug in each direction** (PR #98 review,
    /// F1/F2). The two switches have different scopes and a scheduled run is where that stops being
    /// academic:
    ///
    /// - `TaskRecordingPolicy` is a *per-task composer* control. A scheduled run passes through no
    ///   composer, so there is nothing for it to answer — and it is not merely absent, it is
    ///   actively wrong to read. **The reachable window is the ordinary one, before any dispatch**
    ///   (corrected by PR #98's round-4 pass, F2): `dontSaveButton` renders only when
    ///   `!isTaskInFlight` (`FloatingWidgetView.swift`), so "Don't save this task" is a *pre*-dispatch
    ///   toggle — the user flips it on while composing and has not pressed Send. `isRunning` is
    ///   false, `approvalRequest` is nil and `clarificationQuestion` is nil, so all three of
    ///   `checkScheduledRoutines`' guards pass, a routine fires, and reading the policy here would
    ///   silently strip that routine's traces because of a switch set for a command that has not
    ///   been sent. That is the same class of defect PR #67's F2 fixed by passing `.record`
    ///   explicitly, and calling `allowsRecording(to:)` here would reintroduce it.
    ///
    ///   **The earlier telling of this named the clarification pause and was false at the SHA it was
    ///   written at**: `checkScheduledRoutines` guards on three terms, not two — PR #80's F1 added
    ///   `clarificationQuestion == nil`, closing exactly the window that sentence cited, forty lines
    ///   below its own documentation. Recorded rather than quietly swapped, because a correct
    ///   decision resting on a false premise is one refactor away from being reverted: a reader who
    ///   checks the cited mechanism finds it does not exist and reasonably concludes the deviation
    ///   is obsolete.
    ///
    ///   **And there is no case where a scheduled run should honour the term at all**, which is the
    ///   half that does not depend on any window being reachable: there is no composer in that path,
    ///   so a user has no way to ask for a routine's suppression. Honouring it could only ever apply
    ///   a switch set for a different task — which the toggle's own label, "this task", rules out.
    /// - `MemoryRecordingSettings` is a *standing preference*. It applies to a scheduled run exactly
    ///   as it does to a typed one — `makeExecutor` has said so in a comment since this branch
    ///   started, and everything routed through the executor honours it. The three writes the view
    ///   model performs itself did not, which is what this exists to fix.
    ///
    /// So the rule is: the scheduled path opts out of the composer switch and never out of the
    /// memory switches. **One live exception, named rather than left to be re-found:**
    /// `visionSessionJournalStoreForThisRun` still reads `allowsRecording(to:)` and is handed to a
    /// scheduled run's executor; it fails closed and unattended vision cannot execute, so it stays
    /// as it is. Its own doc carries the argument. Same shape as the foreground guards at `recordTaskHistoryIfTerminal` and
    /// `recordTaskPlanDetail`, with the one term that cannot apply removed rather than the whole
    /// conjunction copied.
    func allowsScheduledRecording(to store: LocalStore) -> Bool {
        memorySettings.allowsRecording(to: store)
    }

    /// The vision journal this run may write to, or `nil` when it may not.
    ///
    /// Internal and separated from its one call site for the same reason
    /// `recentArtifactStoreForThisRun` is (PR #67 review, F1): the decision was previously inline in
    /// `makeLiveVisionEnvironment()`, which **no test in this repository can execute** — the vision
    /// tests inject `visionSessionEnvironment` directly, bypassing the function. So a mutation
    /// handing over the store regardless of policy survived the whole suite. (This gave a second
    /// reason, that `makeVisionEnvironment` returns `nil` without an API key. SONNY-131 made that
    /// builder non-Optional and SONNY-136 deleted the key; the injection is the reason that
    /// remains, and it is the one that was doing the work.) Asserting the decision *is* asserting
    /// the suppression, because row I built a `nil` journal store as "run the session, record
    /// nothing".
    ///
    /// It is a `.trace` store — the sixth, since row E's plan details — and the one
    /// `LocalStoreClassification` calls the most sensitive of them all; it had no seam test, no
    /// mutation and no entry under Known limits, while the other traces were each closed or
    /// recorded.
    /// **The one seam a scheduled run reaches that still reads the composer switch, stated because
    /// it is a real exception to a rule written as a global one** (PR #98 round-4 pass, N2).
    /// `allowsScheduledRecording(to:)`'s doc says the scheduled path opts out of `taskRecordingPolicy`;
    /// this seam is handed over by `makeLiveVisionEnvironment()`, which `makeExecutor` builds for
    /// every run including a scheduled one, and it uses `allowsRecording(to:)`.
    ///
    /// Left as it is, on both counts that matter. It **fails closed** — a stale `.suppressTraces`
    /// withholds the journal rather than writing one — and it is **unreachable**: unattended vision
    /// is refused three independent ways (`.visionSession` is a forbidden routine step, the explicit
    /// belt in `performScheduledRun` checks the routine's steps, its nested steps and the prepared
    /// plan, and the fixed `.approved(.tier2)` ceiling cannot satisfy a tier-3 assessment). Changing
    /// it would be a change to the foreground seam every other caller shares, for a path that cannot
    /// execute, in the safe direction already.
    var visionSessionJournalStoreForThisRun: VisionSessionJournalStore? {
        allowsRecording(to: .visionSessionJournal) ? visionSessionJournalStore : nil
    }

    /// The recent-artifacts store this run may write to, or `nil` when it may not.
    ///
    /// Withholding the store rather than checking a flag at the writing site, because `AgentRunner`
    /// already treats a `nil` store as "record nothing" — the same seam row I gave the vision
    /// journal. One definition, read by every `AgentRunner` this view model builds, so a new runner
    /// call site cannot forget the check by omitting it.
    ///
    /// Internal rather than private so the suite can assert the decision directly. Running a real
    /// task through the fixture cannot reach it: the fixture's deterministic planner has no command
    /// that generates an artifact, so a suppressed run leaves this store untouched either way and
    /// the acceptance test passes for the wrong reason. A mutation battery caught exactly that.
    var recentArtifactStoreForThisRun: RecentArtifactStore? {
        allowsRecording(to: .recentArtifacts) ? recentArtifactStore : nil
    }

    /// The recent-artifacts store a **scheduled** run may write to, or `nil` when it may not.
    ///
    /// The same withhold-the-store seam as above — `AgentRunner` treats a `nil` store as "record
    /// nothing" — reading `allowsScheduledRecording(to:)` instead, for the reason written there.
    /// Internal, and asserted directly by the suite, for the reason `recentArtifactStoreForThisRun`
    /// gives: no command the fixtures can run generates an artifact, so an end-to-end assertion
    /// would pass whether or not the switch were consulted.
    var recentArtifactStoreForScheduledRun: RecentArtifactStore? {
        allowsScheduledRecording(to: .recentArtifacts) ? recentArtifactStore : nil
    }

    /// The output-locations store this run may write to, or `nil` when it may not (SONNY-209).
    ///
    /// The third store on the withhold-the-store seam, and it is the seam rather than a flag at the
    /// writing site for the reason the two above it record: `AgentRunner` already treats `nil` as
    /// "record nothing", so one definition covers every runner this view model builds and a new
    /// construction site cannot forget the check by omitting it.
    ///
    /// Internal rather than private so the suite can assert the decision directly — but that is the
    /// *belt* here, not the coverage. **This seam is also driven end to end**, which the two above it
    /// are not: `MemoryCommandCenterTests` runs a real `create_local_draft` plan that writes a real
    /// file into a real whitelisted folder, on both the foreground and the scheduled path, with a
    /// recording control beside every "nothing was recorded" assertion. That is worth saying plainly
    /// rather than inheriting `recentArtifactStoreForThisRun`'s reasoning, whose premise — that no
    /// command the fixtures can run generates an artifact — is about a different fixture and is not
    /// a claim this store's tests rest on.
    var outputLocationStoreForThisRun: OutputLocationStore? {
        allowsRecording(to: .outputLocations) ? outputLocationStore : nil
    }

    /// The output-locations store a **scheduled** run may write to, or `nil` when it may not.
    ///
    /// `allowsScheduledRecording(to:)`, never `allowsRecording(to:)`, and the reason is written in
    /// full on that method: a scheduled run passes through no composer, so reading
    /// `taskRecordingPolicy` here would apply a "Don't save this task" the user set while composing
    /// a command they have not sent. A routine that files its output into the user's Reports folder
    /// every Monday is exactly the habit this store exists to learn, and it is the one Sonny would
    /// have stopped learning.
    var outputLocationStoreForScheduledRun: OutputLocationStore? {
        allowsScheduledRecording(to: .outputLocations) ? outputLocationStore : nil
    }

    /// Puts "Don't save this task" back to off and lets clipboard history resume — but only once the
    /// run is really over.
    ///
    /// **Called from each terminal point rather than from one `defer`, because no single `defer`
    /// covers them.** `cancelCurrentRun()` has none at all and is the app-wide deny/cancel entry
    /// point; the two that do exist, in `performStart` and `performApproval`, also fire for *pauses*
    /// — approval needed, clarification needed — where the run is still going and the switch must
    /// stay on. The guard below is what tells those apart, using the same
    /// `approvalRequest == nil && clarificationQuestion == nil` test this file already uses.
    private func finishRecordingPolicyIfSettled() {
        guard approvalRequest == nil, clarificationQuestion == nil, !isRunning else {
            return
        }
        guard taskRecordingPolicy != .record else {
            return
        }
        taskRecordingPolicy = .record
        // Resynchronise *before* monitoring restarts. `poll()` records whenever the pasteboard's
        // change count differs from the last one it saw, and that counter survived the pause — so
        // without this the first poll after a suppressed run records exactly what the user copied
        // during it. Measured: it did.
        clipboardHistoryMonitor.resynchronize()
        // Restored from settings rather than unconditionally started, so a user who has clipboard
        // history switched off does not get it switched on by ending a suppressed task.
        refreshClipboardHistoryNotice()
    }

    /// Publishes a finished run's summary for the notification fallback, when nothing else will
    /// report it. See `completedRunNotice` for why this is the only case.
    /// Internal rather than private so the suite can reach the empty-summary guard. No command the
    /// test fixtures can run produces an empty summary, so a mutation removing that guard survived
    /// an end-to-end battery — the guard matters because an empty notification body would be a
    /// notification that says nothing.
    func publishCompletedRunNoticeIfUnreported(_ summary: String, taskID: String?) {
        guard activeTaskOrigin == .commandCenter else {
            return
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        // `taskID` is the id `recordTaskHistoryIfTerminal` returned, handed down from the call
        // site, so a click opens *that* task's detail (PR #67 review, F4).
        //
        // It is passed in rather than re-derived here, and that is the fix for a real defect rather
        // than a preference (PR #67 cycle-3, defect B). This line used to read
        // `taskHistoryRecords.first?.id` — "the newest row must be the one we just wrote". It is
        // not: `completedAt` persists at whole-second resolution, so two runs finishing in the same
        // second compare equal, and `refreshTaskHistory`'s `sorted(by:)` is not stable, so the head
        // can be the earlier row. The notification would then name the wrong task. Whole-second
        // truncation is the same hazard `CompletedTaskRecord.id` exists to defeat (SONNY-115), and
        // it re-entered through the phrase "the most recent row"; the id the write returned cannot
        // tie with anything.
        //
        // `nil` when a suppressed run wrote no row: there is nothing to open, and the notification
        // still tells the user the task finished. An accepted limit, recorded rather than answered
        // with a second behaviour.
        completedRunNotice = CompletedRunNotice(summary: trimmed, taskID: taskID)
    }

    func refreshTaskHistory() {
        do {
            taskHistoryRecords = try taskHistoryStore.loadAll()
                .sorted { $0.completedAt > $1.completedAt }
            clearLocalStorageLoadFailure(.taskHistory)
        } catch {
            taskHistoryRecords = []
            recordLocalStorageLoadFailure(.taskHistory, error: error)
        }
    }

    /// Deletes a task completely — its history row and every record hanging off it.
    ///
    /// **Dependents first, the row last, and the order is not interchangeable.** The row is the only
    /// thing that makes the records hanging off it reachable through the product, so a half-failure
    /// has to leave the row standing:
    ///
    /// - *Dependent gone, row delete failed* → a row whose link resolves to nothing. That is the
    ///   designed dangling-link state row I already ships and the detail view already handles, and
    ///   the user can simply try the delete again.
    /// - *Row gone, dependent delete failed* → a record nobody can reach through the product at all.
    ///   The founder named exactly this as the real defect when declining the never-coupled design
    ///   (SONNY-14, 2026-08-16).
    ///
    /// **This reaches two records today and has to reach three.** The founder moved row E's plan
    /// summary and steps into their own store on 2026-08-17 (SONNY-147, superseding the 2026-08-16
    /// decision to put them on the record). That store shares this row's retention exactly — same
    /// cap, same eviction, deleted together, suppressed together — so when it lands its delete goes
    /// **in the dependents block below, above the row**: not after the row, and not in a second
    /// method a caller could forget to call.
    ///
    /// ## The fourth step, and why it goes first (SONNY-333)
    ///
    /// The three deletes above are local. The backend holds a copy too — the requests this task
    /// made, and every training-snapshot member copied from them — and the founder decision of
    /// 2026-08-16 is that delete means deleted everywhere. `DELETE /v1/tasks/{task_id}` has existed
    /// since SONNY-134 and nothing pressed it, so that rule was true of the endpoint and not of this
    /// button.
    ///
    /// **The id is the thing that cannot survive a half-failure, and everything below follows from
    /// that.** A dependent and a row are both on this Mac, so whichever survives is still reachable
    /// and the user can press Delete again. The id is not: it is carried by the row and by nothing
    /// else, so once the row is gone there is no way left to name the server's copy. That gives one
    /// outcome that must be unreachable — *local records gone, nothing queued* — which is permanent,
    /// unrecoverable and silent.
    ///
    /// **Ordering alone does not make it unreachable, and this comment claimed that it did**
    /// (PR #194 review, F1). The enqueue went first and its `catch` published a notice and then
    /// *fell through* to the deletes below, so the forbidden outcome shipped: byte-for-byte the one
    /// the paragraph above rejects. Putting the enqueue first buys exactly one real property, which
    /// this comment never stated — protection against a **crash** between the two steps, where
    /// there is nobody left to correct anything and erring towards deleting is right. Against a
    /// `throw` the ordering is decorative, because a throw has somewhere to put the correction.
    ///
    /// **So the two throws are handled rather than ordered around**, and together they make this
    /// method all-or-nothing **between the Mac and the server** — the obligation and the local
    /// records move together, or neither does. **Not all-or-nothing among the three local deletes,
    /// which are three files written in sequence with no transaction** (PR #194 cycle-3, R3, and the
    /// distinction matters because the last version of this comment claiming a property the code did
    /// not have is what F1 was): a throw at the plan-detail delete after the screen record has gone
    /// leaves a task whose *What Sonny did on screen* section is missing and whose row is still
    /// there. That residue is recoverable — both per-entry deletes are no-ops for an id that is
    /// already absent, so a second press finishes the job — and a dangling `visionSessionID` is a
    /// designed state that row I already ships. The bullets below are exact; this sentence is the
    /// one that used to overreach:
    ///
    /// - *the enqueue throws* → **abort**. Nothing local has been touched yet, so this returns with
    ///   the row intact and says the delete did not happen. The user can press again, and the queue
    ///   is keyed on the id so a later success holds one entry rather than two.
    /// - *a local delete throws* → **withdraw the obligation**. The row is still standing (each of
    ///   these deletes is atomic and the row's own is last), so an entry left queued would have the
    ///   next launch remove the server's copy of a task the user can still see, after being told the
    ///   delete failed.
    /// - *a crash between them* → the entry is owed for a row that still exists, the sweep delivers
    ///   it, and the user's history keeps a task whose server copy is gone. Over-deletion, chosen
    ///   deliberately, and the only outcome the ordering itself decides.
    ///
    /// **`setError`, not the storage-notice channel, and the earlier reading of CLAUDE.md's rule was
    /// argued from the behaviour this fix removed.** It said a failed enqueue is bookkeeping because
    /// the row was already gone by the time anything rendered — true only while the method fell
    /// through. It aborts now, so nothing at all has been deleted, which is `errorMessage`'s own
    /// meaning: the thing you asked for did not happen. It is also the same sentence the local
    /// failure below reports, which is right, because to the user they are the same event.
    ///
    /// **The systemic form of this failure is closed in the store rather than here.** `enqueue`
    /// loads before it writes, so an undecodable queue file would make *every* future Delete abort;
    /// `PendingServerDeletionStore.loadKeyed()` sets such a file aside and starts fresh, and says
    /// why that is right for this store and for no other.
    ///
    /// **The delivery itself is fired and not awaited**, so the button is never blocked on the
    /// network — the whole point of the 2026-08-30 decision. A pass that cannot reach the gateway
    /// leaves the entry where it is and `sweepPendingServerDeletions()` tries again at the next
    /// launch.
    func deleteTask(_ record: CompletedTaskRecord) {
        guard let id = record.id, !id.isEmpty else {
            // Unreachable in practice — every record `loadAll()` hands out has an id, backfilled if
            // the file predates them. Reachable only if that backfill's rewrite failed, so the
            // message points at the retry that fixes it rather than at the missing field.
            //
            // **The emptiness half is new** (PR #194 review, residuals). An empty id builds
            // `/v1/tasks/`, which is a different route, and the store's own doc argues that this
            // queue is a file outliving the version that wrote it — the same argument that earned
            // the percent-encoding one layer down.
            setError("Could not delete this task: its saved copy has no identifier yet. Try again in a moment.")
            return
        }

        do {
            // The backend's copy, owed before anything local goes — see this method's doc comment
            // for why this one step is not in the dependents-first ordering below.
            try taskDeletionService.recordDeletedTask(id: id)
        } catch {
            // **Aborts, and this `return` is the whole of PR #194's F1.** Falling through to the
            // local deletes here produced exactly the outcome the doc comment above calls permanent,
            // unrecoverable and silent: the id gone from the Mac, nothing queued, the server's copy
            // orphaned with no remaining name. Nothing has been deleted at the moment this runs, so
            // this really is the user's ask not happening — the same thing the block below reports,
            // in the same words and on the same channel.
            setError("Could not delete this task: \(error.localizedDescription)")
            return
        }

        do {
            // Dependents first. Row E's detail store joined this block as SONNY-116's own comment
            // said it would.
            if let visionSessionID = record.visionSessionID {
                try visionSessionJournalStore.delete(id: visionSessionID)
            }
            try taskPlanDetailStore.delete(id: id)
            // The row, last.
            try taskHistoryStore.delete(id: id)
        } catch {
            // **The obligation is withdrawn, which is F1's other half.** Every delete above is
            // load-modify-write with an atomic write and the row's own is last, so a throw here
            // leaves the row standing — and an entry left queued for it would have the next launch
            // delete the server's copy of a task the user can still see, after being told the delete
            // failed. `try?` because the user is already being told the delete did not happen and a
            // second sentence about bookkeeping is not something they could act on separately; the
            // residue if it fails is over-deletion, which is the direction this method chooses
            // everywhere else.
            try? taskDeletionService.withdrawDeletedTask(id: id)
            // A delete is a write, so this gets its own accurate wording and never
            // `recordLocalStorageLoadFailure`, whose banner is hardcoded to "could not be decrypted
            // or decoded" and would be simply wrong here.
            setError("Could not delete this task: \(error.localizedDescription)")
            return
        }

        refreshTaskHistory()
        deliverPendingServerDeletions()
    }

    /// Tries to deliver everything the queue owes, off the caller's path.
    ///
    /// Chained onto whatever pass is already running, for the reason on
    /// `pendingServerDeletionDelivery`: two passes over one file is a lost-update race, and the
    /// chain also guarantees the new pass loads after this delete's enqueue.
    private func deliverPendingServerDeletions() {
        let previous = pendingServerDeletionDelivery
        let service = taskDeletionService
        pendingServerDeletionDelivery = Task { @MainActor in
            await previous?.value
            await service.deliverPendingDeletions()
            completedServerDeletionPasses += 1
        }
    }

    /// How many delivery passes have finished since launch. Test-only, and it exists because the
    /// property it makes observable cannot be waited for through the handle.
    ///
    /// **A test of the chain cannot await `pendingServerDeletionDelivery`** (PR #194 cycle-3's own
    /// battery): that handle is the *last* pass, and without the chain the last pass does not cover
    /// the first — so awaiting it can return while an earlier pass is still issuing requests, and an
    /// assertion on how many were issued measures whatever had landed by then. That made the chain's
    /// only test kill the mutant twice and miss it the third time, which is the same shape as the
    /// racy lock tests one round earlier: a test that finds a defect only when the timing suits it.
    /// A count of *finished* passes is monotone and reaches its final value in both directions, so a
    /// test waits on it and then asserts, and the failing direction is an assertion rather than a
    /// timeout.
    private(set) var completedServerDeletionPasses = 0

    /// A session changed — deliver what the new account can, and discard what belongs to nobody
    /// here (SONNY-404, PR #207's F1).
    ///
    /// **The second half of "deliver what you can for the old account, or discard with a recorded
    /// reason".** The first half is impossible after the fact: signing out clears the tokens, so
    /// there is nothing left to authenticate the outgoing account's obligations with. So this
    /// discards them and says so in the log, which is the record.
    ///
    /// **It only discards when somebody is signed in**, so signing out keeps everything: the account
    /// that owns those obligations may sign back in, and the per-entry delivery gate is what holds
    /// them safe until it does. Signing *in* as a different account is the moment the old ones stop
    /// being deliverable at all, and that is when they go.
    func settlePendingServerDeletionsForSessionChange() {
        let discarded = (try? taskDeletionService.discardObligationsForOtherAccounts()) ?? 0
        if discarded > 0 {
            let noun = discarded == 1 ? "deletion" : "deletions"
            logStore.append(
                .observe,
                "Discarded \(discarded) queued server \(noun) belonging to an account that is no longer signed in."
            )
        }
        sweepPendingServerDeletions()
    }

    /// The launch sweep (SONNY-333): everything a previous run could not deliver, tried again.
    ///
    /// **Needs no session restore to have happened first.** `SonnyBackendClient` reads the Keychain
    /// the first time it is asked for a token, so this authenticates itself rather than depending on
    /// `AppDelegate.decideFirstRunAfterRestoringTheSession()` having finished — which matters,
    /// because that method is asynchronous and everything after its `Task` in
    /// `applicationDidFinishLaunching` runs before it.
    ///
    /// Awaitable through the same handle a delete's pass uses, so a test drives one door rather than
    /// two.
    func sweepPendingServerDeletions() {
        deliverPendingServerDeletions()
    }

    /// The pass in flight, for tests. `nil` when none has been started.
    ///
    /// Internal rather than private for the reason `activeTaskScope` is `private(set)`: the
    /// scheduling *is* the behaviour here — that passes chain rather than overlap — so it has to be
    /// assertable, and there is no surface to observe it through.
    var pendingServerDeletionDeliveryForTests: Task<Void, Never>? {
        pendingServerDeletionDelivery
    }

    /// What the queue still owes, for tests and for nothing else. The queue has no surface, and
    /// `PendingServerDeletionStore` says why.
    func pendingServerDeletionsForTests() throws -> [PendingServerDeletion] {
        try taskDeletionService.pendingDeletions()
    }

    /// Deletes only the screen record, leaving the task row and its `visionSessionID` in place.
    ///
    /// The dangling link this leaves behind is a designed state rather than an error. It is also
    /// deliberately indistinguishable from a screen record that simply aged out at the journal's
    /// cap — pinned by
    /// `TaskHistoryRetentionTests.aDeletedScreenRecordAndAnEvictedOneLeaveTheSameThingBehind`,
    /// because the product cannot tell the two apart without explaining itself and the
    /// no-explanatory-copy rule forbids the explanation.
    ///
    /// **No `refreshTaskHistory()` here, deliberately.** That call exists so `taskHistoryRecords`
    /// agrees with the file, and this delete does not touch task history — the row is byte-identical
    /// afterwards. Calling it anyway would decrypt and decode the whole history file (130 ms at the
    /// cap, measured at `36cef9e`) to reload records that did not change.
    ///
    /// ## The server's copy of the screenshots (SONNY-404)
    ///
    /// The gateway holds the redacted captures this task sent to `POST /v1/screen/analyze`, and
    /// every training-snapshot member copied from them. Until this ticket this button reached none
    /// of it, and it could not be fixed by pressing `DELETE /v1/tasks/{task_id}` — that route takes
    /// a task's *whole* retained content, so it would have deleted the command text and the
    /// responses too, which is more than the button says. The founder decided on 2026-09-05 for a
    /// narrower route, `DELETE /v1/tasks/{task_id}/screenshots`, and the confirmation this button
    /// raises now names what it reaches.
    ///
    /// **The enqueue goes first, and the reason is `deleteTask`'s reason in a milder form.** The
    /// task row survives this press, so the id is not destroyed the way it is there — but the
    /// *button* does not survive it: `showsScreenRecordDeleteAction` is offered only for a screen
    /// record that reads back, so once the journal entry is gone there is nothing left to press
    /// again. A local delete that ran first with the enqueue then failing would leave the
    /// screenshots on the server with no control in the product able to ask for them again.
    ///
    /// So the two throws are handled the same way `deleteTask` handles its own: an enqueue that
    /// throws aborts with the screen record intact, and a local delete that throws withdraws the
    /// obligation it had just recorded — because an entry left queued for a delete the user was told
    /// had failed would have the next launch take the server's screenshots for a record they can
    /// still open.
    func deleteScreenRecord(for record: CompletedTaskRecord) {
        guard let visionSessionID = record.visionSessionID else {
            return
        }
        guard let id = record.id, !id.isEmpty else {
            // The same refusal `deleteTask` makes, in the same words and for the same reason: an id
            // is what names the server's copy, and without one this press cannot keep the promise
            // its confirmation now makes. Unreachable in practice — `loadAll()` backfills the id —
            // so the message points at the retry that fixes it.
            setError("Could not delete this task's screen record: its saved copy has no identifier yet. Try again in a moment.")
            return
        }

        do {
            try taskDeletionService.recordDeletedScreenRecord(taskID: id)
        } catch {
            setError("Could not delete this task's screen record: \(error.localizedDescription)")
            return
        }

        do {
            try visionSessionJournalStore.delete(id: visionSessionID)
        } catch {
            // `try?` for `deleteTask`'s reason: the user is already being told the delete did not
            // happen, and a second sentence about bookkeeping is not something they can act on.
            try? taskDeletionService.withdrawDeletedScreenRecord(taskID: id)
            setError("Could not delete this task's screen record: \(error.localizedDescription)")
            return
        }

        deliverPendingServerDeletions()
    }

    func refreshClipboardHistoryNotice() {
        let settings: ClipboardHistorySettings
        do {
            settings = try clipboardHistorySettingsStore.load()
            clearLocalStorageLoadFailure(.clipboardHistorySettings)
        } catch {
            stopClipboardHistoryMonitoring()
            recordLocalStorageLoadFailure(.clipboardHistorySettings, error: error)
            return
        }

        clipboardHistoryEnabled = settings.isEnabled

        if settings.noticeDismissed && settings.isEnabled {
            startClipboardHistoryMonitoring()
        } else {
            stopClipboardHistoryMonitoring()
        }
    }

    func applyClipboardHistoryNoticeChoice() {
        let settings = ClipboardHistorySettings(
            noticeDismissed: true,
            isEnabled: clipboardHistoryEnabled
        )
        do {
            try clipboardHistorySettingsStore.save(settings)
            if clipboardHistoryEnabled {
                startClipboardHistoryMonitoring()
            } else {
                stopClipboardHistoryMonitoring()
            }
        } catch {
            setError("Could not save clipboard history setting: \(error.localizedDescription)")
        }
    }

    /// Settings' whole wipe — **a promise about the account, not about this Mac** (SONNY-404,
    /// founder decision 2026-09-04, restated 2026-09-05).
    ///
    /// The press deletes what this Mac holds *and* what the gateway retains for the account: every
    /// task's stored content, every training-snapshot copy of it, and the response bodies the
    /// idempotency store holds. **The account itself stays open** — closing it is
    /// `DELETE /v1/account`, a different promise with no control in the app today.
    ///
    /// ## The order, and why each step is where it is
    ///
    /// 1. **Drain the queue**, before the file holding it is removed. That is the cost the founder
    ///    accepted with this decision, in those words.
    /// 2. **Delete the account's server-side content.** Before the local wipe, so that a press which
    ///    succeeds leaves *nothing* behind on either side, and so that a press which fails still has
    ///    every local file intact when it decides what to tell the user.
    /// 3. **Delete every local file**, the queue among them — so no task id survives this press
    ///    whatever happened above it.
    /// 4. **Only if step 2 failed, record one obligation**: everything under this account. It is the
    ///    single thing the wipe may leave on disk, and it is safe to leave because it *names no
    ///    task* — a queue file holding it carries nothing about what the user did.
    /// 5. **Say once, plainly, what happened** — including, when the gateway could not be reached,
    ///    what is still on the servers and what will happen to it.
    ///
    /// **The account-wide obligation is strictly wider than every per-task one**, which is what
    /// makes step 3 safe: an undelivered per-task obligation is not abandoned by the wipe, it is
    /// subsumed. If step 2 succeeded there is nothing left to owe at all.
    ///
    /// **The one obligation that really is abandoned, stated rather than left to be found**: an
    /// entry the drain kept on a `404`, which §4.6 reserves for a task belonging to a *different*
    /// account — a Mac two people have signed into. The account-wide delete cannot reach it, because
    /// it is not this account's, and the queue file goes; so the other user's copy survives. Keeping
    /// it would mean leaving a file that names a task, which is the one thing this press must not
    /// do. Recorded here as the cost of the rule rather than answered.
    ///
    /// **The press now waits on the network, and that is the decision reversing.** Under the
    /// superseded 2026-09-05 reading a privacy wipe could not depend on a network call; under the
    /// standing decision it must, because it is promising something the network is the only way to
    /// keep. What it must not do is fail *silently*, which is what step 5 exists for.
    func deleteLocalData() {
        guard !isRunning else {
            setError("Stop the current run before deleting local data.")
            return
        }
        // Chained rather than overlapped, for `deliverPendingServerDeletions`' reason: two wipes over
        // one queue file is a lost-update race, and the chain also means a second press reads the
        // file the first one left.
        // **The claim is taken here, synchronously, and held for the whole sequence** (PR #207's
        // F3). The guard above is read on the press; the body below is a scheduled `Task` that then
        // awaits a drain and a server call — up to the client's whole multi-attempt budget on a
        // 20-second route — before it touches a file. Nothing re-checked in that window, so a
        // scheduled routine could start inside it and have every store deleted underneath it, its
        // `activeTaskScope` dropped, and its result overwritten by the wipe's own sentence on the
        // channel SONNY-201 reserves for a failure. `isDeletingLocalData` is what the run doors
        // refuse on, and it is set before the press returns rather than inside the task.
        //
        // **Counted rather than flagged, because the flag was released per press and not per chain**
        // (PR #207's cycle-3, F3's second half). Each wipe cleared it when *its own* body finished,
        // so a second press chained behind the first had the first's completion drop the claim while
        // the second was still draining, still calling the gateway and still about to delete every
        // store — the exact window this flag was added to close, re-opened by pressing twice. The
        // count goes up before the press returns and down as each wipe ends, so the claim is held
        // until the **last** one finishes.
        localDataWipesInFlight += 1
        isDeletingLocalData = true
        let previous = localDataWipe
        localDataWipe = Task { @MainActor in
            await previous?.value
            await self.performLocalDataWipe()
            self.localDataWipesInFlight -= 1
            self.isDeletingLocalData = self.localDataWipesInFlight > 0
        }
    }

    /// How many wipes are between their press and their last step (SONNY-404, PR #207's F3).
    ///
    /// **The claim's owner is the chain, not a task.** `isDeletingLocalData` is derived from this and
    /// from nothing else, so the only way to release it is for every wipe to have finished. A
    /// `Bool` set by each press and cleared by each completion is what cycle 3 measured releasing the
    /// claim mid-sequence.
    ///
    /// Two presses are unreachable through the product now — the control is disabled while the claim
    /// is held — and the count is what keeps the model right if a press ever arrives another way.
    ///
    /// **A model-level refusal was the other option and it was rejected**, though the surface-level
    /// one (the disabled control) ships beside this. Returning early from a second press would drop
    /// a press the user made, and it would make the property untestable in the bargain: with no
    /// second wipe there is no chain, so nothing could tell a claim released by the last wipe from
    /// one released by the first, which is precisely the defect cycle 3 found. Chaining keeps the
    /// second press honoured, keeps two wipes off one queue file, and leaves the release observable.
    private var localDataWipesInFlight = 0

    /// Whether Settings' whole wipe is running right now (SONNY-404, PR #207's F3).
    ///
    /// **A claim rather than a mood.** The wipe deletes every store and clears the in-memory state a
    /// run is holding, so a run that starts inside it loses its files and its scope. The three doors
    /// that start a run refuse while this is true, which is the "hold the claim" half of the fix;
    /// the wipe's own `!isRunning` guard is the other direction and is unchanged.
    ///
    /// `private(set)` and published: the run doors read it, and a test needs to see the window.
    @Published private(set) var isDeletingLocalData = false

    /// The wipe in flight, for tests. `nil` when none has been started.
    ///
    /// Internal for the reason `pendingServerDeletionDeliveryForTests` is: the press is asynchronous
    /// now and there is no other surface to observe it settle through.
    var localDataWipeForTests: Task<Void, Never>? {
        localDataWipe
    }

    private func performLocalDataWipe() async {
        // The instant the press covers. Everything below carries it: the server delete bounds itself
        // at or before it, and the obligation left behind carries it so a delivery days later cannot
        // reach content the press never covered (PR #207's F1).
        //
        // **The server's clock, not this Mac's** (PR #207's cycle-3, G1). It is compared against
        // `occurred_at` on the gateway's rows, so a skewed Mac bounds the deletion at the wrong
        // instant in whichever direction it is skewed. `instantToBoundAPressAt()` carries the whole
        // argument, including the sub-second truncation the wire format applies.
        let pressedAt = await taskDeletionService.instantToBoundAPressAt()
        // Stopped first, before anything else: the poll timer can write a clipboard entry between
        // the wipe and the refresh, and the network steps below make that window seconds wide rather
        // than milliseconds.
        stopClipboardHistoryMonitoring()

        // Step 1 — the drain, before the queue file goes.
        await taskDeletionService.drainBeforeAWipe()
        // Step 2 — the account's server-side content, bounded at the press.
        let serverCopyIsGone = await taskDeletionService.deleteEverythingUnderTheAccount(before: pressedAt)

        // Step 3 — every local file, the queue among them. **The result is captured rather than the
        // whole tail living inside the `do`** (PR #207's F2). `deleteAllLocalData` collects failures
        // and throws only *after* deleting everything it could, and the queue is one of the files it
        // deletes — so a wipe that failed on any single file used to land in a `catch` with the
        // queue already gone and step 4 never reached. The server held everything, the Mac owed
        // nothing, and the sentence the user read named only a local file: the exact state the
        // founder's condition forbids, arriving through the failure branch.
        var deletedFileCount = 0
        var localFailure: String?
        do {
            deletedFileCount = try localDataDeletionService.deleteAllLocalData().deletedFileCount
            clearInMemoryLocalDataState()
        } catch {
            localFailure = error.localizedDescription
        }

        // Step 4 — the one obligation the wipe may leave, **on both paths**, and only when it is
        // owed. `try?` because the user is about to be told the servers' copy is still there either
        // way, and a second sentence about bookkeeping is not something they could act on; the
        // residue if it fails is the retry, not the promise, since pressing Delete again re-attempts
        // everything.
        var serverCopyIsOwed = false
        if !serverCopyIsGone {
            serverCopyIsOwed = (try? taskDeletionService.recordOwedAccountContentDeletion(deletedAt: pressedAt)) ?? false
        }

        // Step 5 — one sentence, covering both halves, on every path.
        let message = LocalDataDeletionCopy.outcome(
            deletedFileCount: deletedFileCount,
            localFailure: localFailure,
            serverCopy: serverCopyIsGone ? .deleted : (serverCopyIsOwed ? .owed : .strandedWithNoSession)
        )
        localDataDeletionStatusMessage = message
        if localFailure == nil {
            errorMessage = nil
            finalSummary = message
            logStore.append(.observe, message)
        } else {
            setError(message)
        }
        // After either branch, because the failure branch is the one where both matter: a wipe that
        // took some of the Memory page's kept files and failed on the rest has left that page's
        // sentence and its Reveal control naming a file that is gone (PR #117 review, F1) — on
        // success the record is already `nil` — and a wipe that could not remove a set-aside file
        // leaves it on disk, so the Data page's line has to say so rather than go quiet because the
        // wipe was pressed.
        pruneLastPerRowDeleteToFilesStillOnDisk()
        refreshSetAsideFiles()
    }

    // MARK: - Set-aside files (SONNY-266)

    /// Re-lists the files set aside from every store and republishes `setAsideFilesSummary`.
    ///
    /// Called from the Data page's `onAppear` — a file set aside on a previous launch, or moved
    /// there by hand, is only ever found by looking — and by the three things in this view model
    /// that change the population: `deleteMemory(in:)`, which adds to it, and `deleteLocalData()`
    /// and `deleteSetAsideFiles()`, which empty it — through `deleteAllLocalData()` and
    /// `deleteSetAsideFilesOnly()` respectively.
    func refreshSetAsideFiles() {
        setAsideFilesSummary = localDataDeletionService.setAsideFilesSummary()
    }

    /// Deletes every file set aside from a store, and nothing else — Settings' narrower control
    /// (SONNY-266, founder decision 2026-08-24).
    ///
    /// **Guarded on a running task by founder decision (PR #117 review, F3), and the reason is the
    /// error channel, not the files.** The population argument the first version rested on still
    /// holds: the only writer of a set-aside file is `deleteMemory(in:)` — the one caller of
    /// `LocalDataQuarantine.moveAsideAll` in `Sources/` — and it refuses during a run, so nothing
    /// this deletes can change under one. What that argument missed is where a failure goes. It goes
    /// to `errorMessage`, which both surfaces suppress while `isRunning` and rank above the task's
    /// result once it ends — `performStart`'s `defer` clears `isRunning` and leaves `errorMessage`
    /// standing — so a control that could fail mid-run would report a task that ran and succeeded as
    /// this delete's failure, and pop the widget for it: the SONNY-201 shape, through a new door. The
    /// wipe and the per-row Delete never face it because their guards keep them out of a run. The
    /// guard copied is the wipe's — same page, same row shape, same `isRunning` condition — so the
    /// three doors agree, and the button is disabled under the same condition so this is the
    /// backstop rather than the surface.
    ///
    /// Reports on `localDataDeletionStatusMessage`, the Data page's own slot, which is where the
    /// control sits. A failure also goes to `errorMessage`, as the whole wipe's does: this is a
    /// write the user pressed a control for, and the thing they asked for did not happen.
    func deleteSetAsideFiles() {
        guard !isRunning else {
            setError(MemoryDeletionCopy.setAsideFilesRunGuard)
            return
        }

        do {
            let result = try localDataDeletionService.deleteSetAsideFilesOnly()
            localDataDeletionStatusMessage = MemoryDeletionCopy.setAsideFilesOutcome(
                deletedFileCount: result.deletedFileCount
            )
            errorMessage = nil
        } catch let error as LocalDataDeletionError {
            // The service's error taken apart rather than quoted: its own sentence is the wipe's
            // ("Deleted 0 local data files, but 1 could not be deleted…"), and to the user these
            // are not local data files but the files Sonny could not read (PR #117 review, F4).
            let message = MemoryDeletionCopy.setAsideFilesFailure(error)
            localDataDeletionStatusMessage = message
            setError(message)
        } catch {
            let message = MemoryDeletionCopy.setAsideFilesFailure(describing: error.localizedDescription)
            localDataDeletionStatusMessage = message
            setError(message)
        }
        pruneLastPerRowDeleteToFilesStillOnDisk()
        refreshSetAsideFiles()
    }

    /// Prunes the last per-row Delete's kept files to the ones still on disk, and re-derives its
    /// sentence from what is left (PR #117 review, F1).
    ///
    /// Settings' narrower control and the whole wipe both remove these files, and both can remove
    /// some and fail on the rest. Evidence rather than assumption, after either branch of either:
    /// every kept file is checked on disk, the survivors stay named — the Reveal control selects
    /// exactly them — and the sentence beside it is derived again from the pruned record, so "The 2
    /// files … are still on your Mac" becomes "The file … is still on your Mac" when one remains and
    /// goes when none does. An outcome sentence counts the files and so follows them; a failure
    /// sentence names the step that failed and stays true whatever happens to them, so it is left
    /// alone.
    ///
    /// The sentence on screen is always this record's, which is what lets it be rewritten without
    /// looking at it: `memoryDeletionStatusMessage` has one other writer, `deleteMemory(in:)`, and
    /// that one replaces the record in the same breath (`theMemoryPagesSentenceHasOneWriterBesidesThePrune`).
    /// A first draft compared the sentence to the record's before rewriting it, which was a branch
    /// nothing could reach and no test could hold.
    ///
    /// The first version cleared the whole record when *any* named file was gone, which retired the
    /// sentence and the control for a file still on disk — the one surface that names it.
    private func pruneLastPerRowDeleteToFilesStillOnDisk() {
        guard let last = lastPerRowDelete else {
            return
        }
        let survivors = last.keptFileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard survivors.count < last.keptFileURLs.count else {
            return
        }
        var pruned = last
        pruned.keptFileURLs = survivors
        lastPerRowDelete = survivors.isEmpty ? nil : pruned
        guard last.failure == nil else {
            return
        }
        memoryDeletionStatusMessage = survivors.isEmpty ? nil : MemoryDeletionCopy.perRowDeleteReport(pruned)
    }

    // MARK: - Memory (SONNY-208)

    /// Reloads the memory types that have no list of their own anywhere else in the app.
    ///
    /// Routines, workspaces and task history are deliberately absent: they are already published by
    /// `refreshSavedItems()` and `refreshTaskHistory()`, and a second loader for the same file is a
    /// second answer that can disagree with the first.
    func refreshMemoryEntries() {
        savedSnippets = loadMemoryEntries(.snippets) {
            try snippetStore.loadAll().values
                .sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
        }
        recentArtifacts = loadMemoryEntries(.recentArtifacts) {
            try recentArtifactStore.loadAll()
        }
        clipboardHistoryItems = loadMemoryEntries(.clipboardHistoryItems) {
            try clipboardHistoryMonitor.historyStore.loadAll()
        }
        // **Filtered for display, counted before the filter, from one read** (SONNY-144; the count
        // is PR #175's review, F1). Settings' allowed-apps list and the Memory section's entries
        // sheet both read `approvedApps`, so a filter in one of them is a filter the other does not
        // have — and a revocation list offering to take back a grant on Terminal would tell the user
        // they had allowed something Sonny will never do. The store's write path already refuses to
        // persist one; this is about a file outliving the code that filled it, not about today's
        // writers.
        //
        // `storedApprovedAppCount` is what Settings' Remove All is offered on, and it has to come
        // from before the filter or the filter closes the only route to the entries it hides: with
        // every stored grant ineligible, the rendered list is empty, the Memory row's Delete is
        // disabled at a count of zero, the entries sheet is empty, and nothing short of the whole-app
        // wipe reaches the file. One load answers both, so the count and the list cannot disagree.
        let storedApprovedApps = loadMemoryEntries(.approvedApps) {
            try approvedAppStore.loadAll()
        }
        storedApprovedAppCount = storedApprovedApps.count
        approvedApps = ApprovedAppRevocationPresentation.eligible(storedApprovedApps)
        outputLocations = loadMemoryEntries(.outputLocations) {
            // Already ranked best-suggestion-first by the store, so the sheet lists them in the order
            // Sonny would actually offer them. Sorting again here would be a second ordering that can
            // disagree with the behaviour the list is describing.
            try outputLocationStore.loadAll()
        }
        // Its own function rather than a fifth `loadMemoryEntries` line, because the widget's offer
        // needs this list at launch without Command Center ever opening — `AppDelegate` calls it
        // directly — and the write path calls it after every save and delete.
        refreshResumableTasks()
    }

    /// Empties the list on failure rather than leaving it stale, the same choice
    /// `refreshTaskHistory` makes: a list still showing entries beside a notice saying the file will
    /// not decrypt is the surface contradicting itself.
    private func loadMemoryEntries<Entry>(
        _ source: LocalStorageLoadFailureSource,
        load: () throws -> [Entry]
    ) -> [Entry] {
        do {
            let entries = try load()
            clearLocalStorageLoadFailure(source)
            return entries
        } catch {
            recordLocalStorageLoadFailure(source, error: error)
            return []
        }
    }

    /// Re-reads the enterprise policy and the user's switches. Called whenever the Memory section
    /// appears, so a policy that changed under a running app is picked up without a relaunch.
    func refreshMemorySettings() {
        memorySettings = memorySettingsStore.load(policy: memoryPolicyProvider.currentPolicy())
    }

    /// How many things Sonny currently remembers of this kind.
    ///
    /// Reads the same published arrays the rest of the app renders, so a count and the list it
    /// describes cannot disagree. Task history counts rows, not the plan details and screen records
    /// hanging off them — those are parts of a row rather than things of their own.
    func memoryEntryCount(for category: MemoryCategory) -> Int {
        switch category {
        case .routines:
            return savedRoutines.count
        case .workspaces:
            return savedWorkspaces.count
        case .taskHistory:
            return taskHistoryRecords.count
        case .recentArtifacts:
            return recentArtifacts.count
        case .clipboardHistory:
            return clipboardHistoryItems.count
        case .snippets:
            return savedSnippets.count
        case .approvedApps:
            return approvedApps.count
        case .outputLocations:
            return outputLocations.count
        case .resumableTasks:
            return resumableTasks.count
        }
    }

    /// Whether new entries of this kind are being recorded right now — the *effective* answer, with
    /// the master switch and the enterprise policy already folded in.
    ///
    /// Effective rather than "what the user chose for this row", deliberately: with memory off
    /// wholesale, a per-type switch reading "on" beside a type that records nothing is the surface
    /// telling the user something untrue. Their per-type choices are not lost — they stay in
    /// `MemorySettingsStore` and come back the moment the master switch does.
    func isMemoryCategoryEnabled(_ category: MemoryCategory) -> Bool {
        guard memorySettings.allowsRecording(in: category) else {
            return false
        }
        // Clipboard history's own switch, which predates the Memory section and stays the one
        // source of truth for it.
        return category == .clipboardHistory ? clipboardHistoryEnabled : true
    }

    /// The master switch.
    ///
    /// Refuses while an administrator has taken it away, rather than writing a preference the policy
    /// would override on the next read — a stored value nothing can honour is a switch that springs
    /// back, which reads as a broken control.
    func setMemoryEnabled(_ isEnabled: Bool) {
        guard !memorySettings.isDisabledByPolicy else {
            return
        }
        memorySettingsStore.setMemoryEnabled(isEnabled)
        refreshMemorySettings()
        // Clipboard recording is a *timer*, not a guard consulted at write time, so turning memory
        // off has to actually stop it — and turning memory back on has to restore it from the
        // clipboard's own setting rather than start it unconditionally.
        refreshClipboardHistoryNotice()
    }

    /// One type's switch. The only writer of a per-type memory preference.
    ///
    /// Clipboard history routes to the setting it already had, for the reason on
    /// `MemoryCategory.clipboardHistory`: a second flag over the same behaviour is how a surface
    /// ends up saying "on" while nothing is recording. The side effect that carries — the first-run
    /// notice counts as answered — is correct rather than incidental: choosing here *is* answering
    /// it.
    func setMemoryCategoryEnabled(_ category: MemoryCategory, to isEnabled: Bool) {
        guard !memorySettings.isDisabledByPolicy else {
            return
        }
        guard category != .clipboardHistory else {
            clipboardHistoryEnabled = isEnabled
            applyClipboardHistoryNoticeChoice()
            return
        }
        memorySettingsStore.setCategoryEnabled(isEnabled, for: category)
        refreshMemorySettings()
    }

    /// Forgets everything of one kind, leaving every other kind untouched.
    ///
    /// **`LocalDataDeletionService` again, with a narrower list** — the same service Settings' whole
    /// wipe uses, constructed over this category's files instead of every store's. That buys the
    /// attempt-every-file-and-report-what-survived behaviour a privacy delete needs, rather than a
    /// second deletion routine that stops at the first error.
    ///
    /// **The URLs come from the injected stores**, not from `LocalStore.fileURL(fileManager:)`, which
    /// resolves the *default* location — a test fixture pointing its stores at a temporary directory
    /// would otherwise delete the developer's real files.
    func deleteMemory(in category: MemoryCategory) {
        // `!isAwaitingApproval` as well as `!isRunning`, matching `deleteRoutine` rather than
        // `deleteLocalData`: a run paused at its approval is a run about to write, and this deletes
        // the file it is about to write into. `deleteLocalData`'s narrower guard is not the
        // precedent to copy here — it is the whole-wipe path, which the user reaches from Settings
        // rather than from beside a live task.
        guard !isRunning, !isAwaitingApproval else {
            setError("Finish or stop the current task before deleting memory.")
            return
        }

        if category == .clipboardHistory {
            // The poll timer holds no file handle, but it can write a new entry between the delete
            // and the refresh — which would leave the list non-empty right after a delete reported
            // success.
            stopClipboardHistoryMonitoring()
        }

        // **The server's copies, owed before anything local goes** (SONNY-404). This row deletes
        // every task-history row at once, and the founder decision of 2026-09-05 is that it queues
        // every one of those tasks' server deletions — as one bulk call rather than one call per
        // row. It is the same ordering `deleteTask` uses and for the same reason: the ids are
        // carried by the rows and by nothing else, so a local delete that ran first and an enqueue
        // that then failed would destroy the only remaining name for the server's copies,
        // permanently and silently. An enqueue that throws aborts with everything intact.
        //
        // **The ids come from the file with the published list as the fallback**, and the fallback
        // is the point: `taskHistoryRecords` is what the row's own count was built from, so if the
        // file will not read the press still owes what the user was shown.
        //
        // **What that costs, corrected** (PR #207's R4). This said an unreadable file "names no
        // tasks either way", which is false: the published list is whatever loaded successfully at
        // launch, so a file that broke afterwards still names its tasks here. Those ids are enqueued
        // and their server copies go, while the local bytes are *kept* — quarantined rather than
        // deleted. That is the right direction on both halves (the server copy is what the user
        // asked to remove; the unreadable bytes may still be recoverable under a restored key) and
        // it is not what the previous sentence claimed.
        var enqueuedTaskIDs: [String] = []
        if category == .taskHistory {
            enqueuedTaskIDs = ((try? taskHistoryStore.loadAll()) ?? taskHistoryRecords)
                .compactMap(\.id)
                .filter { !$0.isEmpty }
            do {
                try taskDeletionService.recordDeletedTasks(ids: enqueuedTaskIDs)
            } catch {
                setError("Could not delete task history: \(error.localizedDescription)")
                return
            }
        }

        // **The split this ticket exists for** (SONNY-239, founder decision 2026-08-23). A file
        // Sonny can read is deleted, exactly as before — that is the privacy promise every one of
        // `MemoryDeletionCopy.message(for:)`'s sentences makes, and a Delete that quietly kept a
        // readable file would make each of them false. A file Sonny *cannot* read is moved aside
        // instead, because a decrypt failure proves only that the bytes were written under a
        // different key, and SONNY-253's recorded architecture can hand that key back after a
        // restore. Per store rather than per row, so a row covering four files — Task history —
        // deletes the three that read and keeps only the one that does not.
        // Probed here so the press acts on the truth, and read back out of the same published set
        // the row's words and this category's confirmation were built from.
        refreshStoreReadability()
        let unreadable = category.stores.filter { unreadableStores.contains($0) }
        let readable = category.stores.filter { !unreadableStores.contains($0) }
        // **The readable half splits again, by who owns the file** (SONNY-236, founder decision
        // 2026-08-31). A row whose store shares its file with another collection must not unlink it:
        // this row is named *Unfinished tasks* and `resumable-tasks.json` also holds the user's
        // standing watchers, so the file-level door would destroy something the row never mentions,
        // silently and with nothing failing. `LocalStoreRowDeletionScope` carries the reasoning and
        // is exhaustive, so a fifteenth store has to answer the same question.
        //
        // **The unreadable half is deliberately not split the same way** and goes to quarantine at
        // file level below, whatever a store's scope says: rewriting a file means decoding it, which
        // is exactly what has failed. Nothing is lost by that — quarantine keeps the file, so a
        // shared file's other collection is set aside intact rather than destroyed.
        let readableWholeFile = readable.filter { $0.rowDeletionScope == .wholeFile }
        let readableSharedFile = readable.filter { $0.rowDeletionScope == .collectionWithinASharedFile }

        var deletedFileCount = 0
        var failures: [String] = []

        // Both attempted whatever the other does, the same rule `deleteAllLocalData` follows across
        // its own files: a first step that failed must not leave the second silently unattempted.
        do {
            // **`deleteStoreFilesOnly`, never `deleteAllLocalData`** (PR #110 review, F2). The wipe's
            // door also sweeps every file `LocalDataQuarantine` has set aside from these stores, so
            // this call destroyed the file an earlier press had promised to keep — and reported it
            // in the "N files" figure, where the user can see only one memory type.
            let service = LocalDataDeletionService(fileURLs: readableWholeFile.map(storeFileURL))
            deletedFileCount = try service.deleteStoreFilesOnly().deletedFileCount
        } catch {
            failures.append(error.localizedDescription)
        }

        // Attempted whatever the file-level delete above did, for the reason that comment gives.
        for store in readableSharedFile {
            do {
                try deleteSharedFileRowContents(of: store)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        var keptFileURLs: [URL] = []
        if !unreadable.isEmpty {
            do {
                keptFileURLs = try LocalDataQuarantine().moveAsideAll(unreadable.map(storeFileURL)).movedFileURLs
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        // **The obligation is withdrawn when nothing local went**, the symmetric half of the enqueue
        // above and of `deleteTask`'s own (PR #194's F1). A row that could delete none of its files
        // has left every task still in the user's history, and an entry left queued for it would
        // have the next launch delete those tasks' server copies after the press visibly failed.
        // Keyed on `failures.isEmpty` being false *and* nothing having been deleted, because a
        // partial delete really did remove rows and those tasks' server copies are genuinely owed.
        if !enqueuedTaskIDs.isEmpty, !failures.isEmpty, deletedFileCount == 0, keptFileURLs.isEmpty {
            try? taskDeletionService.withdrawDeletedTasks(ids: enqueuedTaskIDs)
        } else if !enqueuedTaskIDs.isEmpty {
            deliverPendingServerDeletions()
        }

        // Replaced on every press — a delete that keeps nothing leaves `nil`, so the previous one's
        // Reveal control cannot stay on screen beside a message that says nothing was kept — and the
        // sentence is derived from the record rather than written here, so the prune that follows a
        // partial removal of these files derives it again from the same place (PR #117 review, F1).
        let record = LastPerRowDelete(
            category: category,
            deletedFileCount: deletedFileCount,
            keptFileURLs: keptFileURLs,
            failure: failures.first
        )
        lastPerRowDelete = record.keptFileURLs.isEmpty ? nil : record
        memoryDeletionStatusMessage = MemoryDeletionCopy.perRowDeleteReport(record)
        if record.failure == nil {
            errorMessage = nil
        }

        // Before the refresh, and by checking the disk rather than by assuming. Only some of these
        // sources are re-probed by `refreshMemorySurfaces()` — `.taskPlanDetails` is loaded when a
        // task's detail is opened and by nothing else — so a row cleared of an unreadable plan-detail
        // file would keep its banner and keep saying "Can't be read" until the user opened a task.
        clearLoadFailuresForStoresWhoseFileIsGone(
            LocalStorageLoadFailureSource.allCases.filter { $0.memoryCategory == category }
        )
        refreshMemorySurfaces()
        // This is the one press that adds to what Settings' Data page counts (SONNY-266), so the
        // line is re-listed here rather than waiting for that page to appear.
        refreshSetAsideFiles()
    }

    /// Removes one row's own collection from a file it shares, leaving everything else in that file
    /// alone (SONNY-236).
    ///
    /// **Exhaustive with no `default`, and every `.wholeFile` store is listed rather than swept
    /// up.** `rowDeletionScope` is what routes a store here, so all of those are unreachable —
    /// but a `default:` would let a fifteenth store arrive classified as sharing a file and be
    /// silently deleted by nothing at all, which is the same invisible failure the split exists to
    /// prevent, one door along. Listing them means the classification and the door have to be
    /// changed together.
    private func deleteSharedFileRowContents(of store: LocalStore) throws {
        switch store {
        case .resumableTasks:
            // Not `deleteAll()`, which unlinks the file and is Settings' whole-wipe door. This
            // rewrites it without the tasks and keeps the watchers beside them.
            try resumableTaskStore.deleteAllTasks()
        case .visionSessionJournal,
             .routines,
             .workspaces,
             .clipboardHistory,
             .clipboardHistorySettings,
             .snippets,
             .recentArtifacts,
             .shortcutRunHistory,
             .taskHistory,
             .taskPlanDetails,
             .approvedApps,
             .outputLocations,
             .pendingServerDeletions:
            break
        }
    }

    /// Re-reads every store and republishes `unreadableStores`.
    ///
    /// **The one writer, so the row's words and its Delete cannot come from different answers**
    /// (PR #110 fix-round review). Called from the Memory page's `onAppear`, from
    /// `refreshMemoryRowsAfterRun()` so a store that breaks mid-run does not leave the page saying
    /// a count of zero, and from the top of `deleteMemory(in:)` so the press acts on the truth rather than
    /// on a probe from whenever the page last appeared.
    ///
    /// **The remaining window is the confirmation dialog itself, and that is the world changing
    /// rather than two mechanisms disagreeing.** The sentence the user read was built from one probe
    /// and the press re-probes; if a file broke or healed in between, the press does the right thing
    /// and `MemoryDeletionCopy.outcome` reports what actually happened. What cannot happen any more
    /// is the two being derived from different populations.
    func refreshStoreReadability() {
        unreadableStores = Set(LocalStore.allCases.filter { !storeIsReadable($0) })
    }

    /// Whether this store's file can be read right now.
    ///
    /// Exhaustive over `LocalStore` with no `default`, so a fifteenth store cannot be added without
    /// somebody naming its read door — and a store with no read door named here is a store the
    /// delete would destroy unreadable.
    ///
    /// A store with no file at all answers `true`: every one of these loaders returns empty for a
    /// missing file, and there is nothing to protect.
    private func storeIsReadable(_ store: LocalStore) -> Bool {
        do {
            switch store {
            case .visionSessionJournal:
                _ = try visionSessionJournalStore.loadAll()
            case .routines:
                _ = try routineStore.loadAll()
            case .workspaces:
                _ = try workspaceStore.loadAll()
            case .clipboardHistory:
                _ = try clipboardHistoryMonitor.historyStore.loadAll()
            case .clipboardHistorySettings:
                _ = try clipboardHistorySettingsStore.load()
            case .snippets:
                _ = try snippetStore.loadAll()
            case .recentArtifacts:
                _ = try recentArtifactStore.loadAll()
            case .shortcutRunHistory:
                _ = try shortcutRunHistoryStore.loadAll()
            case .taskHistory:
                _ = try taskHistoryStore.loadAll()
            case .taskPlanDetails:
                _ = try taskPlanDetailStore.loadAll()
            case .approvedApps:
                _ = try approvedAppStore.loadAll()
            case .outputLocations:
                _ = try outputLocationStore.loadAll()
            case .resumableTasks:
                _ = try resumableTaskStore.loadAll()
            case .pendingServerDeletions:
                // **Here because this switch is exhaustive over `LocalStore` with no `default`, and
                // for no other reason** (PR #194 review, F6). The sentence that stood here said the
                // whole wipe "splits on readability for every store at once"; it does not —
                // `LocalDataDeletionService.delete(reaching:)` unlinks every file unconditionally,
                // and the door that splits is `deleteMemory(in:)`, per `MemoryCategory`. This
                // store's category is `nil`, so it is in no category, and its answer here is
                // consumed by nothing: `unreadableStores` is read only through `category.stores`.
                //
                // **Kept rather than shortcut to `true`**, at the cost of one file read and decrypt
                // on this refresh, because a set named `unreadableStores` that quietly excluded a
                // store would be a worse thing to leave behind than the read. The store heals an
                // undecodable file itself now, so the answer this returns is also true for longer
                // than it used to be — **and this read can therefore move a file**, which is worth
                // knowing about a method named for a question (PR #194 cycle-3's residuals). It is
                // the same heal any other door would perform and it happens once.
                _ = try pendingServerDeletionStore.loadAll()
            }
            return true
        } catch {
            return false
        }
    }

    /// Forgets the load failures whose file is no longer where it was.
    ///
    /// Evidence rather than assumption: it asks the file system whether the file this source failed
    /// on is actually gone, so a move or a delete that silently did nothing cannot clear a banner
    /// that is still true.
    private func clearLoadFailuresForStoresWhoseFileIsGone(_ sources: [LocalStorageLoadFailureSource]) {
        for source in sources where localStorageLoadFailures[source] != nil {
            guard !FileManager.default.fileExists(atPath: storeFileURL(for: source.store).path) else {
                continue
            }
            clearLocalStorageLoadFailure(source)
        }
    }

    /// One store's file, resolved through the instance this view model was constructed with.
    ///
    /// The switch is exhaustive over `LocalStore` with no `default`, so a fifteenth store
    /// cannot be added without someone deciding which injected instance answers for it here.
    private func storeFileURL(for store: LocalStore) -> URL {
        switch store {
        case .routines:
            return routineStore.fileURL
        case .workspaces:
            return workspaceStore.fileURL
        case .taskHistory:
            return taskHistoryStore.fileURL
        case .taskPlanDetails:
            return taskPlanDetailStore.fileURL
        case .visionSessionJournal:
            return visionSessionJournalStore.fileURL
        case .shortcutRunHistory:
            return shortcutRunHistoryStore.fileURL
        case .recentArtifacts:
            return recentArtifactStore.fileURL
        case .clipboardHistory:
            return clipboardHistoryMonitor.historyStore.fileURL
        case .snippets:
            return snippetStore.fileURL
        case .approvedApps:
            return approvedAppStore.fileURL
        case .clipboardHistorySettings:
            return clipboardHistorySettingsStore.fileURL
        case .outputLocations:
            return outputLocationStore.fileURL
        case .resumableTasks:
            return resumableTaskStore.fileURL
        case .pendingServerDeletions:
            return pendingServerDeletionStore.fileURL
        }
    }

    /// Every Memory row a finished run can have changed, reloaded together.
    ///
    /// **Two calls, because the Memory section's rows are published by two loaders and always have
    /// been** (PR #110 review, F6). `refreshMemoryEntries()` owns the five stores with no page of
    /// their own plus unfinished tasks; `refreshSavedItems()` owns Routines and Workspaces, which it
    /// deliberately does not, since a second loader for the same file is a second answer that can
    /// disagree with the first.
    ///
    /// The first round of SONNY-246 called only the first of the two, and the row that made the gap
    /// visible was the one its own comment used as an example: a run that creates a workspace and
    /// then fails, or *any* scheduled run that creates one, left the Workspaces row showing the old
    /// count. `refreshSavedItems()` was reached only from the success branches — three of them, none
    /// on the scheduled path — so the exact symptom SONNY-246 was filed for survived on two of the
    /// nine rows.
    ///
    /// Task history is not here: both terminal paths already call `refreshTaskHistory()` themselves,
    /// on their own rules, and folding it in would make a third caller of a fourth loader.
    private func refreshMemoryRowsAfterRun() {
        refreshSavedItems()
        refreshMemoryEntries()
        // A store that breaks during a run must not leave the page on screen saying a count of zero
        // with its Delete greyed out until the user navigates away and back — which is this branch's two
        // tickets meeting each other.
        refreshStoreReadability()
    }

    /// Every list the Memory section renders, reloaded together.
    ///
    /// One function rather than four calls at each site: a delete that refreshed three of them left
    /// the fourth showing entries that no longer exist, and which three a given delete touches is
    /// exactly the kind of thing a caller gets wrong.
    private func refreshMemorySurfaces() {
        refreshSavedItems()
        refreshTaskHistory()
        refreshMemoryEntries()
        refreshClipboardHistoryNotice()
        // The delete that brought us here changed which files exist, so which of them read is a
        // different answer now — and a row still saying "Can't be read" about a file that has just
        // been moved aside is the same stale surface the four calls above exist to prevent.
        refreshStoreReadability()
    }

    /// Stops one standing watcher — the Routines page's Stop press (SONNY-382).
    ///
    /// **This is the half of SONNY-382 that must not have been cut.** A watcher a user can start
    /// and cannot stop is a background process they forgot they started, spending a cap they cannot
    /// see, which is the exact failure the founders' cap decision of 2026-08-31 exists to prevent.
    ///
    /// **No notification, and that is deliberate.** `StandingWatcherStopReason.cancelled` has a
    /// sentence and nothing posts it: the four endings Sonny decides are news to somebody who was
    /// not there, and this one is a button the user has their finger on. The row leaving the list is
    /// the feedback. **What that must not become is the impression that Stop is the only way a
    /// watcher ends** — the row's own second line says when it stops on its own, so a user meets
    /// both endings without the product explaining either.
    ///
    /// **`setError`, not `recordLocalStorageWriteFailure`** — `CLAUDE.md`'s channel rule, and this
    /// is the clear side of it: the user pressed a control and the thing they asked for did not
    /// happen. The notice channel is for bookkeeping a *task* did on its own, which is what
    /// `saveStandingWatcher` and `finishStandingWatcher` use, because there `errorMessage` would
    /// replace the result of a run that succeeded.
    ///
    /// **A record that is already gone is not an error**, and that is `ResumableTaskStore.deleteWatcher`'s
    /// own behaviour rather than something decided here: it returns without writing when no watcher
    /// carries the id. So a press on a row a check finished a second earlier reports nothing, and the
    /// refresh below is what makes the list agree with the file. The refresh runs on the failing path
    /// too, because a write that threw may still have changed what is readable.
    func stopWatching(_ watcher: StandingWatcher) {
        do {
            try resumableTaskStore.deleteWatcher(id: watcher.id)
        } catch {
            setError("Could not stop watching \u{201C}\(watcher.subject)\u{201D}: \(error.localizedDescription)")
            refreshSavedItems()
            return
        }
        refreshSavedItems()
    }

    /// Forgets one snippet.
    func deleteSnippet(_ snippet: StoredSnippet) {
        performMemoryEntryDelete(named: "snippet") {
            try snippetStore.delete(trigger: snippet.trigger)
        }
    }

    /// Forgets one recorded file. The file itself is untouched — this store only ever held a note.
    func deleteRecentArtifact(_ artifact: RecentArtifact) {
        performMemoryEntryDelete(named: "recent artifact") {
            try recentArtifactStore.delete(id: artifact.id)
        }
    }

    /// Forgets one copied item.
    func deleteClipboardHistoryItem(_ item: ClipboardHistoryItem) {
        performMemoryEntryDelete(named: "clipboard item") {
            try clipboardHistoryMonitor.historyStore.delete(id: item.id)
        }
    }

    /// Revokes one app's control grant. Sonny asks about that app again the next time it needs it.
    ///
    /// **Two surfaces, one path.** The Memory section's entries sheet has pressed this since
    /// SONNY-208 and Settings' allowed-apps list presses it now (SONNY-144). Neither gets a commit
    /// path of its own, so one failed write cannot be reported two different ways.
    func forgetApprovedApp(_ app: ApprovedApp) {
        performMemoryEntryDelete(named: "allowed app") {
            try approvedAppStore.forget(bundleIdentifier: app.bundleIdentifier)
        }
    }

    /// Revokes every app's control grant — Settings' Remove All (SONNY-144).
    ///
    /// **The confirmation is the view's, and this is deliberately not gated on one.** A press that
    /// reaches here has already been confirmed; putting a second check in the commit path would be a
    /// rule written twice, and the view's `confirmationDialog` is the one a person actually sees.
    /// Per-row Remove has no dialog at all, and the asymmetry is reasoned rather than accidental:
    /// removing one app is a single grant the user re-mints by answering the next ask, and removing
    /// all of them is not something the flow can hand back.
    ///
    /// One store call rather than a loop over `approvedApps`, for two reasons the store's own
    /// `forgetAll()` states: it is one write instead of one per grant, and it reaches a stored entry
    /// the deny-list filter keeps out of the rendered list — which per-row Remove, by construction,
    /// cannot. **The second reason is only true because the control is offered on
    /// `storedApprovedAppCount`** rather than on the rendered list; gated on the list, it was not on
    /// screen in the one case it was the only way through (PR #175 review, F1).
    func forgetAllApprovedApps() {
        performMemoryStoreWrite(failureMessage: "Could not remove your allowed apps") {
            try approvedAppStore.forgetAll()
        }
    }

    /// Forgets one output location. The folder and everything in it are untouched — this store only
    /// ever held a count and two dates about where files went.
    func forgetOutputLocation(_ location: OutputLocation) {
        performMemoryEntryDelete(named: "output location") {
            try outputLocationStore.forget(path: location.path)
        }
    }

    /// The newest thing Sonny remembers of this kind, or `nil` when the type carries no timestamp.
    ///
    /// Routines and workspaces answer `nil` on purpose rather than reaching for a run date: neither
    /// record carries a created-at field, and `recentRunDates` would make the row's "newest" line
    /// mean something different from every other row's.
    func newestMemoryEntryDate(for category: MemoryCategory) -> Date? {
        switch category {
        case .routines, .workspaces:
            return nil
        case .taskHistory:
            return taskHistoryRecords.map(\.completedAt).max()
        case .recentArtifacts:
            return recentArtifacts.map(\.recordedAt).max()
        case .clipboardHistory:
            return clipboardHistoryItems.map(\.copiedAt).max()
        case .snippets:
            return savedSnippets.map(\.updatedAt).max()
        case .approvedApps:
            return approvedApps.map(\.approvedAt).max()
        case .outputLocations:
            // `lastUsedAt`, not `firstUsedAt`: every other row's "newest" line means the most recent
            // thing recorded, and a folder's most recent record is the last time work landed in it.
            return outputLocations.map(\.lastUsedAt).max()
        case .resumableTasks:
            // `updatedAt`, not `startedAt`: this row's "newest" line has to mean the same thing every
            // other row's does — when Sonny last recorded something here — and for this store that is
            // the last unit that finished, not the moment the task began.
            return resumableTasks.map(\.updatedAt).max()
        }
    }

    /// Deletes the entry at `index` of the list the Memory sheet rendered for `category`.
    ///
    /// **By position into the same published array the sheet enumerated**, so the row and the record
    /// it removes cannot come apart — the alternative, passing an identifier back, would let a
    /// refresh between render and tap resolve to a different record with the same id. Out-of-range
    /// is a no-op rather than a crash: the array can shrink under a sheet that is still on screen.
    ///
    /// The three categories with pages of their own are not handled here and never reach it — the
    /// sheet only opens for the other four, and their own deletes (`deleteRoutine`,
    /// `deleteWorkspace`, `deleteTask`) already exist on those pages.
    func deleteMemoryEntry(in category: MemoryCategory, at index: Int) {
        switch category {
        case .snippets:
            guard savedSnippets.indices.contains(index) else { return }
            deleteSnippet(savedSnippets[index])
        case .recentArtifacts:
            guard recentArtifacts.indices.contains(index) else { return }
            deleteRecentArtifact(recentArtifacts[index])
        case .clipboardHistory:
            guard clipboardHistoryItems.indices.contains(index) else { return }
            deleteClipboardHistoryItem(clipboardHistoryItems[index])
        case .approvedApps:
            guard approvedApps.indices.contains(index) else { return }
            forgetApprovedApp(approvedApps[index])
        case .outputLocations:
            guard outputLocations.indices.contains(index) else { return }
            forgetOutputLocation(outputLocations[index])
        case .resumableTasks:
            guard resumableTasks.indices.contains(index) else { return }
            deleteResumableTask(resumableTasks[index])
        case .routines, .workspaces, .taskHistory:
            return
        }
    }

    /// Continues the unfinished task at `index` of the list the Memory sheet rendered — the second
    /// door onto `continueResumableTask`, and the one that reaches a *declined* record (SONNY-282).
    ///
    /// **This door did not exist before SONNY-282, and the decision needs it to.** The sheet only
    /// ever deleted; a task the widget had stopped offering could therefore be reached by nothing
    /// but Delete, which would have made the cross a deletion with extra steps. The founder kept the
    /// record precisely so it could be picked up again, and this is where.
    ///
    /// By position into the same published array, for the reason `deleteMemoryEntry(in:at:)` gives.
    /// `.commandCenter`, because that is where the row is; the sheet closes on `true` and stays open
    /// on a refusal, the way the task-detail sheet does around `runTaskAgain`.
    @discardableResult
    func continueUnfinishedTask(at index: Int) -> Bool {
        guard resumableTasks.indices.contains(index) else { return false }
        return continueResumableTask(resumableTasks[index], origin: .commandCenter)
    }

    /// The four per-entry deletes' shared body.
    ///
    /// `errorMessage`, not `localStorageNotice`, and the distinction is the one CLAUDE.md's
    /// write-failure gotcha draws: the user pressed a control, and the thing they asked for did not
    /// happen. A *task's* bookkeeping write failing is the other case and goes to the notice.
    private func performMemoryEntryDelete(named noun: String, delete: () throws -> Void) {
        performMemoryStoreWrite(failureMessage: "Could not delete this \(noun)", write: delete)
    }

    /// Commits a write onto one of the Memory section's stores, and reloads the lists it publishes.
    ///
    /// **A write failure gets write-failure wording, never the load failure's** (`CLAUDE.md`, and a
    /// bug this repository has shipped once). "Could not be decrypted or decoded" belongs to
    /// `recordLocalStorageLoadFailure` and describes a file that will not open; after a press that
    /// tried to *change* a file, it names the wrong thing entirely.
    ///
    /// `setError` rather than `recordLocalStorageWriteFailure`, because every caller is a control the
    /// user pressed: the thing they asked for did not happen, which is what `errorMessage` means. The
    /// storage notice is for bookkeeping a *task* did on its own, where `errorMessage` would replace
    /// the result of a run that succeeded.
    private func performMemoryStoreWrite(failureMessage: String, write: () throws -> Void) {
        do {
            try write()
        } catch {
            setError("\(failureMessage): \(error.localizedDescription)")
            return
        }
        refreshMemoryEntries()
    }

    /// Creates, replaces, or removes a routine's schedule. Passing nil unschedules it.
    ///
    /// The two methods below can only *modify* an existing schedule — both open with a
    /// `guard let schedule = routine.schedule` — so this is the only path that brings one into
    /// existence. Callers should build the schedule with `RoutineSchedule.newlyCreated(...)`
    /// rather than the initializer, so the catch-up baseline is anchored; see that factory for
    /// what goes wrong otherwise.
    func setRoutineSchedule(_ routine: StoredRoutine, to schedule: RoutineSchedule?) {
        applySchedule(schedule, to: routine.name)
    }

    /// Commits an edited schedule from the detail view's draft.
    ///
    /// Takes the fields rather than a built `RoutineSchedule` on purpose: the view never
    /// constructs one, so the catch-up-baseline invariant cannot drift back into the UI where it
    /// was a trap. Everything goes through `RoutineSchedule.newlyCreated`, which is the single
    /// anchoring path.
    ///
    /// **Editing re-anchors the baseline, and that is deliberate.** Changing a daily routine from
    /// 9am to 7am in the afternoon would otherwise leave the old baseline in place, making today's
    /// 07:00 look outstanding and firing a run — or reporting a missed one — for a time the user
    /// just set. It is the same hazard creation has, reached through a different door. Anchoring at
    /// confirm time means a schedule always starts counting from the moment it became real.
    ///
    /// `isEnabled`, `unattendedTrusted` and `pausedReason` all carry over from the existing
    /// schedule: none is part of the draft, since each is a separate decision about a schedule
    /// rather than a field of one being composed.
    ///
    /// `pausedReason` carrying over matters more than it looks. Editing rebuilds the schedule from
    /// scratch, so before SONNY-31's review this door silently dropped it: changing a paused
    /// routine's run time left the routine switched off with the "Paused" caption and its
    /// explanation gone, which is exactly the unexplained-dead-routine state pausing exists to
    /// end, reached through the editor instead of the scheduler. Enabling remains the only thing
    /// that clears a pause — `newlyCreated` routes this through the same `setEnabled` as every
    /// other path, so an edit that also switches the schedule on still clears it.
    func commitScheduleDraft(
        for routine: StoredRoutine,
        cadence: RoutineCadence,
        hour: Int,
        minute: Int,
        weekday: Int,
        dayOfMonth: Int,
        now: Date = Date()
    ) {
        let existing = routine.schedule
        applySchedule(
            .newlyCreated(
                cadence: cadence,
                hour: hour,
                minute: minute,
                // Both are passed regardless of cadence so switching back and forth in the draft
                // does not silently discard a choice; `validate()` only checks the one that
                // applies.
                weekday: weekday,
                dayOfMonth: dayOfMonth,
                isEnabled: existing?.isEnabled ?? true,
                unattendedTrusted: existing?.unattendedTrusted ?? false,
                pausedReason: existing?.pausedReason,
                now: now
            ),
            to: routine.name
        )
    }

    /// Turns a routine's schedule on or off from the Routines row.
    ///
    /// Goes through `RoutineSchedule.setEnabled(_:now:)` rather than assigning `isEnabled`, because
    /// that is what re-anchors the catch-up baseline — enabling a 9am routine at 3pm must not read
    /// as "this morning was missed" and fire an immediate unattended run.
    /// Takes `now` for the same reason `commitScheduleDraft` and `checkScheduledRoutines` do: the
    /// re-anchor this performs is the thing under test in the resume path, and a test that cannot
    /// name the instant it anchored to has to compare against the wall clock.
    func setRoutineScheduleEnabled(_ routine: StoredRoutine, to isEnabled: Bool, now: Date = Date()) {
        guard var schedule = routine.schedule else {
            return
        }
        schedule.setEnabled(isEnabled, now: now)
        applySchedule(schedule, to: routine.name)
    }

    /// Turns the per-routine trust opt-in on or off — the grant that lets this routine's runs,
    /// scheduled and manual alike (SONNY-54), carry a tier-2 approval instead of pausing to ask —
    /// returning advisory copy when the routine currently assesses at tier 3+ and the grant
    /// therefore cannot cover it anyway.
    ///
    /// The advisory is a heads-up, never a gate — blocking the opt-in here would be the save-time
    /// tier gating this branch explicitly rejected. It is also best-effort: tiers escalate from
    /// real run-time conditions, so a routine that reads clean today can still pause its schedule
    /// (or prompt on a manual run) later.
    @discardableResult
    func setRoutineUnattendedTrust(_ routine: StoredRoutine, to isTrusted: Bool) -> String? {
        guard var schedule = routine.schedule else {
            return nil
        }
        schedule.unattendedTrusted = isTrusted
        applySchedule(schedule, to: routine.name)
        guard isTrusted else {
            return nil
        }
        return UnattendedTrustAdvisory.warning(forRoutineNamed: routine.name, executor: makeExecutor())
    }

    /// The approval decision a manual dispatch may carry on the user's standing per-routine trust
    /// grant: `.approved(.tier2)` when the prepared plan is exactly the canonical single-step
    /// run-routine shape and the named routine is trusted, `.notRequested` otherwise (SONNY-54).
    ///
    /// The routine is re-derived from the plan, never taken from a call site: the planner path
    /// only ever holds the step's `routineName` string, and `runRoutineWidget` deliberately
    /// round-trips through the same text command a user would type. The lookup goes through
    /// `routineStore.routine(named:)` — the identical normalized lookup
    /// `RunRoutineCapabilityAdapter` performs at execute time — so the routine this check reads
    /// and the routine that actually runs cannot resolve differently. Every failure (no such
    /// routine, unreadable store, missing name) yields `.notRequested`: a trust check that cannot
    /// complete relaxes nothing.
    ///
    /// Single-step on purpose: the grant covers the routine's own saved steps, so a planner-built
    /// plan wrapping `run_routine` alongside anything else keeps the full prompt — the extra steps
    /// were never part of what the user marked trusted.
    ///
    /// Internal rather than private so tests can pin the shape rules directly — the planner is not
    /// injectable at this level, so a mixed plan cannot be produced end-to-end in a test.
    func manualRoutineTrustDecision(for plan: AgentPlan) -> RiskApprovalDecision {
        guard plan.steps.count == 1,
              let step = plan.steps.first,
              step.operation == .runRoutine,
              let routineName = step.routineName,
              let routine = try? routineStore.routine(named: routineName),
              routine.schedule?.unattendedTrusted == true else {
            return .notRequested
        }
        return .approved(.tier2)
    }

    private func applySchedule(_ schedule: RoutineSchedule?, to routineName: String) {
        do {
            try routineStore.setSchedule(routineNamed: routineName, to: schedule)
            refreshSavedItems()
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this routine's schedule: \(error.localizedDescription)"
            )
        }
    }

    func runRoutineWidget(_ routine: StoredRoutine) {
        dispatch(command: "Run my \(routine.name) routine", autoExecute: true)
    }

    /// The workspace card's "New task here" action: bring the widget forward with an empty
    /// composer, bound to this workspace.
    ///
    /// Distinct from `openWorkspaceWidget` below, which synthesizes a literal command and runs it.
    /// This one starts nothing — it queues the binding and hands the user a cursor, which is the
    /// half of the founder decision ("started from its card") that had no affordance at all.
    ///
    /// Summons through `widgetPresentationRequest`, never `FloatingWidgetWindowController.show()`:
    /// SONNY-25 exists to remove the remaining direct callers and this must not add one.
    func beginTaskInWorkspace(_ workspace: StoredWorkspace) {
        pendingWorkspaceBinding = workspace.name
        command = ""
        widgetPresentationRequest += 1
    }

    /// Drops a queued card binding before anything has been submitted.
    ///
    /// Only ever clears the *pending* slot. A task already in flight keeps the scope it was
    /// assessed under — un-scoping mid-run would mean the approval the user answered and the
    /// execution that follows it disagreed about the boundary.
    func clearPendingWorkspaceBinding() {
        pendingWorkspaceBinding = nil
    }

    func openWorkspaceWidget(_ workspace: StoredWorkspace) {
        dispatch(command: "Open my \(workspace.name) workspace", autoExecute: true)
    }

    /// Submits one boundary change the workspace detail sheet already knows exactly — SONNY-64.
    ///
    /// **This dispatches where its predecessor composed, and that is the whole ticket.** Until now
    /// the sheet handed the widget composer a ready-made sentence and stopped, because
    /// `AgentViewModel` had no way to run a plan that a screen had built: the only routes to
    /// execution started from text, so "run this edit" meant "have the planner read this sentence
    /// back", and a planner misreading of *remove the folder ~/Documents/X* is a boundary change
    /// nobody typed. The pre-built path removes the reading step instead of trusting it. What the
    /// user approves is now, exactly and provably, what the row said.
    ///
    /// **It still writes nothing itself.** Every scope mutation goes through `edit_workspace`, so
    /// the tier-2 add and tier-3 remove consents — including SONNY-40's "no longer restricts … at
    /// all" — are the ones the command line raises, unchanged and unshortened. A store call here
    /// would be the second write path SONNY-41 adjudicated against; the sheet's one direct write is
    /// still `markWorkspaceAsTeam`, a display badge rather than a boundary.
    ///
    /// **It is not `fromComposer`, so an accepted dispatch kills any armed card binding** rather than
    /// inheriting one. An edit dispatched from workspace B's sheet while "New task here" is armed on
    /// workspace A would otherwise run bound to A while editing B, under a chip naming A. `start`
    /// does the killing; it is named here because the reason is this function's, not `start`'s.
    ///
    /// A *refused* dispatch leaves the arm alone, and that is the correct rule rather than a gap in
    /// this one. The arm's contract is that it binds the next composer dispatch, and a refusal means
    /// no dispatch happened — so the user's earlier "New task here on A" is still unconsumed and
    /// still what they asked for. Killing it here would silently discard an intent because an
    /// unrelated button was pressed at an unlucky moment.
    ///
    /// The arm is not hidden, but it is not necessarily on screen at the moment of the refusal
    /// either: `boundWorkspaceName` prefers the *in-flight* task's binding and falls back to the
    /// arm, so while the task that caused the refusal is still live the chip names that task's
    /// workspace and the arm reappears once it clears. Written out because "the arm stays visible"
    /// is the tempting summary and it is wrong for exactly the window this path runs in.
    ///
    /// **Refusals.** The clarification-pause door and the already-running door are both inherited
    /// rather than re-implemented: this goes through `dispatch`, so `canSubmit`'s terms apply to it
    /// exactly as they apply to the composer's own Send. That is deliberate — H1's lesson was that
    /// a per-surface copy of the rule is a gap waiting for the next surface, and a fourth copy here
    /// would be the fourth chance to write it slightly differently. The log line is the part that is
    /// this function's own, because a button that appears to do nothing needs a reason recorded
    /// somewhere.
    ///
    /// **Summons the widget on success, through `widgetPresentationRequest` and never
    /// `FloatingWidgetWindowController.show()`** (SONNY-25). Not decoration: under the consequence
    /// rule (2026-08-13) every sheet edit runs without asking, and the widget's result panel — with
    /// its ran-without-asking trace — is where that silent run is disclosed; the sheet is a modal
    /// over the very page whose Command Center surfaces would otherwise show it, and the floating
    /// widget is the one surface a modal cannot cover. (Before the rule, the same summon carried
    /// the approval prompt these edits used to raise; if a drift re-arm ever prompts mid-edit, it
    /// still does.)
    /// - Returns: whether the edit was submitted. The picker keeps itself open on `false` rather
    ///   than closing over a refusal — its controls are disabled while a task is in flight, so a
    ///   refusal here means the state changed between the render and the click, and dismissing would
    ///   leave the user with a dialog that closed and an edit that never happened.
    @discardableResult
    func dispatchWorkspaceScopeEdit(_ edit: WorkspaceScopeEditDispatch) -> Bool {
        let accepted = dispatch(
            command: edit.displayCommand,
            prebuiltPlan: EditWorkspaceCapabilityAdapter.plan(for: edit.request)
        )
        guard accepted else {
            // No message of its own any more: `dispatch` records the refusal for every door, and
            // this one's wording claimed "another task needs you", which is true of a pending
            // approval or an open clarification and false of a plain in-flight run where nothing
            // needs the user at all. One accurate line beats a specific inaccurate one. (PR #40
            // review, cycle 1 — the recorded observation, fixed while F5 was open in the same
            // function.)
            return false
        }
        widgetPresentationRequest += 1
        return true
    }

    func markWorkspaceAsTeam(_ workspace: StoredWorkspace) {
        var updated = workspace
        updated.teamType = .team
        do {
            try workspaceStore.save(updated)
            refreshSavedItems()
        } catch {
            setError("Could not update workspace: \(error.localizedDescription)")
        }
    }

    /// Permanently deletes a saved routine — steps, schedule, and run history all live under the
    /// same store key, so all three go together.
    ///
    /// Guarded on more than `isRunning`: a run paused at an approval still holds a prepared plan
    /// that re-reads the store when approved, so deleting out from under it has the same failure as
    /// deleting mid-run.
    ///
    /// **This guard is `isRunning || isAwaitingApproval`, which is the *running-indicator* gate, not
    /// the app's "task in flight" condition.** The doc used to call it the latter and cite
    /// `checkScheduledRoutines` as sharing it; that pointer went stale when the scheduler gained a
    /// third term (`clarificationQuestion == nil`, PR #80 review, F1), and it was loose even before
    /// — `isTaskInFlight` has always been the three-term property, and its own doc comment says the
    /// clarification term is the one that keeps getting left out. Corrected rather than widened:
    /// whether deleting a routine during a clarification pause should also be refused is a real
    /// question this round did not decide, and quietly changing the guard while fixing its comment
    /// would answer it by accident.
    ///
    /// `deleteLocalData`'s narrower `isRunning`-only guard predates even this convention and is left
    /// as it is here. `deleteWorkspace` points at this comment rather than repeating it.
    func deleteRoutine(_ routine: StoredRoutine) {
        guard !isRunning, !isAwaitingApproval else {
            setError("Finish or stop the current task before deleting this routine.")
            return
        }
        do {
            try routineStore.delete(routineNamed: routine.name)
            refreshSavedItems()
        } catch {
            setError("Could not delete routine: \(error.localizedDescription)")
        }
    }

    /// Permanently deletes a saved workspace. See `deleteRoutine` for the in-flight guard's
    /// rationale.
    func deleteWorkspace(_ workspace: StoredWorkspace) {
        guard !isRunning, !isAwaitingApproval else {
            setError("Finish or stop the current task before deleting this workspace.")
            return
        }
        do {
            try workspaceStore.delete(workspaceNamed: workspace.name)
            // An arm naming this workspace dies with it. The chip must never promise a boundary the
            // run will not apply: `resolveTaskScope` returns `.unscoped` for a name the store no
            // longer has, so leaving the arm alive would render "In X" over a task that runs
            // unscoped. Compared through the store's own folding rather than `==`, so the arm and
            // the record are matched the same way every other lookup matches them.
            if let armed = pendingWorkspaceBinding,
               (try? workspaceStore.workspace(named: armed)) == nil {
                pendingWorkspaceBinding = nil
            }
            refreshSavedItems()
        } catch {
            setError("Could not delete workspace: \(error.localizedDescription)")
        }
    }

    func runSuggestion(_ suggestion: RunSuggestion) {
        let url = URL(fileURLWithPath: suggestion.value)
        switch suggestion.kind {
        case .revealInFinder:
            finderRevealer([url])
        case .openFile:
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens Finder on the folder holding the files Sonny kept, with those files selected.
    ///
    /// **The founder's decision of 2026-08-23, recorded on SONNY-239: the user is told where the
    /// set-aside file is with a control, not with copy.** The confirmation says the file is still on
    /// their Mac and stops, which is disclosure they cannot act on — and writing the path into the
    /// sentence would satisfy the letter of "tell them where" and none of the intent, because
    /// `~/Library` is hidden in Finder by default. It also keeps a sentence explaining where Sonny
    /// stores its files out of the product, which is the founder's standing rule.
    ///
    /// **Every file the delete kept, not the first**, since the copy beside it already branches on
    /// how many there were and `activateFileViewerSelecting` selects an array.
    ///
    /// A no-op when the last delete kept nothing, so the control can be rendered off the same state
    /// the message is and does not need a second condition to stay in step with.
    func revealSetAsideFilesInFinder() {
        guard !setAsideFilesFromLastDelete.isEmpty else {
            return
        }
        finderRevealer(setAsideFilesFromLastDelete)
    }

    func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalSummary, forType: .string)
    }

    /// Wipes the in-memory half of "delete all local data": every slot that describes a task, so
    /// nothing the deleted files were about survives them on screen.
    ///
    /// **This enumeration is hand-written, and it has now been missed three times — read the rule
    /// below before adding a stored property to this class.** A new field does not arrive here on
    /// its own, the compiler cannot notice its absence, and the failure mode is never a crash: it is
    /// a stale sentence rendered next to an unrelated summary, which reads as a statement about that
    /// summary. The three:
    ///
    /// 1. `explicitWorkspaceBinding` — filed by SONNY-38's review against this same function.
    /// 2. `pendingWorkspaceBinding` — a new binding field one ticket later, the identical omission,
    ///    which is why the list below is written out rather than trusted.
    /// 3. `ranWithoutAskingTrace` — SONNY-99's trace, filed by PR #48's review. `deleteLocalData`
    ///    writes its own `finalSummary`, and `WidgetResultPanel` renders the trace under whatever
    ///    summary is showing, so a surviving trace put "nothing here is destructive" beneath the one
    ///    deliberately destructive action in the app.
    ///
    /// **The rule, now enforced rather than remembered:** every stored property on this view model
    /// is classified into exactly one of three sets — cleared here, refreshed by one of the three
    /// `refresh…` calls at the end of this function, or deliberately kept (dependencies, settings,
    /// surface preferences). `everyAgentViewModelStoredPropertyIsClassifiedAgainstTheLocalDataWipe`
    /// (`ProductShellTests`) reflects over the real instance and fails by name on any property in
    /// none of the three, so a fourth omission is a red test rather than a fourth review finding.
    /// Adding a field is therefore a decision, not an oversight: put it in a set, with its reason.
    private func clearInMemoryLocalDataState() {
        plan = nil
        suggestions = []
        approvalRequest = nil
        stepStatuses = [:]
        priorTaskContext = nil
        taskUsageSummary = .empty
        taskHistoryRecords = []
        // A finished run's summary is residue of a run whose record the wipe just erased, so it
        // goes with it rather than lingering in memory.
        completedRunNotice = nil
        // A pending request to open a task's detail would point at a row the wipe has just erased.
        taskDetailRequest = nil
        // The grants file is one of the stores the wipe erases, so an in-memory copy of its
        // contents goes with it (SONNY-202). `deleteLocalData` guards on `!isRunning` and this cache
        // is cleared at every session exit, so it is already `nil` here — cleared anyway, because
        // "already nil" is an argument about two other code paths and this is a property of one.
        approvedAppsForThisVisionIteration = nil
        // And the marker that describes an outcome goes with the outcome. `deleteLocalData` writes
        // its own message into `finalSummary` immediately after this returns, and a stale `true`
        // here would make *that* message un-collapsible for a notification nobody sent.
        outcomeWasNotified = false
        // Cleared with the records it filters, not left behind. A stale query over an emptied
        // history would put the Tasks page in its "No matching tasks — try a different word" state,
        // when the honest thing to tell someone who just erased everything is that there is nothing
        // there at all.
        taskHistoryQuery = ""
        clarificationQuestion = nil
        clarificationAnswer = ""
        clarificationAutoExecute = false
        clarificationWorkspaceBinding = nil
        clarificationSubmittedCommand = nil
        activeTaskScope = .unscoped
        ranWithoutAskingTrace = nil
        explicitWorkspaceBinding = nil
        pendingWorkspaceBinding = nil
        preparedRun = nil
        runner = nil
        pendingCommandForPriorTaskContext = nil
        pendingTaskHistoryStartedAt = nil
        preserveUsageForNextStart = false
        // The Memory section's own per-type delete message describes an action the whole-data wipe
        // has just superseded — "Deleted snippets — 1 file." beside a page where everything is now
        // gone. `deleteLocalData` writes its own message into `localDataDeletionStatusMessage`
        // straight after this returns, so the two never contradict each other.
        memoryDeletionStatusMessage = nil
        // The wipe has just deleted the set-aside files too (`deleteAllLocalData` sweeps them), so a
        // surviving record would leave a Reveal in Finder control pointing at files that are gone.
        lastPerRowDelete = nil
        // Row 13's three in-memory slots (SONNY-210; this said "two" while clearing three, corrected
        // by SONNY-235 while extending the block). The wipe has just erased the file all three
        // describe: a surviving checkpoint would write its task straight back on the next unit
        // boundary, a surviving arm would let a dispatch continue a record that no longer exists, and
        // a surviving decline set would silently suppress an offer for a record whose id can only
        // now belong to a different task.
        activeResumableTask = nil
        pendingResumableContinuation = nil
        declinedResumeOfferIDs = []
        // **Row 13's third in-memory slot, and it is the only one that can put a deleted file back**
        // (PR #184 review, F2). `deleteLocalData` guards on `!isRunning`, and a watcher check
        // deliberately does not set `isRunning` because it starts no task — so a wipe pressed while
        // a fetch is open is followed by that fetch's own write-back, and `saveWatcher` on a missing
        // file creates the directory and the file again. A user who presses delete-all-local-data
        // and gets their watchers back is a privacy failure rather than a bug in ordering, and this
        // branch is what makes it matter twice: the wipe's own sentence now promises to take
        // watchers.
        //
        // **Cancelling is half the fix and the other half is in `observeStandingWatcher`.** A
        // cancelled `Task` still runs its continuation, so the check must also *check* for
        // cancellation before it writes. Neither half works alone.
        abandonStandingWatcherCheck()
        watcherNotice = nil
        // The ids go with the records the wipe just deleted; keeping them would silence the first
        // notice of a watcher created afterwards that happened to reuse an id.
        notifiedWatcherIDs = []
        // And SONNY-235's four, for the reason `plan` and `stepStatuses` are cleared above rather
        // than for row 13's: this is what a surface renders about the run in flight, so a surviving
        // "17 of 40" would sit on a page where everything it counted has just been deleted.
        itemJobProgress = nil
        activeItemJobPlan = nil
        activeItemJobCompletedStepIDs = []
        activeItemJobFailures = []
        priorTaskContextStore.clear()
        taskUsageRecorder.reset()
        logStore.reset()
        // **Over every source, before the refreshes** (PR #110 review, F3). Those four reload ten of
        // the eleven load-failure sources between them; the one they never reach is
        // `.taskPlanDetails`, which only `storedPlanDetail(for:)` records. So a user who had pressed
        // Follow up on a task with an unreadable plan-detail file, and then wiped everything, was
        // told "Deleted 13 local data files." while the Task history row still read "Can't be read"
        // with a live Delete and the banner still said to go and clear a file that no longer existed.
        // The evidence check inside is what makes this safe: a file the wipe failed to delete keeps
        // its failure.
        clearLoadFailuresForStoresWhoseFileIsGone(LocalStorageLoadFailureSource.allCases)
        refreshSavedItems()
        refreshTaskHistory()
        // The lists the Memory section renders itself, unfinished tasks included. Without this the
        // wipe empties their files and leaves the page showing every entry it just erased — the same
        // staleness the three calls around it exist to prevent, on the surface that shows the most
        // of it.
        refreshMemoryEntries()
        refreshClipboardHistoryNotice()
        // The wipe deleted every store file, so nothing can still be unreadable. Reached by probing
        // rather than by emptying the set, for the same reason the load-failure sweep above checks
        // the disk: a file the wipe failed to delete keeps its damaged state.
        refreshStoreReadability()
    }

    private func startClipboardHistoryMonitoring() {
        // The master switch and the enterprise policy, asked at the one place monitoring can begin
        // — `refreshClipboardHistoryNotice`, `applyClipboardHistoryNoticeChoice` and
        // `finishRecordingPolicyIfSettled` all start it through here, so one guard covers three
        // callers and a fourth cannot forget it. The clipboard's *own* switch is checked by the
        // two callers that read settings, and again inside `poll()`, which fails closed.
        guard memorySettings.allowsRecording(in: .clipboardHistory) else {
            stopClipboardHistoryMonitoring()
            return
        }
        guard clipboardHistoryTimer == nil else {
            return
        }

        pollClipboardHistory()
        clipboardHistoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollClipboardHistory()
            }
        }
    }

    /// Surfaces a polling failure once rather than discarding it every second. Without this the
    /// clipboard toggle can read "on" while nothing is actually being recorded — a settings-read
    /// failure now fails closed in the monitor, so silence here would hide a privacy-relevant
    /// state from the user indefinitely.
    /// - Returns: whether this tick actually recorded a new clipboard item.
    ///
    /// Internal and answering rather than `private` and silent, so `MemoryCommandCenterTests` can
    /// drive a second tick and assert the negative half of SONNY-246's rule: a tick that recorded
    /// nothing reloads nothing. The timer ignores the answer.
    @discardableResult
    func pollClipboardHistory() -> Bool {
        do {
            // **Refreshed only when the poll actually recorded something** (SONNY-246). This runs
            // once a second; `poll()` returns `nil` for every tick where the pasteboard did not
            // change, was concealed, or held no text, and a reload on each of those would be sixty
            // pointless passes a minute over eight encrypted files — the six `refreshMemoryEntries()`
            // reads plus the two `refreshSavedItems()` adds — on the main actor. A non-nil answer is
            // exactly the case the Memory page's Clipboard history row is stale for. (It said "five"
            // until PR #110's review; `refreshMemoryEntries()` has always loaded six.)
            let recorded = try clipboardHistoryMonitor.poll() != nil
            if recorded {
                refreshMemoryEntries()
            }
            if clipboardHistoryPollFailure != nil {
                clipboardHistoryPollFailure = nil
                localStorageNotice = nil
            }
            return recorded
        } catch {
            let description = error.localizedDescription
            guard clipboardHistoryPollFailure != description else {
                return false
            }
            clipboardHistoryPollFailure = description
            recordLocalStorageWriteFailure(description)
            return false
        }
    }

    private func stopClipboardHistoryMonitoring() {
        clipboardHistoryTimer?.invalidate()
        clipboardHistoryTimer = nil
    }

    /// Records that this store's file will not read, republishing **only when that is news**.
    ///
    /// **The guard is the whole of this function's history** (PR #110 review, F1). It used to
    /// reassign unconditionally, which was harmless while the only readers were a page appearing and
    /// two deletes the user pressed. SONNY-246 gave it a caller that fires on every recorded
    /// clipboard item — up to once a second — and each reassignment was a fresh
    /// `localStorageNotice`, which `AppDelegate` sinks with no `removeDuplicates()` into
    /// `postStorageNoticeNotification`, whose `deliver` uses a fresh `UUID()` and therefore replaces
    /// nothing. With the founder's two broken files that was two Notification Center banners **per
    /// copy**, and the widget's own notice re-raised the moment after the user dismissed it. Before
    /// SONNY-246 a copy fired none of that.
    ///
    /// `clearLocalStorageLoadFailure` below has had the same guard all along, which is what made the
    /// asymmetry a bug rather than a design: clearing an already-clear source was silent and
    /// re-recording an identical failure was not.
    ///
    /// The consequence, stated rather than discovered: a store that fails identically twice leaves
    /// whatever is on the channel in between — a write failure's own sentence, say — standing.
    /// That is the intended reading. The condition has not changed, so there is nothing new to tell
    /// the user, and the row still says "Can't be read" with a live Delete either way.
    private func recordLocalStorageLoadFailure(_ source: LocalStorageLoadFailureSource, error: Error) {
        let detail = "\(source.label): \(error.localizedDescription)"
        guard localStorageLoadFailures[source] != detail else {
            return
        }
        localStorageLoadFailures[source] = detail
        publishLocalStorageLoadError()
    }

    private func clearLocalStorageLoadFailure(_ source: LocalStorageLoadFailureSource) {
        guard localStorageLoadFailures.removeValue(forKey: source) != nil else {
            return
        }
        publishLocalStorageLoadError()
    }

    /// Local-storage problems publish to `localStorageNotice`, never to `errorMessage`.
    /// `errorMessage` means "the task you just ran failed" — routing a corrupt-store notice
    /// there made a *successful* task render as a failure in the widget, since the widget picks
    /// `.failure` ahead of `.result`.
    private func publishLocalStorageLoadError() {
        guard !localStorageLoadFailures.isEmpty else {
            localStorageNotice = nil
            return
        }

        let details = LocalStorageLoadFailureSource.allCases
            .compactMap { localStorageLoadFailures[$0] }
            .joined(separator: "; ")
        // The headline names the *kind* of problem; each detail names the store and why that one
        // failed. It used to also hardcode "A local data file exists but could not be decrypted or
        // decoded.", which was the one distinguishing thing a detail carried back when the underlying
        // errors rendered as raw CryptoKit codes. SONNY-30 gave those errors that exact sentence as
        // their description, so the banner started saying it twice and the per-source detail
        // degraded to a repeat of the line above it (PR #41 cycle-3, R4). Dropping it here rather
        // than from the detail keeps the details distinguishable when two stores fail for *different*
        // reasons — a decrypt failure and a bad key are not the same problem and must not read alike.
        // **The way out, named** (SONNY-239, founder decision 2026-08-23). The banner used to end at
        // the details — accurate and useless in equal measure, since it says which file will not
        // open and nothing about what the person should do, and it returns on every launch. It is
        // appended only when at least one of the failed stores actually has a Memory row to act
        // from, so the sentence is never an instruction to press a control that is not there.
        //
        // The one store it stays silent for is the clipboard switch's own settings file, which the
        // Memory section deliberately does not list. That one is still recoverable from the same
        // page without this sentence: the Clipboard history row's switch commits through
        // `applyClipboardHistoryNoticeChoice`, which writes without loading and overwrites a file it
        // could not read.
        // **Counted over the failures this banner is naming, not over `unreadableStores`.** They
        // answer different questions: the row asks "can this row be read", and this asks "of the
        // stores I am telling you about, how many can the user act on". A banner that pluralised off
        // the other set would say "them" while naming one store.
        let rowsNamedHere = Set(localStorageLoadFailures.keys.compactMap(\.memoryCategory))
        let wayOut: String
        switch rowsNamedHere.count {
        case 0:
            wayOut = ""
        case 1:
            wayOut = " Open Memory in Command Center to clear it."
        default:
            // The founder's two broken files were two rows, and the singular pronoun then covered
            // both (PR #110 review). Small, and it is the sentence someone reads while deciding
            // whether the thing they are being told about is one problem or several.
            wayOut = " Open Memory in Command Center to clear them."
        }
        localStorageNotice = "Sonny could not load encrypted local data. \(details)\(wayOut)"
    }

    /// A local-store *write* failure, which needs its own accurate wording — the load-failure
    /// text ("could not be decrypted or decoded") describes the wrong problem entirely.
    func recordLocalStorageWriteFailure(_ description: String) {
        localStorageNotice = description
    }

    func makeInstantCommandResolver() -> InstantCommandResolver {
        InstantCommandResolver(
            snippetStore: snippetStore,
            recentArtifactStore: recentArtifactStore,
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            shortcutCatalog: shortcutCatalog
        )
    }

    /// A test-supplied vision substrate, or `nil` to build the live one.
    ///
    /// Injected rather than defaulted for the same reason every other machine-touching seam on this
    /// class is: the live environment posts real mouse events, and a test that reached it would move
    /// the developer's cursor. No test in this repo may construct `SystemScreenActionSynthesizer`.
    var visionSessionEnvironment: VisionSessionEnvironment?

    /// **The one screen-control billing gate** (SONNY-213), installed by `main.swift`.
    ///
    /// Set from outside rather than built here, and that is the same wiring `sessionDidChange` gets
    /// two lines away in `main.swift` and for the same reason: the gate needs the *shared*
    /// `EntitlementService`, which `SonnyAccountModel` owns because that is where the one real
    /// Keychain request is allowed to be made (`SignInSurfaceTests.onlyMainAsksForTheRealKeychain`
    /// pins that population at exactly two files). A view model that built its own would be a second
    /// service — a second clock anchor and a second single-flight refresh guard — and would need a
    /// third file to ask for the real Keychain.
    ///
    /// **The default refuses, and the default is the point.** A fixture that says nothing gets a gate
    /// that says no, so a test cannot silently acquire screen control by omission and a shipping
    /// build whose wiring line was deleted refuses rather than runs. `ClosedScreenControlGate`
    /// answers `allowanceUnknown`, which is the true sentence for a gate nobody asked anything.
    var screenControlGate: any ScreenControlGating = ClosedScreenControlGate()

    /// Internal rather than `private` so the vision extension in another file can build the
    /// executor a delegated plan runs through — the *same* executor factory the ordinary path uses,
    /// which is what makes "a delegated command meets the gate a typed one would" true by
    /// construction rather than by a parallel wiring that has to be kept in step.
    /// The whole runner a delegated instruction goes through — same executor factory, same planner
    /// factory, same log store, same artifact store as the ordinary path.
    ///
    /// One named door rather than widening `makePlanner` and `taskUsageRecorder` to internal: what
    /// the vision extension needs is a runner, not two fields, and keeping the construction in this
    /// file is what makes "a delegated instruction is planned by whatever would have planned the
    /// user's own sentence" true by construction rather than by a parallel wiring somebody has to
    /// keep in step.
    ///
    /// **It no longer throws** (SONNY-132). It did because the registry could fail to construct a
    /// selected provider; `PlannerFactory` cannot fail, and `PlannerFactory`'s own doc says why.
    func makeDelegationRunner() -> AgentRunner {
        AgentRunner(
            planner: makePlanner(
                // A delegated instruction is planned under the run it belongs to — same task id,
                // same retention answer — because it is the same task. `makeDelegationRunner`'s
                // whole argument is that a delegated command meets what a typed one would.
                backendTaskContext(recordingPolicy: taskRecordingPolicy),
                taskUsageRecorder
            ),
            executor: makeExecutor(),
            logStore: logStore,
            recentArtifactStore: recentArtifactStoreForThisRun,
            outputLocationStore: outputLocationStoreForThisRun
        )
    }

    /// Builds the live vision environment and keeps a handle on the pause wrapper the HUD writes to.
    ///
    /// The handle is why this is not inline: `pauseVisionSession()` needs the *same* monitor the
    /// running session is consulting, and a second one built later would be a Pause button wired to
    /// nothing. (The summary line above wrote this function's name without its parameter until
    /// PR #144's R3; it takes `recordingPolicy:` since SONNY-131.)
    /// - Parameter recordingPolicy: **already resolved**, never the Optional. It answers two
    ///   different questions that have to agree — which local stores this run writes to, and what
    ///   `retention` the vision route puts on the wire — and resolving it twice from two places is
    ///   how those two come apart. `makeExecutor` resolves it once and hands it to both.
    ///
    /// **No longer Optional** (SONNY-131): the vision client holds no credential, so there is nothing
    /// left that can fail to construct. `makeVisionEnvironment`'s own doc comment carries the reason
    /// and what it means for `visionUnavailable`.
    /// **Internal rather than private so a test can execute it at all** (PR #190's F2).
    ///
    /// `visionSessionJournalStoreForThisRun`'s doc a few thousand lines up records the standing
    /// problem: every vision test injects `visionSessionEnvironment` directly, so this function is
    /// never the thing under test and a mutation inside it survives the whole suite. PR #67 solved
    /// that once by lifting the journal decision *out* into a testable property. The gate has no
    /// decision to lift — it is a stored property handed straight over — so the alternative was for
    /// the one line carrying the product's only billing gate into a real session to stay held by
    /// nothing, which is what it was: replacing `screenControlGate:` below with a closed gate passed
    /// all 2722 tests. Widening this to internal is the smaller change and it closes the class rather
    /// than one instance.
    func makeLiveVisionEnvironment(recordingPolicy: TaskRecordingPolicy) -> VisionSessionEnvironment {
        let monitor = UserPausableAttentionMonitor(base: SystemSessionAttentionMonitor())
        let environment = Self.makeVisionEnvironment(
            interaction: self,
            // The shared client, not a second one: §3.3's single-flight refresh guard is state on
            // that actor, and a vision session is the only caller in this app that makes twelve
            // authenticated requests in a row — so it is the one most able to raise ten concurrent
            // 401s if the process ever held two clients.
            backendClient: backendClient,
            taskContext: backendTaskContext(recordingPolicy: recordingPolicy),
            usageRecorder: taskUsageRecorder,
            // **The one billing gate this process holds** (SONNY-213). It starts as
            // `ClosedScreenControlGate` and `main.swift` replaces it with the live one, so a build
            // that never wires it refuses screen control rather than allowing it. Read here at
            // session-construction time rather than captured once, for the reason the monitor beside
            // it is not: nothing swaps this at runtime today, and reading the current value keeps
            // that true if anything ever does.
            screenControlGate: screenControlGate,
            userPauseMonitor: monitor,
            // The seam row I already built: `VisionSessionEnvironment.journalStore` is Optional, and
            // a nil one runs the session normally and records nothing. So "Don't save this task"
            // withholds the store rather than adding a branch inside the loop — which the ticket's
            // never-touch list forbids, and which would have been a second place to forget.
            journalStore: visionSessionJournalStoreForThisRun
        )
        visionUserPauseMonitor = monitor
        return environment
    }

    /// - Parameter recordingPolicy: defaulted to this run's policy. The scheduled path passes
    ///   `.record` explicitly — see `performScheduledRun`.
    func makeExecutor(recordingPolicy: TaskRecordingPolicy? = nil) -> AgentActionExecutor {
        // Resolved here rather than left Optional, because it now decides two things that have to
        // agree: what the executor records locally, and what `retention` the vision route sends
        // (SONNY-131). Passing the resolved value to both is what keeps them one answer.
        let resolved = recordingPolicy ?? taskRecordingPolicy
        return makeExecutor(
            recordingPolicy: resolved,
            visionSession: visionSessionEnvironment ?? makeLiveVisionEnvironment(recordingPolicy: resolved)
        )
    }

    /// §2.4's two fields for one run: this run's `task_id`, and whether the backend may keep its
    /// content.
    ///
    /// **`recordingPolicy` is a parameter rather than a read of `taskRecordingPolicy`**, and that is
    /// the same care `makeExecutor` already takes for the same term. A scheduled run deliberately
    /// does not read the "Don't save this task" switch — it cannot have been pressed for a run the
    /// user did not start — so it passes `.record`, and reading the published property here would
    /// have sent `retention: "none"` for a routine that fired while the switch happened to be on
    /// for something the user was composing.
    ///
    /// The mapping is §10.1's, exactly: the switch is the only thing that produces `"none"`. The
    /// memory switches are about which local stores a run writes to and say nothing about what the
    /// backend keeps.
    func backendTaskContext(recordingPolicy: TaskRecordingPolicy) -> BackendTaskContext {
        BackendTaskContext(
            taskID: currentTaskID,
            retention: recordingPolicy.suppressesTraces ? .notStored : .standard
        )
    }

    /// A new task's identity: a fresh `task_id` and a cleared usage recorder, **together**.
    ///
    /// One function rather than three lines at each site, because the two things have identical
    /// lifetimes and the failure of letting them drift is silent in both directions — a stale id
    /// files this task's content under the last one's, and a stale recorder bills this task for it.
    private func beginNewTaskIdentity() {
        currentTaskID = UUID().uuidString
        taskUsageRecorder.reset()
        taskUsageSummary = .empty
    }

    /// The executor with its vision environment named by the caller. `nil` is the dry-run form for
    /// a resolver-built plan (SONNY-281, `locallyCompletedCommand`): a resolver plan never carries a
    /// vision step, and `makeLiveVisionEnvironment()` assigns `visionUserPauseMonitor` on the way —
    /// a side effect a routing decision must not have. Every run takes the overload above.
    private func makeExecutor(
        recordingPolicy: TaskRecordingPolicy?,
        visionSession: VisionSessionEnvironment?
    ) -> AgentActionExecutor {
        let resolvedRecordingPolicy = recordingPolicy ?? taskRecordingPolicy
        let taskContext = backendTaskContext(recordingPolicy: resolvedRecordingPolicy)
        return AgentActionExecutor(
            // A fresh executor per run, so this cannot leak into the next task.
            recordingPolicy: resolvedRecordingPolicy,
            // Never overridable by the caller, unlike `recordingPolicy` directly above: the
            // scheduled path deliberately passes `.record` because an unattended run cannot have
            // had "Don't save this task" pressed for it, but the memory switches are the user's
            // standing answer and apply to a scheduled run exactly as they do to a typed one.
            memoryRecording: memorySettings,
            whitelist: whitelist,
            zipArchiver: zipArchiver,
            documentConverter: documentConverter,
            browserOpener: browserOpener,
            appOpener: appOpener,
            fileOpener: fileOpener,
            mediaOpener: mediaOpener,
            finderContextReader: finderContextReader,
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            // **No `try?` and no degradation branch any more** (SONNY-130). Construction used to
            // throw for a missing `TAVILY_API_KEY` and `nil` fell back to
            // `UnavailableWebSearchProvider`; there is no key to miss now, so search is always
            // present and a call made with no session signed in fails at the request with a
            // sentence the user can act on. What the user sees when the backend is unreachable is
            // `feature/row-12-degradation`'s, which this leaves possible rather than decides.
            webSearchProvider: TavilySearchProvider(
                client: backendClient,
                taskContext: taskContext
            ),
            // Passed rather than defaulted for the first time: the executor's own fallback is now
            // `UnavailableWebResearchSynthesizer`, which refuses, because the lazy
            // environment-reading indirection it replaced had nothing left to read.
            webResearchSynthesizer: OpenAIWebResearchSynthesizer(
                client: backendClient,
                taskContext: taskContext,
                usageRecorder: taskUsageRecorder
            ),
            usageRecorder: taskUsageRecorder,
            // The monitor's own store, not a second one. The executor only *reads* clipboard
            // history, so while this parameter carried a default it read the real
            // `~/Library/Application Support/Sonny/clipboard-history.json` — including from every
            // fixture that had carefully injected a monitor at a temp root. Found by the compiler
            // the moment SONNY-350 removed the default, and fixed the way
            // `ClipboardHistoryMonitor.historyStore` says to: reading it back off the already
            // injected monitor cannot diverge from what recording writes.
            clipboardHistoryStore: clipboardHistoryMonitor.historyStore,
            snippetStore: snippetStore,
            runningAppSwitcher: runningAppSwitcher,
            recentArtifactStore: recentArtifactStore,
            shortcutCatalog: shortcutCatalog,
            shortcutInvoker: shortcutInvoker,
            shortcutRunHistoryStore: shortcutRunHistoryStore,
            resumableTaskStore: resumableTaskStore,
            // **The `reveal_in_finder` capability reveals through this view model's own
            // `finderRevealer`, not through one of its own** (SONNY-395). The control the user
            // presses and the capability a plan runs are the same act, so they get one seam: the
            // shipping app hands `atItsRealStoreLocations()`'s live closure to both, and a fixture
            // hands `hermeticFinderRevealer` to both.
            //
            // Before this line the executor took `CapabilityRegistry.default`, whose reveal
            // adapter called `NSWorkspace.activateFileViewerSelecting` inline — so a reveal inside
            // a *plan* went around the undefaulted seam this view model already had, and two
            // fixtures that were passing `hermeticFinderRevealer` correctly still opened four real
            // Finder windows per suite run, measured.
            capabilityRegistry: .revealing(with: finderRevealer),
            hotKeyReady: { [weak self] in self?.voiceHotKeyReady ?? true },
            // The published answer rather than a fresh read: `PermissionReadinessCapabilityAdapter`
            // is synchronous and this is the same value the Settings page is showing, so the tool
            // and the page cannot disagree about the account.
            modelAccessReadiness: { [weak self] in self?.modelAccessReadiness ?? .undetermined },
            // **`nil` now means only "this caller asked for no vision"** (SONNY-131) — the dry-run
            // resolver above is the one that does, and a vision session dispatched into that
            // executor fails loudly with `visionUnavailable` rather than half-running. It used to
            // also mean "`OPENCODE_API_KEY` is unset", which was a real state a real user could be
            // in; there is no key to be unset now, so `makeLiveVisionEnvironment` always builds one.
            // `visionSessionEnvironment` is still an injectable seam so a test supplies its own
            // substrate and never touches the machine.
            visionSession: visionSession
        )
    }

    private func startVoiceRecording(trigger: VoiceRecordingTrigger, origin: TaskOrigin) {
        guard canUseVoice else {
            reportVoiceRefusal()
            return
        }

        voiceRecordingOrigin = origin
        // Captured now, beside the origin, and never re-derived — `voiceRecordingPurpose` says why
        // the state at the transcript's arrival is the wrong thing to route on. The question's own
        // text goes with it, so delivery can tell "the question is still open" from "a question is".
        voiceRecordingPurpose = .forRecordingStarted(clarificationQuestion: clarificationQuestion)
        isPreparingVoiceRecording = true

        Task {
            let granted = await AudioCommandRecorder.requestMicrophonePermission()
            guard granted else {
                isPreparingVoiceRecording = false
                setError("Microphone permission was denied. Allow microphone access for the launching app, then try again.", persistent: true)
                return
            }

            if trigger == .hotKey && !isPushToTalkHotKeyDown {
                isPreparingVoiceRecording = false
                return
            }

            do {
                try audioRecorder.start()
                if trigger == .hotKey && !isPushToTalkHotKeyDown {
                    audioRecorder.cancel()
                    isPreparingVoiceRecording = false
                    return
                }

                isPreparingVoiceRecording = false
                isRecordingVoice = true
                errorMessage = nil
                switch voiceRecordingPurpose {
                case .command:
                    // A fresh recording is a fresh interaction — clear the *previous* task's
                    // leftovers now, not only once a real submission reaches `performStart`.
                    // Otherwise, if this new attempt fails before ever getting that far (e.g.
                    // transcription comes back with no text), the failure panel reuses
                    // `WidgetExistingStepRows` and renders the old, unrelated task's step rows
                    // above the new error — a real, reported bug.
                    finalSummary = ""
                    plan = nil
                    stepStatuses = [:]
                    suggestions = []
                case .clarificationAnswer:
                    // **Nothing is cleared, because nothing here is a leftover** (SONNY-283). The
                    // plan and its step statuses are the paused task's own, and the clarification
                    // panel is drawing them above the question this recording answers — wiping
                    // them would blank the panel the user is speaking into. The summary is that
                    // pause's "Clarification needed" line, and neither this nor
                    // `stopVoiceRecordingAndTranscribe` touches it, or the paused task's usage,
                    // while the question is open (PR #119 review, F4).
                    break
                }
                let recordingMessage: String
                switch (voiceRecordingPurpose, trigger) {
                case (.command, .hotKey):
                    recordingMessage = "Recording voice command from hotkey"
                case (.command, .button):
                    recordingMessage = "Recording voice command"
                case (.clarificationAnswer, .hotKey):
                    recordingMessage = "Recording voice answer from hotkey"
                case (.clarificationAnswer, .button):
                    recordingMessage = "Recording voice answer"
                }
                logStore.append(.observe, recordingMessage)
            } catch {
                isPreparingVoiceRecording = false
                setError(error.localizedDescription)
                logStore.append(.summarize, "Voice recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopVoiceRecordingAndTranscribe() {
        let recording: FinishedRecording
        do {
            recording = try audioRecorder.stop()
            isRecordingVoice = false
        } catch {
            isRecordingVoice = false
            isPushToTalkHotKeyDown = false
            setError(error.localizedDescription)
            return
        }

        Task {
            switch voiceRecordingPurpose {
            case .command:
                // A command is a fresh task, and its transcription is the first cost of it: the
                // recorder starts over here so the summary the run ends with is this task's alone.
                // **And the `task_id` starts over with it** (SONNY-130) — the transcription is the
                // first request this task makes, so it must already carry the id the run will use,
                // or the voice half of a task is filed under the previous task's key.
                // `performStart` sees `preserveUsageForNextStart` and keeps both.
                beginNewTaskIdentity()
                logStore.append(.act, "Transcribing voice command")
            case .clarificationAnswer:
                // **An answer belongs to the task that is paused, so nothing of that task's is
                // reset** (PR #119 review, F4). The recorder keeps the pause's own cost and the
                // transcription is added to it; `preserveUsageForNextStart` below then carries the
                // whole of it into the answer's `start()`, so the continuation's usage line is the
                // cost of the task the user asked for — the pause, the words, and the re-plan.
                // (A *typed* answer's `start()` resets instead, which predates this branch and is
                // left as it is.)
                logStore.append(.act, "Transcribing voice answer")
            }
            isTranscribingVoice = true
            errorMessage = nil
            defer {
                publishTaskUsageSummary()
                try? FileManager.default.removeItem(at: recording.url)
            }

            do {
                let transcriber = OpenAITranscriber(
                    client: backendClient,
                    // A transcription belongs to the task it begins, so it carries that task's
                    // retention answer too: a run the user started with "Don't save this task" on
                    // sends `retention: "none"` for their voice, which is the most personally
                    // sensitive of the four content types this branch moved.
                    taskContext: backendTaskContext(recordingPolicy: taskRecordingPolicy),
                    usageRecorder: taskUsageRecorder
                )
                let result = try await transcriber.transcribe(
                    audioFileURL: recording.url,
                    // How long the user held the key, not how long the file is — `FinishedRecording`
                    // says why the two differ once the recorder bounds itself.
                    recordedDuration: recording.heldFor
                )
                // Deliberately does *not* write `command` here. `dispatchTranscribedCommand` routes
                // through `dispatch`, which assigns it and clears it again if the dispatch is
                // refused — writing it first would reinstate exactly the residue this round removes,
                // for a transcription that completed into a clarification pause.
                if case .command = voiceRecordingPurpose {
                    // The previous task's summary, cleared for a new one. An answer's paused task
                    // keeps its "Clarification needed" line until the question is answered or
                    // cancelled (F4 again).
                    finalSummary = ""
                }
                isTranscribingVoice = false
                preserveUsageForNextStart = true
                // States only what is known here. "Sonny will act now" was written *before* the
                // dispatch and was contradicted by it whenever the dispatch was refused — a
                // transcription that completed into a pending approval left the spoken words gone,
                // no error set, and this sentence as the last thing said about them. What happens
                // next is `dispatch`'s to record, and it now does, on every door. (PR #40 review, F5.)
                logStore.append(.observe, "Transcript ready.")
                deliverTranscript(result.text, recordedFor: voiceRecordingPurpose, origin: voiceRecordingOrigin)
            } catch {
                deliverTranscriptionError(error)
            }
        }
    }

    /// Where a transcription that produced no transcript ends — the one seam, called by the real
    /// catch above and driven directly by tests, for the same reason `deliverTranscript` below is.
    ///
    /// **A stop is not a failure, and this route never asked** (SONNY-327). The catch this replaces
    /// called `setError(error.localizedDescription)` unconditionally, so it was not one of the call
    /// sites `SonnyBackendError.isCancellation` reaches — unlike `performStart`'s catch and
    /// `performApproval`'s, which both consult it. A cancellation arriving here rendered as "Sonny
    /// couldn't finish this one. Try again.", because `TranscriptionError.backend(.cancelled)`'s
    /// `errorDescription` is `SonnyBackendCopy.sentence(for: .cancelled)`.
    ///
    /// **Nothing can raise one today, and the guard is the point.** `stopVoiceRecordingAndTranscribe`
    /// runs the transcription in an unstructured `Task { }` that nothing stores, so
    /// `cancelCurrentRun`'s `currentTask?.cancel()` cannot reach it whatever the user presses. That
    /// — not the absence of a control — is what makes a cancellation unraisable here. Whether a
    /// transcription should be stoppable at all is a product question and SONNY-332's, not this
    /// seam's; what this seam does is make the day it becomes one a change to the recording surface
    /// rather than a wrong sentence nobody was watching for.
    ///
    /// **This used to add that `canCancel` is false throughout a *command* transcription, and that
    /// is false in reachable states** (PR #151 review, F2). `canCancel`'s third term is
    /// `isRunning && currentTask != nil`, and a recording does not block the scheduler: its guard
    /// is `!isRunning, !isAwaitingApproval, clarificationQuestion == nil`, all three of which a live
    /// recording satisfies, so a due routine fires mid-sentence and sets both. The mic stays
    /// pressable by design while recording (`isVoiceControlDisabled` carries `!isRecordingVoice`,
    /// so that an approval landing mid-sentence cannot trap the user in a live microphone), and
    /// neither exit re-checks — so the transcription that follows runs with a live stop control.
    /// `canSubmit` does not exclude `isRecordingVoice` either, so a row action started during the
    /// recording can park an approval and make the *first* term true as well. None of that is a
    /// defect today, because the press reaches the routine rather than the transcription; it is
    /// only the reason the enumeration above says nothing about controls.
    ///
    /// The predicate is consulted here rather than as a `catch let error where …` arm above so that
    /// the whole non-success exit has one call site and one test seam; a second arm would give the
    /// scan two regions to pin and the behaviour no more coverage.
    func deliverTranscriptionError(_ error: Error) {
        isTranscribingVoice = false
        guard !isCancellationError(error) else {
            logStore.append(.summarize, "Transcription canceled by user")
            return
        }
        // This is the bug that made the auto-clear timer feel broken: a failed
        // transcription (e.g. no speech captured) never calls `start()`, so it never
        // touches `lastCommand` — the old `hasRetryableCommand`-based gate treated that
        // exactly like a persistent config problem and refused to time it out. It isn't
        // one: try again and it's just as likely to work fine.
        setError(error.localizedDescription)
        logStore.append(.summarize, "Transcription failed: \(error.localizedDescription)")
    }

    /// Where a finished transcript goes — the one router, called by the real completion above and
    /// driven directly by tests (SONNY-283).
    ///
    /// Routes on the purpose the recording *started* with, never on the state it finds now;
    /// `voiceRecordingPurpose` gives both mismatches and why each is refused rather than re-routed.
    /// Internal rather than private for the reason `dispatchTranscribedCommand` is: the live path
    /// needs a real transcriber and an API key to reach it, and this is the seam a test drives
    /// instead.
    func deliverTranscript(
        _ transcript: String,
        recordedFor purpose: VoiceRecordingPurpose,
        origin: TaskOrigin
    ) {
        switch purpose {
        case .command:
            dispatchTranscribedCommand(transcript, origin: origin)
        case .clarificationAnswer(let question):
            answerClarificationWithTranscript(transcript, answering: question)
        }
    }

    /// Puts a transcript recorded *as an answer* into the clarification panel's answer field, for
    /// the user to send (SONNY-283, founder decision 2026-08-25: the mic and the hotkey both feed
    /// the answer field).
    ///
    /// **Feeds the field; does not send it.** The decision's own words are "feed the answer field",
    /// and its manual item is "confirm it lands in the answer field" — neither of which a transcript
    /// that submitted itself could satisfy. It is also the safer shape: a voice command auto-executes
    /// because a misheard command reaches a planner and a gate, but a misheard *answer* to "which
    /// folder?" is one keystroke from running against the wrong folder, and the field it lands in
    /// already has the caret, so sending is Return. Appended rather than replacing, the way dictation
    /// lands at the caret in the founder's reference product (Wispr Flow): a user who typed "the"
    /// and then spoke "Downloads folder" has "the Downloads folder", not the second half alone.
    ///
    /// **Dropped, with a log line, when the question it answers is no longer the one on screen** —
    /// cancelled while the user was mid-sentence, answered by typing before the transcript came
    /// back, or replaced by a second question inside the transcription's round trip (PR #119
    /// review, F3: a guard that only asked whether *a* question was open let the answer to the
    /// first land in the second one's field). Running it as a command instead is the
    /// auto-executing dispatch `voiceRecordingPurpose` exists to rule out, and there is no field
    /// that is rightly its.
    private func answerClarificationWithTranscript(_ transcript: String, answering question: String) {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clarificationQuestion == question else {
            // The transcription's usage was armed for the answer's own `start()`, which is not
            // coming. Left armed, it would be billed to whatever unrelated task runs next.
            preserveUsageForNextStart = false
            logStore.append(.observe, "Voice answer discarded: the question it answered is no longer open.")
            return
        }
        guard !spoken.isEmpty else {
            logStore.append(.observe, "Voice answer was empty.")
            return
        }
        let existing = clarificationAnswer
        if existing.isEmpty {
            clarificationAnswer = spoken
        } else if existing.last?.isWhitespace == true {
            clarificationAnswer = existing + spoken
        } else {
            clarificationAnswer = existing + " " + spoken
        }
        logStore.append(.observe, "Voice answer placed in the answer field.")
    }

    /// The dispatch a completed voice transcription issues for a *command* — the one
    /// implementation, called through `deliverTranscript` by the real completion above and driven
    /// directly by tests.
    ///
    /// Internal rather than private so it is reachable without a real transcriber and an API key,
    /// which is what the live path needs. It is a seam, not a reimplementation: there is exactly one
    /// copy of the guard and one `start(...)` call, so a test that exercises this exercises what
    /// ships.
    ///
    /// **The guard is here as well as in `canUseVoice` for a reason, not by belt-and-braces habit.**
    /// `canUseVoice` gates the *entry* points — the mic button and push-to-talk — but a
    /// transcription already in flight when a clarification arrives would still land here. Refusing
    /// at the dispatch makes the guarantee independent of that timing. **It is the only guard now**
    /// (SONNY-283): `isVoiceTransientlyBusy` dropped its clarification term so that a recording can
    /// *start* during a question, and a recording started then is delivered to the answer field and
    /// never here — so what reaches this guard is exactly the case it was written for, a command
    /// recorded before the question arrived.
    func dispatchTranscribedCommand(_ transcript: String, origin: TaskOrigin = .widget) {
        guard clarificationQuestion == nil else {
            logStore.append(.observe, "Voice command ignored while a clarification is open.")
            return
        }
        // Voice submitted from the widget's own mic *is* the composer, with the chip visible; from
        // anywhere else it is not. Routed through `dispatch` so a refusal for any *other* reason —
        // a run that started between the transcription and this call — leaves no residue either;
        // the guard above stays because it is the one this method's own contract names.
        dispatch(
            command: transcript,
            autoExecute: true,
            origin: origin,
            fromComposer: origin == .widget
        )
    }

    /// Resolves which workspace this task is in, and loads it into a scope.
    ///
    /// Two signals, in a fixed order. An **explicit binding** from a dispatch that already knows its
    /// workspace (B4's card action) wins; otherwise the name is resolved from the plan and command
    /// by `WorkspaceTaskTagging`, reused exactly as it stands. That resolver already matches
    /// `in [the|my] workspace X` — and, since SONNY-68, `in [the|my] X workspace` — against real
    /// saved names using the stores' own case/diacritic folding,
    /// with a documented leftmost-then-longest tie-break and deliberate non-`\b` boundary checks —
    /// writing a second matcher here would give one concept two behaviours, which is how "why did it
    /// tag that" bugs start.
    ///
    /// **This is the only site that calls it** (SONNY-191, SONNY-195). It used to say that
    /// `recordPriorTaskContext` "already makes" the same call for task history and that the
    /// difference was purely *when* — true, and the whole defect: a second derivation taken after
    /// the run terminated, from a signature that can see neither the binding above nor whether the
    /// store answered, so the row and the boundary disagreed in both directions. The row now reads
    /// this function's answer back off `activeTaskScope`; see `assessedWorkspaceName`.
    ///
    /// Returns `.unscoped` for a name that no longer resolves to a stored record — a workspace
    /// deleted between dispatch and assessment binds to nothing rather than to an empty boundary,
    /// because an empty `WorkspaceScope` would report `.unconstrained` for every kind and read as a
    /// workspace that restricts nothing rather than as no workspace at all.
    ///
    /// **A store that will not load is a different thing from a workspace that is not there, and this
    /// used to answer both the same way** (SONNY-78). The read was `try? workspaceStore.workspace(named:)`,
    /// which throws `.missingWorkspace` for absence and rethrows a file-read, AES-GCM authentication
    /// or JSON-decode failure — so an unreadable `workspaces.json` silently unbound the task, and
    /// `.unscoped` is not a smaller boundary but no boundary: `assessRisk` computes scope findings
    /// only when a workspace scope is present, so every out-of-scope advisory for that run vanished
    /// along with the sentence the ran-without-asking trace would have carried. `findWorkspace(named:)`
    /// (SONNY-30's primitive, added for exactly this distinction) answers `nil` only when the load
    /// succeeded and nothing matched.
    ///
    /// **A load failure says so and the run continues, rather than being refused.** It goes to this
    /// file's own load-failure channel, which publishes to `localStorageNotice` and never to
    /// `errorMessage` — a corrupt store is not this task failing. Refusing the dispatch was the
    /// alternative and is declined: since the consequence rule, a workspace scope gates no prompt at
    /// all (its escalation is `.advisory`), so a lost boundary costs legibility rather than
    /// permission, and blocking a task the user asked for in order to report a storage problem
    /// inverts escalate-never-block for no safety gain. What the user gets instead is the same
    /// banner every other unreadable store raises, naming this one.
    private func resolveTaskScope(command: String, plan: AgentPlan?) -> TaskWorkspaceScope {
        let resolvedName = explicitWorkspaceBinding ?? WorkspaceTaskTagging.resolvedWorkspaceName(
            command: command,
            plan: plan,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )
        // **A blank name is no name, and it must never reach the store** (PR #83, F1). `findWorkspace`
        // validates before it loads: `normalizedName` throws `.missingName` for a blank or
        // whitespace-only string *without touching the file*, so handing it one and reporting the
        // throw below would put "could not load encrypted local data" in front of a user whose store
        // is perfectly healthy.
        //
        // Reachable with no tampering at all. The planner schema requires a `workspaceName` slot on
        // every step and `""` is a valid value for it; nothing normalises blank to `nil` on the way
        // in; and `WorkspaceTaskTagging.directWorkspaceName` is `steps.compactMap(\.workspaceName).first`,
        // which reads the field off *any* operation rather than only the workspace ones. The
        // persisted form is worse than the transient one: `validateStepSafety` checks operations and
        // not fields, so a routine can be saved carrying a stray `""`, and `nestedRoutineWorkspaceName`
        // then reproduces it on every single run of that routine.
        //
        // Guarded here rather than caught below, so the store is never asked a question that has no
        // answer. It also leaves the `catch` honestly storage-only: `.missingName` is the one
        // non-storage error `findWorkspace` can raise, and this is what makes it unreachable from
        // there.
        guard let resolvedName,
              !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unscoped
        }

        let found: StoredWorkspace?
        do {
            found = try workspaceStore.findWorkspace(named: resolvedName)
            clearLocalStorageLoadFailure(.savedWorkspaces)
        } catch {
            recordLocalStorageLoadFailure(.savedWorkspaces, error: error)
            return .unscoped
        }

        guard let record = found else {
            return .unscoped
        }
        // The injected whitelist, not `WorkspaceScope`'s default: the scope's idea of a valid file
        // location and the executor's must come from one object, or a test-injected root would
        // assess under a scope that thinks the same path is inert.
        return .scoped(WorkspaceScope(workspace: record, whitelist: whitelist))
    }

    /// The product's one posture dial — Safe | Normal | Power, the founder's segmented control
    /// (SONNY-90 as amended 2026-08-14; wireframe `docs/wireframes/15-SegmentedControl.svg`).
    /// Safe asks before everything attended and is the only place the data-leaves-device label
    /// renders (E9's ratified §11.3 deviation); Normal is the consequence-rule default; **Power is
    /// the one mode that asks about no app at all** — row J, 2026-08-21. Two supersessions in
    /// order: this sentence first said row I's screen-control features would gate on Power, which
    /// the founder replaced on 2026-08-14 with "identical to Normal, gating nothing"; row J then
    /// gave Power a rule of its own, so the second version is false too. Screen control itself is
    /// still gated on no mode; what differs is *which apps* each mode drives without asking.
    /// Persisted so the dial survives relaunch — a posture that
    /// silently reset to Normal on restart would quietly un-dial itself. Defaults to Normal, the
    /// ratified product default.
    @Published var interactionMode: AgentInteractionMode = .normal {
        didSet {
            userDefaults.set(interactionMode.rawValue, forKey: UserDefaultsKeys.interactionMode)
        }
    }

    /// The third real approval-resolution point: a user answering a mid-loop vision approval.
    ///
    /// It is a real resolution by the flag's own definition — "the first time the user resolves
    /// *any* approval, allow or deny" — and a vision session is where a user is most likely to meet
    /// their first approval, since it is the one capability that asks mid-run.
    func markFirstApprovalCompleted() {
        hasCompletedFirstApproval = true
    }

    /// The authority context every dispatch threads into `AgentRunner` — the user's mode, and the
    /// per-app control standing for whatever this requirement is being derived about.
    ///
    /// **`interactionMode` is mapped to the engine here and nowhere else.** A second site reading
    /// its own value would be a second place that work has to find, and the one it misses would run
    /// a Safe-mode user's tasks under ordinary rules.
    ///
    /// **The engine's input is no longer a boolean, and this paragraph used to say it was**
    /// (PR #88 cycle 2, F3). It read "the engine's input stays row C's boolean seam; Normal and
    /// Power both map false" — the exact claim SONNY-142 deleted when it replaced `safeMode: Bool`
    /// with the whole `AgentInteractionMode`, precisely because two booleans cannot express three
    /// modes and row J needs Normal and Power told apart. It was also sitting on
    /// `markFirstApprovalCompleted`, several functions from the one it describes, which is how it
    /// survived a ticket that rewrote this seam.
    ///
    // Internal rather than `private`: the vision extension lives in another file and
    // `visionApprovalContext(targetBundleIdentifier:)` forwards to this one function, which is what
    // keeps the "mapped to the engine here and nowhere else" rule true across the split.
    /// - Parameter visionTarget: the bundle identifier of the app whose per-app standing this
    ///   context should carry, or `nil` when there is no per-app question to answer. **Not
    ///   defaulted, on purpose.** A default is how row I's resolver hook came to exist and never be
    ///   called: `nil` has to be an answer a caller gives, so that adding a call site is adding a
    ///   decision rather than inheriting one.
    ///
    ///   **Every plan-time caller answers `nil`, and that is the founder's ordering rather than an
    ///   omission** (2026-08-21, §4.3). The per-app question is asked inside the vision session,
    ///   after the first capture has cleared the screen check, because only a capture can reveal a
    ///   shell in a window whose *app* no name list refuses. A plan-time standing would raise the
    ///   question before that capture exists — which is the accidental-approval trap §4.3 closes —
    ///   and, since `AgentRunner.execute` re-derives the requirement, would also refuse to run the
    ///   session the user had just approved. The only non-`nil` caller is
    ///   `visionApprovalContext(targetBundleIdentifier:)`, inside the loop.
    func approvalContext(visionTarget: String?) -> ApprovalContext {
        // The mode travels whole (SONNY-142). It used to be folded through `asksBeforeEveryAction`
        // into a boolean here, which made Normal and Power indistinguishable to the engine —
        // correct while the engine distinguished two postures, and wrong the moment row J gave
        // Power a rule of its own.
        ApprovalContext(
            mode: interactionMode,
            appControl: AppControlResolver.standing(
                mode: interactionMode,
                targetBundleIdentifier: visionTarget,
                starterList: AppControlStarterList.bundleIdentifiers,
                // Fails closed to "no grants" when the file will not open, which can only *raise* an
                // ask — the safe direction for a requirement. A session needs the sharper answer and
                // asks `visionAppControlState` instead; both read through this one loader.
                approvedApps: loadApprovedAppsForGate().apps
            )
        )
    }

    /// The user's own grants, for the gate — **one read, two callers, so the two cannot disagree.**
    ///
    /// The load failure is surfaced rather than swallowed: the visible symptom of a swallowed one is
    /// Sonny asking about apps the user already allowed, which reads as the feature working badly
    /// rather than as a file that will not open. It goes through the same banner every other store's
    /// load failure uses, and clears itself when the file reads again.
    ///
    /// The failure is *returned* as well as recorded, because the two callers need different things
    /// from it. A requirement fails closed to "no grants", which can only raise an ask. A live
    /// session cannot: ending it as a withdrawal would tell the user they were no longer allowed
    /// when nothing was withdrawn (PR #88, F3).
    // Internal rather than `private`: the vision extension lives in another file and derives the
    // session's own state from this same read, which is what keeps the two answers from drifting.
    func loadApprovedAppsForGate() -> (apps: [ApprovedApp], failure: String?) {
        if let cached = approvedAppsForThisVisionIteration {
            return cached
        }
        return readApprovedAppsForGate()
    }

    /// Takes the one read this iteration will answer every gate question from.
    // Internal rather than `private`: `visionIterationWillBegin()` lives in the vision extension,
    // in another file, and is the only caller — the same split `loadApprovedAppsForGate` already
    // carries, and for the same reason.
    func cacheApprovedAppsForThisVisionIteration() {
        approvedAppsForThisVisionIteration = readApprovedAppsForGate()
    }

    /// The read itself, which is a file read plus an AES-GCM open plus a JSON decode.
    ///
    /// **The cache above is written only by `visionIterationWillBegin()`, never here**, and that
    /// asymmetry is what bounds its lifetime to one iteration (SONNY-202). A loader that populated
    /// its own cache would keep the answer alive after the loop stopped asking, and the next reader
    /// outside a session — a plan-time `approvalContext(visionTarget:)` — would get it. Today that
    /// caller passes `nil` and the resolver ignores the grants entirely, so nothing would go wrong;
    /// that is a fact about one call site rather than a property, and it is not what this rests on.
    private func readApprovedAppsForGate() -> (apps: [ApprovedApp], failure: String?) {
        do {
            let apps = try approvedAppStore.loadAll()
            clearLocalStorageLoadFailure(.approvedApps)
            return (apps, nil)
        } catch {
            recordLocalStorageLoadFailure(.approvedApps, error: error)
            return ([], error.localizedDescription)
        }
    }

    /// Records that the user has allowed Sonny to control this app, returning whether it was
    /// stored.
    ///
    /// **The only writer, and its only caller is the loop's per-app gate** — a grant is minted by
    /// the person answering that question and by nothing else. It used to be called from
    /// `approvePendingRun`, on any plan-level Allow whose plan happened to carry a vision target,
    /// which minted grants nothing on that panel had disclosed and which no standing was ever
    /// consulted for (PR #88, F2). Moving the question into the session moved the write with it, and
    /// the gate is now structural: no question, no write.
    ///
    /// `approve` returns `nil` when it refuses — a blank identifier, or an app the terminal deny list
    /// refuses — and that is reported as a failure here rather than ignored. It is unreachable
    /// today, because the deny list refuses at three doors above any session, but the reachability
    /// argument lives in another file and this makes the answer structural instead (PR #88, F5).
    func rememberAppControlGrant(bundleIdentifier: String, displayName: String) -> Bool {
        // **Allowed-apps memory switched off refuses the grant, and the session stops** (SONNY-208).
        //
        // `false` here means the caller ends the session — `VisionSessionRunner.resolveAppControl`
        // returns `.appControlNotRemembered`, whose sentence ("Sonny stopped because it could not
        // save that you allowed it to control X") is literally what has happened. Nothing weaker was
        // available without changing what `false` means to that gate, and its contract is the
        // fail-closed one: never run on a grant that does not exist.
        //
        // **This affects new apps only, which is exactly the switch's promise.** An app already on
        // the list settles at `.allowed` and returns before this method is reached, so existing
        // grants keep working until the user deletes them. Turning the type off stops Sonny keeping
        // *new* ones, and screen control on a not-yet-allowed app is what that costs.
        guard allowsRecording(to: .approvedApps) else {
            return false
        }
        do {
            guard try approvedAppStore.approve(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            ) != nil else {
                recordLocalStorageWriteFailure(
                    "Sonny did not save that you allowed it to control \(displayName)."
                )
                return false
            }
            return true
        } catch {
            // A *write* failure, which is a different thing from a load failure and must never
            // borrow its wording — "could not be decrypted or decoded" describes an existing file
            // that will not read back, which is the wrong problem entirely.
            recordLocalStorageWriteFailure(
                "Sonny could not save that you allowed it to control \(displayName): \(error.localizedDescription)"
            )
            return false
        }
    }

    private func executePreparedRun(
        preparedRun: PreparedAgentRun,
        runner: AgentRunner,
        approvalDecision: RiskApprovalDecision,
        confirmationMessage: String,
        logRiskAssessment: Bool
    ) async throws -> AgentRunResult {
        markAllSteps(.running)
        let result = try await runner.execute(
            preparedRun,
            approvalDecision: approvalDecision,
            confirmationMessage: confirmationMessage,
            logRiskAssessment: logRiskAssessment,
            // The same value the approval the user saw was built from. `execute` re-assesses fresh
            // on every call, so a `.unscoped` here against a scoped `approvalRequest` would have the
            // stale-approval guard comparing two different assessments. The context threads for the
            // same reason: one origin at the prompt and another at execution would derive two
            // different requirements from one run.
            scope: activeTaskScope,
            // `nil`, matching the prompt this execution is running under. `execute` re-derives the
            // requirement, so a standing here and none there would refuse to run the very session
            // the user had just approved.
            context: approvalContext(visionTarget: nil),
            // Row 13's progress channel (SONNY-210). Both halves are `nil`-by-default on the
            // executor and are supplied only here, on the foreground path — the scheduled path
            // passes neither, for the reason `beginResumableTask` records.
            //
            // The closure fires on the main actor from inside `executeChain`, which is
            // `@MainActor` like this type, and it is weak so that a view model torn down mid-run
            // cannot be resurrected by an executor still unwinding.
            onUnitCompleted: { [weak self] unit in
                self?.recordRunUnit(unit)
            },
            // SONNY-235's half of the same channel: an item of a job that could not be done. Weak and
            // main-actor for the identical reasons.
            onItemFailed: { [weak self] failure in
                self?.recordRunItemFailure(failure)
            }
        )
        markAllSteps(.complete)
        // The task itself succeeded; a bookkeeping failure is a storage notice, not a task error.
        if let artifactFailure = runner.lastRecentArtifactFailure {
            recordLocalStorageWriteFailure(artifactFailure)
        }
        if let outputLocationFailure = runner.lastOutputLocationFailure {
            recordLocalStorageWriteFailure(outputLocationFailure)
        }
        return result
    }

    private func approvePendingRun() {
        // **The vision branch first, and it must be first.** A mid-loop vision approval writes the
        // same `approvalRequest` every other approval writes — deliberately, so one approval surface
        // serves both — which means every Allow control in the app routes here while a session is
        // paused. The guard below would then fall through to `isRunning`, which is *true* during a
        // session, and silently do nothing: the user would press Allow and watch nothing happen.
        // Worse, if it did not, `preparedRun` and `runner` are the vision plan's own, so approving
        // would start a second vision session on top of the paused one.
        if let approvalRequest, visionApprovalContinuation != nil {
            resolveVisionApproval(approving: approvalRequest)
            return
        }
        // `isDeletingLocalData` for the reason `dispatch` gives: approving starts a run, and the
        // wipe is about to delete the stores that run would write into (PR #207's F3).
        guard !isRunning, !isDeletingLocalData, let preparedRun, let runner, let approvalRequest else {
            return
        }

        currentTask?.cancel()
        isRunning = true
        currentTask = Task {
            await performApproval(preparedRun: preparedRun, runner: runner, approvalRequest: approvalRequest)
        }
    }

    private func performApproval(
        preparedRun: PreparedAgentRun,
        runner: AgentRunner,
        approvalRequest: RiskApprovalRequest
    ) async {
        errorMessage = nil
        finalSummary = ""
        self.approvalRequest = nil
        hasCompletedFirstApproval = true

        defer {
            publishTaskUsageSummary()
            isRunning = false
            currentTask = nil
            // Guarded exactly as `performStart`'s is, and for the same reason: reaching this point
            // does *not* mean the task ended. `AgentRunner.execute` re-assesses on every call and
            // throws `.approvalRequired` whenever the re-assessed tier exceeds the tier the user
            // approved — the ordinary state-drift class, "the zip already exists" landing between
            // the approval and the execution. The catch below re-arms `approvalRequest`, which is a
            // second pause, not a terminal exit.
            //
            // Clearing there would hand the *second* approval's execution `.unscoped`: the run would
            // still proceed (an unscoped re-assessment can only be lower, so the stale-approval
            // guard still passes) but the workspace boundary would not be applied to it — no nested
            // forwarding, no scope escalation in the trace. That is the same outcome-invisible shape
            // as mutation B3, arriving on a real code path instead of a mutated one.
            // `self.` is load-bearing: this function's own parameter is also called
            // `approvalRequest` and is never nil, so an unqualified read here would shadow the
            // published property and the guard would never fire — the clear would stay effectively
            // unconditional while looking guarded.
            if self.approvalRequest == nil {
                activeTaskScope = .unscoped
                explicitWorkspaceBinding = nil
            }
            finishRecordingPolicyIfSettled()
        }

        do {
            let result = try await executePreparedRun(
                preparedRun: preparedRun,
                runner: runner,
                // `answering:` rather than a bare tier: the decision now carries the escalation
                // reasons this exact prompt showed, so `AgentRunner.execute`'s re-check can tell a
                // second, different tier-3 cause apart from the one the user actually read
                // (SONNY-62). The request passed here is the one that was on screen — the same
                // object `performApproval` received — which is what makes the recorded consent a
                // record of what was consented to rather than of what was merely true at the time.
                approvalDecision: .approved(answering: approvalRequest),
                confirmationMessage: "User approved \(approvalRequest.assessment.effectiveTier.displayName) action",
                logRiskAssessment: true
            )
            finalSummary = result.summary
            suggestions = result.suggestions
            var recordedTaskID: String?
            if let pendingCommandForPriorTaskContext {
                recordedTaskID = recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .completed,
                    summary: result.summary,
                    // Same reason as `performStart`'s completed path: the provenance travels with
                    // the result, and an approved run reaches storage through this second door.
                    resultProvenance: result.summaryProvenance,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            publishCompletedRunNoticeIfUnreported(result.summary, taskID: recordedTaskID)
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
            refreshSavedItems()
        } catch let error where isCancellationError(error) {
            markAllSteps(.canceled)
            finalSummary = "Canceled."
            logStore.append(.summarize, "Canceled by user")
            if let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .canceled,
                    summary: finalSummary,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
        } catch RiskApprovalError.approvalRequired(let request) {
            markAllSteps(.pending)
            self.approvalRequest = request
            finalSummary = "Approval needed before Sonny can act."
            logStore.append(.confirm, "Approval required for \(request.assessment.effectiveTier.displayName)")
            if let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .approvalNeeded,
                    summary: finalSummary
                )
            }
        } catch {
            markAllSteps(.failed)
            setError(error.localizedDescription)
            logStore.append(.summarize, "Stopped: \(error.localizedDescription)")
            if let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .failed,
                    summary: error.localizedDescription,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
        }
    }

    /// Returns the task-history row id this call wrote, or `nil` when it wrote none.
    ///
    /// - Parameter resultProvenance: who wrote `summary` (SONNY-147). Defaults to `.codeAuthored`,
    ///   which is correct for every caller here except the two that pass an `AgentRunResult`'s own
    ///   summary — those forward `result.summaryProvenance`, which the adapter that authored the
    ///   text set. The declaration is made where the text is written, not here; this parameter only
    ///   carries it the last hop to storage.
    @discardableResult
    private func recordPriorTaskContext(
        command: String,
        preparedRun: PreparedAgentRun,
        status: PriorTaskOutcomeStatus,
        summary: String,
        resultProvenance: StoredTaskResult.Provenance = .codeAuthored,
        startedAt: Date? = nil
    ) -> String? {
        // **The request, not the prompt** (SONNY-248). Four readers, and the fourth was missing from
        // this list until PR #109's review found it: the Tasks list names a row by this; the
        // follow-up chip says "Following up: …" with it; `runTaskAgain` resubmits it; and
        // `followUpOnTask` builds a `PriorTaskContext` from the row, so it reaches a later planner
        // inside `plannerContextText`. Two labels and two payloads — which is also why
        // `ClarifiedCommand.request(in:)` matches the whole question-and-answer pair rather than one
        // line, since a false positive here truncates a command rather than a caption.
        //
        // **Why Run again re-runs the request, stated correctly this time** (PR #109 review F1).
        // The first version of this reasoned by analogy to `runTaskAgain` re-requesting an approval,
        // and the analogy does not transfer: a re-request is a *safety* property, there because the
        // world may have changed since the approval was granted, while a clarification answer is
        // *intent* and does not go stale. The real reason is plainer. This value is the row's label
        // and the row's payload at once, so the control on that row must submit the thing the row
        // shows; submitting a longer string the user was never shown would make the product do
        // something other than what it displayed. Nothing is lost by it — what the answer produced
        // is in the plan the row stores — and a task that is still ambiguous gets asked again, which
        // is the honest state rather than a stale answer applied to a new attempt. Pinned by
        // `runningAClarifiedTaskAgainSubmitsExactlyWhatItsRowShows`.
        let recordedCommand = ClarifiedCommand.request(in: command)
        priorTaskContextStore.record(
            command: recordedCommand,
            plan: preparedRun.plan,
            outcome: PriorTaskOutcome(status: status, summary: summary, provenance: resultProvenance)
        )
        priorTaskContext = priorTaskContextStore.currentContext()
        return recordTaskHistoryIfTerminal(
            command: recordedCommand,
            status: status,
            startedAt: startedAt,
            result: StoredTaskResult.declaring(resultProvenance, text: summary),
            plan: preparedRun.plan
        )
    }

    /// Returns the task-history row id this call wrote, or `nil` when it wrote none.
    ///
    /// The overload for a run that never reached a prepared plan. It stores the result the same way
    /// and stores no plan detail, which is exactly what a follow-up on such a task will find: the
    /// command and the outcome, and nothing about a plan that was never produced.
    @discardableResult
    private func recordPriorTaskContext(
        command: String,
        status: PriorTaskOutcomeStatus,
        summary: String,
        resultProvenance: StoredTaskResult.Provenance = .codeAuthored,
        startedAt: Date? = nil
    ) -> String? {
        // The overload above's decision, restated here because this one records the same two things
        // for a run that never reached a plan (SONNY-248).
        //
        // **Held by a test of its own since PR #109's review, which found it held by none** (F2).
        // Reverting this line to `command` passed the entire suite: every clarification test reached
        // the *other* overload, because a clarified run that gets as far as a plan has a
        // `preparedRun`. This one is reached from `performStart`'s catch when the re-plan itself
        // throws — an offline planner, a missing key — and it wrote the whole prompt, scaffolding
        // included, into the history row and the prior-task context. Pinned by
        // `aClarifiedRunThatFailsBeforeItPlansStillRecordsTheRequest`.
        let recordedCommand = ClarifiedCommand.request(in: command)
        priorTaskContextStore.record(
            command: recordedCommand,
            outcome: PriorTaskOutcome(status: status, summary: summary, provenance: resultProvenance)
        )
        priorTaskContext = priorTaskContextStore.currentContext()
        return recordTaskHistoryIfTerminal(
            command: recordedCommand,
            status: status,
            startedAt: startedAt,
            result: StoredTaskResult.declaring(resultProvenance, text: summary),
            plan: nil
        )
    }

    /// The workspace this run was **actually bound to**, for its history row — `nil` when nothing
    /// bound it.
    ///
    /// The founder's decision of 2026-08-21: a task's history record shows the workspace the run ran
    /// in, not the one the user meant. So it reads `activeTaskScope` — the answer `resolveTaskScope`
    /// already produced and the same value `AgentRunner.execute` was handed — rather than deriving
    /// the name a second time.
    ///
    /// **It was that second derivation, and it was wrong in both directions.** Both
    /// `recordPriorTaskContext` overloads called `WorkspaceTaskTagging.resolvedWorkspaceName` again
    /// after the run terminated, from a signature that cannot see a binding and never learns whether
    /// the store answered:
    ///
    /// - **Under-tagged** (SONNY-195): a dispatch bound through `explicitWorkspaceBinding` — the
    ///   workspace card's "New task here" — whose command never names the workspace resolved no name
    ///   at all. A run that really was scoped filed under nothing, while the widget's own chip said
    ///   "In Research" for the whole of it.
    /// - **Over-tagged** (SONNY-191): `directWorkspaceName` reads `AgentStep.workspaceName` straight
    ///   off the plan with no store access, so a plan naming a workspace that had been deleted — or
    ///   whose store would not decrypt, or whose name was blank — resolved that name anyway, and the
    ///   workspace card's task count included runs it had never scoped.
    ///
    /// Reading the scope answers both by construction rather than by two derivations happening to
    /// agree: `.unscoped` is exactly the set of runs no boundary applied to, whatever the cause.
    ///
    /// **`activeTaskScope`, not `lastAssessedScope`**, though both are live at every call site.
    /// `lastAssessedScope` is deliberately never cleared, so a run that threw inside
    /// `AgentRunner.prepare` — before `performStart` resolves a scope at all — would inherit the
    /// *previous* task's workspace. `activeTaskScope` is `.unscoped` again at the top of every
    /// `performStart`, is held across an approval or clarification pause, and is cleared in a
    /// `defer` that runs after every one of these writes.
    private var assessedWorkspaceName: String? {
        guard case .scoped(let scope) = activeTaskScope else {
            return nil
        }
        return scope.workspaceName
    }

    /// Returns the id of the row it wrote, or `nil` when it wrote none — suppressed, non-terminal,
    /// or the write failed. The caller needs that id to name this run's task in a notification, and
    /// it must come from here: re-deriving it afterwards as "the newest row" is not sound, because
    /// `completedAt` persists at whole-second resolution and two runs finishing in the same second
    /// tie under a non-stable sort (PR #67 cycle-3, defect B).
    @discardableResult
    private func recordTaskHistoryIfTerminal(
        command: String,
        status: PriorTaskOutcomeStatus,
        startedAt: Date?,
        result: StoredTaskResult,
        plan: AgentPlan?
    ) -> String? {
        // **Row 13's settle, first and above every guard below** (SONNY-210).
        //
        // *Why here.* This is the one function every foreground outcome passes through carrying its
        // own status — both `recordPriorTaskContext` overloads end in it, and those two are called
        // from every terminal and every pause in `performStart`, in `performApproval`, and from all
        // three of `cancelCurrentRun`'s exits. A settle attached to those call sites instead would
        // be a dozen places to remember, which is precisely the write-path enumeration this
        // repository has paid for twice.
        //
        // *Why above the guards.* Both of them would drop a settle that has to happen. The status
        // guard refuses `.prepared`, which is the preview-only exit — terminal, and its record must
        // go. The memory guard refuses a suppressed or memory-disabled run, and a run whose *record*
        // is withheld must still clear a record an earlier run left; a settle that inherited that
        // guard would leave Sonny offering to continue a task that had already finished.
        settleResumableTask(for: status)

        // **The Memory section's lists, reloaded on the same signal** (SONNY-246), and above the
        // same guards for a related reason.
        //
        // *Why here.* Almost nothing the Memory page shows is written by this view model. Output
        // locations and recent artifacts are written by `AgentRunner` and the executor; a saved
        // snippet is written by a capability adapter; all of it happens inside `MacAgentCore` while
        // the page is on screen. `refreshMemoryEntries()` had exactly one call site in the view
        // layer — Memory's own `.onAppear` — and SwiftUI fires that when a view is *inserted*, not
        // while it stays mounted. So the page was fully responsive to everything the user did on it
        // and blind to the one case it exists to display: the founder wrote a note into `~/Documents`
        // with Memory open, watched nothing happen, and had to leave the page and come back. This is
        // the one function every foreground outcome passes through, which is why the resumable-task
        // settle above it is here too.
        //
        // *Why above the guards.* Both would drop refreshes that have to happen. The status guard
        // refuses `.prepared`, and the memory guard refuses a suppressed run — but suppression
        // withholds *trace* stores only, so a run with "Don't save this task" on can still have
        // saved a snippet or created a workspace, and a refresh that inherited that guard would
        // leave the row that changed showing the old number.
        //
        // *What it costs, measured rather than guessed.* `refreshMemoryRowsAfterRun()` is three
        // calls: `refreshSavedItems()`, `refreshMemoryEntries()` and `refreshStoreReadability()`.
        // **18.4 ms, median of ten passes** on a deliberately heavy tree — min 18.2, max 19.3 —
        // broken down as 6.1 for saved items, 4.3 for the memory lists and 8.9 for the readability
        // probe. The tree: every capped store at its cap (clipboard history 100 items of 10 000
        // characters, a 1 011 740-byte file; recent artifacts 100; output locations 50), the
        // uncapped ones at 100 each (snippets, allowed apps, routines, workspaces), and 500
        // task-history rows at 343 930 bytes — six times the founder's own 55 KB, and a twentieth of
        // that store's 10 000 cap. 1.47 MB in total. Measured at 2440938 with a throwaway harness,
        // deliberately not committed: a timing assertion in this suite would be a flake.
        //
        // **The probe re-reads eleven files the other two calls just read, and that duplication is
        // bought deliberately** (PR #110 fix-round review). Readability has to come from one place
        // or the row's words and its Delete disagree, which they did — and the loaders cannot supply
        // it, because three of the fourteen stores have no load-failure source and so were invisible
        // to anything derived from those. 12 ms of the 18 is that decision.
        //
        // **No ratio against task history, and the missing one is the point.** The obvious
        // comparison is `refreshTaskHistory()` on this same path, whose neighbourhood records 130 ms
        // at the cap — but `TaskHistoryStore`, where that figure comes from, attributes it to
        // `record(_:)`: a decode, a re-encrypt and a write, not a load. Dividing one by the other
        // compares different work; measured here, that load is 4.3 ms on the same tree. What can be
        // said without measuring the wrong thing: this is tens of milliseconds after a run has
        // already finished, with nobody waiting on it, and on a suppressed or preview-only run —
        // where `refreshTaskHistory()` is never called — it is the whole of the cost rather than an
        // addition to someone else's.
        //
        // The one duplicated read is unfinished tasks, which a run carrying a checkpoint has just
        // reloaded inside the settle above; the ordering is worth it, since a refresh placed before
        // the settle would publish a checkpoint the settle was about to delete.
        if status.endsTheRun {
            refreshMemoryRowsAfterRun()
        }

        guard [.completed, .failed, .canceled].contains(status),
              let startedAt else {
            return nil
        }

        // Task history is a `.trace` store, so a suppressed run writes no row at all. Note the
        // consequence for a screen-control run: with no row written there is nothing for a deleted
        // journal to dangle from, so suppression creates no dangling link.
        guard allowsRecording(to: .taskHistory) else {
            return nil
        }

        let record = CompletedTaskRecord(
            // **This run's own id, rather than the fresh UUID the initializer would default to**
            // (SONNY-130, contract §5.1). The default is evaluated per call and would therefore
            // arrive *after* every request the task made, leaving the backend's retained content
            // filed under one key and this row under another — and `DELETE /v1/tasks/{task_id}`
            // with nothing to join them on.
            id: currentTaskID,
            command: command,
            startedAt: startedAt,
            completedAt: Date(),
            outcomeStatus: status,
            // Read off the scope the run was assessed under, for the reason the line below already
            // gives about `trigger`: a parameter restating something this type already knows is a
            // second thing to forget to pass, and both ways of forgetting it happened
            // (SONNY-191, SONNY-195). See `assessedWorkspaceName`.
            workspaceName: assessedWorkspaceName,
            // Derived from origin rather than threaded through every call site — origin
            // already records who started this run, and a second parameter saying the same
            // thing is a second thing to forget to pass.
            trigger: activeTaskOrigin == .scheduled ? .scheduled : .manual,
            // The link, written on every terminal exit including the failures — a link
            // present only on clean finishes would be missing from exactly the runs someone
            // most wants to read afterwards. `nil` for every task that ran no session, which
            // is every task the product had before row I.
            visionSessionID: activeVisionSessionID,
            // What the run produced, on every terminal exit for the same reason (SONNY-147): a
            // failed run's text is the one a user most wants to read back, and a cancelled run
            // still says "Canceled." rather than nothing.
            result: result,
            // **The link to this task's unfinished-run record, read *after* the settle above** — so
            // it is the id of a record that survived, and `nil` whenever there is nothing to carry
            // on with. A completed or cancelled run had its record deleted three lines up and
            // therefore writes no link; a failed run kept its record and writes one, which is what
            // lets `runTaskAgain` recognise this row's task after a relaunch (PR #105 re-check, F1's
            // fourth door). The ordering is load-bearing: read before the settle, every row would
            // claim a link to a record that was about to be deleted.
            resumableTaskID: activeResumableTask?.id
        )

        do {
            let evictedTaskIDs = try taskHistoryStore.record(record)
            recordTaskPlanDetail(for: record, plan: plan, evictedTaskIDs: evictedTaskIDs)
            refreshTaskHistory()
            return record.id
        } catch {
            // **A lost row is a storage problem, not a failed task** (SONNY-201), so it goes to
            // `localStorageNotice` with its own write wording — matching `recordScheduledTaskHistory`,
            // which is the same failure on the unattended path and already answered this way, and
            // matching `recordTaskPlanDetail` one line above, which PR #89's F4 moved for the same
            // reason.
            //
            // It called `setError`, and the cost is the one `publishLocalStorageLoadError`'s own doc
            // comment records: `errorMessage` means "the thing you asked for did not happen", and the
            // widget picks `.failure` ahead of `.result` — so a task that ran and produced its result
            // showed "Could not save task history: …" where that result belonged. The run happened;
            // what is lost is the row.
            //
            // **A heavier loss than the plan write's, and still not a task failure.** A failed plan
            // write leaves the task fully visible and only its plan missing; a failed row write
            // leaves it absent from the Tasks list, from search, from Insights, and from anything a
            // follow-up could be aimed at. That is worth saying plainly, which is what the wording
            // does — it is not worth saying in the slot that means the task itself failed.
            recordLocalStorageWriteFailure(
                "Sonny could not save this task to task history: \(error.localizedDescription)"
            )
            logStore.append(.observe, "Could not record task history: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes this task's plan beside its row, and drops the plans of the rows that write evicted.
    ///
    /// **After the row, never before.** The row is the only thing that makes a plan detail
    /// reachable — `TaskPlanDetailStore` is keyed on `CompletedTaskRecord.id` and has no other index
    /// — so a detail written first and then orphaned by a failed row write would be unreachable
    /// bytes nothing could ever delete through the product. This is the write-side mirror of
    /// `deleteTask`'s dependents-first rule, and it points the same way: the row bounds the
    /// dependent's reachability in both directions.
    ///
    /// **The eviction handoff is not an optimisation.** `TaskHistoryStore.record(_:)` returns the
    /// ids it evicted, and they are dropped in this same write. Without it the two stores would only
    /// stay level while every row had a plan — and a run that failed before preparing one writes a
    /// row with no detail, so the detail store would fill more slowly, evict later, and keep the
    /// plans of tasks the user can no longer see. "Same cap, same eviction" is the founder's
    /// requirement of 2026-08-17; this is what makes it true rather than approximately true.
    ///
    /// **A failure here is reported on the storage channel and never as this task failing** (PR #89
    /// cycle 2, F4). It is a *write* failure and gets write wording, and it goes to
    /// `recordLocalStorageWriteFailure` — `localStorageNotice` — exactly as its scheduled twin does.
    ///
    /// It used to call `setError`, and `publishLocalStorageLoadError`'s own doc comment already
    /// records what that costs: routing a storage notice into `errorMessage` makes a *successful*
    /// task render as a failure, because `FloatingWidgetView` picks `.failure` ahead of `.result`.
    /// So a task that ran, produced its result and wrote its row would show "Could not save this
    /// task's plan" where its result belonged. A plan-persistence failure is a **degraded
    /// follow-up**, not a failed task: the run happened, the row landed, and what is lost is that a
    /// later follow-up will have this task's command and outcome but not its plan. Reported rather
    /// than swallowed, because that consequence is narrow and worth saying — just not in the slot
    /// that means "the thing you asked for did not happen".
    private func recordTaskPlanDetail(
        for record: CompletedTaskRecord,
        plan: AgentPlan?,
        evictedTaskIDs: [String]
    ) {
        // Classified `.trace`, so it is withheld by the same switch that withheld the row. Asked
        // explicitly rather than inferred from having got past the row's own guard: the reach of
        // "Don't save this task" is a rule read off `LocalStore.kind`, and a store that relied on a
        // sibling's guard would be the one store the rule did not actually cover.
        guard allowsRecording(to: .taskPlanDetails) else {
            return
        }

        do {
            guard let plan, let taskID = record.id else {
                try taskPlanDetailStore.delete(ids: evictedTaskIDs)
                return
            }
            try taskPlanDetailStore.save(
                StoredTaskPlanDetail(taskID: taskID, completedAt: record.completedAt, plan: plan),
                evictedTaskIDs: evictedTaskIDs
            )
        } catch {
            recordLocalStorageWriteFailure("Sonny could not save this task's plan: \(error.localizedDescription)")
            logStore.append(.observe, "Could not record this task's plan: \(error.localizedDescription)")
        }
    }

    // MARK: - Unfinished tasks (row 13, SONNY-210)

    /// Checkpoints the run that is about to happen, so that an interruption leaves something to
    /// carry on from.
    ///
    /// **Written before anything runs, which is the whole mechanism.** A record created at the end
    /// of a run could only ever describe runs that reached an end, and the case this exists for is
    /// the one that does not: the laptop closes, the app is quit, the process dies. So the record
    /// goes down first and is *removed* when the run finishes — which makes "a record still on disk"
    /// mean "this run never finished", with no code needed at the moment of the interruption, where
    /// there is none to run.
    ///
    /// **Both memory switches, because a foreground run passes through the composer.** This is not
    /// the scheduled path's question — see below — so it asks `allowsRecording(to:)`, the conjunction
    /// of "Don't save this task" and the standing Memory switches. The store is classified `.trace`,
    /// so a suppressed run writes nothing here and therefore raises no offer, which is the switch
    /// keeping its promise rather than an omission.
    ///
    /// **A scheduled routine writes no record here at all, and that is a decision** rather than a
    /// path nobody wired. Two reasons, either sufficient:
    ///
    /// - `performScheduledRun`'s own contract is that "every property that surface UI reads as *your
    ///   last task* is deliberately untouched here", because the user did nothing and nothing they
    ///   are looking at should change. This offer is exactly such a surface — a proactive panel that
    ///   raises itself the next time they open the widget — and a task they never started must not
    ///   be what interrupts them. It is the same argument `recordScheduledTaskHistory` already makes
    ///   for keeping a background run out of `PriorTaskContext`.
    /// - There would be nothing to resume *from*. A scheduled run prepares the one-step
    ///   `run_routine` plan `RunRoutineCapabilityAdapter.plan(forRoutineNamed:)` builds, so it has
    ///   exactly one unit; the routine's own steps run as a nested plan, which reports nothing by
    ///   construction. "Continue" could only mean "run the whole routine again", which is what the
    ///   next occurrence already does.
    ///
    /// The consequence, stated so nobody has to re-derive it: a scheduled routine that fails partway
    /// reports itself through `scheduledRunNotice` and its paused schedule, exactly as before, and
    /// never through this offer. `aScheduledRoutineRunLeavesNoUnfinishedTaskRecord` pins it.
    ///
    /// - Parameter continuing: what this run inherits from a record already in flight, when the
    ///   dispatch said it is carrying one on. Its id and `startedAt` are kept so a task interrupted
    ///   twice stays one entry that began when the user first asked for it; its
    ///   `chainedArtifactPath` is carried only by a *resume*, which is rejoining a chain a finished
    ///   unit had already fed.
    private func beginResumableTask(
        command: String,
        plan: AgentPlan,
        startedAt: Date,
        continuing: ResumableTaskContinuation?
    ) {
        guard allowsRecording(to: .resumableTasks) else {
            return
        }
        let now = Date()
        let task = ResumableTask(
            id: continuing?.id ?? UUID().uuidString,
            // **The request, not the prompt** (SONNY-248). This field is a label — `remainingPlan()`
            // is what a resume actually runs, and `ResumableTask.command`'s own doc says nothing
            // re-plans from it — and the label is read back in the founder's own sentence, "You were
            // partway through …". A clarified run's prompt carries the exchange behind the request,
            // and the offer squeezes a command onto one line and cuts it to sixty characters, so a
            // short request would leave Sonny quoting its own question back at the user.
            command: ClarifiedCommand.request(in: command),
            plan: plan,
            // Empty, always. A resumed run's plan *is* the remainder, so its finished steps are the
            // ones that are no longer in it — carrying the old ids forward would subtract them
            // twice. A restart has done nothing yet either.
            completedStepIDs: [],
            chainedArtifactPath: continuing?.chainedArtifactPath,
            startedAt: continuing?.startedAt ?? startedAt,
            updatedAt: now,
            // The value a record keeps when nothing ever settles it, which is the honest description
            // of an interruption: there is no code running at the moment the lid closes to write
            // anything more specific. A run that *fails* is stamped `.failed` by the settle.
            stopReason: .interrupted
        )
        // **A continuation spends a decline, here and nowhere else** (SONNY-282; PR #119 review,
        // F2). The record above is written afresh with no `declinedAt`, so the disk now says "offer
        // this if it stops again" — and the session set has to say the same, or the widget stays
        // silent about it until the next launch. This is the one site every continuation door
        // reaches — the offer's Continue and Memory's (`.resuming`), the failure panel's Retry and
        // the Tasks row's Run again (`.restarting`) — which is why the remove is here rather than
        // in whichever door happened to be written first. A task of its own (`continuing == nil`)
        // has a fresh id and nothing to un-decline.
        if let continuing {
            declinedResumeOfferIDs.remove(continuing.id)
        }
        activeResumableTask = task
        writeResumableTask(task, describing: "could not save what this task was partway through")
    }

    /// Records that another unit of this run's plan finished.
    ///
    /// Asked through `allowsRecording(to:)` again rather than inferred from a checkpoint existing.
    /// The reach of a suppression is a rule read off `LocalStore.kind`, and this repository's
    /// standing habit — `recordTaskPlanDetail` and `recordScheduledTaskPlanDetail` both do it — is
    /// that a store relying on a sibling's guard is the one store the rule does not cover.
    ///
    /// **Only one of the two terms can change mid-run, and the other is kept anyway.** The Memory
    /// switches are standing preferences the user can turn off from Command Center while a run is in
    /// flight, so that term is live. `taskRecordingPolicy` is not: "Don't save this task" is a
    /// pre-dispatch toggle (`dontSaveButton` renders only when `!isTaskInFlight`), and a suppressed
    /// run has no checkpoint for this function to append to in the first place — the guard's own
    /// first term returns.
    ///
    /// So a mutant swapping this for `allowsScheduledRecording(to:)` — the memory switches alone —
    /// **survives the suite, and it is an equivalent mutant rather than a coverage gap** (SONNY-210's
    /// battery, M3 at `e0d4c78`). It is recorded rather than closed with a test that drives this
    /// function directly: such a test would assert a state the app cannot reach, and the conjunction
    /// is kept because it fails closed and because a per-site subtraction of a term is exactly the
    /// shape `allowsRecording(to:)` exists to stop anyone writing.
    /// One finished unit of the run in flight, on its way to two places that are not the same place.
    ///
    /// Progress is updated unconditionally; the durable checkpoint is written only if the user's
    /// memory switches allow it. Both from one call site, because a unit reaching one of them and not
    /// the other is exactly the kind of divergence that is invisible until somebody turns a switch
    /// off (SONNY-235).
    private func recordRunUnit(_ unit: CompletedRunUnit) {
        activeItemJobCompletedStepIDs.append(contentsOf: unit.stepIDs)
        refreshItemJobProgress()
        recordResumableTaskUnit(unit)
    }

    /// One item of a job that could not be done. Same two destinations, same split (SONNY-235).
    private func recordRunItemFailure(_ failure: ItemJobFailure) {
        activeItemJobFailures.append(failure)
        refreshItemJobProgress()
        recordResumableTaskItemFailure(failure)
    }

    /// Appends a failed item to this run's checkpoint, so a job interrupted at item thirty still
    /// tells the user that item three failed when they come back to it.
    ///
    /// The guard is `recordResumableTaskUnit`'s, for its reasons: a run with no checkpoint — a
    /// suppressed run, or unfinished-task memory switched off — has nothing to append to, and the
    /// failure is still on the run's own result and in `itemJobProgress` either way.
    private func recordResumableTaskItemFailure(_ failure: ItemJobFailure) {
        guard var task = activeResumableTask, allowsRecording(to: .resumableTasks) else {
            return
        }
        task.itemJobFailures.append(failure)
        task.updatedAt = Date()
        activeResumableTask = task
        writeResumableTask(task, describing: "could not save which items this task could not do")
    }

    private func refreshItemJobProgress() {
        guard let plan = activeItemJobPlan else {
            itemJobProgress = nil
            return
        }
        itemJobProgress = ItemJobProgress.of(
            plan: plan,
            completedStepIDs: activeItemJobCompletedStepIDs,
            failures: activeItemJobFailures
        )
    }

    private func recordResumableTaskUnit(_ unit: CompletedRunUnit) {
        guard var task = activeResumableTask, allowsRecording(to: .resumableTasks) else {
            return
        }
        task.completedStepIDs.append(contentsOf: unit.stepIDs)
        task.chainedArtifactPath = unit.chainedArtifactPath
        task.updatedAt = Date()
        activeResumableTask = task
        writeResumableTask(task, describing: "could not save how far this task got")
    }

    /// Ends this run's checkpoint the way its outcome requires.
    ///
    /// Three answers, and the middle one is the feature:
    ///
    /// - **Completed, cancelled, or preview-only — deleted.** The task is over. Cancelling counts as
    ///   over because the user pressed stop; offering to continue what they just stopped would be
    ///   the product arguing with them.
    /// - **Failed — kept, and stamped `.failed`.** This is the founder's second shape: an error at
    ///   step 7 of 10, picked up from 7 rather than restarted. The steps that finished are still
    ///   finished, so the record keeps them and the offer resumes from there.
    /// - **Approval or clarification needed — untouched.** Not a terminal state. The record stays
    ///   exactly as it is, which is what makes a question the user walks away from resumable after a
    ///   relaunch.
    ///
    /// A policy refusal arrives here as `.failed`, so it is kept, and continuing it will be refused
    /// again with the same message. That is a true description of the state — the task really is
    /// unfinished — and the alternative is a settle that reads the summary text to guess at a cause.
    private func settleResumableTask(for status: PriorTaskOutcomeStatus) {
        guard let task = activeResumableTask else {
            return
        }
        switch status {
        case .approvalNeeded, .clarificationNeeded:
            return
        case .failed:
            var failed = task
            failed.stopReason = .failed
            failed.updatedAt = Date()
            activeResumableTask = failed
            writeResumableTask(failed, describing: "could not save where this task stopped")
        case .completed, .canceled, .prepared, .dryRun:
            activeResumableTask = nil
            do {
                try resumableTaskStore.delete(id: task.id)
            } catch {
                recordLocalStorageWriteFailure(
                    "Sonny could not clear the record of a task that has now finished: \(error.localizedDescription)"
                )
                logStore.append(.observe, "Could not clear an unfinished-task record: \(error.localizedDescription)")
            }
            refreshResumableTasks()
        }
    }

    /// The one writer, so that the failure channel and the refresh are decided once.
    ///
    /// **`recordLocalStorageWriteFailure`, never `errorMessage`.** Every write through here is a
    /// task's own bookkeeping rather than something the user pressed a control for, and CLAUDE.md's
    /// rule is exact about the difference: `errorMessage` means "the thing you asked for did not
    /// happen", and the widget picks `.failure` ahead of `.result` — so a bookkeeping failure routed
    /// there would replace the result of a task that ran and succeeded. That defect has arrived
    /// through two other doors already (PR #89's F4 and SONNY-201); this is a third door and it does
    /// not repeat it.
    ///
    /// A refused plan (`ResumableTaskStoreError.planTooLarge`) reports through the same channel and
    /// leaves `activeResumableTask` set. That is deliberate: the run carries on, the later unit
    /// writes retry the same refusal and say so at most once more per unit, and what is lost is the
    /// offer rather than the task.
    private func writeResumableTask(_ task: ResumableTask, describing what: String) {
        do {
            try resumableTaskStore.save(task)
        } catch {
            recordLocalStorageWriteFailure("Sonny \(what): \(error.localizedDescription)")
            logStore.append(.observe, "Could not record an unfinished task: \(error.localizedDescription)")
        }
        refreshResumableTasks()
    }

    /// Re-reads the unfinished-task list.
    ///
    /// Called after every write this view model makes and at launch, so the widget's offer and the
    /// Memory row are both describing the file rather than a memory of it. A load failure empties
    /// the list and raises the load-failure banner, the same choice `refreshTaskHistory` and
    /// `loadMemoryEntries` make: a surface still offering to continue a task whose file will not
    /// decrypt is the surface contradicting itself.
    func refreshResumableTasks() {
        do {
            resumableTasks = try resumableTaskStore.loadAll()
            clearLocalStorageLoadFailure(.resumableTasks)
        } catch {
            resumableTasks = []
            recordLocalStorageLoadFailure(.resumableTasks, error: error)
        }
    }

    /// Carries on with what is left of an unfinished run — the widget offer's Continue.
    ///
    /// **It dispatches the remaining steps through the ordinary path, and that is the safety
    /// argument.** `prebuiltPlan` replaces planning only: the run rejoins at `prepare`, so the
    /// assessment, the approval gate, the prompt, the trace events and the history row are the ones
    /// an equivalent typed command would have produced. Nothing here is a way past a gate — a
    /// resumed plan is re-assessed from scratch against the world as it is now, which is what makes
    /// re-running an interrupted unit safe to offer at all.
    ///
    /// `.resumedTask` rather than `.directUserAction`: these steps came from wherever the original
    /// run's did, and claiming a stronger origin than that is the one thing `PreparedPlanSource`
    /// exists to prevent.
    ///
    /// - Parameter origin: which surface's Continue this is. **Two doors as of SONNY-282**: the
    ///   widget's offer passes `.widget`, and the Memory sheet's row passes `.commandCenter`, each
    ///   stated at its call site per `.claude/rules/macagent-ui-conventions.md` — a task-submitting
    ///   entry point passes its own real origin rather than inheriting a default. It matters here:
    ///   `hasVisibleWidgetPanel` gates the widget's working and result panels on `.widget`, so a
    ///   Continue pressed in Command Center that claimed `.widget` would move its progress into the
    ///   widget while Command Center kept showing its own.
    /// - Returns: whether the dispatch was accepted, so the caller can tell a refusal apart from a
    ///   start rather than re-deriving `canSubmit`'s rule.
    @discardableResult
    func continueResumableTask(_ task: ResumableTask, origin: TaskOrigin) -> Bool {
        // **The same gate the offer is filtered by, asked again here** (PR #105 review F5). Neither
        // surface renders Continue for a record that must not be repeated silently, so this is the
        // belt: `mayBeOfferedForResume` is the whole rule, and a third entry point added later
        // cannot route around it by holding a `ResumableTask` from somewhere else. A *declined*
        // record passes it on purpose — declining withholds the widget's offer and nothing else, and
        // continuing from Memory is exactly what the founder kept the record for (SONNY-282).
        guard task.mayBeOfferedForResume else {
            logStore.append(.observe, "Not continued: finishing this task could repeat something Sonny must not do twice.")
            return false
        }
        // Armed for this dispatch only. `start()` spends it before its own guards and drops it if
        // the dispatch is refused, so it can never be inherited by a later, unrelated run.
        pendingResumableContinuation = .resuming(task)
        let started = dispatch(
            command: task.command,
            origin: origin,
            // **The file the earlier attempt wrote, written into the plan before it is
            // dispatched** — not handed to the executor at run time, which was tried and is wrong:
            // `AgentRunner.prepare` previews every step and rejects a bare `open_generated_artifact`
            // long before execution, so a value supplied later cannot be seen by the gate that runs
            // first. Baking it also keeps the assessment honest, since the file being opened is part
            // of what gets assessed. A no-op for every remainder that does not begin with such a
            // step, and `ChainedArtifactCarry` is the one place that rule lives.
            prebuiltPlan: ChainedArtifactCarry.applying(
                // Not `chainedArtifactPath` — see `ResumableTask.chainedArtifactPathForRemainder`.
                // For an ordinary plan the two are the same value; for a job the carry is withheld
                // when it would cross an item boundary, because applying it here puts it in the plan
                // before `executeChain` runs and no reset inside that loop can take it back out
                // (PR #185, F2(b)).
                task.chainedArtifactPathForRemainder,
                toLeadingStepOf: task.remainingPlan()
            ),
            prebuiltPlanSource: .resumedTask
        )
        guard started else {
            pendingResumableContinuation = nil
            return false
        }
        // **Continuing does not decline — it un-declines, and that is deliberate.** The obvious
        // extra line here would mark the offer answered so it cannot reappear — and it would be
        // wrong for the case that matters: a resumed run that fails *again* would then have no offer
        // for the rest of the session, even though the task is still unfinished and the record is
        // still on disk. Nothing needs it, either. While the run is live `resumeOffer` is silent on
        // `!isTaskInFlight`; if it succeeds the record is deleted; if it fails, the widget shows the
        // failure, which outranks the offer until the user has read it.
        //
        // The opposite line *is* needed (SONNY-282), and it lives in `beginResumableTask` rather
        // than here (PR #119 review, F2): a task the user declined on the widget and then picked up
        // — from Memory, from the failure panel's Retry, or from Run again on its Tasks row — is a
        // task they have re-engaged with, and all three doors reach the one site that writes the
        // record afresh with no `declinedAt`. The session set is un-declined there, so the disk
        // and the widget cannot disagree whichever door was used.
        return true
    }

    /// Arms the **next** dispatch to continue the unfinished-run record a *history row* names, when
    /// it names one (PR #105 re-check, F1's fourth door).
    ///
    /// **Why this cannot be `armRestartOfTaskInFlight()`, which is the whole of the design here.**
    /// That helper arms whatever `activeResumableTask` holds, and it is sound for the two doors it
    /// serves because each of those is *by construction* the run that just paused or just failed.
    /// This door is neither: it takes an arbitrary historical record off the Tasks page, and it can
    /// run after a relaunch, when `activeResumableTask` is `nil` while the record and its row both
    /// survive on disk. Arming blindly there would merge two different tasks into one record — the
    /// opposite defect — and arming from the in-memory handle would simply do nothing after a
    /// relaunch, which is the case the user is most likely to be in.
    ///
    /// So the answer is durable and exact: `CompletedTaskRecord.resumableTaskID`, written when the
    /// row was, matched against the published list this view model loads at launch.
    ///
    /// **What it does not cover, stated rather than left to be found.** A row written before that
    /// field existed carries `nil` and re-runs as a fresh task — nothing can invent the link after
    /// the fact, and the natural key that could approximate it is the `(command, startedAt)` pair
    /// `CompletedTaskRecord.id` exists because it collides. A record already deleted from Memory or
    /// past its idle period is not found either, which is correct: there is nothing to carry on
    /// with. And a *scheduled* run's row never carries a link, because that path writes no resumable
    /// record at all.
    ///
    /// A no-op in every one of those cases, so the caller does not have to ask.
    private func armRestartOfRecordedTask(_ record: CompletedTaskRecord) {
        guard let linked = record.resumableTaskID,
              let task = resumableTasks.first(where: { $0.id == linked }) else {
            return
        }
        pendingResumableContinuation = .restarting(task)
    }

    /// Arms the **next** dispatch to run the task in flight again from the top rather than as a
    /// task of its own (PR #105 review F1).
    ///
    /// **The two doors that need it, and why they are exactly two.** A third continuation door,
    /// `runTaskAgain`, needs the *record-matched* helper above instead — see it for why the
    /// in-flight handle cannot express what that door is doing. `performStart` drops its handle
    /// on the outstanding checkpoint at the top of every run, which is right for a run that is a
    /// different task and wrong for a run that is the same one continuing. Three dispatches are the
    /// same task: `continueResumableTask`, which arms `.resuming` because it carries a finished
    /// unit's file with it; and these two, which arm `.restarting` because nothing has finished yet
    /// — an answered clarification never executed a step, and a retry starts the command over.
    ///
    /// A no-op when there is no checkpoint — memory off, the record deleted, or a run that never
    /// reached a plan — so the caller does not have to ask.
    ///
    /// `everyDispatchEntryPointDecidesWhetherItContinuesTheTaskInFlight` enumerates the doors and
    /// fails when a new one arrives unclassified. The name deliberately avoids the substring
    /// `start(`: that scan counts call sites of `start(...)` textually, and a helper whose own name
    /// ended in `Restart(` was three false positives in the population it pins.
    private func armRestartOfTaskInFlight() {
        guard let task = activeResumableTask else {
            return
        }
        pendingResumableContinuation = .restarting(task)
    }

    /// The widget's cross: stops Sonny offering this task, for good, without forgetting it
    /// (SONNY-282, founder decision 2026-08-25).
    ///
    /// Two writes, in this order. The session set first, so the widget repaints on this press even
    /// if the disk refuses — `declinedResumeOfferIDs` says why that matters. Then `declinedAt` on
    /// the record, which is what the next launch reads; `updatedAt` is left alone, because declining
    /// is not activity on the task and must not buy it a fresh idle period.
    ///
    /// **`errorMessage`, not `recordLocalStorageWriteFailure`, on a failed write.** CLAUDE.md's
    /// rule: a write the user pressed a control for is `errorMessage`, because the thing they asked
    /// for did not happen — and it did not, in the one way that matters to them, which is that the
    /// offer may come back after a relaunch. A task's own bookkeeping writes go to the other
    /// channel; this is not one of those.
    ///
    /// The in-memory checkpoint is kept in step when it is the same record, for the reason
    /// `deleteResumableTask` gives: a failed run leaves `activeResumableTask` pointing at its record,
    /// and a later write from that handle would otherwise put an undeclined copy straight back.
    ///
    /// **Nothing is deleted here, so nothing is owed to any server** (SONNY-426). SONNY-426 was
    /// filed reading this control as a fourth delete door; it is not a delete door at all, which is
    /// the whole of the 2026-08-25 decision above. `decliningAnUnfinishedTaskReachesTheServerNotAtAll`
    /// holds it, because "queues nothing" is only visible as an absence and an absence is what a
    /// later change removes without noticing.
    func declineResumeOffer() {
        guard let offer = resumeOffer else {
            return
        }
        declinedResumeOfferIDs.insert(offer.id)

        var declined = offer
        declined.declinedAt = Date()
        do {
            try resumableTaskStore.save(declined)
        } catch {
            setError(
                "Sonny could not save that you declined this task, so it may offer it again after a relaunch: \(error.localizedDescription)"
            )
            logStore.append(.observe, "Could not record a declined unfinished task: \(error.localizedDescription)")
        }
        if activeResumableTask?.id == offer.id {
            activeResumableTask = declined
        }
        refreshResumableTasks()
    }

    /// Forgets one unfinished task. The Memory sheet's per-entry delete.
    ///
    /// **It reaches no server, and that is a measurement rather than an omission** (SONNY-426,
    /// decided 2026-09-06 from review-207's residual R7). The three doors SONNY-404 routed through
    /// `PendingServerDeletionStore` each hold the key to what they remove — §5.1's `task_id`, which
    /// is `CompletedTaskRecord.id`. This one holds nothing of the sort. A `ResumableTask` stores ten
    /// fields and no backend key; the wire id is `currentTaskID`, which `beginNewTaskIdentity()`
    /// mints afresh on **every continuation of one of these records** — `continueResumableTask`
    /// dispatches through `performStart` with `preserveUsageForNextStart` unset — while the record
    /// deliberately keeps *its own* id across those continuations. So one record spans as many wire
    /// ids as the task had attempts, and there is no single one it could carry. (Not *every*
    /// dispatch, which is what this said until PR #214's R1: `performStart` skips the re-mint when
    /// that flag is set, which is the voice-command and clarification-answer path and is never a
    /// continuation of an unfinished record.)
    ///
    /// The two cases, because they fail differently and neither ends in a queue entry. A run that
    /// **failed** wrote a history row under its wire id and pointed it here through
    /// `CompletedTaskRecord.resumableTaskID`; this press leaves that row standing, so the server's
    /// copy stays reachable through *Delete task* and *Memory › Task history › Delete*, and queueing
    /// here would delete the server's copy of a task the user can still open locally — the opposite
    /// of `PendingServerDeletion.scope`'s rule that the queue carries what the delete reached on the
    /// Mac. A run that was **interrupted** never wrote a row and never will, per `ResumableTask.id`,
    /// so nothing on this Mac names its content and the press could not say what to delete.
    ///
    /// What this press does destroy is the checkpoint — the plan and how far it got — which is
    /// local-only state the server never held. `theUnfinishedTasksPerEntryDeleteReachesTheServerNotAtAll`
    /// pins that, so a later session adding a queue call here fails rather than passing quietly.
    func deleteResumableTask(_ task: ResumableTask) {
        performMemoryEntryDelete(named: "unfinished task") {
            try resumableTaskStore.delete(id: task.id)
        }
        // **The in-memory checkpoint goes with the record, and this path has no `!isRunning` guard
        // to lean on** (PR #105 review F8; this comment used to claim one). `deleteMemory(in:)`
        // guards on `!isRunning, !isAwaitingApproval`; `deleteMemoryEntry(in:at:)` and
        // `performMemoryEntryDelete` do not, so a per-entry delete really can land while a run is
        // paused at an approval. That is why the clear is unconditional rather than a tidy-up:
        // without it the paused run's next unit boundary — or its failure settle — writes the
        // deleted record straight back.
        if activeResumableTask?.id == task.id {
            activeResumableTask = nil
        }
        refreshResumableTasks()
    }

    // MARK: - Routine scheduling

    /// Poll interval. Far coarser than the clipboard monitor's 1s because nothing here is
    /// interactive — the worst case is starting a routine up to this late, which is irrelevant
    /// against catch-up windows measured in hours.
    private static let scheduleTickInterval: TimeInterval = 30

    /// Starts the schedule timer and the wake observer.
    ///
    /// The wake observer is not redundant with the timer: `Timer` does not fire while the machine
    /// is asleep and does not retroactively catch up on wake, and the app commonly stays running
    /// across a sleep — so checking only on launch and on tick would miss the single most common
    /// real scenario, a laptop closed overnight and opened in the morning.
    func startRoutineScheduling() {
        routineScheduleTimer?.invalidate()
        checkScheduledRoutines()
        checkStandingWatchers()
        routineScheduleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.scheduleTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkScheduledRoutines()
                self?.checkStandingWatchers()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkScheduledRoutines()
                self?.checkStandingWatchers()
            }
        }
    }

    /// Handles at most one outstanding occurrence per call, oldest first.
    ///
    /// One at a time rather than draining the whole backlog: each run sets `isRunning`, which the
    /// guard below respects, so a backlog is worked through across ticks instead of firing several
    /// unattended routines at once — which is exactly the burst behavior that ruled out unbounded
    /// catch-up in the first place.
    func checkScheduledRoutines(now: Date = Date()) {
        // Never interrupt or race a task already in flight, whoever started it.
        //
        // **The third term is the founder's decision of 2026-08-20 (PR #80 review, F1), and it
        // closes a real overlap rather than a theoretical one.** A clarification pause looks idle
        // from out here — `performStart`'s defer has set `isRunning` false and a clarification never
        // writes `approvalRequest` — so the two-term guard let a routine fire on top of a user's
        // half-finished task. What that cost is specific: `finishRecordingPolicyIfSettled()` refuses
        // while `isRunning`, so a user cancelling their clarification during the scheduled run's
        // window got no reset at all — "Don't save this task" stayed on and clipboard history stayed
        // paused until relaunch, which is the exact failure SONNY-166 was filed to end, reintroduced
        // through a door that ticket never looked at.
        //
        // **A delay, not a loss.** The occurrence stays outstanding because nothing here resolves
        // it, and the 30-second tick (plus the wake observer) picks it up on the next pass, which is
        // the same catch-up path a routine firing during any other in-flight task already takes.
        //
        // Spelled out rather than written `!isTaskInFlight`, which is exactly these three terms
        // today. A background trigger's refusal set should not change because a UI predicate grows a
        // fourth term later; if a new state ought to block the scheduler, it gets added here on
        // purpose.
        // **The unattended door, and the one the review named as needing no user action to enter**
        // (PR #207's F3): a scheduled routine sets `isRunning` from a timer, so the window the wipe
        // opens is one a routine can walk into with nobody watching.
        guard !isRunning, !isDeletingLocalData, !isAwaitingApproval, clarificationQuestion == nil else {
            return
        }

        // Read from the store, never from `savedRoutines`. An in-memory snapshot can outlive the
        // file — "delete all local data" wipes routines.json while the published array still holds
        // the old values, and `RoutineStore.delete(routineNamed:)` can now remove one routine the
        // same way. A fresh read narrows the window in which a fired routine can be missing by
        // run time, but no longer closes it: see `performScheduledRun`'s missing-routine comment
        // for the in-flight race that remains, and the guard there that fails it closed.
        let routines: [StoredRoutine]
        do {
            routines = Array(try routineStore.loadAll().values)
        } catch {
            recordLocalStorageLoadFailure(.savedRoutines, error: error)
            return
        }

        guard let next = RoutineScheduler.outstanding(in: routines, now: now).first,
              let occurrence = next.occurrence else {
            return
        }

        switch next.decision {
        case .notDue:
            return
        case .missed:
            resolveOccurrence(for: next.routine.name, at: occurrence)
            scheduledRunNotice = "“\(next.routine.name)” did not run at its scheduled time — too much time had passed by the time Sonny was available again."
        case .due:
            guard next.routine.schedule?.unattendedTrusted == true else {
                // An enabled schedule without unattended trust cannot run: the outer run-routine
                // gate is tier 2 and there is nobody to approve it. Skipping and saying so is
                // deliberate — pausing at the approval and waiting was considered for this branch
                // and rejected, because it reduces scheduling to "notify me it's ready, I'll
                // finish it myself".
                resolveOccurrence(for: next.routine.name, at: occurrence)
                scheduledRunNotice = "“\(next.routine.name)” was not run because it is not set to run unattended. Turn on unattended running for it, or run it yourself."
                return
            }
            isRunning = true
            // **Set here, beside `isRunning`, rather than inside `performScheduledRun`** (PR #188's
            // F3). That method's own doc names `activeTaskOrigin` as one of the two properties it
            // must set, because it is what keeps widget surfaces off a task the user never started
            // — but it is the body of an unstructured `Task`, so it first ran a main-actor turn
            // after `isRunning` had already said a task was under way. For that one render every
            // surface gated on the origin read the *previous* one, and the widget's runs-left gate
            // read a `plan` this method deliberately never touches. The two properties a scheduled
            // run does change are now changed together.
            let previousOrigin = activeTaskOrigin
            activeTaskOrigin = .scheduled
            // Deliberately does not touch `lastCommand`. That property is the user's own last
            // submission: it feeds `hasRetryableCommand` and `retryLastCommand()`, so overwriting
            // it here would point the widget's Retry button at a routine the user never ran.
            // `runningCommandDisplayText` reads the scheduled label separately while this runs.
            currentTask = Task {
                await performScheduledRun(
                    next.routine,
                    occurrence: occurrence,
                    restoringOriginTo: previousOrigin
                )
            }
        }
    }

    // MARK: - Standing watchers

    /// Checks at most one standing watcher, if any is due.
    ///
    /// **Its own checker on the shared pulse, decided explicitly rather than defaulted** (SONNY-236;
    /// the ticket asks for exactly this decision). It rides `startRoutineScheduling`'s timer and wake
    /// observer, because those are already the app's "something might be due" heartbeat and a second
    /// timer beside them would be two things to keep in step. It is **not** part of
    /// `checkScheduledRoutines`, and the reason is that method's own guard: a scheduled routine
    /// *starts a task*, so it must refuse while one is in flight — and it sets `isRunning` while it
    /// runs. Folding watchers in would make them blind for the length of every routine and every
    /// typed command, for no reason at all, because a watcher starts no task. It reads a page and
    /// posts a notice.
    ///
    /// **So the guards here are deliberately narrower, and the omission of `!isRunning` is the
    /// decision rather than an oversight.** What is guarded is re-entrancy: a fetch can outlast the
    /// 30-second pulse, and a stalled request must not accumulate checks behind it.
    ///
    /// **One watcher per pulse, oldest first**, the same rule `checkScheduledRoutines` follows for a
    /// backlog and for the same reason: five watchers coming due together should be five requests
    /// spread over two and a half minutes, not five at once.
    func checkStandingWatchers(now: Date = Date()) {
        // **A stalled check is abandoned before the guard is consulted, or the guard is permanent**
        // (PR #184 review, F3). The slot exists so a slow fetch does not accumulate checks behind
        // it; it must not become a way for one page that never answers to stop every watcher. The
        // abandoned check is recorded as a *failed reading* against the watcher it was about, so
        // `maxConsecutiveFailures` can still end it — without that the cap written to stop a dead
        // page occupying a watcher is unreachable through this door.
        if let startedAt = standingWatcherCheckStartedAt,
           now.timeIntervalSince(startedAt) >= StandingWatcherLimits.standard.checkTimeout,
           let stalled = standingWatcherCheckSubject {
            abandonStandingWatcherCheck()
            apply(StandingWatcherEvaluator.applyFailure(to: stalled, now: now))
        }

        guard standingWatcherCheck == nil else {
            return
        }

        let watchers: [StandingWatcher]
        do {
            watchers = try resumableTaskStore.loadWatchers()
        } catch {
            recordLocalStorageLoadFailure(.resumableTasks, error: error)
            return
        }

        // Expiry is asked before due-ness, inside `decideBeforeObserving`, so a watcher whose
        // lifetime ran out three minutes after its last check is retired on this pulse rather than
        // waiting out an interval it no longer has.
        //
        // **The handle is assigned before the task body can run, and that is a property of the
        // isolation rather than luck.** This method is on the main actor, `Task {}` inherits that
        // context, and nothing below suspends before the assignment — so the body cannot start
        // first and clear a handle that has not been set. Worth writing down because the failure
        // would be silent and permanent: a handle left non-nil stops every future check, and
        // nothing anywhere would report it.
        for watcher in watchers {
            switch StandingWatcherEvaluator.decideBeforeObserving(watcher, now: now) {
            case .notDue:
                continue
            case .stopped(let stopped, let reason):
                finishStandingWatcher(stopped, reason: reason)
                return
            case .pending, .unchanged:
                // **`now` travels into the fetch rather than being re-read there** (found by the
                // full suite; the filtered run was green). `observeStandingWatcher` used to default
                // its own `now` to `Date()`, so due-ness was decided on the caller's clock and
                // `lastCheckedAt` was stamped from the real one. Under an unloaded run the two are
                // milliseconds apart and every test passes; under a loaded parallel suite they
                // drift by seconds, and a check that should have been due reads as not due — one
                // silently skipped check, which is a wrong *count* rather than a failure. Two
                // clocks in one decision is the defect, not the drift.
                //
                // It also means `lastCheckedAt` records when the check *began* rather than when the
                // page answered, which is the more honest of the two: the interval this feeds is
                // "how often Sonny asks", and a slow page should not buy itself a longer gap.
                standingWatcherCheckSubject = watcher
                standingWatcherCheckStartedAt = now
                let generation = standingWatcherCheckGeneration
                standingWatcherCheck = Task { [weak self] in
                    await self?.observeStandingWatcher(watcher, now: now, generation: generation)
                    // Only the check that is still current clears the slot. An abandoned one
                    // answering late must not clear a slot a *newer* check is holding.
                    guard let self, generation == standingWatcherCheckGeneration else {
                        return
                    }
                    standingWatcherCheck = nil
                    standingWatcherCheckSubject = nil
                    standingWatcherCheckStartedAt = nil
                }
                return
            }
        }
    }

    /// Waits for the check in flight, if any.
    ///
    /// **For tests, and it is not a seam that changes behaviour.** `checkStandingWatchers` starts a
    /// `Task` and returns, because the 30-second pulse it runs on must not block the main actor for
    /// the length of an HTTP request — so a test that called it and asserted immediately would be
    /// racing the fetch and would usually win, which is the worst kind of passing test. Nothing in
    /// `Sources/` calls this.
    func awaitStandingWatcherCheck() async {
        await standingWatcherCheck?.value
    }

    /// Reads one watcher's page and applies what came back.
    ///
    /// **Every failure is a failed *reading*, not a failed task.** A refused connection, a robots
    /// disallow, a 404 and a page that stopped being HTML all arrive here as a throw, and all of them
    /// mean the same thing to a watcher: this check did not happen. `applyFailure` decides how many
    /// of those in a row is enough to give up, and until then nothing is said to the user — a
    /// notification per flaky fetch would be worse than the silence it replaced.
    private func observeStandingWatcher(_ watcher: StandingWatcher, now: Date, generation: Int) async {
        let decision: StandingWatcherDecision
        do {
            let text = try await standingWatcherObserver.readableText(at: watcher.url)
            decision = StandingWatcherEvaluator.apply(
                reading: StandingWatcherEvaluator.digest(of: text),
                to: watcher,
                now: now
            )
        } catch {
            decision = StandingWatcherEvaluator.applyFailure(to: watcher, now: now)
        }

        // **Nothing is written by a check that has been abandoned** (PR #184 review, F2 and F3).
        // This is the half of F2's fix that cancellation cannot do: a cancelled `Task` still runs
        // its continuation, and the observer may not be cancellable at all — so a wipe that unlinked
        // the file would otherwise be followed by this line recreating it. It is also what keeps a
        // stalled check that answers eventually from overwriting the failure already recorded
        // against its watcher, or from resurrecting a watcher a later check has finished.
        guard generation == standingWatcherCheckGeneration else {
            return
        }
        apply(decision)
    }

    /// Applies one check's decision: save what is still running, finish what is not.
    ///
    /// Split out so the stalled-check path in `checkStandingWatchers` reaches exactly the same two
    /// doors rather than a second copy of the same `switch` — the shape this repository consolidates
    /// away, because the copy that does not get updated is the one that matters.
    private func apply(_ decision: StandingWatcherDecision) {
        switch decision {
        case .notDue:
            return
        case .unchanged(let updated), .pending(let updated):
            saveStandingWatcher(updated)
        case .stopped(let stopped, let reason):
            finishStandingWatcher(stopped, reason: reason)
        }
    }

    /// Forgets the check in flight without waiting for it, and makes whatever it eventually returns
    /// inert.
    ///
    /// Called by the wipe (F2) and by the stalled-check path (F3). Both halves are needed: the
    /// cancel stops a cancellation-aware observer promptly, and the generation bump is what a
    /// continuation — cancelled or not — is checked against before it writes.
    private func abandonStandingWatcherCheck() {
        standingWatcherCheckGeneration += 1
        standingWatcherCheck?.cancel()
        standingWatcherCheck = nil
        standingWatcherCheckSubject = nil
        standingWatcherCheckStartedAt = nil
    }

    /// Tells the user what this watcher had to say, then forgets it.
    ///
    /// **In that order, and the order is the decision.** A watcher deleted before its notice was
    /// published would leave nothing anywhere if the publish were ever to fail; a notice published
    /// after a delete that failed would tell the user a watcher had stopped while it was still in the
    /// file and still being checked.
    ///
    /// **This used to end "the worst case is a watcher that says the same thing twice, which is a
    /// nuisance rather than a lie", and that was true of a transient failure and false of a
    /// persistent one** (PR #184 cycle 3, N1). A delete that keeps throwing leaves the record, the
    /// expired branch re-decides `.stopped` on every pulse, and the repeat is unbounded — 11 notices
    /// across 11 pulses, measured. The ordering is unchanged and the bound is `notifiedWatcherIDs`,
    /// which is what makes the sentence above true rather than aspirational. Recorded rather than
    /// silently corrected, because a comment claiming a case is bounded is exactly what stopped
    /// three readers looking.
    private func finishStandingWatcher(_ watcher: StandingWatcher, reason: StandingWatcherStopReason) {
        // **Once per watcher, whatever happens to the delete below** (PR #184 cycle 3, N1). The
        // ordering here is deliberate and unchanged — publish, then delete — so the worst case of a
        // *transient* failure is still a repeat rather than silence. What this adds is the bound the
        // comment below used to assume: a *persistent* failure leaves the record, and the expired
        // branch re-decides `.stopped` on every pulse, so without this the repeat is unbounded.
        if notifiedWatcherIDs.insert(watcher.id).inserted {
            watcherNotice = StandingWatcherNoticeCopy.message(for: reason, watcher: watcher)
        }
        do {
            try resumableTaskStore.deleteWatcher(id: watcher.id)
        } catch {
            recordLocalStorageWriteFailure("what Sonny is watching")
        }
        refreshMemoryRowsAfterRun()
    }

    /// Writes back a watcher that is still running.
    ///
    /// **`recordLocalStorageWriteFailure`, never `errorMessage`** — CLAUDE.md's channel rule, and
    /// this is the clearest case of it in the product: nobody pressed anything, so there is no task
    /// to have failed, and `errorMessage` outranks `.result` in the widget. A watcher's bookkeeping
    /// write failing would otherwise blank the result of a task that ran and succeeded.
    private func saveStandingWatcher(_ watcher: StandingWatcher) {
        do {
            try resumableTaskStore.saveWatcher(watcher)
        } catch {
            recordLocalStorageWriteFailure("what Sonny is watching")
        }
    }

    /// Runs a routine with nobody watching, without disturbing anything that describes the user's
    /// own last task.
    ///
    /// That isolation is the whole design of this method, and it is why it does not reuse
    /// `performStart`'s state handling. Every property that surface UI reads as "your last task" —
    /// `errorMessage`, `finalSummary`, `suggestions`, `plan`, `stepStatuses`, `preparedRun`,
    /// `lastCommand`, `priorTaskContext`, the usage summary — is deliberately untouched here. A
    /// background event silently erasing an unresolved error, or an "open the file" suggestion the
    /// user had not acted on yet, is a worse failure than a scheduled run being under-reported: the
    /// user did not do anything, so nothing they were looking at should change.
    ///
    /// `isRunning` and `activeTaskOrigin` are the two exceptions, because both are needed *during*
    /// the run — one blocks re-entrancy and drives Command Center's running indicator, the other
    /// keeps the widget from raising a progress panel for a task the user never started. Origin is
    /// restored afterwards so the user's previous result stays visible in the widget.
    ///
    /// Everything this method has to say goes to `scheduledRunNotice`, task history, and the
    /// routine's own run history.
    private func performScheduledRun(_ routine: StoredRoutine, occurrence: Date, restoringOriginTo previousOrigin: TaskOrigin) async {
        // A scheduled run is a task, so it gets a `task_id` of its own (SONNY-130): the routine it
        // runs reaches the backend through the same executor a typed command does, and the row this
        // run writes has to be the row those requests are filed under.
        //
        // **Only the id, and deliberately not `beginNewTaskIdentity()`.** That helper also clears
        // the usage recorder and the published summary, and the summary is one of the properties
        // this method's own doc comment lists as untouched on purpose — a background event silently
        // blanking the usage line of the task the user is looking at is exactly the failure that
        // paragraph exists to prevent. The recorder's own contents are left as they were, which is
        // what this path has always done.
        currentTaskID = UUID().uuidString
        let startedAt = Date()
        let name = routine.name
        scheduledRunDisplayCommand = "Run my \(name) routine"
        defer {
            activeTaskOrigin = previousOrigin
            scheduledRunDisplayCommand = nil
            isRunning = false
            currentTask = nil
            // A scheduled routine writes to the same stores a typed command does — output
            // locations, recent artifacts, a saved snippet, a *routine or a workspace* — and Command
            // Center can be open the whole time it runs (SONNY-246). The foreground twin of this
            // line is in `recordTaskHistoryIfTerminal`, which this path does not go through; the
            // `defer` is the one place every exit here passes, including the ones that never reach
            // `recordScheduledTaskHistory` at all.
            refreshMemoryRowsAfterRun()
        }

        // Whatever happens below, this occurrence is handled. Advancing first means an unexpected
        // throw can't leave it outstanding for the next tick to retry 30 seconds later, forever.
        resolveOccurrence(for: name, at: occurrence)

        do {
            // `.record` explicitly, never this run's policy (PR #67 review, F2). A scheduled routine is
            // never suppressed — it passes through no composer, so there is no switch to have been
            // left on. Inheriting `taskRecordingPolicy` lost a routine's Shortcut run history while
            // still writing its task-history row, which is a different writer. Stated here the same
            // way `recentArtifactStoreForScheduledRun` already is, rather than left to the policy
            // happening to be right.
            //
            // **The window that made it reachable is not the one this comment used to name**
            // (PR #98 round 4, F2). It said a foreground run paused at a *clarification*, and that
            // pause has been closed at this door since PR #80's F1 added `clarificationQuestion ==
            // nil` as `checkScheduledRoutines`' third guard term. The live window is the ordinary
            // one, before any dispatch: "Don't save this task" is a pre-dispatch toggle
            // (`dontSaveButton` renders only when `!isTaskInFlight`), so a user who flips it on
            // while composing and has not pressed Send passes all three guards. Corrected rather
            // than deleted, because the fix it justifies is still right and a reader who checks a
            // dead mechanism concludes the fix is dead too. Full reasoning at
            // `allowsScheduledRecording(to:)`.
            let executor = makeExecutor(recordingPolicy: .record)
            let runner = AgentRunner(
                planner: InstantOnlyFallbackPlanner(),
                executor: executor,
                logStore: logStore,
                // **`recentArtifactStoreForScheduledRun`, which is neither of the two obvious
                // choices** (PR #98 review, F2). This line used to pass the raw store, on reasoning
                // that was right about the composer switch and silent about the memory switches —
                // so a scheduled routine that wrote a file recorded a note naming its full path with
                // Memory switched off. `recentArtifactStoreForThisRun` is not the fix either: it
                // folds in `taskRecordingPolicy`, which is exactly what must not be read here — see
                // `allowsScheduledRecording(to:)` for why, and note that the reason is the
                // pre-dispatch composer window rather than the clarification pause an earlier
                // telling named (PR #98 round 4, F2).
                recentArtifactStore: recentArtifactStoreForScheduledRun,
                // And its own seam, for the same reason and reading the same standing-switch-only
                // question (SONNY-209). Never `outputLocationStoreForThisRun`: that one folds in
                // `taskRecordingPolicy`, which is the term a scheduled run must not read.
                outputLocationStore: outputLocationStoreForScheduledRun
            )
            self.runner = runner
            // The same plan a typed "run my X routine" produces — built directly rather than
            // round-tripped through the resolver or the planner, so a scheduled run is
            // deterministic and costs no model call.
            let prepared = try runner.prepare(
                plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: name),
                source: .instantResolver
            )
            // Reachable since routine deletion exists, not merely defensive. It has a second cause
            // as of SONNY-186: a routine may carry an `open_workspace` step, so a routine's own
            // steps *can* now name a missing target, and a workspace deleted or renamed since the
            // routine was taught reaches this line as `.missingWorkspaceInRoutine` — a clarification
            // naming the routine and the workspace, so the notice below says what could not be
            // found rather than reporting a routine that quietly did nothing. The original cause is
            // unchanged: the routine itself is re-resolved *by name* in `prepare` above, and
            // `checkScheduledRoutines` spawning this method as a `Task` is a real suspension point
            // between reading the routine and this line running. Deleting the routine inside that
            // window makes `RunRoutineCapabilityAdapter`'s store read throw `.missingRoutine`,
            // which `AgentActionExecutor.prepare` converts into this clarification. Failing closed
            // rather than stalling on a question nobody is present to answer is correct for every
            // cause. Pinned by ScheduledRoutineRunTests.
            // aRoutineDeletedBetweenScheduleFireAndTaskStartBecomesAClarificationInstead. (A
            // delete landing later still fails closed: `runner.execute`'s own store read throws
            // into the generic catch below.)
            if let question = prepared.clarificationQuestion {
                scheduledRunNotice = "“\(name)” was not run because Sonny needed to ask something first: \(question)"
                return
            }

            // **Unattended vision: never — the belt** (SONNY-94, E7 as ratified under C8).
            //
            // The other two layers are structural and would each stop this on their own: a stored
            // routine cannot carry a vision step at all (`StoredRoutine.forbiddenStepOperations`),
            // and the `.approved(.tier2)` ceiling below cannot cover a tier-3 vision assessment.
            // This layer is neither — it is an *explicit* refusal that names the reason, and it
            // exists precisely because the other two are silent about theirs: a plan blocked by the
            // ceiling produces "approval required", a plan blocked by the routine store produces
            // "unsafe routine step", and neither tells a user that screen control is a thing Sonny
            // will not do while they are away.
            //
            // Three layers, three pins, so no single regression unbars unattended screen control.
            // This one is deliberately the least load-bearing and the most legible.
            //
            // A present human is an authority requirement, not an accuracy hedge: their presence is
            // the whole basis on which a program is allowed to move their cursor, and no amount of
            // model quality substitutes for it. So this refuses in *every* mode, Power included,
            // and there is no toggle anywhere that turns it off.
            // **Checked against the routine's own steps, not only the prepared plan** — and that
            // distinction is the whole reason this check needed writing twice. The scheduled path
            // prepares a one-step `run_routine` plan, so a vision step carried by the routine lives
            // *inside* the stored record and never appears in `prepared.plan.steps` at all. A belt
            // that looked only at the prepared plan would have been unreachable code that read like
            // a guarantee.
            let carriesVision = routine.steps.contains { $0.operation == .visionSession }
                || (routine.steps.compactMap(\.routineSteps).flatMap { $0 }).contains { $0.operation == .visionSession }
                || prepared.plan.steps.contains { $0.operation == .visionSession }
            if carriesVision {
                logStore.append(.summarize, "Scheduled run refused: screen control never runs unattended")
                pauseSchedule(
                    routineNamed: name,
                    because: "It needs to control an app on screen, and Sonny only does that while you are here."
                )
                return
            }

            let result = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                confirmationMessage: "Scheduled run approved by this routine's unattended-run setting",
                // `.unscoped` on purpose, not by omission — and the reason is now a decision rather
                // than an absence (SONNY-186). It used to be that no workspace name could reach
                // here at all: a routine could not carry `open_workspace`, so a stored routine
                // could never name a workspace, and nothing else in a scheduled run carries one —
                // there is no command text a user typed and no dispatch that named one. A routine
                // may carry it now, so a name genuinely is available, and this stays `.unscoped`
                // anyway.
                //
                // **Opening a workspace is not the same act as being bound by one, and the
                // scheduled path is where treating them alike does damage.** The founder decision
                // binds the *step*: it says which workspace to open. Turning that into the run's
                // boundary would put an unattended run one out-of-scope resource away from a tier-3
                // escalation — which this path structurally cannot satisfy — and per SONNY-10 that
                // skips this occurrence and usually every future one, silently, for a routine the
                // user taught deliberately. That is the exact interaction
                // `docs/sonny-founder-design-decisions.md` records as the one genuinely dangerous
                // one. The foreground path is the opposite case and binds it: `WorkspaceTaskTagging`
                // reads the routine's own `open_workspace` step, and there is a person present to
                // answer the escalation it can produce.
                //
                // Under the consequence rule this choice also carries the unattended ceiling's
                // advisory half: an unscoped assessment can produce no out-of-scope advisory, and
                // `StoredRoutine.forbiddenStepOperations` rejects `edit_workspace`, so no advisory
                // escalation of any kind is reachable here — every tier-3 an unattended run can
                // reach still asks, and the `.approved(.tier2)` ceiling below still refuses it.
                // Reachability, not a type-level guarantee; a test named for the hazard pins it.
                scope: .unscoped,
                // `nil`, and it is an answer rather than an omission: a stored routine can never
                // contain a `vision_session` step (`StoredRoutine.forbiddenStepOperations`), and
                // unattended vision is refused by three independent layers anyway. A scheduled run
                // controls no app, so it has no per-app standing.
                context: approvalContext(visionTarget: nil)
            )
            // The scheduled twin of the two foreground sites' bookkeeping-failure handover
            // (SONNY-209). `recordLocalStorageWriteFailure`, never `errorMessage`: the routine ran
            // and did what it was asked, and only the note about where its file landed could not be
            // saved — CLAUDE.md's write-failure channel rule exactly.
            //
            // **`lastRecentArtifactFailure` is *not* read here, and that is not an oversight of this
            // ticket's** — it has never been read on this path, so a scheduled routine whose
            // recent-artifacts write fails still reports nothing. That is the other store's defect
            // and the other store is on this ticket's never-touch list; it is filed rather than
            // fixed here.
            if let outputLocationFailure = runner.lastOutputLocationFailure {
                recordLocalStorageWriteFailure(outputLocationFailure)
            }
            recordScheduledRunInHistory(name: name, at: occurrence)
            recordScheduledTaskHistory(
                status: .completed,
                startedAt: startedAt,
                // The result was dropped here until SONNY-147, while the very next line used it for
                // the notice — proof it was in scope and simply not threaded. `result.plan` is the
                // one-step `run_routine` plan this path prepares, which is what a follow-up on a
                // scheduled run gets to correct against.
                result: result.storedResult,
                plan: result.plan
            )
            scheduledRunNotice = "“\(name)” ran on schedule. \(result.summary)"
        } catch let error as RiskApprovalError {
            // The tier-3+ backstop firing. `AgentRunner` re-assesses at execute time and requires
            // the approved tier to be at least the effective tier, so a tier-2 unattended approval
            // simply cannot satisfy a tier-3 plan — the refusal is structural, not a policy check
            // written here that could drift out of sync with the real gate. The backstop itself is
            // untouched by SONNY-31; what changed is only what happens afterwards.
            //
            // Pause rather than skip. Every condition that reaches here is sticky: a file that
            // exists still exists tomorrow, a snippet whose text really did change still differs
            // next week, a tier-4 plan is tier 4 forever. Leaving the schedule enabled meant the
            // same refusal every single occurrence, each one posting the same notice that named no
            // cause — the user learned only that Sonny had stopped, never why. One notification
            // carrying the real reason, then silence, is the founder decision recorded on
            // SONNY-31 (chosen over keep-skipping-with-notice and hold-the-approval).
            //
            // All three `RiskApprovalError` cases pause, not just `.approvalRequired`.
            // `.previewOnly` (unproducible since the policy dials' 2026-08-14 deletion, but
            // still public API) and `.refused` (tier 4) are equally
            // permanent for a run with nobody present to approve anything, and leaving either one
            // on the old skip-forever path would keep this bug alive in two of the three branches
            // that can reach it.
            logStore.append(.summarize, "Scheduled run paused: \(error.localizedDescription)")
            pauseSchedule(routineNamed: name, because: scheduledRunPauseCause(for: error))
        } catch {
            logStore.append(.summarize, "Scheduled run failed: \(error.localizedDescription)")
            recordScheduledTaskHistory(
                status: .failed,
                startedAt: startedAt,
                // The same text the notice below shows, so a failed scheduled run's detail says what
                // went wrong instead of nothing. No plan: this catch is reachable before `prepare`
                // returns as well as after, so there is not always one to store.
                result: .codeAuthored(error.localizedDescription),
                plan: nil
            )
            scheduledRunNotice = "“\(name)” failed on its scheduled run: \(error.localizedDescription)"
        }
    }

    /// Records a scheduled run in task history *without* going through `recordPriorTaskContext`.
    ///
    /// The split is the point. History is a log of what Sonny did, and a scheduled run that failed
    /// has to be debuggable, so it belongs there. `PriorTaskContext` is a different thing: it is
    /// the last-task-only context that lets "use ~/Downloads instead" correct a just-finished task
    /// without restating it — a feature explicitly about correcting *your own* last action. Letting
    /// a background event become that target would silently redirect the next correction onto a
    /// task the user never started, with nothing in the phrasing to reveal it.
    ///
    /// A routine is also the wrong shape for that feature even setting the confusion aside: its
    /// steps are saved and fixed, so there is no command text for a correction to rewrite.
    private func recordScheduledTaskHistory(
        status: PriorTaskOutcomeStatus,
        startedAt: Date,
        result: StoredTaskResult,
        plan: AgentPlan?
    ) {
        guard let command = scheduledRunDisplayCommand else {
            return
        }
        // **The memory switches apply to a scheduled run exactly as to a typed one** (PR #98 review,
        // F1). The foreground twin guards the identical write at `recordTaskHistoryIfTerminal`; this
        // one guarded nothing, so a routine firing at 9am wrote a row into the encrypted store while
        // the switch on screen read off — reproduced through `checkScheduledRoutines(now:)`. The
        // term dropped relative to the foreground guard is `taskRecordingPolicy`, deliberately; see
        // `allowsScheduledRecording(to:)` for why reading it here would be its own defect.
        guard allowsScheduledRecording(to: .taskHistory) else {
            return
        }
        let record = CompletedTaskRecord(
            // The scheduled twin of the foreground line above, and it needs it for the same reason:
            // a routine's run makes backend requests through the executor, and they are filed under
            // the id this row carries.
            id: currentTaskID,
            command: command,
            startedAt: startedAt,
            completedAt: Date(),
            outcomeStatus: status,
            trigger: .scheduled,
            result: result
        )
        // **Two writes, two catches, matching the foreground path** (PR #89 review). One `do` around
        // both said "could not save this scheduled run to task history" when only the *plan* write
        // had failed — the row had landed — and skipped `refreshTaskHistory()`, so the row that did
        // land was missing from the list until something else refreshed it. Two failures with
        // different consequences need two messages and two recoveries; `recordTaskHistoryIfTerminal`
        // and `recordTaskPlanDetail` already split them this way for a foreground run, and these are
        // separate functions rather than one shared helper, so agreeing is something to do rather
        // than something inherited.
        let evictedTaskIDs: [String]
        do {
            evictedTaskIDs = try taskHistoryStore.record(record)
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this scheduled run to task history: \(error.localizedDescription)"
            )
            return
        }

        recordScheduledTaskPlanDetail(for: record, plan: plan, evictedTaskIDs: evictedTaskIDs)

        // Regardless of the plan write, because the row landed either way and the list has to agree
        // with the file. The foreground path refreshes on the same rule — and this line is the whole
        // reason the plan write moved into its own function below.
        refreshTaskHistory()
    }

    /// The plan-detail half of a scheduled run's record, in its own function **so that its guard's
    /// `return` cannot take `refreshTaskHistory()` with it** (PR #98 round-4 pass, F3).
    ///
    /// The guard used to be inline, where returning exited `recordScheduledTaskHistory` entirely and
    /// skipped the refresh — leaving a row on disk that the Tasks list would not show until
    /// something else refreshed it. That is verbatim the defect PR #89's review fixed on this same
    /// pair of writes, and the foreground path has been shaped this way ever since precisely because
    /// of it: `recordTaskPlanDetail` is a separate function so its own early return is local.
    ///
    /// **It was unreachable and that was not a reason to leave it.** Plan details and history rows
    /// share the `.taskHistory` memory row today, so the guard can only fire in a world where the
    /// row's guard already returned. But the guard is kept for the day `LocalStore.memoryCategory`
    /// gives plan details a row of their own — and on that day the inline version became live and
    /// silently re-introduced a fixed bug. A latent defect that arrives with a future refactor is
    /// the one shape nobody is watching for.
    private func recordScheduledTaskPlanDetail(
        for record: CompletedTaskRecord,
        plan: AgentPlan?,
        evictedTaskIDs: [String]
    ) {
        // Classified `.trace`, and withheld by the same switch that withheld the row — asked
        // explicitly rather than inferred from having got past the row's guard, exactly as the
        // foreground `recordTaskPlanDetail` does and for the same reason: the reach of a suppression
        // is a rule read off `LocalStore.kind`, and a store relying on a sibling's guard is the one
        // store the rule does not actually cover.
        //
        // **The `taskRecordingPolicy` half stays absent, and that was always right** — a scheduled
        // run passes through no composer, so there is no "Don't save this task" switch to have been
        // left on, the same reasoning written beside `makeExecutor(recordingPolicy: .record)`.
        // `recordTaskPlanDetail` is still not reused here for exactly that reason. What the earlier
        // wording missed is that "no policy check" and "no check at all" are different sentences,
        // and only the first one was true of the intent.
        guard allowsScheduledRecording(to: .taskPlanDetails) else {
            return
        }

        do {
            if let plan, let taskID = record.id {
                try taskPlanDetailStore.save(
                    StoredTaskPlanDetail(taskID: taskID, completedAt: record.completedAt, plan: plan),
                    evictedTaskIDs: evictedTaskIDs
                )
            } else {
                try taskPlanDetailStore.delete(ids: evictedTaskIDs)
            }
        } catch {
            // A *write* failure, with its own accurate wording — never the load-failure banner,
            // whose text is hardcoded to "could not be decrypted or decoded" and would be wrong
            // twice over here. The honest consequence is narrow and worth saying: the run is in the
            // history, and a follow-up on it will have its command and its outcome but not its plan.
            recordLocalStorageWriteFailure(
                "Sonny could not save what this scheduled run planned: \(error.localizedDescription)"
            )
        }
    }

    /// Switches a routine's schedule off after an approval refusal and says so, once.
    ///
    /// "Exactly one notification" is not enforced by a counter here — it falls out of pausing.
    /// `scheduledRunNotice` is published once per attempt and `AppDelegate` mirrors it to a
    /// notification; a disabled schedule produces no further attempts, so there is nothing left to
    /// post. A counter would have been a second source of truth for the same fact.
    ///
    /// A failed pause write still notifies. The store failure gets its own surfacing through
    /// `recordLocalStorageWriteFailure`, but suppressing the explanation as well would leave the
    /// user with a routine that stopped working, no reason, and a storage banner that does not
    /// mention the routine at all.
    private func pauseSchedule(routineNamed name: String, because cause: String) {
        do {
            try routineStore.pauseSchedule(routineNamed: name, reason: cause)
            refreshSavedItems()
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not pause this routine's schedule: \(error.localizedDescription)"
            )
        }
        scheduledRunNotice = "“\(name)” needs your approval to run, so Sonny paused its schedule instead of skipping it every time. \(cause) Run it yourself to review, then switch its schedule back on."
    }

    /// The user-facing reason a scheduled run was refused.
    ///
    /// Prefers the escalation reasons, because they are the only part of an assessment that names
    /// the *specific* condition — "Draft output already exists at …/weekly.md." is actionable in a
    /// way "This may affect external services or overwrite/destructively change data." is not.
    /// Falls back to the tier's generic risk reason when a refusal carries no escalations at all,
    /// which is the shape of a plan sitting at a high baseline tier rather than one raised into it.
    private func scheduledRunPauseCause(for error: RiskApprovalError) -> String {
        let request: RiskApprovalRequest
        switch error {
        case .approvalRequired(let value), .previewOnly(let value), .refused(let value):
            request = value
        }

        let escalationReasons = request.assessment.escalations
            .map(\.reason)
            .joined(separator: " ")
        return escalationReasons.isEmpty ? request.approvalCopy.riskReason : escalationReasons
    }

    /// Marks an occurrence handled so the next tick moves past it. Applies to every outcome — ran,
    /// refused, skipped, missed — because any of them leaving the baseline untouched would make the
    /// scheduler retry the same occurrence every 30 seconds.
    private func resolveOccurrence(for routineName: String, at occurrence: Date) {
        do {
            try routineStore.advanceScheduleBaseline(routineNamed: routineName, to: occurrence)
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this routine's schedule state: \(error.localizedDescription)"
            )
        }
    }

    /// Appends the occurrence to the routine's own run history — the dates the Routines row's streak
    /// badge is computed from.
    ///
    /// **Guarded, by the founder's decision of 2026-08-22** (PR #98 round-4 verification pass, F1).
    /// This is the fourth write in the category the other three came from and the last one an
    /// enumeration of the scheduled path found: with every memory switch off, a routine firing on
    /// its schedule still appended a dated entry to `routines.json` — the file the Routines memory
    /// row governs — visible to the user as a streak, with no control anywhere that stopped it.
    ///
    /// **Guarding it costs nothing operationally, which is what made the call cheap.** Nothing in
    /// the scheduling path reads `recentRunDates`: the due-check runs off the routine's schedule and
    /// the clock. The data is display-only, so the badge simply goes quiet while memory is off.
    ///
    /// The counter-argument is real and lost on consistency rather than on being wrong: a routine is
    /// something the user deliberately created, so its run log arguably belongs to the routine
    /// rather than being something Sonny recorded *about* them. But the same user, in the same
    /// session, with the same switch off, would otherwise find three kinds of scheduled write silent
    /// and a fourth still recording, with nothing to tell them apart. The deeper question — that
    /// turning off Routines memory blocks *saving* a routine while still logging runs, which may be
    /// backwards, since saving is the deliberate act and logging the passive one — is **SONNY-223**'s,
    /// not this write's.
    private func recordScheduledRunInHistory(name: String, at occurrence: Date) {
        guard allowsScheduledRecording(to: .routines) else {
            return
        }
        do {
            try routineStore.recordRun(routineNamed: name, at: occurrence)
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this routine's run history: \(error.localizedDescription)"
            )
        }
    }

    private func publishTaskUsageSummary() {
        taskUsageSummary = taskUsageRecorder.snapshot()
    }

    private func initializeStepStatuses(for plan: AgentPlan) {
        stepStatuses = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.id, AgentStepStatus.pending) })
        // Beside the step statuses because it is the same fact at the job's granularity, and because
        // this is the one place every dispatch passes with the plan it is about to run — including a
        // resumed one, whose plan is what is *left* of the job (SONNY-235).
        //
        // **This comment used to describe behaviour the code could not produce**, which is how PR
        // #185's F1 stayed invisible: it said a remainder reports "0 of 40 done" and climbs, while
        // `remainingPlan()` was dropping `itemJob` so a remainder produced no progress at all. Both
        // are fixed, and the count is the remainder's own — `ItemJobProgress` is scoped to the items
        // *this plan* is responsible for, so a resume of the last two of forty reports "0 of 2" and
        // climbs to "2 of 2" rather than either claiming forty or saying nothing.
        activeItemJobPlan = plan.itemJob == nil ? nil : plan
        activeItemJobCompletedStepIDs = []
        activeItemJobFailures = []
        refreshItemJobProgress()
    }

    private func markAllSteps(_ status: AgentStepStatus) {
        guard !stepStatuses.isEmpty else {
            return
        }
        stepStatuses = Dictionary(uniqueKeysWithValues: stepStatuses.keys.map { ($0, status) })
    }
}

enum AgentStepStatus: String {
    case pending
    case running
    case complete
    case failed
    case canceled
}

/// The planner handed to a run whose plan is already made — a pre-built plan from the screen, or
/// one the instant resolver produced. Asking it for a plan is a bug, and it says so.
///
/// **It threw `PlannerError.missingAPIKey` until SONNY-136**, which meant a user who somehow reached
/// this was told to export `OPENAI_API_KEY`: a live path wearing the message of a dead one. The case
/// is `noPlannerRan` now, named for what this actually is.
@MainActor
private struct InstantOnlyFallbackPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        throw PlannerError.noPlannerRan
    }
}

/// What the Memory page's last per-row Delete did, kept so its sentence can be derived again when
/// the files it kept change from under it (PR #117 review, F1). `AgentViewModel.lastPerRowDelete`
/// holds one; `MemoryDeletionCopy.perRowDeleteReport` turns one into the sentence.
struct LastPerRowDelete: Equatable {
    let category: MemoryCategory
    /// The files that read and were deleted.
    let deletedFileCount: Int
    /// Where the files that would not read now live — pruned to the ones still on disk when
    /// Settings' narrower control or the whole wipe removes some of them.
    var keptFileURLs: [URL]
    /// The first step that failed, if one did, in which case the sentence is about that and not
    /// about the kept files.
    let failure: String?
}
