import AppKit
import MacAgentCore
import SwiftUI

/// The floating widget's own lifecycle model — §3.3's six wireframe states plus a best-effort
/// seventh (clarification) that no wireframe covers, since AgentViewModel can genuinely reach it.
/// `.stepError` from §3.3.5 is deliberately not a distinct case here: today's `AgentActionExecutor`
/// treats any step failure as whole-run failure (all steps flip to `.failed` together, no partial-
/// plan resume) — see docs/sonny-ui-backend-gaps.md. A failed row's coral treatment still renders
/// for real inside `.working`/`.failure` via `AgentStepStatus.failed`; there is no separate real
/// per-step-retry action to attach a button to, so `.failure` is the only true terminal error state.
///
/// **Internal rather than private, so a test can read the state the widget resolved to** (SONNY-255).
/// This precedence is the most consequential ordering in the app and it was, until that ticket, held
/// by source scans alone — which pin where a branch sits in a file and cannot say what the widget
/// does with a real view model in a real state. The defect they missed was exactly that gap:
/// `.controlling` sat above `.permission`, so from a screen-control session's first iteration the
/// approval it raised mid-loop was unreachable, and every scan of the file agreed the branch was
/// where the file said it was. Nothing outside `FloatingWidgetView` and its tests reads this.
enum WidgetState {
    case idle
    case working
    case clarification(String)
    /// A risk approval is parked on the user.
    ///
    /// **Above `.controlling`, and that placement is this state's whole design** (SONNY-255). It
    /// used to sit below, which made it unreachable for the entire length of a screen-control
    /// session: `visionSessionProgress` is written at the top of every iteration and cleared only
    /// when the session ends, so `.controlling` won from iteration 1 onward and a mid-loop approval
    /// rendered in the widget nowhere at all — the panel on screen was the HUD, which carries no
    /// question, while the loop sat waiting for an answer to one. Every mid-loop *action* approval
    /// took that path (`VisionSessionRunner`'s per-action gate raises it after the iteration's
    /// progress report), so it was the common case rather than an edge.
    ///
    /// It now sits with the three parked questions above it rather than under the progress line, and
    /// the rule that puts it there is uniform: **a parked continuation outranks a progress report**.
    /// `.captureReview`, `.delegationReview` and `.sessionPaused` are all suspended continuations
    /// inside a live session and are all already above `.controlling` for that reason; this is the
    /// fourth, and it was the one placed below the line by accident rather than by argument. The
    /// HUD is not merely outranked here, it is *inaccurate*: its action line was written at the top
    /// of this iteration and names looking at the app, not the action being asked about.
    case permission(RiskApprovalRequest)
    /// Safe mode is about to send a screenshot of an app, and is showing it first (row I, SONNY-92;
    /// founder decision 2, 2026-08-14).
    ///
    /// A seventh state rather than a variant of `.permission`, because it is answering a different
    /// question — "may this leave your Mac" rather than "may Sonny do this" — and because its own
    /// controls are Send/Don't send, not Allow/Deny. It sits above `.permission` in the precedence
    /// below for the reason every precedence here exists: it is a parked continuation, so a state
    /// that outranked it would leave a Safe-mode session suspended with nothing on screen able to
    /// answer it.
    case captureReview(VisionCapturePreview)
    /// Safe mode is about to hand an instruction to Sonny's own planner, and is asking first (row I,
    /// SONNY-93; founder decision 4, 2026-08-14). Normal and Power never reach this state.
    case delegationReview(VisionDelegationRequest)
    /// The session paused because the user stopped being at the Mac (row I, SONNY-94). Resuming is
    /// an explicit press — nothing here clears itself.
    case sessionPaused(VisionSessionPause)
    /// Sonny is controlling an app right now (row I, SONNY-95). The HUD: what it is doing, in which
    /// app, with Stop always reachable and Pause reachable while the loop is advancing.
    ///
    /// **"Pause and Stop always reachable" is what this line said, and SONNY-255's own hunks left it
    /// standing while making half of it false** (PR #132 review, F2 — the same stale-comment class
    /// this ticket corrected four of elsewhere). Stop is always reachable and now genuinely is on
    /// both panel shapes; Pause is offered only here, and the paragraph below the `case` and
    /// `WidgetControllingPanel`'s own Stop comment both say why.
    ///
    /// **Below every question a session can park, all four of them** (SONNY-255 added the fourth).
    /// This describes a loop that is advancing; each of those describes a loop that has stopped and
    /// is waiting on a human, and a progress line drawn over a waiting continuation is a widget
    /// saying "working" about something that is not. Stop does not go with it: while an approval is
    /// up, `WidgetPermissionPanel` carries the session's own Stop, so the emergency control for a
    /// program driving the user's screen is on screen in both states.
    case controlling(VisionSessionProgress)
    case result(String, RunSuggestion?)
    case failure(String)
    /// §8.3's wall: this deployment refuses this build, so nothing that needs the gateway can work
    /// (SONNY-402).
    ///
    /// **Above `.failure` and below every parked question.** Above, because a failure panel offers
    /// Retry and a `410 version.unsupported` is the one refusal the contract defines as permanent —
    /// §9.3 makes it non-retryable and `SonnyBackendErrorCode.maximumAttempts` answers 1 — so the
    /// state that says "try again" must not be what the user is looking at. Below, because the four
    /// parked continuations, the live session's HUD and an unanswered clarification are all things
    /// a *local* capability can produce with the gateway never touched, and every one of them hangs
    /// a run if the widget declines to draw it. That is `WidgetState`'s standing rule — a parked
    /// continuation outranks everything that is merely a report — and this is a report about the
    /// app rather than a question waiting on the user.
    case tooOld(ClientVersionPrompt)
    /// §8.4's warning: below `recommended_client`, and everything still works (SONNY-402).
    ///
    /// **Last of all, above nothing but `.idle`, and that placement is the whole of this state's
    /// design.** It is not about a task at all, and the band it reports lasts until the user
    /// updates — days or weeks. Placed anywhere above `.resumeOffer` it would hold every other panel
    /// off screen for that whole time, which is the failure `.resumeOffer`'s own placement argument
    /// spells out one case further down: a fifth competitor for this surface must not be able to
    /// displace a thing from now, and this is not even a thing from before.
    case updateAvailable(ClientVersionPrompt)
    /// Sonny is offering to carry on with a task an earlier run began and did not finish (row 13,
    /// SONNY-210).
    ///
    /// **Last in the precedence below, above nothing but `.idle`, and that placement is the whole
    /// of this state's design.** Every case above it describes the task the user is doing *now* — a
    /// question parked on them, a run in flight, the outcome of the one that just ended. This
    /// describes a task from before, and a thing from before must never take the surface from a
    /// thing from now. That is not a stylistic preference: CLAUDE.md records this precedence as
    /// already delicate, because `.failure` sits ahead of `.result` and a bookkeeping write failure
    /// routed into `errorMessage` twice replaced the result of a task that had actually succeeded.
    /// A fifth competitor for the panel is exactly the shape that goes wrong the same way, so it is
    /// placed where it cannot: below `.failure`, so a run that failed partway shows why rather than
    /// an offer with the reason hidden, and below `.result`, so a finished task's answer is never
    /// displaced by an older task's question.
    case resumeOffer(ResumableTask)
}

struct FloatingWidgetView: View {
    @ObservedObject var viewModel: AgentViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which of the widget's two text fields has the caret, or `nil` (SONNY-283).
    ///
    /// **Owned here, for both fields, rather than one `Bool` per field.** The composer used to own
    /// `pillFocused` and the clarification panel its own `answerFocused`, and the push-to-talk
    /// hotkey's presentation request could reach only the first — which correctly refused to focus
    /// a disabled composer while a question was parked, and then had nothing else to focus. The
    /// panel takes a binding to this, so every summon goes through one helper that knows about
    /// both fields; `WidgetInputField.takingInput` is the rule.
    @FocusState private var focusedField: WidgetInputField?
    /// Per Wispr Flow's own "shrink the bubble when not in use" behavior — collapses to a tiny
    /// icon-only capsule after a period with nothing needing attention, so the widget doesn't sit
    /// on screen as a constant visual barrier. Only meaningful while `isCollapsible` (see below);
    /// forced back to `false` the instant something needs real attention. One single timer drives
    /// both this AND clearing stale `.result`/`.failure` content together (see
    /// `scheduleAutoDismissIfNeeded`) — they used to be two separate timers at two different
    /// delays, which was a real, reported bug: the widget would visually shrink while the old
    /// result/error was still logically "there," and anything that caused a re-render before the
    /// second timer caught up would show the exact same stale content again, reading as "it took
    /// multiple compacts to actually go away."
    @State private var isCompact = false
    @State private var autoDismissTask: Task<Void, Never>?
    /// Whether a hint should be showing, and its countdown. Deliberately not `@State` — see
    /// `MicHoverHintModel`, which exists so the countdown is something a test can drive, and which
    /// records why "should be showing" is not quite "on screen": this view still has to hand it the
    /// slot, below.
    ///
    /// **The only thing this view keeps about the hover.** Where the pointer is is not stored here
    /// at all — the mic's tracking view reports each arrival and departure and this responds; see
    /// `micHintPointerEnteredMic` for the hover SONNY-179 found a stored copy swallowing.
    ///
    /// *How long* it counts for is not here and not `WidgetAutoCollapseDelay`'s: it
    /// arrives with the hint, from `AgentViewModel.micHoverHintPresentation`, because one of the two
    /// hints this row can show does not count down at all.
    @StateObject private var micHint = MicHoverHintModel()

    var body: some View {
        // .leading, not .trailing: the panel and pill are both a fixed 472pt (matching the
        // wireframe, where the mic button is a separate satellite floating outside that column,
        // not part of its width) — the pill+mic HStack is wider than the panel alone (~520pt vs
        // 472pt), so .trailing right-aligned them, leaving the panel's *left* edge visibly
        // indented relative to the pill below it. That was the "error banner misplaced" bug.
        VStack(alignment: .leading, spacing: 12) {
            // One positioning mode, always — the widget never composites into Command Center's
            // (or any other app's) own window. See FloatingWidgetWindowController's doc comment.
            if isCompact {
                compactCapsule
            } else {
                if showsPanel {
                    styledPanel
                } else if let hint = micHint.visibleHint {
                    micHoverHintRow(hint)
                }

                // What the scheduler did while nobody was watching (SONNY-113). Until now this
                // notice rendered on exactly four Command Center pages and nowhere else, and the
                // notification that was supposed to cover "nobody is looking at Command Center" is
                // suppressed whenever the user *is* working in Sonny — so a routine that fired while
                // they sat on a routine-detail or workspace-detail sheet, or typed into this widget
                // with Command Center closed, reached them on no surface at all. Founder decision,
                // 2026-08-20.
                //
                // First in the stack, mirroring the precedence Command Center's own notice row
                // already states: it reports something that already happened without the user
                // present, which outranks an ambient storage problem that will still be true after
                // they dismiss this.
                //
                // The accent tint rather than the error red, because this channel carries successes
                // too — `clock.arrow.circlepath` is the same glyph Command Center shows for the same
                // notice, so one event does not look like two different kinds of thing depending on
                // which surface the user reads it on.
                if let notice = viewModel.scheduledRunNotice {
                    WidgetNoticeStrip(
                        message: notice,
                        icon: "clock.arrow.circlepath",
                        tint: WidgetTheme.primaryAction,
                        dismissAccessibilityLabel: "Dismiss scheduled run notice"
                    ) {
                        viewModel.scheduledRunNotice = nil
                    }
                }

                if let notice = viewModel.localStorageNotice {
                    WidgetNoticeStrip(
                        message: notice,
                        icon: "externaldrive.badge.exclamationmark",
                        dismissAccessibilityLabel: "Dismiss storage notice"
                    ) {
                        viewModel.localStorageNotice = nil
                    }
                }

                // **A second notice strip stood here and is gone** (SONNY-132). It was the planner
                // router's "never a silent planner swap" surface (SONNY-85), naming which planner
                // had actually planned a task when the configured selection could not be honored.
                // Provider choice is a server decision now, the response is forbidden from naming
                // which provider served it (contract §4.2), and a task that fails outright still
                // says so through `errorMessage` below. `AgentViewModel`'s own note where the
                // published property used to be enumerates all four states and where each went.

                // **Bottom-aligned since the pill can carry a chip row** (SONNY-150). With
                // `.center` the two circular buttons would float against the middle of a 66pt pill
                // while the text field sat at its foot. Their own 40pt box makes their centres land
                // exactly on the field row's, and in the no-chip case the whole thing is
                // pixel-identical to what it was: a 40pt pill beside a 40pt box.
                //
                // `micButton` always renders, so the box is never empty and its spacing never opens
                // a gap where a hidden `dontSaveButton` used to be.
                HStack(alignment: .bottom, spacing: 12) {
                    composerPill
                    HStack(spacing: 12) {
                        dontSaveButton
                        voiceRecordingCountdownLabel
                        micButton
                    }
                    .frame(height: 40)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: widgetStateKey)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isCompact)
        // Real headroom for the (now much smaller, border-led) shadow plus a little breathing
        // room around the glass edge — not shadow-bleed-driven the way the old, larger padding
        // was, since there's no more large drop shadow needing room to fade out.
        .padding(16)
        .onAppear {
            focusTheFieldThatTakesInput()
            scheduleAutoDismissIfNeeded()
        }
        .onChange(of: widgetStateKey) { _, _ in
            scheduleAutoDismissIfNeeded()
        }
        .onChange(of: viewModel.command) { _, _ in
            if !isCompact {
                scheduleAutoDismissIfNeeded()
            }
        }
        .onChange(of: isVoiceActive) { _, _ in
            scheduleAutoDismissIfNeeded()
        }
        // An arriving scheduled notice re-runs the collapse decision, which now refuses (see
        // `isCollapsible`) and so pushes `isCompact` back to false. Without this the guard would
        // only be consulted the next time something else changed, and a routine firing at an
        // already-compact widget would sit behind the capsule until then.
        .onChange(of: viewModel.scheduledRunNotice) { _, _ in
            scheduleAutoDismissIfNeeded()
        }
        // The one place the allowance is read for the widget (SONNY-214). Asked when a
        // screen-control task goes in flight; an ordinary task asks for nothing, which is the same
        // rule the line's own gate follows one property up.
        //
        // **What this does not do, corrected here rather than left overstated** (PR #188's F7): the
        // read is asynchronous and nothing clears the figure first, deliberately — clearing would
        // blink the line off at exactly the moment the ticket wants it on screen. So from the moment
        // the run goes in flight until the reply lands, the line shows the *previous* read: one run
        // stale after a completed session, and for a whole client timeout on a slow network. The
        // figure is an estimate either way (SONNY-212 derives it at read time), which is what makes
        // that trade the right one and not merely the convenient one.
        .onChange(of: viewModel.isScreenControlTaskInFlight) { _, isScreenControl in
            if isScreenControl {
                Task { await viewModel.refreshScreenControlAllowance() }
            }
        }
        .onChange(of: viewModel.widgetPresentationRequest) { _, _ in
            if isCompact {
                expandFromCompact()
            } else {
                focusTheFieldThatTakesInput()
                scheduleAutoDismissIfNeeded()
            }
        }
        // The panel (or a collapse) taking the slot mid-countdown dismisses the hint and cancels
        // with it, so nothing is left counting toward a row that is no longer there. The slot coming
        // back free deliberately does not re-show it: the user is looking at whatever just finished,
        // not at a reminder they have already been given. It returns on the next real hover.
        .onChange(of: isMicHintSlotFree) { _, isFree in
            if !isFree {
                micHint.dismiss()
            }
        }
        .onDisappear {
            micHint.dismiss()
        }
        // Forces SwiftUI to report its real ideal (non-expanding) size rather than growing to fill
        // whatever frame AppKit hands it — FloatingWidgetWindowController reads that size via
        // NSHostingController.view.fittingSize to keep the panel bottom-pinned and tightly sized.
        .fixedSize()
    }

    /// Whether the panel (step-log/permission/clarification/result/failure) should render at all.
    /// Delegates to `AgentViewModel.hasVisibleWidgetPanel` — see its doc comment for the full
    /// per-state reasoning (origin-gating on working/result, why permission/clarification/failure
    /// always show) — kept there rather than duplicated here since `isMicHintSlotFree` below reads
    /// the exact same predicate and the two must never drift apart.
    ///
    /// Until SONNY-189 that second reader was named as `FloatingWidgetWindowController`'s
    /// compositing decision. That positioning mode was superseded on 2026-07-21, the controller has
    /// had exactly one mode since (see its doc comment), and nothing composites into Command Center
    /// anymore. What survives the correction is why the sentence was here at all: this is one
    /// predicate read in more than one place, and a second reader disagreeing with it once made the
    /// widget vanish silently at launch.
    private var showsPanel: Bool {
        viewModel.hasVisibleWidgetPanel
    }

    /// Whether the hover hint's slot is free. The panel and the compact capsule both occupy the same
    /// slot and both outrank it, so this is the one predicate the hint is gated on — the panel's own
    /// states are enumerated on `AgentViewModel.hasVisibleWidgetPanel`.
    private var isMicHintSlotFree: Bool {
        !isCompact && !showsPanel
    }

    /// Voice recording/transcription isn't part of `WidgetState` (it's orthogonal to a task being
    /// in flight) — omitting it from `isCollapsible` was a real bug: the widget auto-collapsed
    /// mid-recording, hiding the mic UI while it was actively listening.
    private var isVoiceActive: Bool {
        // The view model's own composite, so the collapse rule here and the answer gate
        // (`canSendClarificationAnswer`) read one definition of "voice is in flight".
        viewModel.isVoiceInputInFlight
    }

    /// Matches your own framing: compact only when "nothing is running or user is not using
    /// Sonny at the moment" — anything actively needing a decision (working/permission/
    /// clarification), or active voice input, stays fully visible, same as Wispr Flow's bubble
    /// expanding during active recording rather than shrinking away from it. `.working` is
    /// collapsible when it isn't the widget's own task — there's nothing widget-relevant being
    /// hidden by collapsing, since `showsPanel` already wouldn't render anything for it either.
    private var isCollapsible: Bool {
        guard !isVoiceActive else {
            return false
        }
        // **A scheduled notice holds the widget open until the user dismisses it (SONNY-113).**
        //
        // Without this the strip above is close to useless for the case it was added for. Every
        // notice strip renders inside the `else` branch of `if isCompact`, and the widget's steady
        // state when nobody is using Sonny is compact — which is exactly the state a routine fires
        // in. The notice would have arrived on a surface the user cannot see and been reported as
        // covered.
        //
        // Holding it open indefinitely is the intended shape, not an oversight: this is the same
        // rule `.permission` and `.clarification` follow, and the same one a notified outcome
        // follows below. Something that needs a human does not shrink itself away, and this notice
        // has an explicit Dismiss control, so nothing is stuck — the user ends it by reading it.
        //
        // Deliberately only this channel. `localStorageNotice` has the same hole and is not this
        // ticket's; SONNY-187 records it rather than widening the guard past what was decided. That
        // is still where it sits: SONNY-187 has since closed its *other* half — the storage notice
        // no longer posts a notification carrying a Retry that runs an unrelated task — and the
        // founder's decision of 2026-08-21 left this half open, because holding the widget open for
        // another channel is a behaviour change nobody has asked for.
        //
        // **This named `plannerFallbackNotice` as a second channel with the same hole, and SONNY-132
        // deleted that channel** — provider choice moved server-side, so the state it described
        // cannot occur. SONNY-187's open half is now one channel rather than two, and the sentence
        // that used to argue the two were "not symmetrical" has nothing left to compare.
        guard viewModel.scheduledRunNotice == nil else {
            return false
        }
        switch state {
        case .idle, .resumeOffer:
            // Idle is the one state where the composer is enabled and the user can actually be
            // mid-typing. Collapsing out from under unsent text after 6s of thinking-while-typing
            // was a real bug — the field is genuinely "in use" even with nothing submitted yet.
            //
            // **The offer collapses on exactly the same rule, and collapsing is not answering it**
            // (SONNY-210). Holding the widget open until an offer is answered would turn a task
            // abandoned last Tuesday into a permanent panel over the user's screen, which is the
            // opposite of what an *offer* is; and there is nothing to lose by collapsing, because
            // `shouldClearOutcomeOnDismiss` does not clear this state and the record stays on disk.
            // So the widget shrinks back to its capsule, and the offer is there again the next time
            // it is opened — which is the founder's own wording for when it should be raised.
            return viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .result, .failure:
            // An outcome the user was notified about does not collapse (SONNY-121). They were
            // working somewhere else when it happened, so the outcome's timer would measure how
            // long they have been *away*, not how long they have had to read it. Returning `false` here
            // also stops the clear: `scheduleAutoDismissIfNeeded` returns before arming the timer.
            //
            // Only `.failure` can currently be notified — the marker is set when an error
            // notification posts — but the two share this branch, and a `.result` that is not
            // notified reads `true` exactly as before.
            return !viewModel.outcomeWasNotified
        case .working:
            return viewModel.activeTaskOrigin != .widget
        case .tooOld, .updateAvailable:
            // **Collapses on exactly the rule `.idle` and `.resumeOffer` collapse on, and that is
            // the decision rather than the default** (SONNY-402). Neither state is a parked
            // continuation: nothing hangs while they are on screen, and §16.3's free local
            // capabilities keep working through both — a build the gateway refuses still opens an
            // app, expands a snippet and does arithmetic. So a widget held permanently expanded
            // would sit over the user's screen for as long as the condition lasts, which is until
            // they update, and the wall in particular has no Dismiss to end it with. Collapsing
            // loses nothing: neither state is cleared by the dismiss timer
            // (`shouldClearOutcomeOnDismiss` answers `false` for both through its `default`), so the
            // panel is there again the next time the widget is opened.
            return viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .permission, .clarification, .captureReview, .delegationReview, .sessionPaused, .controlling:
            return false
        }
    }

    /// `.result` (including a clean "Canceled.") always clears when this fires — there's no
    /// persistent-vs-transient axis for a completed run the way there is for errors, every result
    /// is tied to one specific, already-finished task. `.failure` only clears when
    /// `errorIsPersistent` is false — a config problem (API key missing, mic permission denied)
    /// keeps saying so until the user actually fixes it rather than silently vanishing.
    private var shouldClearOutcomeOnDismiss: Bool {
        switch state {
        case .result:
            return true
        case .failure:
            // Belt and braces with `isCollapsible` above, which already prevents this being reached
            // for a notified outcome. Stated twice deliberately: the two decisions are read in
            // different places, and a later change to the collapse rule must not silently start
            // wiping outcomes nobody has seen. Both read the one marker, so it is one fact.
            return !viewModel.errorIsPersistent && !viewModel.outcomeWasNotified
        default:
            return false
        }
    }

    private func scheduleAutoDismissIfNeeded() {
        autoDismissTask?.cancel()
        guard isCollapsible else {
            isCompact = false
            return
        }
        // Two figures since SONNY-446: an outcome gets longer than idle, because a collapsed
        // result is a cleared one and six seconds was not enough to read it and press Open.
        // `WidgetAutoCollapseDelay` holds both and their order; `isCollapsible` above has already
        // said this state has a clock, so a `nil` here is a state the two disagree about and the
        // safe answer is to leave it alone.
        guard let delay = WidgetAutoCollapseDelay.delay(for: state, showsPanel: showsPanel) else {
            isCompact = false
            return
        }
        let shouldClearOutcome = shouldClearOutcomeOnDismiss
        autoDismissTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isCompact = true
            if shouldClearOutcome {
                viewModel.clearStaleTaskOutcome()
            }
        }
    }

    private func expandFromCompact() {
        isCompact = false
        focusTheFieldThatTakesInput()
        scheduleAutoDismissIfNeeded()
    }

    /// Puts the caret in whichever field can use it — the composer, the clarification panel's
    /// answer field, or neither (SONNY-247, SONNY-283).
    ///
    /// **All three callers used to write `pillFocused = true` unconditionally**, which is the wrong
    /// half of the founder's report (SONNY-247). While a question is parked on the user the
    /// composer is `.disabled`, so a keystroke aimed at it reaches nothing at all — and the field
    /// that *is* live is the clarification panel's, a few pixels above. The first fix made this
    /// helper decline to focus the dead composer, and left the answer field to claim the caret for
    /// itself when its question arrived. That was right for the keyboard and silent for the hotkey:
    /// Ctrl-Opt-Space with a question pending reached this helper, which correctly set nothing, and
    /// so the hotkey did nothing (SONNY-283). Now the helper knows both fields, and a summon during
    /// a clarification lands the caret in the answer. Writing `nil` for the other states rather than
    /// skipping the assignment is still deliberate: the widget being re-opened onto an approval
    /// must not leave the caret parked in a field that has since gone dead.
    private func focusTheFieldThatTakesInput() {
        focusedField = WidgetInputField.takingInput(
            clarificationPanelShowing: isShowingClarificationPanel,
            composer: composerState
        )
    }

    /// Whether the panel on screen is the clarification panel — read off `state`, the same
    /// precedence that decides what is drawn, so the caret can never be aimed at a field that
    /// another panel has outranked.
    private var isShowingClarificationPanel: Bool {
        if case .clarification = state {
            return true
        }
        return false
    }

    private var styledPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panel

            // **The in-task usage indicator** (SONNY-214). Inside the panel's own glass rather than
            // as a strip of its own, because it is a fact about the run the panel is already
            // describing and not a notice about something else that happened.
            //
            // One insertion point for every panel state, gated by one property: the widget shows
            // this while a *screen-control* task is in flight or waiting on its approval, and shows
            // nothing at all for an ordinary free task — which is
            // `AgentViewModel.screenControlRunsLeftForTaskInFlight`'s whole job, and where the rule
            // is stated. A gate spelled out here instead would be a rule enforced by nothing but a
            // reader noticing it.
            if let runsLeft = viewModel.screenControlRunsLeftForTaskInFlight {
                Text(ScreenControlUsagePresentation.inTaskLine(runsLeft: runsLeft))
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(width: WidgetTheme.panelWidth, alignment: .leading)
        .widgetGlassPanel()
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The collapsed widget. Icon-only by design, so its words are `CompactCapsulePresentation`'s
    /// — see there for why it carries no visible label and why the tooltip's wording is a question
    /// left open rather than answered here.
    ///
    /// **The VoiceOver name is the fix SONNY-251 turned up.** This control had a tooltip and no
    /// `.accessibilityLabel` at all, which made it the only one of the file's four icon-only
    /// controls that named itself on *neither* channel — the other three have carried a full
    /// accessibility name throughout. The name sits directly above the tooltip here and on all
    /// three of the others, which is the convention
    /// `WidgetControlNamingTests.everyTooltipInTheWidgetSitsBesideAVoiceOverName` reads.
    private var compactCapsule: some View {
        Button(action: expandFromCompact) {
            Image(systemName: "wand.and.stars.inverse")
                .font(WidgetType.iconLarge)
                .foregroundStyle(WidgetTheme.textStrong)
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .widgetGlassPill()
        .accessibilityLabel(CompactCapsulePresentation.expandLabel)
        .help(CompactCapsulePresentation.expandLabel)
    }

    /// Which panel the widget draws, and the order is the whole of it — the first branch that
    /// matches wins, so every reader of this property is really reading its ordering.
    ///
    /// Not `private`: see `WidgetState`'s own doc comment for why a test reads this.
    var state: WidgetState {
        if let preview = viewModel.visionCapturePreview {
            return .captureReview(preview)
        }
        if let delegation = viewModel.visionDelegationRequest {
            return .delegationReview(delegation)
        }
        if let pause = viewModel.visionSessionPause {
            return .sessionPaused(pause)
        }
        // **The fourth parked question, and it belongs with the three above rather than under the
        // progress line below** (SONNY-255). All four suspend the loop on a continuation nothing but
        // the user resolves; a progress report describes a loop that is moving. Placed below
        // `.controlling`, as it was until this ticket, it could never render during a session at
        // all — `visionSessionProgress` is written at the top of every iteration and cleared only at
        // session end, so the branch below won from iteration 1 and the question was on no widget
        // surface while the run waited for it.
        if let approvalRequest = viewModel.approvalRequest {
            return .permission(approvalRequest)
        }
        // Below the four parked questions and above `.working`: a question waiting on the user
        // outranks a progress line, and a vision session's progress line outranks the generic
        // working panel, which would otherwise say "Sonny is working" while it moves the cursor.
        if let progress = viewModel.visionSessionProgress {
            return .controlling(progress)
        }
        // Below `.controlling`, and unlike the approval above it that is not an accident: a
        // clarification is unreachable inside a session by construction. `clarificationQuestion` is
        // written in exactly one place, `performStart`, and a delegated plan that needs one never
        // reaches it — `runVisionDelegation` hands the question back to the model as a failed
        // delegation rather than putting it to the user, so one question is on screen at a time.
        if let question = viewModel.clarificationQuestion {
            return .clarification(question)
        }
        // §8.3's wall, above `.failure` — see `WidgetState.tooOld` for why it sits exactly here.
        // `AgentViewModel.hasVisibleWidgetPanel` mirrors this branch in the same position.
        if viewModel.isTooOldForThisBackend,
           let prompt = ClientVersionCopy.prompt(for: viewModel.clientVersionState) {
            return .tooOld(prompt)
        }
        if let error = viewModel.errorMessage, !viewModel.isRunning {
            return .failure(error)
        }
        if viewModel.isRunning {
            return .working
        }
        if !viewModel.finalSummary.isEmpty {
            let suggestion = viewModel.suggestions.first { $0.kind == .openFile }
            return .result(viewModel.finalSummary, suggestion)
        }
        // `AgentViewModel.hasVisibleWidgetPanel` mirrors this branch in the same position, and the
        // two must not drift — its own doc comment is where the shared rule lives.
        if let offer = viewModel.resumeOffer {
            return .resumeOffer(offer)
        }
        // §8.4's warning, last — see `WidgetState.updateAvailable`. `hasVisibleWidgetPanel` mirrors
        // this branch in the same position.
        if viewModel.showsUpdateAvailablePrompt,
           let prompt = ClientVersionCopy.prompt(for: viewModel.clientVersionState) {
            return .updateAvailable(prompt)
        }
        return .idle
    }

    /// A cheap, `Equatable` key to drive `.animation(value:)` without making `WidgetState` itself
    /// conform (it holds non-Equatable payloads like `RiskApprovalRequest`).
    private var widgetStateKey: Int {
        switch state {
        case .idle: return 0
        case .working: return 1
        case .clarification: return 2
        case .permission: return 3
        case .captureReview: return 6
        case .delegationReview: return 7
        case .sessionPaused: return 8
        case .controlling: return 9
        case .result: return 4
        case .failure: return 5
        case .resumeOffer: return 10
        case .tooOld: return 11
        case .updateAvailable: return 12
        }
    }

    /// Which of the composer's three states the app is in — and, with it, what the field says while
    /// it is not taking input (SONNY-247).
    ///
    /// **The seven conditions `isTaskInFlight` covers are classified here rather than merged.** They
    /// were merged, and the cost was a composer that kept its idle placeholder in all seven, stopped
    /// responding, and swallowed a paste — reported twice in one day as a hung app. What the user
    /// should do differs between them, so what the composer says has to differ too;
    /// `ComposerPresentation.State` is where each case's reasoning lives.
    ///
    /// **The union is exactly the old disjunction, term for term.** Nothing was added or dropped,
    /// which is what lets `isTaskInFlight` below be derived from this rather than computed a second
    /// time. `everyConditionTheComposerDisablesOnIsClassified` holds the population so an eighth
    /// cannot arrive unclassified, and `theWidgetsOwnPrecedenceIsWhatMakesTheComposersClassificationTrue`
    /// holds the ordering the branches below depend on.
    ///
    /// **The branch order mirrors `state`'s, and that mirroring is the whole correctness argument**
    /// (PR #107 review, F1). The first version asked `hasVisibleWidgetPanel`, which answers "is a
    /// panel visible" — and then concluded "is *that* panel visible", which is a different question
    /// and was false. `state` above returns the *first* branch that matches, so the panel a user is
    /// actually looking at is whichever question outranks the rest; a condition may therefore only
    /// be called `.waitingOnYou` once every branch that outranks it has been ruled out. That is what
    /// the ordering here does, rather than a sentence claiming it.
    ///
    /// **So when `state`'s order moves, this moves with it, and the reason a term sits where it does
    /// is not the reason it used to be** (SONNY-255). The approval was ruled out *after* the live
    /// session because it lost to the session in `state`; it now wins, so it is classified before
    /// the session term and the sentence "answer above" is true of it in both cases. That is a
    /// smaller claim than it looks: nothing here decides anything, it reads an ordering that lives
    /// one property up, and the test named above is what stops the two drifting apart in silence.
    ///
    /// Not `private`, for the reason `WidgetState` gives: the mirroring is checkable in the file and
    /// its *effect* — the sentence the user reads, in the state they are actually in — is not, so a
    /// test reads this beside `state` and asserts the pair agree in a live run.
    var composerState: ComposerPresentation.State {
        // These three outrank `.controlling` in `state`, so each really does put its own question on
        // screen whatever else is happening.
        if viewModel.visionCapturePreview != nil
            || viewModel.visionDelegationRequest != nil
            || viewModel.visionSessionPause != nil {
            return .waitingOnYou
        }
        // **Above the session line below it, because `.permission` outranks `.controlling`**
        // (SONNY-255). It did not, and the branch order here recorded that: an approval raised
        // mid-session was answerable on no widget surface, so calling it a question above this
        // composer would have pointed at a panel that was not there. The approval now takes the
        // panel whenever it is pending, session or no session, so it is a question in both cases and
        // needs no session term ruled out first.
        if viewModel.isAwaitingApproval {
            return .waitingOnYou
        }
        // The HUD, which really does carry no question — and now says so about a smaller window than
        // it used to: a live session with nothing parked on it.
        if viewModel.visionSessionProgress != nil {
            return .working
        }
        // Below the session line, and correctly so: a clarification cannot be raised inside a
        // session (`state`'s own branch says why), so reaching this means no session is live and
        // `.clarification` is the branch that wins.
        if viewModel.clarificationQuestion != nil {
            return .waitingOnYou
        }
        // A run in flight with nothing here to type into, and no guaranteed panel either: the
        // running branch of `hasVisibleWidgetPanel` is origin-gated, so a run a Command Center row
        // action started shows nothing in the widget at all.
        if viewModel.isRunning {
            return .working
        }
        return .ready
    }

    /// Unchanged in value, derived rather than restated. Every existing reader — the field's
    /// `.disabled`, the three chips' clear affordances, `dontSaveButton`, the Start button, the
    /// pill's trailing inset — keeps exactly the behaviour it had.
    private var isTaskInFlight: Bool {
        !ComposerPresentation.acceptsInput(composerState)
    }

    private func submit() {
        let text = viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isTaskInFlight else { return }
        // `start()` itself now clears `command` centrally, synchronously, right after capturing
        // it — correct for every caller, not just this one.
        viewModel.start(origin: .widget, fromComposer: true)
    }

    /// The in-composer binding indicator and its clear affordance.
    ///
    /// System B tokens only — this is the widget, not a Command Center surface. Rendered *inside*
    /// the composer row rather than as its own strip: the contract's own constraint is that no
    /// indicator exists anywhere outside the in-flight composer, and a separate strip is the first
    /// step toward the rejected persistent "Active" badge.
    @ViewBuilder
    private var workspaceBindingChip: some View {
        if let name = viewModel.boundWorkspaceName {
            HStack(spacing: 4) {
                Text(AgentActivityPresentation.workspaceBindingIndicatorText(workspaceName: name))
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)

                // Only offered before submitting. Once a task is in flight its scope is already
                // assessed and answered; dropping it mid-run would leave the approval the user saw
                // and the execution that follows it disagreeing about the boundary.
                if !isTaskInFlight {
                    Button {
                        viewModel.clearPendingWorkspaceBinding()
                    } label: {
                        Image(systemName: "xmark")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .frame(width: Self.composerChipRowHeight, height: Self.composerChipRowHeight)
                    .contentShape(Rectangle())
                    .accessibilityLabel(
                        AgentActivityPresentation.clearWorkspaceBindingLabel(workspaceName: name)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(WidgetTheme.neutralButtonFill)
            .clipShape(Capsule())
        }
    }

    /// The "Don't be saved" state, made unmissable in the composer itself (SONNY-120).
    ///
    /// The button alone is not enough. The two mistakes are not symmetrical: leaving the switch on
    /// costs a history row nobody minds losing, while forgetting it is off records something the
    /// user wanted private — and that one cannot be undone afterwards. So the on state gets a chip
    /// in the pill, where the user is already looking as they type.
    ///
    /// Same chip shape, dismiss affordance and System B tokens as `workspaceBindingChip`, and the
    /// same only-before-dispatch rule. No explanatory sentence beside it: the label is the message.
    @ViewBuilder
    private var dontSaveChip: some View {
        if viewModel.taskRecordingPolicy.suppressesTraces {
            HStack(spacing: 4) {
                Text(TaskRecordingPresentation.activeChipText)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)

                if !isTaskInFlight {
                    Button {
                        viewModel.taskRecordingPolicy = .record
                    } label: {
                        Image(systemName: "xmark")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .frame(width: Self.composerChipRowHeight, height: Self.composerChipRowHeight)
                    .contentShape(Rectangle())
                    .accessibilityLabel(TaskRecordingPresentation.clearAccessibilityLabel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(WidgetTheme.neutralButtonFill)
            .clipShape(Capsule())
        }
    }

    /// The armed-follow-up chip (row E, SONNY-150).
    ///
    /// Same chip shape, same dismiss affordance, same System B tokens as the two beside it, and the
    /// same only-before-dispatch rule for the clear button. What it adds is a *name*: without one
    /// the user is typing into a box with invisible state attached, and an invisible trusted block
    /// reaching the planner is worse than an invisible workspace binding — which is the case the
    /// slot this sits in already exists to prevent.
    ///
    /// Rendered off `viewModel.priorTaskContext` rather than off a second published flag, so the
    /// chip and the context the planner will actually receive cannot disagree: there is one value,
    /// and `isArmed` is a field on it.
    @ViewBuilder
    private var followUpChip: some View {
        if let context = viewModel.priorTaskContext, context.isArmed {
            HStack(spacing: 4) {
                Text(FollowUpPresentation.chipText(command: context.previousCommand))
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !isTaskInFlight {
                    Button {
                        viewModel.clearArmedFollowUp()
                    } label: {
                        Image(systemName: "xmark")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .frame(width: Self.composerChipRowHeight, height: Self.composerChipRowHeight)
                    .contentShape(Rectangle())
                    .accessibilityLabel(
                        FollowUpPresentation.clearAccessibilityLabel(command: context.previousCommand)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(WidgetTheme.neutralButtonFill)
            .clipShape(Capsule())
        }
    }

    /// Whether any chip is on, and therefore whether the pill carries a chip row at all.
    ///
    /// Read off the same three conditions the chips themselves render on. Two sources for one
    /// question would let the pill reserve a row for a chip that is not there, or fail to reserve
    /// one for a chip that is.
    private var hasComposerChips: Bool {
        viewModel.boundWorkspaceName != nil
            || viewModel.taskRecordingPolicy.suppressesTraces
            || viewModel.priorTaskContext?.isArmed == true
    }

    /// The pill's height. 40 with no chip — exactly what it has always been — and taller by one
    /// chip row plus its spacing when there is one.
    private var composerPillHeight: CGFloat {
        hasComposerChips ? 40 + Self.composerChipRowHeight + Self.composerChipRowSpacing : 40
    }

    private static let composerChipRowHeight: CGFloat = 18
    private static let composerChipRowSpacing: CGFloat = 8

    private var composerPill: some View {
        VStack(alignment: .leading, spacing: Self.composerChipRowSpacing) {
            // **A row of their own, above the field** — the founder's decision of 2026-08-21, taken
            // against the two alternatives. Three chips inline leave the text field about 57 points
            // wide, at the exact moment the user is typing a correction into it; a chip that names
            // no task fits but reintroduces the invisible state the chip exists to prevent.
            //
            // **Order: the two that were here first, then the new one.** The ticket's rule is compose
            // with them, do not displace them — so the workspace binding and "Won't be saved" keep
            // the reading position they have always had and the follow-up joins after them, rather
            // than the newest arrival taking the front.
            if hasComposerChips {
                HStack(spacing: 8) {
                    workspaceBindingChip
                    dontSaveChip
                    followUpChip
                    Spacer(minLength: 0)
                }
                .frame(height: Self.composerChipRowHeight)
            }

            composerFieldRow
        }
        .padding(.leading, 14)
        .padding(.trailing, isTaskInFlight ? 14 : 8)
        .frame(width: WidgetTheme.panelWidth, height: composerPillHeight)
        .widgetGlassPill()
    }

    private var composerFieldRow: some View {
        HStack(spacing: 10) {
            // Dimmed while the field takes nothing (SONNY-247). This glyph is the composer's "type
            // here" affordance, so turning it down is the composer withdrawing the invitation — the
            // placeholder beside it carries the actual sentence, and stays at full `textMuted` so
            // that the one thing able to explain a dead click is the one thing not dimmed.
            Image(systemName: "wand.and.stars.inverse")
                .font(WidgetType.icon)
                .foregroundStyle(isTaskInFlight ? WidgetTheme.textFaint : WidgetTheme.textMuted)

            TextField(
                "",
                text: $viewModel.command,
                prompt: Text(ComposerPresentation.prompt(for: composerState))
                    .foregroundStyle(WidgetTheme.textMuted)
            )
            .textFieldStyle(.plain)
            .font(WidgetType.pillQuery)
            .foregroundStyle(WidgetTheme.textFull)
            .disabled(isTaskInFlight)
            .focused($focusedField, equals: .composer)
            .submitLabel(.go)
            .onSubmit(submit)

            if !isTaskInFlight {
                let isCommandEmpty = viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: submit) {
                    HStack(spacing: 3) {
                        Text("Start")
                        Image(systemName: "chevron.right")
                            .font(WidgetType.headlineChip)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(WidgetTheme.textStrong)
                .font(WidgetType.headlineChip)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .widgetCapsuleBackground(tint: WidgetTheme.primaryAction)
                .disabled(isCommandEmpty)
                .opacity(isCommandEmpty ? 0.5 : 1)
            }
        }
        // The field row is always 40 tall, whether or not a chip row sits above it. That is what
        // keeps the two circular buttons beside the pill level with the field: the composer row
        // aligns them to the pill's bottom edge and gives them a 40-tall box of their own.
        //
        // The trailing inset: 8pt matches the Start button's own vertical inset (24pt tall in a
        // 40pt row leaves 8pt above and below); a uniform 14pt left it visibly farther from the
        // trailing edge than from the top and bottom. Applied on the pill rather than here, and
        // conditional because the button is not rendered while a task is in flight — that state
        // keeps its shipped 14pt rather than pulling the disabled field 6pt closer to the capsule's
        // curve to fix a complaint about a different state.
        .frame(height: 40)
    }

    /// "Don't save this task" (SONNY-120).
    ///
    /// **Only before dispatch.** Hidden outright while a task is in flight rather than disabled —
    /// the same reasoning already written beside the workspace-binding chip's clear affordance, and
    /// it holds harder here: flipping this mid-run would promise to un-write records already on
    /// disk, which it cannot do. A disabled-but-visible control invites the user to try.
    ///
    /// A third circular button in the composer row, matching `micButton`'s 36×36 and reusing
    /// `widgetCircularBackground`, so it introduces no new System B token. **The honest cost, stated
    /// rather than discovered:** this widens the composer row by 48pt, and the widget is a permanent
    /// on-screen overlay, so that is a real change to its footprint. The alternative — putting it
    /// inside the pill — squeezes the text field, which is worse. Proposed on session judgment with
    /// no wireframe to defer to; SONNY-109 settles it.
    ///
    /// **This button has no backdrop of its own, and that is the fact everything else here follows
    /// from (SONNY-174).** The composer row is `HStack { composerPill; dontSaveButton; micButton }`
    /// and only `composerPill` carries `.widgetGlassPill()`; the enclosing stack has no background
    /// and `FloatingWidgetWindowController` makes the panel fully transparent. So these two
    /// circular buttons composite onto **whatever window the user happens to have behind the
    /// widget** — never onto the widget's dark glass. Every other untinted-variant button in the
    /// app lives inside a `Widget*Panel`, which does sit on glass. **A fill whose opacity is less
    /// than 1 therefore buys its contrast from the user's desktop**, and out here there is no
    /// desktop to buy it from.
    ///
    /// That is what makes both of the first two treatments wrong, for the same reason twice over:
    /// - **Shipped originally:** `neutralButtonFill` passed as a *tint*. A non-nil tint takes
    ///   `WidgetTintedButtonBackground`'s other branch — a `Color.white.opacity(0.94)` underlay
    ///   with the tint composited `.plusDarker` over it — so `rgba(153,153,153,.17)` came out as
    ///   **#EDEDED at 95% alpha**, a near-opaque pale disc carrying a white glyph at
    ///   **1.16–1.31:1**. The founder's report, "too light for anyone to figure it out."
    /// - **The first attempt at fixing it,** `tint: nil`, took the fill from 95% opaque down to
    ///   **17%** — the opposite of presence. It read as darker only because the thing showing
    ///   through happened to be dark. Over a white window the two branches are not merely close,
    ///   they are **identical**: with a white destination `plusDarker` reduces to the source, so
    ///   both collapse to `0.932000` and a **1.16:1** glyph. On a white window that change was a
    ///   no-op on screen. (PR #73 review, F1.)
    ///
    /// **So the fill is opaque, which is the ticket's own first lever — give the fill real
    /// presence — done where it actually had to be done.** An opaque tint resolves through that
    /// branch to exactly itself at alpha 1 (`αs = 1` ⇒ the composite is the source), which is why
    /// `micButton` beside it and this button's own on state are already backdrop-proof.
    ///
    /// **Which token, enumerated over the whole set rather than picked.** System B has ten colour
    /// tokens. Two are translucent (`neutralButtonFill`, `textMuted`) and the finding above
    /// disqualifies both. Of the eight opaque ones, five are accents that already mean something —
    /// `primaryAction` is this button's *own* on state, `secondaryCircular` is the mic 12pt away,
    /// and `allowAction`/`errorGlyph`/`taskFailureRetry` carry Allow, error and retry. The last two
    /// are opaque and are not accents, but another layer of *this same button* already uses them:
    /// `hairline` draws its rim and `textFull` its glyph, so either one as the fill erases the very
    /// thing it would have to contrast against (each measures 1.00:1 against its own layer).
    /// `panelBase` is the one that remains, and it is also the best of them on the numbers. No new
    /// token is warranted either: the one candidate worth adding, §3.1's neutral fill
    /// pre-composited over `panelBase` (#303030), measures *worse* on every axis — glyph 13.20:1
    /// against this one's 17.40:1, rim 2.94:1 against 3.41:1, and less separation from the on state.
    ///
    /// **Measured over the backdrop swept 0.0 to 1.0, the screen and not a panel**, all three
    /// constant because the fill is opaque: white glyph **17.40:1**, hairline rim **3.41:1**
    /// against its own fill, and **5.38:1** between off and the untouched on state — the widest
    /// separation any candidate gave. The glyph beats the mic's own 2.23:1 by a wide margin. The
    /// fill matches *some* backdrop at every opacity (worst case 1.01:1 here, 1.00:1 for both the
    /// mic and the on state), which is why the rim, the top highlight and the shadow draw the
    /// silhouette rather than the fill — and all three are backdrop-independent too.
    ///
    /// **The shadow rides along with the branch, and that is right here rather than merely
    /// tolerable.** A non-nil tint carries the heavier `black 0.45 / r12 / y6`; §3.1 pairs its
    /// lighter `0.04 / r8 / y4` with the neutral variant, which is a button *on a panel* that
    /// already provides separation. This one has nothing under it, so the heavier shadow is what
    /// separates it from a bright desktop — and it now matches the mic beside it and its own on
    /// state, so the row carries one shadow instead of two.
    ///
    /// On and off are now solid `#0091FF` against solid `#1A1A1A`, plus `eye.slash.fill` against
    /// `eye.slash`. **Every figure above is composited arithmetic, not eyesight** — Porter-Duff
    /// source-over with `kCGBlendModePlusDarker`, WCAG luminance from linearised sRGB. Whether
    /// either state actually reads right is the founder's manual pass, and nothing here replaces it.
    @ViewBuilder
    private var dontSaveButton: some View {
        if !isTaskInFlight {
            let isOn = viewModel.taskRecordingPolicy.suppressesTraces
            Button {
                viewModel.taskRecordingPolicy = isOn ? .record : .suppressTraces
            } label: {
                Image(systemName: isOn ? "eye.slash.fill" : "eye.slash")
                    .font(WidgetType.captionMedium)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .frame(width: 36, height: 36)
            .widgetCircularBackground(tint: isOn ? WidgetTheme.primaryAction : WidgetTheme.panelBase)
            .accessibilityLabel(TaskRecordingPresentation.controlLabel)
            .accessibilityValue(TaskRecordingPresentation.controlAccessibilityValue(isOn: isOn))
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        }
    }

    /// How long Sonny will keep listening — the founders' ask on 2026-09-09: "so user knows how
    /// long Sonny will listen to you." Leads `micButton` in the composer row, and only while a
    /// recording is actually running; nothing renders (nor reserves space) otherwise.
    ///
    /// `TimelineView` rather than a stored `@State` something has to poll or update, for the same
    /// reason `MicHoverHintModel`'s countdown is a `Task` and not a `Timer` written into a view: the
    /// tick belongs to a mechanism a test can reason about, and here `VoiceRecordingCountdown`'s
    /// pure functions are that mechanism — this view only asks them what to draw.
    ///
    /// No `.help()`: the founders' rule against explanatory copy rules out "max 3:00" as a tooltip
    /// as much as it rules out a sentence, and the digits already say everything there is to say.
    /// `.accessibilityHidden(true)` for the same reason — the words a screen reader needs are on
    /// `micButton`'s own `.accessibilityValue`, so VoiceOver is not asked to read this digit-only
    /// label as if it were prose.
    @ViewBuilder
    private var voiceRecordingCountdownLabel: some View {
        if viewModel.isRecordingVoice, let startedAt = viewModel.voiceRecordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let remaining = VoiceRecordingCountdown.remaining(startedAt: startedAt, now: context.date)
                Text(VoiceRecordingCountdown.label(remaining: remaining))
                    .font(WidgetType.captionMedium)
                    .monospacedDigit()
                    .foregroundStyle(
                        VoiceRecordingCountdown.isWarning(remaining: remaining)
                            ? WidgetTheme.attention
                            : WidgetTheme.textFaint
                    )
                    // "9:59" is the widest this ever renders; reserved so the field beside it never
                    // shifts width as the digits themselves change width.
                    .frame(minWidth: VoiceRecordingCountdown.labelReservedWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    /// `voiceButtonTitle` alone once a recording ends; while one runs, the countdown's own words
    /// ride along so VoiceOver hears the same thing `voiceRecordingCountdownLabel` shows.
    private func micButtonAccessibilityValue(now: Date) -> String {
        guard viewModel.isRecordingVoice, let startedAt = viewModel.voiceRecordingStartedAt else {
            return viewModel.voiceButtonTitle
        }
        let remaining = VoiceRecordingCountdown.remaining(startedAt: startedAt, now: now)
        return "\(viewModel.voiceButtonTitle), \(VoiceRecordingCountdown.accessibilityValue(remaining: remaining))"
    }

    /// The same four states the glyph reads, so a screen reader and a sighted user hear and see
    /// one answer while a recording starts or a transcription runs. While one is running, the
    /// countdown's own words ride along ("Stop, 2 minutes 57 seconds left"), read off the same
    /// one-second `TimelineView` tick that drives `voiceRecordingCountdownLabel`, so VoiceOver never
    /// hears a remaining time the label has already moved past (phase 11 review, F1 and F3).
    @ViewBuilder
    private var micButton: some View {
        if viewModel.isRecordingVoice, let startedAt = viewModel.voiceRecordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                micButtonBody
                    .accessibilityValue(micButtonAccessibilityValue(now: context.date))
            }
        } else {
            micButtonBody
                .accessibilityValue(viewModel.voiceButtonTitle)
        }
    }

    private var micButtonBody: some View {
        Button {
            viewModel.toggleVoiceRecording(origin: .widget)
        } label: {
            Image(systemName: viewModel.voiceButtonIcon)
                .font(WidgetType.captionMedium)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 36)
        .widgetCircularBackground(tint: WidgetTheme.secondaryCircular)
        .accessibilityLabel("Voice input")
        // **Transient reasons only** — the rule and its whole predicate live on
        // `AgentViewModel.isVoiceControlDisabled`. A disabled SwiftUI button never runs its action,
        // so every term folded in here is a press the user makes and never hears back about. The
        // missing-API-key term used to be one: pressing the mic with no key did nothing at all,
        // while holding the hotkey — gated by no SwiftUI state — said why (SONNY-173). A
        // configuration failure the user can go and fix belongs to the guard inside
        // `startVoiceRecording`, which explains it; a control may only be disabled for something
        // that clears on its own.
        .disabled(viewModel.isVoiceControlDisabled)
        // Diagnosed via a debug print: hover worked exactly once, right after a fresh launch, and
        // never again — including after the panel had since lost key status (e.g. the user clicked
        // into another app). SwiftUI's `.onHover` is backed by an `NSTrackingArea` that defaults to
        // `.activeInKeyWindow` — it only tracks mouse enter/exit while this panel is *actually* the
        // system's key window, which stops being true the instant focus moves anywhere else. This
        // widget needs hover to work regardless of key status (it's visible and interactive even
        // when some other app is active), so it needs a real `.activeAlways` tracking area instead
        // of SwiftUI's default — not achievable through `.onHover` itself.
        .overlay(
            AlwaysActiveHoverTracker(
                onEnter: { micHintPointerEnteredMic() },
                onExit: { micHint.dismiss() }
            )
        )
    }

    /// The pointer arrived on the mic. Shown as a real layout row (see `micHoverHintRow`) rather
    /// than a `.help()` tooltip — `.help()` already proved unreliable in this exact app once before
    /// (the Insights weekly chart), and was confirmed unreliable **for this button** too, not just
    /// assumed. (Those two words are the scope, added by PR #140's review, F4: it read as a claim
    /// about the whole widget, and `WidgetResumeOfferPanel` records a `.help` that demonstrably
    /// fires on its own two controls. Both observations are real and neither generalises.)
    ///
    /// **Called from the arrival itself, not from a change of "the pointer is on the mic"
    /// (SONNY-179).** SONNY-177 shipped this as `.onChange(of:)` over a `@State` boolean the
    /// tracking view wrote, and that swallowed a hover: both of the events that write such a
    /// boolean require the pointer to *cross* a tracking area's edge while that area exists, and
    /// this one is created and destroyed with the mic button — the auto-collapse takes the mic away
    /// under a stationary pointer, and no crossing happens, so nothing writes `false` and the
    /// boolean stays `true` with the pointer nowhere near the mic. The next real hover then re-wrote
    /// `true` over `true`, which is not a change, so `.onChange` never ran and that hover showed
    /// nothing; leaving restored the two to agreement and every hover after it worked. Exactly one
    /// hover lost, and only the first — the founder's report. An arrival is an event, so there is no
    /// second copy of the pointer's position left to disagree with the pointer.
    ///
    /// An arrival while the panel or the compact capsule owns the hint's slot shows nothing, and
    /// why that is so — and why it is not left to the render condition — is on `pointerArrived`,
    /// which is where the rule now lives so that a test can hold it. All that is left here is which
    /// boolean to hand it.
    private func micHintPointerEnteredMic() {
        micHint.pointerArrived(slotIsFree: isMicHintSlotFree) {
            viewModel.micHoverHintPresentation
        }
    }

    /// Real layout row (same slot the panel occupies), not a `.help()` tooltip or a floating
    /// `.overlay` — both would need extra window padding to avoid clipping the same way the old
    /// drop shadow did; this participates in `fixedSize()`'s measurement like everything else, so
    /// the window just grows to fit it correctly. Deliberately matches `composerPill`'s own shape
    /// (`Capsule` via `widgetGlassPill()`, not `widgetGlassPanel()`'s `RoundedRectangle`) and exact
    /// 472×40 frame, not just a text-sized bubble — an unconstrained width/height and a different
    /// corner shape than the pill directly beneath it read as a stray, misaligned fragment rather
    /// than a hint that visibly belongs to the row it's describing.
    ///
    /// **The frame is unchanged by SONNY-179, and that was measured rather than assumed.** Both
    /// sentences this row can carry were laid out at the row's real font (SF Pro Medium 10, via
    /// `WidgetType.captionSmall`) against the 444pt the 472pt frame leaves after its 14pt padding:
    /// both the shortcut reminder and the configuration message fit with room, so each stays a
    /// single line with room to spare and nothing about the window controller's fitted-size
    /// positioning has to be revisited. (SONNY-177 measured the same two at 285.4pt and 254.1pt;
    /// the reminder is the one whose wording SONNY-179 replaced, and it got shorter.)
    private func micHoverHintRow(_ hint: MicHoverHintPresentation) -> some View {
        Text(hint.message)
            .font(WidgetType.captionSmall)
            .foregroundStyle(WidgetTheme.textFull)
            .padding(.horizontal, 14)
            .frame(width: WidgetTheme.panelWidth, height: 40, alignment: .leading)
            .widgetGlassPill()
            .transition(.opacity)
    }
}

// MARK: - Panel routing

private extension FloatingWidgetView {
    @ViewBuilder
    var panel: some View {
        switch state {
        case .idle:
            EmptyView()
        case .working:
            WidgetWorkingPanel(
                plan: viewModel.plan,
                stepStatuses: viewModel.stepStatuses,
                itemJobProgress: viewModel.itemJobProgress
            )
        case .clarification(let question):
            WidgetClarificationPanel(
                plan: viewModel.plan,
                stepStatuses: viewModel.stepStatuses,
                question: question,
                answer: $viewModel.clarificationAnswer,
                focusedField: $focusedField,
                canSend: viewModel.canSendClarificationAnswer,
                onSubmit: { viewModel.submitClarification() },
                // The same app-wide entry point the permission panel's Deny above uses, not a
                // clarification-specific method (SONNY-166). `CommandCenterAttentionPanel`'s own
                // Cancel calls it too, so the two surfaces cannot end a paused task differently.
                onCancel: { viewModel.cancelCurrentRun() }
            )
        case .permission(let request):
            WidgetPermissionPanel(
                plan: viewModel.plan,
                stepStatuses: viewModel.stepStatuses,
                request: request,
                isFirstApproval: !viewModel.hasCompletedFirstApproval,
                safeMode: viewModel.interactionMode == .safe,
                // Non-nil exactly when a screen-control session is live under this question
                // (SONNY-255), which is what turns the panel's refusal into the session's Stop.
                sessionProgress: viewModel.visionSessionProgress,
                onAllow: { viewModel.start() },
                onDeny: { viewModel.cancelCurrentRun() },
                // The same call the HUD's own Stop makes, not a second stop path: it logs the press
                // as an emergency stop and routes into `cancelCurrentRun`, which is also what
                // `onDeny` above does. One implementation of "control was lost, for any reason" is
                // §13.5's invariant, and a bespoke path here would be the one that forgets to
                // release the mouse button.
                onStop: { viewModel.emergencyStopVisionSession() }
            )
        case .captureReview(let preview):
            WidgetCaptureReviewPanel(
                preview: preview,
                onSend: { viewModel.resolveVisionCapturePreview(allowing: true) },
                onDecline: { viewModel.resolveVisionCapturePreview(allowing: false) }
            )
        case .delegationReview(let delegation):
            WidgetDelegationReviewPanel(
                delegation: delegation,
                onAllow: { viewModel.resolveVisionDelegation(allowing: true) },
                onDecline: { viewModel.resolveVisionDelegation(allowing: false) }
            )
        case .sessionPaused(let pause):
            WidgetSessionPausedPanel(
                pause: pause,
                onResume: { viewModel.resolveVisionPause(resuming: true) },
                onEnd: { viewModel.resolveVisionPause(resuming: false) }
            )
        case .controlling(let progress):
            WidgetControllingPanel(
                progress: progress,
                onPause: { viewModel.pauseVisionSession() },
                onStop: { viewModel.emergencyStopVisionSession() }
            )
        case .resumeOffer(let task):
            WidgetResumeOfferPanel(
                command: task.command,
                // `.widget`, stated: the offer's Continue is pressed here, and `hasVisibleWidgetPanel`
                // shows the resumed run's progress in this widget only for a `.widget` origin
                // (`.claude/rules/macagent-ui-conventions.md`). The Memory sheet's Continue says
                // `.commandCenter` for the same reason.
                onContinue: { viewModel.continueResumableTask(task, origin: .widget) },
                onDecline: { viewModel.declineResumeOffer() }
            )
        case .result(let summary, let suggestion):
            WidgetResultPanel(
                summary: summary,
                ranWithoutAskingTrace: viewModel.ranWithoutAskingTrace,
                suggestion: suggestion
            ) { suggestion in
                viewModel.runSuggestion(suggestion)
            }
        case .failure(let message):
            WidgetFailurePanel(
                plan: viewModel.plan,
                stepStatuses: viewModel.stepStatuses,
                message: message,
                canRetry: viewModel.hasRetryableCommand,
                onRetry: { viewModel.retryLastCommand() }
            )
        case .tooOld(let prompt), .updateAvailable(let prompt):
            // One panel for both states, and the states differ only in the value they carry — which
            // is what makes it impossible for the wall and the warning to drift apart visually. What
            // separates them is the precedence above, not the drawing.
            WidgetVersionPanel(
                prompt: prompt,
                onUpdate: { viewModel.openClientVersionLink() },
                onDismiss: { viewModel.dismissUpdateAvailablePrompt() }
            )
        }
    }
}

// MARK: - Step rows (§3.3.2/§3.3.5)

/// One row per plan step, reused across every panel state that has a plan in flight. Icon slot
/// shows a live spinner while `.running`, a coral warning glyph while `.failed`, the step's real
/// resolved app icon (via `WorkspaceAppIconResolver`, same resolver `RoutineDetailView` uses) once
/// `.complete`, or a muted fallback glyph otherwise. Text opacity is the state signal per §3.3.2:
/// only the active or failed row gets full white, everything else stays muted.
private struct WidgetStepRow: View {
    let step: AgentStep
    let status: AgentStepStatus

    private var title: String {
        AgentActivityPresentation.planStepTitle(step)
    }

    var body: some View {
        HStack(spacing: 8) {
            iconSlot
            Text(title)
                .font(WidgetType.caption)
                .foregroundStyle(isEmphasized ? WidgetTheme.textFull : WidgetTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(title)
                .help(title)
            Spacer(minLength: 8)
        }
    }

    private var isEmphasized: Bool {
        status == .running || status == .failed
    }

    private var resolvedIcon: NSImage? {
        guard let appName = step.appName else {
            return nil
        }
        return WorkspaceAppIconResolver.shared.icon(forAppName: appName)
    }

    @ViewBuilder
    private var iconSlot: some View {
        ZStack {
            switch status {
            case .running:
                WidgetSpinner()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(WidgetType.icon)
                    .foregroundStyle(WidgetTheme.errorGlyph)
            default:
                if let resolvedIcon {
                    Image(nsImage: resolvedIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(status == .complete ? 1 : 0.6)
                } else {
                    Image(systemName: status == .complete ? "checkmark" : AgentActivityPresentation.eventIcon(.act))
                        .font(WidgetType.iconSmall)
                        .foregroundStyle(WidgetTheme.textMuted)
                }
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// **One row for a job over many items, in place of one row per item** (SONNY-235).
///
/// A forty-item job's plan holds forty step groups, and every panel below renders one row per step —
/// so an approval prompt would be forty rows to scroll, which is the per-item prompt the founder's
/// decision of 2026-08-31 rejected wearing different clothes. `ItemJobProgressPresentation` is where
/// the sentence lives, shared with Command Center so the two surfaces cannot say different things
/// about one run.
private struct WidgetItemJobRow: View {
    let title: String
    let progressLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(WidgetType.iconSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
            }
            if let progressLine {
                Text(progressLine)
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 24)
            }
        }
    }
}

/// Real steps only — no fallback row, since this is reused by panels (permission/clarification/
/// failure) that append their own specific content below whatever steps exist, including zero.
private struct WidgetExistingStepRows: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]

    var body: some View {
        // `progress: nil` on purpose: these panels are the ones that raise a *question* —
        // permission, clarification, failure — and none of them is a report of how far a run got.
        switch ItemJobProgressPresentation.rows(for: plan, progress: nil) {
        case .job(let title, let progressLine):
            WidgetItemJobRow(title: title, progressLine: progressLine)
        case .steps(let steps):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps) { step in
                    WidgetStepRow(step: step, status: stepStatuses[step.id] ?? .pending)
                }
            }
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Working (§3.3.2)

private struct WidgetWorkingPanel: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]
    /// How far a job over many items has got, or `nil` for every run that is not one (SONNY-235).
    let itemJobProgress: ItemJobProgress?

    var body: some View {
        switch ItemJobProgressPresentation.rows(for: plan, progress: itemJobProgress) {
        case .job(let title, let progressLine):
            WidgetItemJobRow(title: title, progressLine: progressLine)
        case .steps(let steps):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps) { step in
                    WidgetStepRow(step: step, status: stepStatuses[step.id] ?? .pending)
                }
            }
        case nil:
            HStack(spacing: 8) {
                WidgetSpinner()
                Text("Understanding your request\u{2026}")
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetTheme.textFull)
            }
        }
    }
}

// MARK: - Permission (§3.3.3)

private struct WidgetPermissionPanel: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]
    let request: RiskApprovalRequest
    /// Branch 9 checkpoint 8, split 2026-07-24 (see `docs/sonny-founder-design-decisions.md`):
    /// only the first-time explainer copy ships here — the "curated example" half of the original
    /// resolution is explicitly deferred, not built. SONNY-10 extended that copy from one line to
    /// the reassurance sentence plus this action's own `riskReason`; see
    /// `AgentActivityPresentation.firstRunApprovalExplainerLines` for why, and for why the
    /// steady-state panel is unchanged.
    let isFirstApproval: Bool
    let safeMode: Bool
    /// The screen-control session this question was raised inside, or `nil` when the run is an
    /// ordinary one (SONNY-255).
    ///
    /// **What it changes is the panel's context row and its refusal, not the question.** The
    /// approval itself is the same `RiskApprovalRequest` every other approval is, raised by the same
    /// method and answered by the same two entry points — a session does not get an approval surface
    /// of its own. What a session does get is the two things the HUD this panel now outranks was
    /// carrying: the statement that Sonny is controlling an app, and the way to stop it.
    let sessionProgress: VisionSessionProgress?
    let onAllow: () -> Void
    let onDeny: () -> Void
    /// Ends the screen-control session. Only reachable while `sessionProgress` is non-nil.
    let onStop: () -> Void

    private var escalationReasons: String {
        request.assessment.escalations
            .map(\.reason)
            .joined(separator: " ")
    }

    private var firstRunExplainerLines: [String] {
        AgentActivityPresentation.firstRunApprovalExplainerLines(
            for: request,
            isFirstApproval: isFirstApproval
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // **Inside a session this row replaces the step rows rather than joining them**
            // (SONNY-255). The plan a screen-control run carries is the outer one, whose step is
            // "control this app" — so the identity line says what those rows say and adds the step
            // count and the way out. Two rows saying the same thing on a 472pt panel is how a panel
            // stops being read.
            //
            // **What is deliberately not carried across from the HUD is its action line.** At the
            // moment an approval is raised, `currentAction` still holds what the iteration reported
            // when it began — "Looking at Safari" — because the loop's next progress report comes
            // *after* the approval returns. Rendering it here would put a stale sentence directly
            // above an accurate one about the same moment.
            if let sessionProgress {
                HStack(spacing: 8) {
                    WidgetSessionIdentityLine(appDisplayName: sessionProgress.appDisplayName)

                    Spacer(minLength: 8)

                    Text(ScreenControlSessionPresentation.stepLine(
                        iteration: sessionProgress.iteration,
                        maximumIterations: sessionProgress.maximumIterations
                    ))
                        .font(WidgetType.captionSmall)
                        .foregroundStyle(WidgetTheme.textMuted)
                        .lineLimit(1)

                    WidgetSessionStopButton(
                        appDisplayName: sessionProgress.appDisplayName,
                        action: onStop
                    )
                }
            } else {
                WidgetExistingStepRows(plan: plan, stepStatuses: stepStatuses)
            }

            ForEach(Array(firstRunExplainerLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Why this action was escalated above its default tier — "the zip already exists",
            // "this snippet trigger would be replaced", and since SONNY-37 "example.com is not
            // part of the Research workspace." Without it the panel asks for approval on a raised
            // tier while showing nothing about what raised it. Rendered as its own line rather
            // than folded into the resource line below, which is `lineLimit(1)` and would truncate
            // these mid-sentence; the first-approval lines above set the precedent for an
            // explanatory line in this panel.
            //
            // **Amber, not error red** — founder design pass, 2026-08-06, SONNY-38 requirement 6.
            // This line shipped in `WidgetTheme.errorGlyph`, so a workspace-scope prompt asked the
            // user for permission in Sonny's failure colour: an "allow anyway?" question that
            // looked like something had gone wrong. `secondaryCircular` is System B's amber and the
            // counterpart of Command Center's `SonnyTheme.warning`, so the two approval surfaces no
            // longer disagree about what an escalation looks like.
            //
            // Applied to every escalation reason rather than only the scope ones, decided in the
            // same pass: no escalation is an error — each one explains why approval is being asked —
            // so the failure colour was wrong for all of them.
            //
            // **The checkable property that leaves behind, restated because its original wording had
            // gone stale twice over.** It said `errorGlyph` was used "exclusively by genuine error
            // states", naming two sites by line number; both numbers had moved, and row I had since
            // added a site that is not an error state at all — the control that stops a session. The
            // property worth holding is narrower and has never been false: **nothing that asks the
            // user a question is drawn in the failure colour.** Red is the failed-step glyph, the
            // notice strip's default tint, and `WidgetSessionStopButton` — which is one site serving
            // both the HUD and, since SONNY-255, this panel. Three code sites in this file
            // (`git grep -cE '^[^/]*WidgetTheme\.errorGlyph' -- Sources/MacAgent/FloatingWidgetView.swift`
            // → 3 — the leading-slash exclusion is what keeps prose like the line above out of it).
            if !escalationReasons.isEmpty {
                Text(escalationReasons)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.secondaryCircular)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Safe mode only (SONNY-90): the one place "Data leaves device: yes/no" survives
            // E9's ratified §11.3 deviation. Normal and Power render nothing here — the
            // relocation, not an omission. One muted caption, matching the panel's label-free
            // voice.
            if let dataEgressLine = AgentActivityPresentation.widgetDataEgressLine(
                for: request,
                safeMode: safeMode
            ) {
                Text(dataEgressLine)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(WidgetType.icon)
                    .foregroundStyle(WidgetTheme.textMuted)

                (Text("Allow access to ").font(WidgetType.caption)
                    + Text(request.approvalCopy.involvedResource).font(WidgetType.captionMedium))
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // **One refusal, never two** (SONNY-255). Outside a session this cross is the panel's
                // Deny and the only way to say no. Inside one, `cancelCurrentRun` — which is what it
                // calls — ends the whole session rather than declining a step, which is exactly what
                // the labelled Stop in the row above does; two controls with one effect on the
                // surface a program driving the user's screen asks from is the worst place in the
                // app for that ambiguity, and an icon-only cross reading as "skip this step" while
                // it ends the session is the surprise `cancelCurrentRun`'s own doc comment calls the
                // most expensive one this product can produce. So the refusal moves to the row that
                // says what it does, and nothing is lost: it is the same call, on the same press
                // count, with a word on it.
                //
                // When SONNY-80's standing note lands — a labelled "deny this step" that resumes the
                // continuation without cancelling — it comes back here as a genuinely *different*
                // control beside that Stop, which is the shape `VisionSessionRunner`'s approval arm
                // already anticipates.
                if sessionProgress == nil {
                    Button(action: onDeny) {
                        Image(systemName: "xmark")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(WidgetTheme.textFull)
                    }
                    .buttonStyle(.plain)
                    .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                    .widgetCircularBackground()
                    .accessibilityLabel("Deny")
                    .keyboardShortcut(.cancelAction)
                }

                Button(action: onAllow) {
                    Image(systemName: "checkmark")
                        .font(WidgetType.headlineChip)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
                .accessibilityLabel("Allow")
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Safe-mode capture review (no wireframe — best-effort, per founder decision 5)

/// What Sonny is about to send, shown before it is sent.
///
/// Safe mode only. Founder decision 5 (2026-08-14) put row I's UI on session judgment with no
/// wireframe gate, and a dedicated whole-product UI/UX pass before release — so this is built to
/// System B's tokens and to the panels around it, deliberately plainly, and it is a candidate for
/// that pass rather than a finished design.
///
/// **The thumbnail is the redacted bytes, not the original.** Showing the user one picture and
/// sending another would make the preview a lie about the thing it previews, which is the whole
/// reason a pre-send preview exists.
private struct WidgetCaptureReviewPanel: View {
    let preview: VisionCapturePreview
    let onSend: () -> Void
    let onDecline: () -> Void

    /// One line naming what redaction found and covered, or nothing when it found nothing.
    ///
    /// "Nothing found" is deliberately left unsaid rather than stated as a reassurance: redaction
    /// covers the classes `SecretTextDetector` knows about, and a cheerful "no secrets found" would
    /// read as a guarantee about the whole screenshot that no detector can make.
    private var redactionLine: String? {
        guard !preview.redactionReport.isEmpty else { return nil }
        let total = preview.redactionReport.reduce(0) { $0 + $1.count }
        return total == 1
            ? "1 possible secret was blacked out before this was prepared."
            : "\(total) possible secrets were blacked out before this was prepared."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sonny wants to send this picture of \(preview.appDisplayName) to its vision model.")
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)

            if let data = preview.redactedImageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: WidgetTheme.thumbnailRadius, style: .continuous))
                    .accessibilityLabel("Screenshot of \(preview.appDisplayName) that Sonny is about to send")
            }

            if let redactionLine {
                Text(redactionLine)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.secondaryCircular)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                // **The shared owner's sentence, not a hand-written one** (SONNY-303). This line
                // interpolated `preview.appDisplayName` where the iteration cap belongs, so Safe
                // mode's pre-send review read "Step 2 of Safari". The cap was genuinely missing from
                // `VisionCapturePreview` and appears to have been substituted for rather than
                // dropped; it is a field on the type now, and this reads it through the same
                // `ScreenControlSessionPresentation.stepLine` the HUD and both approval panels use,
                // which is the point — one sentence, one owner. The old text is not quoted here on
                // purpose: `WidgetSessionApprovalPanelTests` counts that literal across this whole
                // file and the count is the guard, so a comment carrying a copy of it would be
                // arguing with the scan about what the file contains.
                Text(ScreenControlSessionPresentation.stepLine(
                    iteration: preview.iteration,
                    maximumIterations: preview.maximumIterations
                ))
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(action: onDecline) {
                    Text("Don\u{2019}t send")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetTheme.textFull)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground()
                .keyboardShortcut(.cancelAction)

                Button(action: onSend) {
                    Text("Send")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Safe mode is about to let Sonny use its own tools for one step instead of clicking.
///
/// **Declining here is not stopping.** This panel is the first place in the product where a labelled
/// "keep clicking" sits beside a labelled allow — SONNY-80's standing note asked for exactly that
/// distinction, deferred until a surface could carry it honestly, and a delegation is where it is
/// obviously useful: "no, do not use your tools for that, try it on screen" is a real answer. The
/// stop control still stops (it is `cancelCurrentRun`, unchanged); this one only answers the
/// question.
private struct WidgetDelegationReviewPanel: View {
    let delegation: VisionDelegationRequest
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sonny wants to use its own tools for one step instead of clicking in \(delegation.appDisplayName).")
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)

            Text(delegation.instructionText)
                .font(WidgetType.captionMedium)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)

            if !delegation.rationaleText.isEmpty {
                Text(delegation.rationaleText)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Said plainly, because it is the thing a user most needs to know to answer: allowing
            // this does not skip the ordinary approval on whatever it turns out to do.
            Text("Anything it does still asks you first if it would delete something or reach someone else.")
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.secondaryCircular)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 8)

                Button(action: onDecline) {
                    Text("Keep clicking")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetTheme.textFull)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground()
                .keyboardShortcut(.cancelAction)

                Button(action: onAllow) {
                    Text("Use tools")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The session paused because the user stopped being at the Mac.
///
/// **Resume is a press, never a timer.** The whole point of the pause is that Sonny stopped when the
/// user did; a panel that resumed itself when the screen unlocked would give that back for nothing.
private struct WidgetSessionPausedPanel: View {
    let pause: VisionSessionPause
    let onResume: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sonny paused controlling \(pause.appDisplayName) because \(pause.reason.userFacingReason).")
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)

            Text("It only runs while you are here. Nothing happened while it waited.")
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 8)

                Button(action: onEnd) {
                    Text("End")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetTheme.textFull)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground()
                .keyboardShortcut(.cancelAction)

                Button(action: onResume) {
                    Text("Resume")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - What a live session says and how it is stopped, wherever the panel is

/// "Sonny is controlling <app>" — the statement row I requires a session to be making at all times.
///
/// **One copy, two panels** (SONNY-255). It began inside `WidgetControllingPanel` and moved out when
/// `WidgetPermissionPanel` had to make the same statement, because while a question is parked the HUD
/// is not the panel on screen and the requirement is about the session rather than about one panel.
/// A second hand-written copy of this sentence is how two surfaces start describing one session
/// differently.
private struct WidgetSessionIdentityLine: View {
    let appDisplayName: String

    var body: some View {
        HStack(spacing: 8) {
            // Amber, not the failure red: this is Sonny doing something unusual, not something
            // going wrong — the same distinction the approval panel's escalation line draws.
            Image(systemName: "cursorarrow.rays")
                .font(WidgetType.icon)
                .foregroundStyle(WidgetTheme.secondaryCircular)

            (Text(ScreenControlSessionPresentation.controllingPrefix).font(WidgetType.caption)
                + Text(appDisplayName).font(WidgetType.captionMedium))
                .foregroundStyle(WidgetTheme.textFull)
                .lineLimit(1)
        }
    }
}

/// The control that ends a screen-control session, wherever the session's panel happens to be.
///
/// **Shared for the same reason the line above is** (SONNY-255): the emergency control for a program
/// driving the user's screen has one label, one colour and one VoiceOver name, whether it is sitting
/// in the HUD or in the approval panel that outranks it. Its action is the caller's, and both callers
/// pass the same one — `emergencyStopVisionSession`, which routes into `cancelCurrentRun` like every
/// other stop in the product.
private struct WidgetSessionStopButton: View {
    let appDisplayName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(ScreenControlSessionPresentation.stopLabel)
                .font(WidgetType.captionMedium)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: WidgetTheme.controlSize)
        .widgetCircularBackground(tint: WidgetTheme.errorGlyph)
        .accessibilityLabel(ScreenControlSessionPresentation.stopAccessibilityLabel(appDisplayName: appDisplayName))
    }
}

/// **The HUD: power without covertness.**
///
/// While Sonny controls an app it says so, says which app, says what it is doing right now, and puts
/// Stop where the user can reach it — with Pause beside it while the loop is advancing, which is
/// whenever this panel is the one on screen. That is the whole requirement, and it is a product
/// requirement rather than a courtesy: a program moving someone's cursor with no visible statement of
/// what it is doing is the shape this feature must never take.
///
/// **This sentence read "puts Pause and Stop where the user can reach them" and was left standing by
/// the change that made half of it false** (PR #132 review, F2). Stop reaches both panel shapes;
/// Pause reaches only this one, deliberately, for the reason stated beside it below.
///
/// **This panel is not the only place that requirement is met** (SONNY-255). Four states outrank it,
/// each of them a question the session has parked on the user, and while one of those is on screen
/// this panel is not. The three Safe-mode ones each name the app in their own copy; the approval one
/// renders `WidgetSessionIdentityLine` and `WidgetSessionStopButton` above the question, so the
/// statement and the way out survive the panel being outranked.
///
/// **No wireframe** — the founder put row I's UI on session judgment on 2026-08-14, with a dedicated
/// whole-product UI/UX pass before release. Built to System B's tokens and to the panels around it,
/// deliberately plainly, and a candidate for that pass rather than a finished design.
private struct WidgetControllingPanel: View {
    let progress: VisionSessionProgress
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetSessionIdentityLine(appDisplayName: progress.appDisplayName)

            Text(progress.currentAction)
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(ScreenControlSessionPresentation.stepLine(
                    iteration: progress.iteration,
                    maximumIterations: progress.maximumIterations
                ))
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(action: onPause) {
                    Text("Pause")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(WidgetTheme.textFull)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: WidgetTheme.controlSize)
                .widgetCircularBackground()
                .accessibilityLabel(ScreenControlSessionPresentation.pauseAccessibilityLabel(
                    appDisplayName: progress.appDisplayName
                ))

                // **Pause does not travel to the approval panel with the Stop, and that is the one
                // thing this ticket left behind on purpose** (SONNY-255). `pauseVisionSession` sets
                // the attention monitor's flag, which the loop reads at the *top of its next
                // iteration* — so pressing it while an approval is parked freezes nothing, because
                // the loop is already frozen on the continuation. It would take effect only after
                // the user answered the question, which is a control that appears to do nothing and
                // then acts later.
                WidgetSessionStopButton(appDisplayName: progress.appDisplayName, action: onStop)
            }

            // The hotkey, said once and quietly. During a session the pointer is not the user's to
            // aim, so the keyboard is the one input path that is reliably theirs — and a control
            // nobody knows about is not a control.
            Text("\(EmergencyStopHotKey.displayName) stops it from anywhere.")
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.textMuted)
        }
    }
}

// MARK: - Clarification (no wireframe — best-effort, flagged for review)

/// **The Cancel control is a founder-approved exception to the wireframe rule, not a fidelity gap
/// (SONNY-166, approved 2026-08-20).** This panel has no wireframe to match — §3.3 covers six states
/// and clarification is the seventh, reachable in the real view model and drawn nowhere — so there
/// was no existing element to build rather than invent. The exception was proposed with its exact
/// shape and copy and answered before any of it was written, per the repo's standing rule that a
/// deliberate departure is a stated, reasoned one.
///
/// The shape is borrowed rather than designed: a `WidgetTheme.controlSize` circular `xmark` on the
/// neutral fill is `WidgetPermissionPanel`'s Deny button, reused verbatim. No new component, so the
/// one thing this adds to System B is a button that already exists two panels away. (Was a bare
/// 23pt literal until the 2026-09-08 modernization pass routed it through the shared token.)
private struct WidgetClarificationPanel: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]
    let question: String
    @Binding var answer: String
    /// **The caret goes where the typing can actually land** (SONNY-247), and the widget owns the
    /// caret (SONNY-283).
    ///
    /// This panel has always had the only live text field on the widget while a question is parked,
    /// and it never asked for the caret — the composer below did, unconditionally, and then refused
    /// every keystroke and every paste because it is `.disabled` in exactly this state. The founder
    /// reported that twice in one day as the widget being unable to type or paste. Claiming focus
    /// here is the half of the fix that makes the other half rarely matter: the first key pressed
    /// after a question appears goes into the answer.
    ///
    /// A binding to `FloatingWidgetView`'s one `FocusState` rather than a `Bool` of this panel's
    /// own, because the push-to-talk hotkey's summon is handled by the widget and has to be able to
    /// reach this field — with a private `Bool` here it could not, and the hotkey did nothing while a
    /// question was pending.
    @FocusState.Binding var focusedField: WidgetInputField?
    /// Whether Send is live — `AgentViewModel.canSendClarificationAnswer`, which is also what
    /// `submitClarification` refuses on, so the control and the state cannot disagree (PR #119
    /// review, F1). Off while the answer is empty, as before, and now also while a voice recording or
    /// its transcription is in flight, because a send inside that window tore the pause down and put
    /// nothing back.
    let canSend: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetExistingStepRows(plan: plan, stepStatuses: stepStatuses)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(WidgetType.icon)
                        .foregroundStyle(WidgetTheme.textMuted)
                    Text(question)
                        .font(WidgetType.caption)
                        .foregroundStyle(WidgetTheme.textFull)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    // On the question's row rather than beside the send arrow below, deliberately:
                    // inside the answer capsule it would read as "clear what I typed", and this
                    // ends the task. It sits where the thing it declines is.
                    //
                    // Icon-only, so `ClarificationPresentation.cancelLabel` is its VoiceOver name
                    // and its tooltip instead of visible text — the same string Command Center
                    // shows on its own button.
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(WidgetTheme.textFull)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                    .widgetCircularBackground()
                    .accessibilityLabel(ClarificationPresentation.cancelLabel)
                    .help(ClarificationPresentation.cancelLabel)
                }

                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: $answer,
                        prompt: Text("Type your answer\u{2026}").foregroundStyle(WidgetTheme.textMuted)
                    )
                    .textFieldStyle(.plain)
                    .font(WidgetType.pillQuery)
                    .foregroundStyle(WidgetTheme.textFull)
                    .focused($focusedField, equals: .clarificationAnswer)
                    .onSubmit(onSubmit)

                    Button(action: onSubmit) {
                        Image(systemName: "arrow.up")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                    .widgetCircularBackground(tint: WidgetTheme.primaryAction)
                    .disabled(!canSend)
                    .accessibilityLabel("Send answer")
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(WidgetTheme.hairline.opacity(0.4), lineWidth: 0.5))
            }
        }
        .onAppear {
            focusedField = .clarificationAnswer
        }
        // A run may ask more than one question, and SwiftUI keeps this view's identity across them —
        // so `onAppear` fires once and the second question would arrive with the caret still sitting
        // in the answer the user has just sent. The panel appearing and a new question arriving are
        // two different events and both need the caret.
        .onChange(of: question) { _, _ in
            focusedField = .clarificationAnswer
        }
    }
}

// MARK: - Result (§3.3.4)

private struct WidgetResultPanel: View {
    let summary: String
    /// The ran-without-asking line (SONNY-99), or nil for a run whose silence was ordinary. One
    /// line of muted text on this existing surface — the founder-approved wireframe exception,
    /// bounded to exactly this shape: tokens already on the panel, no new component.
    let ranWithoutAskingTrace: String?
    let suggestion: RunSuggestion?
    let onOpen: (RunSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary)
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textFull)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(summary)
                .help(summary)

            if let ranWithoutAskingTrace {
                Text(ranWithoutAskingTrace)
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let suggestion {
                WidgetFilePreviewChip(suggestion: suggestion, onOpen: onOpen)
            }
        }
    }
}

// MARK: - Resume offer (row 13, SONNY-210 — no wireframe)

/// "You were partway through X." — Continue, or don't ask again.
///
/// **System B throughout, and only System B.** This is the floating widget, so it is
/// `WidgetTheme`/`WidgetType` and the circular-background controls the panels around it already use;
/// `SonnyTheme`/`SonnyType` are Command Center's and do not appear here. The two token sets are
/// deliberately separate rather than variants of each other (`.claude/rules/
/// macagent-ui-conventions.md`), and the founder restated the constraint on this specific panel when
/// signing the design off on 2026-08-22.
///
/// No wireframe covers this state, so it is built to the panels beside it rather than to a drawing —
/// the same footing `WidgetCaptureReviewPanel` is on, and a candidate for the whole-product UI pass
/// for the same reason. Its shape is `WidgetCaptureReviewPanel`'s: a sentence, then a right-aligned
/// pair of controls with the affirmative one tinted.
///
/// **The controls are a tick and a cross, and this panel alone diverges that way** (founder,
/// 2026-08-23, SONNY-244 — "only tick and cross would be fine"). The panels beside it keep their
/// words on purpose rather than following: this one asks a yes/no question about a single thing, and
/// a glyph can carry yes and no. `WidgetCaptureReviewPanel` ("Send" / "Don't send"),
/// `WidgetDelegationReviewPanel` ("Use tools" / "Keep clicking") and `WidgetSessionPausedPanel`
/// ("Resume" / "End") each offer two *different actions*, and "Keep clicking" is not the negation of
/// anything — a cross there would say something the button does not. So the divergence is stated
/// rather than propagated.
///
/// **What the words cost, and where they went — the doubt this paragraph recorded has been
/// answered** (SONNY-295; observed by the founder 2026-08-26, recorded by SONNY-294).
/// `.accessibilityLabel` keeps the full sentence naming the task, which matters *more* once the
/// button shows no text at all, and that one was never in question. `.help` carries the words —
/// "Continue", "Don't ask again" — on hover, and **it fires**: the founder hovered the tick and the
/// cross on the packaged app at `368ab85` and reported "yes tooltips appeared". That is the first
/// direct evidence in this project's record that a `.help` tooltip reaches anything in this widget
/// at all, and the §3d-bis checklist row that carried the question carries the answer.
///
/// **What that establishes is exactly that, and it is deliberately not generalised.** One pass, two
/// buttons, one Mac. `micHintPointerEnteredMic`, further up this file, still records `.help()` as
/// unreliable and that sentence is left standing on purpose: it is about the *mic button*, a
/// different control in a slot this panel competes with, and a hover that worked here is evidence
/// about the hover that worked, not about a mechanism. So the two statements do not contradict each
/// other, and neither is written as "`.help()` is reliable in this widget", which is the claim
/// nothing in the record supports.
///
/// **Two** other `.help` calls in this file predate the finding and were left in place — the compact
/// capsule's "Open Sonny" and the clarification panel's cancel — and those two are still unhovered
/// by anyone; §3d-bis now asks about them too, since one pass answers it. (Two, not the three this
/// said before PR #107's F3. That correction's own figures were about `94afca1`, where a plain
/// search answered four — two calls plus two doc-comment mentions — and the live count was 2. At
/// this head the live count is 4, which is those two plus this panel's pair:
/// `git grep -cE '^[[:space:]]*\.help\(' -- Sources/MacAgent/FloatingWidgetView.swift` → 4 at
/// `372528e`. The POSIX class rather than `\s` is not decoration — `git grep`'s ERE engine answers
/// **0** for the same pattern written with `\s`, exit 1 and no output, which reads exactly like a
/// file with no `.help` call in it. A plain search over this file answers more than four now and
/// will keep drifting, because this correction added doc-comment mentions of its own; the call
/// count is the one worth quoting.)
///
/// **So a sighted user does not lose the words.** What stood here concluded the opposite, on the
/// strength of the doubt, and named a remedy — a real hover row like the mic's, "a design change,
/// not a fix" — that is not owed. The arc is kept rather than deleted, the way the checklist row
/// keeps it: doubted 2026-08-23, observed reachable 2026-08-26.
///
/// **The cross means "don't ask again", and the ambiguity the previous paragraph here worried about
/// was settled by the founder's manual pass — against the design** (SONNY-282, decision 2026-08-25).
/// It used to mean "not now": the record untouched, the offer back at the next launch. The paragraph
/// that stood here said a cross also reads as "close this panel", that nothing in a 23pt glyph could
/// tell the two apart, and that only the manual pass could say whether the cross read as an answer.
/// It did not. The founder pressed it, relaunched, pressed it, relaunched, pressed it again and
/// stopped to ask what was broken — a control pressed three times expecting an effect it never has
/// is a defect whatever its tooltip says. So the behaviour moved to the glyph's conventional
/// meaning: `onDecline` writes `ResumableTask.declinedAt`, the offer never returns for that task,
/// and the record is *not* deleted — deleting on the cross was considered and rejected so that no
/// control in the widget can lose work irreversibly. The task stays under Memory → Unfinished
/// tasks, which now has a Continue of its own beside Delete.
private struct WidgetResumeOfferPanel: View {
    let command: String
    let onContinue: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // **The reserved height is the fix, not the stack** (SONNY-244) — see
            // `ResumeOfferPresentation.reservedMessageHeight` for why the controls were being drawn
            // on top of this sentence intermittently, and why making the stack taller would have
            // aimed at the wrong thing. `lineLimit` and the reservation are one mechanism and have
            // to move together: the cap is what makes the reservation sufficient.
            Text(ResumeOfferPresentation.message(command: command))
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textFull)
                .lineLimit(ResumeOfferPresentation.messageLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: ResumeOfferPresentation.reservedMessageHeight)

            HStack(spacing: 8) {
                Spacer(minLength: 8)

                // `WidgetTheme.controlSize` on the neutral circular fill, and a `WidgetType.headlineChip`
                // `xmark`: this is `WidgetClarificationPanel`'s own cancel control, glyph for glyph,
                // which is itself `WidgetPermissionPanel`'s Deny. No new component.
                Button(action: onDecline) {
                    Image(systemName: "xmark")
                        .font(WidgetType.headlineChip)
                        .foregroundStyle(WidgetTheme.textFull)
                }
                .buttonStyle(.plain)
                .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                .widgetCircularBackground()
                .accessibilityLabel(ResumeOfferPresentation.declineAccessibilityLabel(command: command))
                .help(ResumeOfferPresentation.declineLabel)
                .keyboardShortcut(.cancelAction)

                // The affirmative stays the tinted one, which is the whole of what tells "carry on"
                // apart from "leave it" now that neither carries a word.
                //
                // **Both glyphs now share `WidgetType.headlineChip`** (2026-09-08 modernization
                // pass) — the same token `WidgetPermissionPanel`'s Deny/Allow pair and
                // `WidgetClarificationPanel`'s cancel/send pair use, so the founder's open question
                // about whether an 11pt checkmark read the same size as a 10pt one is moot: every
                // icon-only glyph in these panels is the one size now.
                Button(action: onContinue) {
                    Image(systemName: "checkmark")
                        .font(WidgetType.headlineChip)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                .widgetCircularBackground(tint: WidgetTheme.primaryAction)
                .accessibilityLabel(ResumeOfferPresentation.continueAccessibilityLabel(command: command))
                .help(ResumeOfferPresentation.continueLabel)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Filename/size/modified-date come from `FileManager` attributes on the suggestion's real path,
/// and the thumbnail is the file's own real icon via `NSWorkspace` — all genuine data about the
/// actual artifact on disk, not invented. `RunSuggestion`/`.openFile` already exists for this.
private struct WidgetFilePreviewChip: View {
    let suggestion: RunSuggestion
    let onOpen: (RunSuggestion) -> Void

    private var url: URL {
        URL(fileURLWithPath: suggestion.value)
    }

    private var attributes: [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: suggestion.value)
    }

    private var sizeText: String {
        guard let bytes = attributes?[.size] as? Int else {
            return "Unknown size"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var modifiedText: String {
        guard let date = attributes?[.modificationDate] as? Date else {
            return "Unknown date"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return "Modified \(formatter.string(from: date))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: suggestion.value))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(WidgetType.captionMedium)
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)
                Text(sizeText)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
                Text(modifiedText)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
            }

            Spacer(minLength: 8)

            Button {
                onOpen(suggestion)
            } label: {
                HStack(spacing: 4) {
                    Text("Open")
                    Image(systemName: "arrow.up.right")
                        .font(WidgetType.headlineChip)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(WidgetTheme.textStrong)
            .font(WidgetType.headlineChip)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .widgetCapsuleBackground(tint: WidgetTheme.primaryAction)
        }
    }
}

// MARK: - Task-level failure (§3.3.6)

/// Local-storage health, shown *alongside* whatever the widget is already doing rather than as a
/// `WidgetState`. It is deliberately not part of the state priority chain: a corrupt store is not
/// a task outcome, and routing it through `.failure` is exactly what made a successful task read
/// as failed. It never raises the panel on its own — it only appears when the widget is expanded.
private struct WidgetNoticeStrip: View {
    let message: String
    let icon: String
    /// The glyph's colour. Defaulted to the error red the two original callers ship, so adding this
    /// parameter changed neither of them — and parameterised at all because the third caller
    /// (SONNY-113's scheduled-run notice) carries successes as well as failures, and reporting "your
    /// 9am routine ran" in Sonny's failure colour is the same mistake as posting it in the failure
    /// notification category, one surface further in.
    var tint: Color = WidgetTheme.errorGlyph
    let dismissAccessibilityLabel: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(WidgetType.icon)
                .foregroundStyle(tint)
            Text(message)
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissAccessibilityLabel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: WidgetTheme.panelWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WidgetTheme.noticeRadius, style: .continuous)
                .fill(WidgetTheme.panelBase.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WidgetTheme.noticeRadius, style: .continuous)
                .strokeBorder(WidgetTheme.hairline.opacity(0.25), lineWidth: 1)
        )
    }
}

/// §8's two version states, in System B (SONNY-402).
///
/// **Both words come from `ClientVersionCopy.prompt(for:)` and none is written here**, which is the
/// same rule `ScreenControlSessionPresentation` holds for the session's own sentence and for the same
/// reason: this panel's System A counterpart is `CommandCenterAttentionPanel`'s `versionContent`, the
/// two cannot share a view because neither token set may cross into the other's surface, and a
/// hand-written literal on either side is one condition described two ways.
///
/// **The Update control is offered only when the prompt carries a label**, which is only when the
/// state carries a link this app will open. The founder's decision of 2026-09-04: an Update Sonny
/// button that opens the URL, or the message with no button, and never a visible URL or a Copy.
///
/// The two controls are `WidgetCaptureReviewPanel`'s text buttons, token for token —
/// `WidgetTheme.controlSize` high on the circular fill, `captionMedium`, the affirmative tinted and
/// the other neutral. No new component and
/// no new System B token.
private struct WidgetVersionPanel: View {
    let prompt: ClientVersionPrompt
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(WidgetType.icon)
                    .foregroundStyle(WidgetTheme.primaryAction)

                Text(prompt.title)
                    .font(WidgetType.captionMedium)
                    .foregroundStyle(WidgetTheme.textFull)

                Spacer(minLength: 8)
            }

            Text(prompt.message)
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 8)

                if let dismissLabel = prompt.dismissLabel {
                    Button(action: onDismiss) {
                        Text(dismissLabel)
                            .font(WidgetType.captionMedium)
                            .foregroundStyle(WidgetTheme.textFull)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: WidgetTheme.controlSize)
                    .widgetCircularBackground()
                    .keyboardShortcut(.cancelAction)
                }

                if let updateLabel = prompt.updateLabel {
                    Button(action: onUpdate) {
                        Text(updateLabel)
                            .font(WidgetType.captionMedium)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: WidgetTheme.controlSize)
                    .widgetCircularBackground(tint: WidgetTheme.primaryAction)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private struct WidgetFailurePanel: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]
    let message: String
    /// `errorMessage` also carries pre-flight errors (empty-command validation, voice-
    /// transcription failures) that never reached a real submission — showing a Retry button for
    /// those was a real dead-end-button bug, since `retryLastCommand()` silently no-ops when
    /// there's no real last command behind it.
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetExistingStepRows(plan: plan, stepStatuses: stepStatuses)

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(WidgetType.icon)
                    .foregroundStyle(WidgetTheme.taskFailureRetry)

                // Shows AgentViewModel's real error text rather than the wireframe's fixed
                // "Sonny failed to complete the task" placeholder — genuinely useful error content
                // beats literal copy fidelity here, consistent with how completed-task summaries
                // elsewhere in this app show real data instead of wireframe placeholder text.
                Text(message)
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
                    .help(message)

                Spacer(minLength: 8)

                if canRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                    .widgetCircularBackground(tint: WidgetTheme.taskFailureRetry)
                    .accessibilityLabel("Retry task")
                }
            }
        }
    }
}

// MARK: - Hover tracking that works regardless of key-window status

/// SwiftUI's `.onHover` is backed by an `NSTrackingArea` that only tracks while the containing
/// window is key by default — wrong for a permanent overlay that's routinely *not* key (any other
/// app being active means this panel isn't). Uses a real `.activeAlways` tracking area instead,
/// which AppKit fires regardless of key-window status. `.inVisibleRect` keeps the tracked region
/// correct automatically as the view's frame changes (this panel resizes/repositions often), with
/// no manual re-registration needed — and since SONNY-444 the code does none: re-registering on
/// every layout pass was what re-showed an expired hint under a stationary pointer.
///
/// **It reports the two arrivals, and holds no answer to "is the pointer here" (SONNY-179).** It
/// used to write a `Binding<Bool>`, and a caller that reads such a boolean is reading a second copy
/// of where the pointer is — one AppKit only ever corrects by delivering a crossing. Both events
/// below need the pointer to cross this area's edge *while the area exists*, and this whole view is
/// created and destroyed with the control it sits on, so a stationary pointer plus an appearing or
/// disappearing area is a correction that never arrives and a copy that stays wrong until the next
/// crossing spends itself repairing it. There is nothing to go stale in a callback.
struct AlwaysActiveHoverTracker: NSViewRepresentable {
    /// The pointer arrived. Called on every arrival, including one whose predecessor's departure
    /// was never delivered — which is the whole of what the boolean could not do.
    let onEnter: () -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onEnter = onEnter
        view.onExit = onExit
        return view
    }

    /// Both closures are re-read on every update, because they close over the view they were built
    /// from and that view's state moves under them.
    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onEnter = onEnter
        nsView.onExit = onExit
    }

    final class TrackingNSView: NSView {
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?

        /// **Clicks pass through** (SONNY-443). This view sits over the mic button as an overlay,
        /// and `NSView`'s default `hitTest` claims every point inside its bounds — so the click the
        /// founders made on the mic landed here and the button beneath never saw it, while the
        /// hint still showed, because tracking areas do not go through hit-testing. Nothing here
        /// wants a click; answering nil hands it to whatever is under this view.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        /// **One tracking area, registered once and kept** (SONNY-444). This used to remove every
        /// area and add a fresh one on each call. **Why that blinked the hint is a working
        /// hypothesis, not settled AppKit behaviour** (PR #230's fresh review, F1): the reading
        /// was that AppKit delivers `mouseEntered` for an area added under a pointer already
        /// inside it, so the reminder's own expiry — the hint row leaving, the window resizing,
        /// a layout pass asking this view to update its areas — re-added the area under the
        /// stationary pointer and a synthetic arrival re-showed the row every three seconds.
        /// Two records contradict that reading. Apple's `NSTrackingArea.Options.assumeInside`
        /// documentation says that without that option "the first event is generated when the
        /// cursor leaves the tracking area if the cursor is initially inside the area", an exit
        /// and not an arrival; and the founders measured this very code on 2026-08-20 (macOS
        /// 26.5.2, the SONNY-179 row of the checklist) with the pointer inside the mic while the
        /// row came and went, and the hint went once and did not come back. What differs between
        /// that measurement and the founders' pass that saw the blink is unmeasured: this Mac
        /// moved to macOS 26.6.2 on 2026-08-31, and the ui-ux-claude mic commits of 2026-09-09
        /// (`643848ab`, `01aa3be3`) landed in between. Whatever sends the extra arrival, keeping
        /// one area removes the re-registration, and `MicHoverHintModel`'s belt holds whatever
        /// sends it. `.inVisibleRect` keeps the one area correct as the view's geometry changes,
        /// which the comment on this type always said and the code did not do.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else {
                return
            }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            onEnter?()
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}
