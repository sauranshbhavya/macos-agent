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
private enum WidgetState {
    case idle
    case working
    case clarification(String)
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
    /// app, with Pause and Stop always reachable.
    case controlling(VisionSessionProgress)
    case result(String, RunSuggestion?)
    case failure(String)
}

struct FloatingWidgetView: View {
    @ObservedObject var viewModel: AgentViewModel
    @FocusState private var pillFocused: Bool
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
    /// *How long* it counts for is not here and not `autoCollapseDelay`'s neighbour below: it
    /// arrives with the hint, from `AgentViewModel.micHoverHintPresentation`, because one of the two
    /// hints this row can show does not count down at all.
    @StateObject private var micHint = MicHoverHintModel()

    private static let autoCollapseDelay: Duration = .seconds(6)

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

                if let notice = viewModel.localStorageNotice {
                    WidgetNoticeStrip(
                        message: notice,
                        icon: "externaldrive.badge.exclamationmark",
                        dismissAccessibilityLabel: "Dismiss storage notice"
                    ) {
                        viewModel.localStorageNotice = nil
                    }
                }

                // The planner router's "never a silent planner swap" surface (SONNY-85): when
                // the configured planner selection couldn't be honored, this says who actually
                // planned the task and why. The widget renders it because the widget is where
                // a run is watched; it is not a failure — the task ran.
                if let notice = viewModel.plannerFallbackNotice {
                    WidgetNoticeStrip(
                        message: notice,
                        icon: "exclamationmark.triangle",
                        dismissAccessibilityLabel: "Dismiss planner notice"
                    ) {
                        viewModel.plannerFallbackNotice = nil
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    composerPill
                    dontSaveButton
                    micButton
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: widgetStateKey)
        .animation(.easeOut(duration: 0.18), value: isCompact)
        // Real headroom for the (now much smaller, border-led) shadow plus a little breathing
        // room around the glass edge — not shadow-bleed-driven the way the old, larger padding
        // was, since there's no more large drop shadow needing room to fade out.
        .padding(16)
        .onAppear {
            pillFocused = true
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
        .onChange(of: viewModel.widgetPresentationRequest) { _, _ in
            if isCompact {
                expandFromCompact()
            } else {
                pillFocused = true
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
    /// always show) — kept there rather than duplicated here since
    /// `FloatingWidgetWindowController`'s compositing decision now depends on the exact same
    /// predicate and the two must never drift apart.
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
        viewModel.isPreparingVoiceRecording || viewModel.isRecordingVoice || viewModel.isTranscribingVoice
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
        switch state {
        case .idle:
            // Idle is the one state where the composer is enabled and the user can actually be
            // mid-typing. Collapsing out from under unsent text after 6s of thinking-while-typing
            // was a real bug — the field is genuinely "in use" even with nothing submitted yet.
            return viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .result, .failure:
            // An outcome the user was notified about does not collapse (SONNY-121). They were
            // working somewhere else when it happened, so the six-second timer measures how long
            // they have been *away*, not how long they have had to read it. Returning `false` here
            // also stops the clear: `scheduleAutoDismissIfNeeded` returns before arming the timer.
            //
            // Only `.failure` can currently be notified — the marker is set when an error
            // notification posts — but the two share this branch, and a `.result` that is not
            // notified reads `true` exactly as before.
            return !viewModel.outcomeWasNotified
        case .working:
            return viewModel.activeTaskOrigin != .widget
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
        let shouldClearOutcome = shouldClearOutcomeOnDismiss
        autoDismissTask = Task {
            try? await Task.sleep(for: Self.autoCollapseDelay)
            guard !Task.isCancelled else { return }
            isCompact = true
            if shouldClearOutcome {
                viewModel.clearStaleTaskOutcome()
            }
        }
    }

    private func expandFromCompact() {
        isCompact = false
        pillFocused = true
        scheduleAutoDismissIfNeeded()
    }

    private var styledPanel: some View {
        panel
            .padding(18)
            .frame(width: 472, alignment: .leading)
            .widgetGlassPanel()
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var compactCapsule: some View {
        Button(action: expandFromCompact) {
            Image(systemName: "wand.and.stars.inverse")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .widgetGlassPill()
        .help("Open Sonny")
    }

    private var state: WidgetState {
        if let preview = viewModel.visionCapturePreview {
            return .captureReview(preview)
        }
        if let delegation = viewModel.visionDelegationRequest {
            return .delegationReview(delegation)
        }
        if let pause = viewModel.visionSessionPause {
            return .sessionPaused(pause)
        }
        // Below the three parked questions and above `.working`: a question waiting on the user
        // outranks a progress line, and a vision session's progress line outranks the generic
        // working panel, which would otherwise say "Sonny is working" while it moves the cursor.
        if let progress = viewModel.visionSessionProgress {
            return .controlling(progress)
        }
        if let approvalRequest = viewModel.approvalRequest {
            return .permission(approvalRequest)
        }
        if let question = viewModel.clarificationQuestion {
            return .clarification(question)
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
        }
    }

    private var isTaskInFlight: Bool {
        viewModel.isRunning
            || viewModel.isAwaitingApproval
            || viewModel.clarificationQuestion != nil
            || viewModel.visionCapturePreview != nil
            || viewModel.visionDelegationRequest != nil
            || viewModel.visionSessionPause != nil
            || viewModel.visionSessionProgress != nil
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
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                    .buttonStyle(.plain)
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
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(TaskRecordingPresentation.clearAccessibilityLabel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(WidgetTheme.neutralButtonFill)
            .clipShape(Capsule())
        }
    }

    private var composerPill: some View {
        HStack(spacing: 10) {
            workspaceBindingChip
            dontSaveChip

            Image(systemName: "wand.and.stars.inverse")
                .font(WidgetType.icon)
                .foregroundStyle(.white.opacity(0.61))

            TextField(
                "",
                text: $viewModel.command,
                prompt: Text("Let Sonny take it from here\u{2026}").foregroundStyle(WidgetTheme.textMuted)
            )
            .textFieldStyle(.plain)
            .font(WidgetType.pillQuery)
            .foregroundStyle(WidgetTheme.textFull)
            .disabled(isTaskInFlight)
            .focused($pillFocused)
            .submitLabel(.go)
            .onSubmit(submit)

            if !isTaskInFlight {
                Button(action: submit) {
                    HStack(spacing: 3) {
                        Text("Start")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .font(WidgetType.headlineChip)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .widgetCapsuleBackground(tint: WidgetTheme.primaryAction)
                .disabled(viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
        }
        .padding(.leading, 14)
        // 8pt matches the Start button's own vertical inset (24pt tall in a 40pt pill leaves 8pt
        // above and below); the previous uniform 14pt left it visibly farther from the trailing
        // edge than from the top and bottom. Conditional because the button is not rendered while
        // a task is in flight — that state keeps its shipped 14pt rather than pulling the disabled
        // field 6pt closer to the capsule's curve to fix a complaint about a different state.
        .padding(.trailing, isTaskInFlight ? 14 : 8)
        .frame(width: 472, height: 40)
        .widgetGlassPill()
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
                    .font(.system(size: 13, weight: .medium))
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

    private var micButton: some View {
        Button {
            viewModel.toggleVoiceRecording(origin: .widget)
        } label: {
            Image(systemName: viewModel.voiceButtonIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 36)
        .widgetCircularBackground(tint: WidgetTheme.secondaryCircular)
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
    /// (the Insights weekly chart), and was confirmed unreliable here too, not just assumed.
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
    /// Entering only shows the hint when the slot is *already* free, which is not the same as
    /// letting the render condition decide. A hint shown while the panel is up would sit there
    /// unrendered and appear the instant the panel closed — a stale flicker attached to nothing the
    /// user just did, and for the configuration variant it would wait there indefinitely, since
    /// that one has no countdown to expire.
    private func micHintPointerEnteredMic() {
        if isMicHintSlotFree {
            micHint.show(viewModel.micHoverHintPresentation)
        } else {
            micHint.dismiss()
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
    /// the shortcut reminder is 189.6pt and the configuration message 254.1pt, so each stays a
    /// single line with room to spare and nothing about the window controller's fitted-size
    /// positioning has to be revisited. (SONNY-177 measured the same two at 285.4pt and 254.1pt;
    /// the reminder is the one whose wording SONNY-179 replaced, and it got shorter.)
    private func micHoverHintRow(_ hint: MicHoverHintPresentation) -> some View {
        Text(hint.message)
            .font(WidgetType.captionSmall)
            .foregroundStyle(WidgetTheme.textFull)
            .padding(.horizontal, 14)
            .frame(width: 472, height: 40, alignment: .leading)
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
            WidgetWorkingPanel(plan: viewModel.plan, stepStatuses: viewModel.stepStatuses)
        case .clarification(let question):
            WidgetClarificationPanel(
                plan: viewModel.plan,
                stepStatuses: viewModel.stepStatuses,
                question: question,
                answer: $viewModel.clarificationAnswer,
                onSubmit: { viewModel.submitClarification() }
            )
        case .permission(let request):
            WidgetPermissionPanel(
                plan: viewModel.plan,
                stepStatuses: viewModel.stepStatuses,
                request: request,
                isFirstApproval: !viewModel.hasCompletedFirstApproval,
                safeMode: viewModel.interactionMode == .safe,
                onAllow: { viewModel.start() },
                onDeny: { viewModel.cancelCurrentRun() }
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

    var body: some View {
        HStack(spacing: 8) {
            iconSlot
            Text(AgentActivityPresentation.planStepTitle(step))
                .font(WidgetType.caption)
                .foregroundStyle(isEmphasized ? WidgetTheme.textFull : WidgetTheme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
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
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetTheme.errorGlyph)
            default:
                if let resolvedIcon {
                    Image(nsImage: resolvedIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(status == .complete ? 1 : 0.6)
                } else {
                    Image(systemName: status == .complete ? "checkmark" : AgentActivityPresentation.eventIcon(.act))
                        .font(.system(size: status == .complete ? 10 : 11, weight: .semibold))
                        .foregroundStyle(WidgetTheme.textMuted)
                }
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// Real steps only — no fallback row, since this is reused by panels (permission/clarification/
/// failure) that append their own specific content below whatever steps exist, including zero.
private struct WidgetExistingStepRows: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]

    var body: some View {
        if let plan, !plan.steps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.steps) { step in
                    WidgetStepRow(step: step, status: stepStatuses[step.id] ?? .pending)
                }
            }
        }
    }
}

// MARK: - Working (§3.3.2)

private struct WidgetWorkingPanel: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]

    var body: some View {
        if let plan, !plan.steps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.steps) { step in
                    WidgetStepRow(step: step, status: stepStatuses[step.id] ?? .pending)
                }
            }
        } else {
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
    let onAllow: () -> Void
    let onDeny: () -> Void

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
            WidgetExistingStepRows(plan: plan, stepStatuses: stepStatuses)

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
            // so the failure colour was wrong for all of them. It also leaves `errorGlyph` used
            // exclusively by genuine error states (the failed-step glyph at :430 and the
            // storage-failure notice at :754), which is what makes "visually distinguishable from
            // Sonny's error states" a checkable property rather than a claim.
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
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetTheme.textMuted)

                (Text("Allow access to ").font(WidgetType.caption)
                    + Text(request.approvalCopy.involvedResource).font(WidgetType.captionMedium))
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(action: onDeny) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WidgetTheme.textFull)
                }
                .buttonStyle(.plain)
                .frame(width: 23, height: 23)
                .widgetCircularBackground()

                Button(action: onAllow) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(width: 23, height: 23)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
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
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Screenshot of \(preview.appDisplayName) that Sonny is about to send")
            }

            if let redactionLine {
                Text(redactionLine)
                    .font(WidgetType.captionSmall)
                    .foregroundStyle(WidgetTheme.secondaryCircular)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Step \(preview.iteration) of \(preview.appDisplayName)")
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
                .frame(height: 23)
                .widgetCircularBackground()

                Button(action: onSend) {
                    Text("Send")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 23)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
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
                .frame(height: 23)
                .widgetCircularBackground()

                Button(action: onAllow) {
                    Text("Use tools")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 23)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
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
                .frame(height: 23)
                .widgetCircularBackground()

                Button(action: onResume) {
                    Text("Resume")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 23)
                .widgetCircularBackground(tint: WidgetTheme.allowAction)
            }
        }
    }
}

/// **The HUD: power without covertness.**
///
/// While Sonny controls an app it says so, says which app, says what it is doing right now, and puts
/// Pause and Stop where the user can reach them. That is the whole requirement, and it is a product
/// requirement rather than a courtesy: a program moving someone's cursor with no visible statement of
/// what it is doing is the shape this feature must never take.
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
            HStack(spacing: 8) {
                // Amber, not the failure red: this is Sonny doing something unusual, not something
                // going wrong — the same distinction the approval panel's escalation line draws.
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 12))
                    .foregroundStyle(WidgetTheme.secondaryCircular)

                (Text("Sonny is controlling ").font(WidgetType.caption)
                    + Text(progress.appDisplayName).font(WidgetType.captionMedium))
                    .foregroundStyle(WidgetTheme.textFull)
                    .lineLimit(1)
            }

            Text(progress.currentAction)
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("Step \(progress.iteration) of \(progress.maximumIterations)")
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
                .frame(height: 23)
                .widgetCircularBackground()
                .accessibilityLabel("Pause Sonny controlling \(progress.appDisplayName)")

                Button(action: onStop) {
                    Text("Stop")
                        .font(WidgetType.captionMedium)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 23)
                .widgetCircularBackground(tint: WidgetTheme.errorGlyph)
                .accessibilityLabel("Stop Sonny controlling \(progress.appDisplayName)")
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

private struct WidgetClarificationPanel: View {
    let plan: AgentPlan?
    let stepStatuses: [String: AgentStepStatus]
    let question: String
    @Binding var answer: String
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetExistingStepRows(plan: plan, stepStatuses: stepStatuses)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetTheme.textMuted)
                    Text(question)
                        .font(WidgetType.caption)
                        .foregroundStyle(WidgetTheme.textFull)
                        .fixedSize(horizontal: false, vertical: true)
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
                    .onSubmit(onSubmit)

                    Button(action: onSubmit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 23, height: 23)
                    .widgetCircularBackground(tint: WidgetTheme.primaryAction)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(WidgetTheme.hairline.opacity(0.4), lineWidth: 0.5))
            }
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
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
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
    let dismissAccessibilityLabel: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(WidgetType.icon)
                .foregroundStyle(WidgetTheme.errorGlyph)
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
        .frame(width: 472, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WidgetTheme.panelBase.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(WidgetTheme.hairline.opacity(0.25), lineWidth: 1)
        )
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
                    .font(.system(size: 12))
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

                Spacer(minLength: 8)

                if canRetry {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 23, height: 23)
                    .widgetCircularBackground(tint: WidgetTheme.taskFailureRetry)
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
/// no manual re-registration needed.
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

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
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
