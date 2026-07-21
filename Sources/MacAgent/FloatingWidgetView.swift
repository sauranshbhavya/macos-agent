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
    case result(String, RunSuggestion?)
    case failure(String)
}

struct FloatingWidgetView: View {
    @ObservedObject var viewModel: AgentViewModel
    /// Whether `FloatingWidgetWindowController` currently has this composited inside the Command
    /// Center window (§3.4) rather than floating standalone — defaulted so existing call sites
    /// (tests constructing this directly) don't need updating; the window controller passes its
    /// own real instance. Drives hiding the compose pill/compact capsule entirely while
    /// composited: per §3.4, "only the step-log panel appears; the separate idle input pill is
    /// not shown alongside it" — Command Center already has its own composer on-page, a second
    /// one floating on top of it is exactly what read as "2 widgets" being shown.
    @ObservedObject var positionState: WidgetPositionState = WidgetPositionState()
    @FocusState private var pillFocused: Bool
    /// Per Wispr Flow's own "shrink the bubble when not in use" behavior — collapses to a tiny
    /// icon-only capsule after a period with nothing needing attention, so the widget doesn't sit
    /// on screen as a constant visual barrier. Only meaningful while `isCollapsible` (see below);
    /// forced back to `false` the instant something needs real attention.
    @State private var isCompact = false
    @State private var autoCollapseTask: Task<Void, Never>?
    /// Drives a hover hint shown as a real layout row (see `micHoverHint`) rather than a
    /// `.help()` tooltip — `.help()` already proved unreliable in this exact app once before
    /// (the Insights weekly chart), and was confirmed unreliable here too, not just assumed.
    @State private var isMicHovered = false

    private static let autoCollapseDelay: Duration = .seconds(6)

    var body: some View {
        // .leading, not .trailing: the panel and pill are both a fixed 472pt (matching the
        // wireframe, where the mic button is a separate satellite floating outside that column,
        // not part of its width) — the pill+mic HStack is wider than the panel alone (~520pt vs
        // 472pt), so .trailing right-aligned them, leaving the panel's *left* edge visibly
        // indented relative to the pill below it. That was the "error banner misplaced" bug.
        VStack(alignment: .leading, spacing: 12) {
            if positionState.isComposited {
                if showsPanel {
                    styledPanel
                }
                // Nothing else while composited — no compose pill, no compact capsule, no mic
                // hint. Command Center's own composer/indicator already occupies that role on
                // the page underneath; showing a second one here is the exact bug this fixes.
            } else if isCompact {
                compactCapsule
            } else {
                if showsPanel {
                    styledPanel
                } else if isMicHovered {
                    micHoverHint
                }

                HStack(alignment: .center, spacing: 12) {
                    composerPill
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
            scheduleAutoCollapseIfNeeded()
        }
        .onChange(of: widgetStateKey) { _, _ in
            scheduleAutoCollapseIfNeeded()
        }
        .onChange(of: viewModel.command) { _, _ in
            if !isCompact {
                scheduleAutoCollapseIfNeeded()
            }
        }
        .onChange(of: isVoiceActive) { _, _ in
            scheduleAutoCollapseIfNeeded()
        }
        // Forces SwiftUI to report its real ideal (non-expanding) size rather than growing to fill
        // whatever frame AppKit hands it — FloatingWidgetWindowController reads that size via
        // NSHostingController.view.fittingSize to keep the panel bottom-pinned and tightly sized.
        .fixedSize()
    }

    /// Whether the panel (step-log/permission/clarification/result/failure) should render at all.
    /// `.working`/`.result` are gated to `activeTaskOrigin == .widget` — those are exactly the two
    /// states that showed real content, and showing them for a task the widget didn't submit is
    /// what caused the widget to render a second, confusing copy of whatever Command Center's own
    /// composer/indicator was already showing for the same task. `.permission`/`.clarification`
    /// stay ungated: they're the *only* functional path to resolve either today (Command Center's
    /// own on-page indicator deliberately has no approval controls), so hiding them for a
    /// Command-Center-originated task would make it permanently un-actionable, not just visually
    /// duplicated. `.failure` also stays ungated for a related reason: Command Center shows
    /// `errorMessage` nowhere on its own pages, so the widget is currently the only place a task
    /// failure is proactively surfaced at all — gating it away would make failures invisible
    /// rather than just non-duplicated. Flagged in docs/sonny-ui-backend-gaps.md as worth a real
    /// fix (e.g. Command Center showing its own failure state) rather than silently left this way.
    private var showsPanel: Bool {
        switch state {
        case .idle:
            return false
        case .working, .result:
            return viewModel.activeTaskOrigin == .widget
        case .permission, .clarification, .failure:
            return true
        }
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
        case .idle, .result, .failure:
            return true
        case .working:
            return viewModel.activeTaskOrigin != .widget
        case .permission, .clarification:
            return false
        }
    }

    private func scheduleAutoCollapseIfNeeded() {
        autoCollapseTask?.cancel()
        guard isCollapsible else {
            isCompact = false
            return
        }
        autoCollapseTask = Task {
            try? await Task.sleep(for: Self.autoCollapseDelay)
            guard !Task.isCancelled else { return }
            isCompact = true
        }
    }

    private func expandFromCompact() {
        isCompact = false
        pillFocused = true
        scheduleAutoCollapseIfNeeded()
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
        case .result: return 4
        case .failure: return 5
        }
    }

    private var isTaskInFlight: Bool {
        viewModel.isRunning || viewModel.isAwaitingApproval || viewModel.clarificationQuestion != nil
    }

    private func submit() {
        let text = viewModel.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isTaskInFlight else { return }
        viewModel.start(forceRealExecution: true, origin: .widget)
        viewModel.command = ""
    }

    private var composerPill: some View {
        HStack(spacing: 10) {
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
        .padding(.horizontal, 14)
        .frame(width: 472, height: 40)
        .widgetGlassPill()
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
        .disabled(!viewModel.canUseVoice && !viewModel.isRecordingVoice)
        .onHover { hovering in isMicHovered = hovering }
    }

    /// Real layout row (same slot the panel occupies), not a `.help()` tooltip or a floating
    /// `.overlay` — both would need extra window padding to avoid clipping the same way the old
    /// drop shadow did; this participates in `fixedSize()`'s measurement like everything else, so
    /// the window just grows to fit it correctly.
    private var micHoverHint: some View {
        Text("Speak your command — or hold Ctrl-Opt-Space anywhere")
            .font(WidgetType.captionSmall)
            .foregroundStyle(WidgetTheme.textFull)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .widgetGlassPanel()
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
                onAllow: { viewModel.start() },
                onDeny: { viewModel.cancelCurrentRun() }
            )
        case .result(let summary, let suggestion):
            WidgetResultPanel(summary: summary, suggestion: suggestion) { suggestion in
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
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetExistingStepRows(plan: plan, stepStatuses: stepStatuses)

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
    let suggestion: RunSuggestion?
    let onOpen: (RunSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary)
                .font(WidgetType.caption)
                .foregroundStyle(WidgetTheme.textFull)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

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
