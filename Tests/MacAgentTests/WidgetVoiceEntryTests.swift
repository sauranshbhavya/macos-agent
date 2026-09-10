import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// SONNY-173. The floating widget's mic button and the push-to-talk hotkey are two doors onto one
/// action, and with no API key exported they answered differently: the hotkey said the key was not
/// set, the button did nothing whatsoever. Nothing was missing — the button carried
/// `.disabled(!viewModel.canUseVoice && ...)`, a disabled SwiftUI button never runs its action, and
/// so the guard that already held the right message could not be reached from the one surface most
/// people press. (That message named the variable when this was written; SONNY-177 made it
/// provider-neutral, and SONNY-136 deleted it outright along with the variable.)
///
/// What is pinned here is the split that fixes it, not the API key. `canUseVoice` folded one
/// **actionable** failure the user can go and fix together with five **transient** ones that clear
/// on their own, and only the transient half may ever disable a control. **SONNY-136 has now landed
/// and the prediction held**: it deleted every provider environment variable and with it the one
/// actionable reason this split ever carried, and not one test here changed meaning, because every
/// test that needs a configuration failure states one through `voiceConfigurationBlockerOverride`
/// with a literal of its own rather than reaching for the shipped constant. The rule outlived its
/// only instance, which is what it was written to do.
///
/// **Nothing here ever presses the mic with voice actually available.** A press that gets past the
/// guard reaches `AVCaptureDevice.requestAccess`, which a `swift test` process has no bundle
/// identity to survive — a test suite must not raise a microphone prompt, or a privacy-usage crash,
/// on the machine running it. So every press in this file sits behind `try #require(canUseVoice ==
/// false)` rather than `#expect`: a broken gate ends the test on the spot instead of walking the
/// press into the recorder. That is not belt-and-braces — it is the difference between a mutation
/// battery reporting a killed mutant and one taking the machine's microphone with it.
@Suite
@MainActor
struct WidgetVoiceEntryTests {
    /// The bug itself, from the surface that had it, and the sibling surface beside it for
    /// comparison — the point was never that the button was silent, it was that the two disagreed.
    @Test
    func pressingTheMicWithAConfigurationProblemSaysWhatTheHotkeySays() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let button = try makeViewModel(root: root)
        button.voiceConfigurationBlockerOverride = { Self.aConfigurationProblem }
        // The press has to reach the action at all before anything else here means anything.
        #expect(button.isVoiceControlDisabled == false)
        // `#require`, not `#expect`: see the note on the suite. If voice were somehow available the
        // press would run, and the test must end here rather than reach the recorder.
        try #require(button.canUseVoice == false)
        button.toggleVoiceRecording(origin: .widget)

        #expect(button.errorMessage == Self.aConfigurationProblem)
        #expect(button.errorIsPersistent)
        // Refused before the recorder, so no microphone prompt and no half-started recording.
        #expect(button.isRecordingVoice == false)
        #expect(button.isPreparingVoiceRecording == false)

        let hotKey = try makeViewModel(root: root)
        hotKey.voiceConfigurationBlockerOverride = { Self.aConfigurationProblem }
        try #require(hotKey.canUseVoice == false)
        hotKey.beginPushToTalkVoice()

        #expect(hotKey.errorMessage == button.errorMessage)
        #expect(hotKey.errorIsPersistent == button.errorIsPersistent)
        #expect(hotKey.isRecordingVoice == false)
        #expect(hotKey.isPreparingVoiceRecording == false)
    }

    /// The configuration failure this file states when it needs one.
    ///
    /// **A literal here rather than `AgentViewModel.missingAPIKeyVoiceMessage`, which SONNY-136
    /// deleted.** That constant was the default answer of a property whose live answer had already
    /// been `nil` since SONNY-130 — a shipped sentence nothing in `Sources/` could produce, naming a
    /// condition that can no longer occur — so it went with the environment variable it was about.
    /// Nothing in this file was ever about its wording: what is pinned is that an *actionable*
    /// refusal reaches the user through both doors and does not disable the control, and any
    /// sentence serves for that.
    private static let aConfigurationProblem = "Sonny has no transcription provider configured."

    /// The words themselves, once, so a rewrite of the copy is a deliberate act rather than a
    /// silent one.
    ///
    /// **This asserted two messages until SONNY-136 and now asserts one.** The other was
    /// `missingAPIKeyVoiceMessage`, and the rule it carried — SONNY-177, founder decision
    /// 2026-08-19: no provider name and no environment-variable name in anything a user reads —
    /// did not go with it. It moved to the copy that is still shown, where
    /// `SonnyBackendCopyTests.noSentenceNamesAProviderOrAnEnvironmentVariable` holds it over every
    /// sentence `SonnyBackendCopy` and `SignInCopy` can produce, which is a wider population than
    /// one constant ever was.
    ///
    /// The em-dash assertion stays here because it is about *this* string, and the exact match goes
    /// stale the next time the founder rewords it, by design.
    @Test
    func theHoverReminderIsTheFoundersOwnWordingAndCarriesNoEmDash() {
        // SONNY-179's wording, given verbatim by the founder; SONNY-177 shipped
        // "Speak your command — or hold Ctrl-Opt-Space anywhere". The chord itself is written
        // as the platform's key glyphs since 2026-09-08 (ui-ux-claude), the one edit to that
        // wording: the status line beside it reads `PushToTalkHotKey.displayName`, and two
        // spellings of one shortcut on one surface is the inconsistency that branch removes.
        #expect(
            AgentViewModel.micHoverShortcutReminder == "Click to speak or hold \u{2303}\u{2325}Space."
        )
        // The em dash is the thing the founder asked to be rid of, so it is asserted as an absence
        // and not merely implied by the literal above — a later reword may not quietly bring one
        // back.
        #expect(!AgentViewModel.micHoverShortcutReminder.contains("—"))
    }

    /// SONNY-177. The hover hint is one condition with two answers, and a view may read neither half
    /// of the readiness that picks between them — so the pick happens on the view model, and this is
    /// the resolved value a view actually receives.
    ///
    /// The blocked case states a blocker that is deliberately *not* the API-key message, for the
    /// reason `aConfigurationProblemRefusesVoiceWithoutDisablingTheControl` gives: it proves the
    /// hint's text arrives from the blocker rather than from a literal that happens to sit beside
    /// it, which is what has to keep holding once SONNY-136 changes what the blocker reports.
    @Test
    func theHoverHintRemindsWhenVoiceWorksAndReportsTheProblemWhenItDoesNot() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let working = try makeViewModel(root: root)
        working.voiceConfigurationBlockerOverride = { nil }
        #expect(working.micHoverHintPresentation.message == AgentViewModel.micHoverShortcutReminder)
        #expect(
            working.micHoverHintPresentation.autoDismissDelay == .seconds(3),
            "a reminder that will not leave is nagging — three seconds, and it goes (SONNY-179)"
        )

        let blocked = try makeViewModel(root: root)
        blocked.voiceConfigurationBlockerOverride = { "Sonny has no transcription provider configured." }
        #expect(
            blocked.micHoverHintPresentation.message == "Sonny has no transcription provider configured."
        )
        #expect(
            blocked.micHoverHintPresentation.autoDismissDelay == nil,
            "the message reporting something broken stays for the whole hover"
        )
    }

    /// SONNY-177's structural half. The hover and the press are one condition on one control, and
    /// they say the same thing because they take it from the same place — not because two literals
    /// happen to match today, which is precisely how the mic and the hotkey came to disagree in
    /// SONNY-173.
    @Test
    func hoveringAndPressingTheMicSayTheSameThingWhenVoiceIsUnconfigured() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { "Sonny has no transcription provider configured." }

        let hovered = viewModel.micHoverHintPresentation.message

        // `#require`, not `#expect`: see the note on the suite.
        try #require(viewModel.canUseVoice == false)
        viewModel.toggleVoiceRecording(origin: .widget)

        #expect(viewModel.errorMessage == hovered)
        #expect(viewModel.errorIsPersistent)
    }

    /// The live rule, with no override in the way, in whatever environment the suite is actually
    /// running in. Both branches assert something real, so this is deterministic rather than
    /// conditionally skipped — it is the one test here that does read `hasAPIKey`.
    @Test
    func theLiveRuleBlocksVoiceOnNothingAtAllSinceTheGatewayLanded() throws {
        // **The successor to `theLiveRuleReportsAMissingKeyAndOnlyAMissingKey`** (SONNY-130), and
        // the outcome is inverted because the rule's one input is gone. Transcription runs through
        // Sonny's backend under the user's session, and the founder's manual item launches the
        // packaged app from Finder — where no shell environment exists, so a gate on
        // `OPENAI_API_KEY` would have blocked the mic on every launch this ticket is about.
        //
        // Unconditional now, where the old test had to branch on the environment the suite happened
        // to be launched with. `hasAPIKey` still exists and still answers about the variable; what
        // changed is that voice no longer asks it.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)

        #expect(viewModel.voiceConfigurationBlocker == nil)
        #expect(viewModel.canUseVoice)
        // The message it used to return is gone as well (SONNY-136), and with it the last thing in
        // this file that named a credential. What is left is the seam and the rule.
        #expect(viewModel.micHoverHintPresentation.message == AgentViewModel.micHoverShortcutReminder)
    }

    /// The half the fix must not have broken. Each of these clears on its own, the user can do
    /// nothing about any of them, and a press during one is correctly swallowed — so the button
    /// stays disabled and nothing is said.
    ///
    /// **Four reasons, not five** (SONNY-283): "a clarification open" was the fifth and is no longer
    /// transient at all — the founder decided voice answers a clarification, so a press during one
    /// is the one the product most wants. `aPendingClarificationLeavesTheMicLiveAndVoiceUsable`
    /// below holds the other direction.
    @Test
    func everyTransientReasonStillDisablesTheMicAndStaysSilent() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let reasons: [(reason: String, apply: (AgentViewModel) -> Void)] = [
            ("a run in flight", { $0.isRunning = true }),
            (
                "an approval waiting",
                {
                    $0.approvalRequest = RiskApprovalRequest(
                        assessment: CapabilityRiskAssessment(defaultTier: .tier2),
                        requirement: .explicitApproval
                    )
                }
            ),
            ("the recorder starting up", { $0.isPreparingVoiceRecording = true }),
            ("a transcription in flight", { $0.isTranscribingVoice = true })
        ]

        for (reason, apply) in reasons {
            let viewModel = try makeViewModel(root: root)
            // Configuration is fine, so the transient state is the only thing under test.
            viewModel.voiceConfigurationBlockerOverride = { nil }
            #expect(viewModel.isVoiceTransientlyBusy == false, "\(reason): precondition")
            #expect(viewModel.isVoiceControlDisabled == false, "\(reason): precondition")
            #expect(viewModel.canUseVoice, "\(reason): precondition")

            apply(viewModel)

            #expect(viewModel.isVoiceTransientlyBusy, "\(reason) must count as transient")
            #expect(viewModel.isVoiceControlDisabled, "\(reason) must disable the mic control")
            try #require(viewModel.canUseVoice == false, "\(reason) must refuse voice")

            // A disabled button cannot be pressed, but the hotkey is gated by no view state at
            // all — so this is the one reachable press during a transient refusal, and it must
            // say nothing. Reached only past the `#require` above, which is what keeps a broken
            // gate from walking this press into the recorder.
            viewModel.beginPushToTalkVoice()
            #expect(viewModel.errorMessage == nil, "\(reason) must not explain itself")
            #expect(viewModel.isRecordingVoice == false, "\(reason) must not start recording")
            #expect(viewModel.isPreparingVoiceRecording == (reason == "the recorder starting up"))
        }
    }

    /// **SONNY-283: a parked clarification leaves the mic live and voice usable**, with the control
    /// that the same fixture one line earlier refused for a transient reason — so this is a claim
    /// about the clarification term and not about a fixture whose voice happens to be free.
    ///
    /// The founder found both the mic button and the push-to-talk hotkey inert while a question was
    /// pending. The cause was this predicate: `clarificationQuestion != nil` was a term of
    /// `isVoiceTransientlyBusy`, so the button was `.disabled` and the hotkey's `canUseVoice` guard
    /// refused in silence — correctly silent for a transient reason, and wrong that this was one.
    /// Nothing here presses the mic with voice available (see the note on the suite); what the
    /// predicates say is the whole of what a press would consult.
    @Test
    func aPendingClarificationLeavesTheMicLiveAndVoiceUsable() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }

        // The control: a transient reason still refuses in this fixture.
        viewModel.isTranscribingVoice = true
        #expect(viewModel.isVoiceControlDisabled)
        #expect(viewModel.canUseVoice == false)
        viewModel.isTranscribingVoice = false

        viewModel.clarificationQuestion = "Which folder?"

        #expect(viewModel.isVoiceTransientlyBusy == false, "a question waiting on the user is not the app being busy")
        #expect(viewModel.isVoiceControlDisabled == false, "the mic button must be pressable while a question is pending")
        #expect(viewModel.canUseVoice, "the hotkey's guard must let a recording start while a question is pending")
        // And a recording started now is for the answer field, not for a new task.
        #expect(
            AgentViewModel.VoiceRecordingPurpose.forRecordingStarted(clarificationQuestion: "Which folder?")
                == .clarificationAnswer(question: "Which folder?")
        )
        #expect(
            AgentViewModel.VoiceRecordingPurpose.forRecordingStarted(clarificationQuestion: nil)
                == .command
        )
    }

    /// The fix, stated as the property it actually is: a configuration failure refuses voice and
    /// leaves the control pressable, so the press is what explains the failure.
    ///
    /// The message deliberately is **not** the API-key one. It proves the text reaches the user
    /// from the blocker rather than from a literal that happens to sit next to the guard — which is
    /// what has to hold once SONNY-136 changes what the blocker reports.
    @Test
    func aConfigurationProblemRefusesVoiceWithoutDisablingTheControl() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { "Sonny has no transcription provider configured." }

        try #require(viewModel.canUseVoice == false)
        #expect(viewModel.isVoiceTransientlyBusy == false)
        #expect(viewModel.isVoiceControlDisabled == false)

        viewModel.toggleVoiceRecording(origin: .widget)

        #expect(viewModel.errorMessage == "Sonny has no transcription provider configured.")
        #expect(viewModel.errorIsPersistent)
    }

    /// The stop half. Once a recording is running the button is Stop, and something transient
    /// landing mid-sentence — an approval from a run started elsewhere — must not disable it and
    /// trap the user in a live microphone.
    @Test
    func aTransientStateArrivingMidRecordingLeavesStopPressable() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }
        viewModel.isRecordingVoice = true

        viewModel.approvalRequest = RiskApprovalRequest(
            assessment: CapabilityRiskAssessment(defaultTier: .tier2),
            requirement: .explicitApproval
        )

        #expect(viewModel.isVoiceTransientlyBusy)
        #expect(viewModel.canUseVoice == false)
        #expect(viewModel.isVoiceControlDisabled == false)
    }

    /// Phase 11, the voice lane: the countdown's own auto-stop, firing on its own once the window
    /// elapses.
    ///
    /// **Cannot go through `startVoiceRecording`/`toggleVoiceRecording`**, for the reason this
    /// suite's own header gives — the real path reaches `AVCaptureDevice.requestAccess`, which a
    /// `swift test` process has no bundle identity to survive. So the state `startVoiceRecording`
    /// would have set is arranged directly (the same technique
    /// `aTransientStateArrivingMidRecordingLeavesStopPressable` uses for `isRecordingVoice`), and
    /// `scheduleVoiceRecordingAutoStop` — driven directly, like `deliverTranscript` and
    /// `deliverTranscriptionError` beside it — is called to arm the real `Task`.
    ///
    /// **What this can and cannot prove.** `audioRecorder` is a concrete, un-fakeable
    /// `AudioCommandRecorder` (`AudioCommandRecorder.start()` opens a real `AVAudioRecorder`, which
    /// is exactly the boundary this suite never crosses), and no recording was ever really started
    /// here — so when the auto-stop fires, `stopVoiceRecordingAndTranscribe`'s
    /// `audioRecorder.stop()` throws `VoiceRecordingError.noActiveRecording` and the function takes
    /// its failure arm rather than the success one. That arm still runs first and still clears both
    /// published properties, which is the property this test can honestly hold: the auto-stop found
    /// a live recording (by `voiceRecordingStartedAt` matching) and ended it. What it cannot prove
    /// is that a *real* recording's transcription follows — no test in this suite can, per its own
    /// header.
    @Test
    func theAutoStopEndsTheRecordingOnceTheWindowElapses() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }
        viewModel.voiceRecordingListeningWindow = 0.05

        let startedAt = Date()
        viewModel.isRecordingVoice = true
        viewModel.voiceRecordingStartedAt = startedAt
        viewModel.scheduleVoiceRecordingAutoStop(startedAt: startedAt)

        // Awaits the real `Task` rather than sleeping a fixed interval and hoping it has finished
        // by then (CLAUDE.md's own gotcha on exactly that pattern) — the window above is short only
        // so this test does not sit for three minutes, not so a sleep-then-assert can guess at it.
        await viewModel.voiceRecordingAutoStopTask?.value

        #expect(viewModel.isRecordingVoice == false, "the stop path must have run")
        #expect(viewModel.voiceRecordingStartedAt == nil)
    }

    /// The other half: a stop that beats the deadline cancels the scheduled auto-stop, so a
    /// recording the user ended themselves is never stopped a second time.
    ///
    /// `toggleVoiceRecording` with `isRecordingVoice` already `true` reaches
    /// `stopVoiceRecordingAndTranscribe` directly — the same "the mic's Stop" path the doc comment
    /// on `scheduleVoiceRecordingAutoStop` names — without ever touching the microphone-permission
    /// branch `startVoiceRecording` guards.
    @Test
    func aStopBeforeTheDeadlineCancelsTheScheduledAutoStop() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }
        // A day, not a minute: a window the test must not reach is a wall-clock bet, and a loaded
        // machine collects. With sixty seconds, a run beside three other lanes' builds took 87
        // seconds inside this test, the task fired, and two assertions failed on a clean tree
        // (phase 12, the insights lane's first run). Bounded far past any delay the machine can
        // produce, as CLAUDE.md's wall-clock gotcha asks.
        viewModel.voiceRecordingListeningWindow = 86_400

        let startedAt = Date()
        viewModel.isRecordingVoice = true
        viewModel.voiceRecordingStartedAt = startedAt
        viewModel.scheduleVoiceRecordingAutoStop(startedAt: startedAt)
        let scheduledTask = try #require(viewModel.voiceRecordingAutoStopTask)

        viewModel.toggleVoiceRecording(origin: .widget)

        #expect(viewModel.isRecordingVoice == false, "the manual stop must have run")
        #expect(viewModel.voiceRecordingStartedAt == nil)

        // `cancel()` sets `isCancelled` synchronously, so the flag is the signal and nothing is
        // awaited. Awaiting the task's value here would wait out the whole window under a mutant
        // that drops the cancel, which is how the phase 12 battery stalled on exactly that mutant
        // for a day-long window instead of reporting the kill. The task is cancelled again
        // afterwards either way, so nothing sleeping outlives the test.
        #expect(scheduledTask.isCancelled, "the manual stop must cancel the task it is racing")
        scheduledTask.cancel()
    }

    /// Two schedules back to back leave one live task: the second cancels the first, so a stop and
    /// a fresh press inside one window never leave two auto-stops racing (phase 11 review, F3).
    @Test
    func schedulingASecondAutoStopCancelsTheFirst() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }
        viewModel.voiceRecordingListeningWindow = 86_400

        let first = Date()
        viewModel.isRecordingVoice = true
        viewModel.voiceRecordingStartedAt = first
        viewModel.scheduleVoiceRecordingAutoStop(startedAt: first)
        let firstTask = try #require(viewModel.voiceRecordingAutoStopTask)

        let second = first.addingTimeInterval(1)
        viewModel.voiceRecordingStartedAt = second
        viewModel.scheduleVoiceRecordingAutoStop(startedAt: second)
        let secondTask = try #require(viewModel.voiceRecordingAutoStopTask)

        // The flag, never the first task's value: under a mutant that drops the cancel the value
        // would take the whole window to arrive (see the stop test above).
        #expect(firstTask.isCancelled, "the second schedule must cancel the first")
        #expect(!secondTask.isCancelled)
        #expect(viewModel.isRecordingVoice, "neither task stopped anything")
        firstTask.cancel()
        secondTask.cancel()
    }

    /// An auto-stop scheduled for one recording must never stop a different one: the guard on
    /// `voiceRecordingStartedAt` holds that, belt and braces beside cancel-on-stop, so it is exercised
    /// on its own here with the task left live and the start time moved underneath it.
    @Test
    func anAutoStopScheduledForAnEarlierRecordingLeavesTheLiveOneAlone() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }
        viewModel.voiceRecordingListeningWindow = 0.05

        let earlier = Date()
        viewModel.isRecordingVoice = true
        viewModel.voiceRecordingStartedAt = earlier
        viewModel.scheduleVoiceRecordingAutoStop(startedAt: earlier)
        let scheduledTask = try #require(viewModel.voiceRecordingAutoStopTask)

        // A later recording is the live one now, and nothing cancelled the earlier task.
        let later = earlier.addingTimeInterval(1)
        viewModel.voiceRecordingStartedAt = later

        await scheduledTask.value
        #expect(viewModel.isRecordingVoice, "a task for an earlier recording must not stop the live one")
        #expect(viewModel.voiceRecordingStartedAt == later)
    }

    /// **A hotkey release that arrives after the auto-stop has already ended the recording must do
    /// nothing a second time.** `endPushToTalkVoice`'s `guard isRecordingVoice else { return }` is
    /// what this pins: without it, a release landing after the countdown's own stop would call
    /// `stopVoiceRecordingAndTranscribe` again.
    ///
    /// Observed through `errorMessage` rather than through a call count, since nothing here exposes
    /// one: the failure arm of `stopVoiceRecordingAndTranscribe` (see
    /// `theAutoStopEndsTheRecordingOnceTheWindowElapses`'s note on why that is the arm this fixture
    /// always takes) calls `setError`, so a second, un-guarded call would leave a fresh message
    /// where this test clears one to nothing.
    @Test
    func hotkeyReleaseAfterAnAutoStopRemainsHarmless() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)
        viewModel.voiceConfigurationBlockerOverride = { nil }
        viewModel.voiceRecordingListeningWindow = 0.05

        let startedAt = Date()
        viewModel.isPushToTalkHotKeyDown = true
        viewModel.isRecordingVoice = true
        viewModel.voiceRecordingStartedAt = startedAt
        viewModel.scheduleVoiceRecordingAutoStop(startedAt: startedAt)
        await viewModel.voiceRecordingAutoStopTask?.value
        try #require(viewModel.isRecordingVoice == false)

        // The auto-stop's own failure arm already cleared `isPushToTalkHotKeyDown` and left an
        // error behind; simulate the hotkey's physical key still being down when its release now
        // arrives, with the trace cleared so a second stop is visible.
        viewModel.isPushToTalkHotKeyDown = true
        viewModel.errorMessage = nil

        viewModel.endPushToTalkVoice()

        #expect(viewModel.isPushToTalkHotKeyDown == false)
        #expect(viewModel.isRecordingVoice == false)
        #expect(
            viewModel.errorMessage == nil,
            "a release after the recording already ended must not stop it a second time"
        )
    }

    /// The class guard, half one. `.disabled` is where this bug lives: a term folded into one is a
    /// press the user makes and never hears back about, so no `.disabled` predicate anywhere in the
    /// app may mention the actionable half of voice readiness.
    ///
    /// Same shape as `ShellSurfaceDetectorTests.onlyTheDetectorProducesVerdictsInTheLiveModule` —
    /// a rule a reader would otherwise be the only thing enforcing.
    @Test
    func noDisabledPredicateInTheAppGatesOnAnActionableFailure() throws {
        // `hasAPIKey` was the third term and SONNY-136 deleted the property, so forbidding it here
        // would forbid a symbol that cannot exist. The two that remain are the composite and the
        // actionable half itself, which are the two a future `.disabled` would reach for.
        let forbidden = ["canUseVoice", "voiceConfigurationBlocker"]
        var offenders: [String] = []
        let files = try Self.appSourceFiles()
        // The scan means nothing if it did not really find the module.
        #expect(files.count > 20)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for predicate in disabledPredicates(in: source) {
                for term in forbidden where predicate.contains(term) {
                    offenders.append("\(file.lastPathComponent): .disabled(\(predicate))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A control may only be disabled for a transient reason. Gate on \
            `AgentViewModel.isVoiceControlDisabled` (or `isVoiceTransientlyBusy`) and let the guard \
            inside `startVoiceRecording` explain the actionable failure instead: \(offenders)
            """
        )
    }

    /// The class guard, half two. `.disabled` is not the only way to make a press impossible — a
    /// view that branches on voice readiness can hide the control outright and reproduce the same
    /// silence. So the readiness internals stay where they are computed and no view reads them.
    ///
    /// **Two terms, not one, and the second was a hole this guard used to leave open.** Scanning
    /// only for `canUseVoice` let `if viewModel.voiceConfigurationBlocker == nil { micButton }`
    /// through — a view that hides the mic exactly when the user has something to fix, which is
    /// SONNY-173's silence rebuilt out of the actionable half alone, and it touches neither
    /// `.disabled(` nor the composite. It is also the obvious wrong fix someone reaches for.
    /// Filed as residual (a) by PR #73's cycle-1 review and left recorded through cycle 2; closed
    /// here, and the mutant expressing that view is in the branch's battery precisely because it
    /// *survived* this guard before the second term was added.
    ///
    /// Views take `isVoiceControlDisabled`, which is the transient half and nothing else.
    @Test
    func theCompositeVoiceReadinessIsReadInOneFileOnly() throws {
        var readingFiles: Set<String> = []
        let files = try Self.appSourceFiles()
        #expect(files.count > 20)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("canUseVoice") || source.contains("voiceConfigurationBlocker") {
                readingFiles.insert(file.lastPathComponent)
            }
        }

        #expect(
            readingFiles == ["AgentViewModel.swift"],
            """
            A view may read neither `canUseVoice` — the composite, actionable and transient folded \
            together — nor `voiceConfigurationBlocker`, the actionable half on its own. Branching \
            on either lets a view refuse or hide a press for a reason it never shows. Views take \
            `isVoiceControlDisabled`; both of these stay internal. Found in: \
            \(readingFiles.sorted())
            """
        )
    }

    /// Every `.disabled(...)` argument in `source`, with nesting handled, since these predicates
    /// really do contain parenthesised calls.
    private func disabledPredicates(in source: String) -> [String] {
        var predicates: [String] = []
        var searchStart = source.startIndex

        while let opening = source.range(of: ".disabled(", range: searchStart..<source.endIndex) {
            var depth = 1
            var index = opening.upperBound
            while index < source.endIndex, depth > 0 {
                switch source[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth > 0 {
                    index = source.index(after: index)
                }
            }
            if depth == 0 {
                predicates.append(String(source[opening.upperBound..<index]))
            }
            searchStart = opening.upperBound
        }

        return predicates
    }

    private static func appSourceFiles() throws -> [URL] {
        // <package root>/Tests/MacAgentTests/<this file>
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgent")
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }
}

@MainActor
private func makeViewModel(root: URL) throws -> AgentViewModel {
    let suiteName = "WidgetVoiceEntryTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json")
        ),
        shortcutCatalog: VoiceEntryEmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). Nothing here runs a
        // plan today, but the fixture is hermetic structurally rather than by luck — the same
        // reasoning `CommandCenterAttentionSurfaceTests` records beside its own copy.
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        finderRevealer: hermeticFinderRevealer,
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json")
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json")
        ),
        resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
        pendingServerDeletionStore: PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json")
        ),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: VoiceEntryFakePasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
        // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
        // every request fails before a URL is built, and an in-memory Keychain of its own.
        backendClient: makeHermeticBackendClient(),
        // In-memory by construction — this store has no file at all.
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
}

private struct VoiceEntryEmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class VoiceEntryFakePasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WidgetVoiceEntryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
