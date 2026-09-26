import MacAgentCore
import SwiftUI

/// The floating widget: the composer, the microphone, and above them the panel for the task the
/// person is following. It collapses to the logo when nothing needs it and expands on a click,
/// the menu's Ask Sonny, the voice hotkey or a task that needs the person.
struct WidgetView: View {
    @ObservedObject var model: SonnyAppModel
    @State private var isCompact = false
    @State private var collapse: Task<Void, Never>?
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long an idle, empty widget stays open.
    static let collapseDelay: Duration = .seconds(8)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isCompact {
                compactButton
            } else {
                if let task = model.widgetTask {
                    WidgetTaskPanel(model: model, task: task)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                ForEach(model.desk.notices.suffix(2)) { notice in
                    WidgetNoticeStrip(message: notice.message, icon: icon(for: notice.kind)) {
                        model.desk.dismiss(notice)
                    }
                }
                if let versionNotice {
                    WidgetNoticeStrip(message: versionNotice, icon: "arrow.down.circle", onDismiss: nil)
                }
                if let problem = model.voiceProblem {
                    WidgetNoticeStrip(message: problem, icon: "mic.slash", onDismiss: nil)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    composerPill
                    voiceControl
                        .transaction { $0.animation = nil }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: stateKey)
        .padding(16)
        .fixedSize()
        .onAppear {
            composerFocused = true
            scheduleCollapse()
        }
        .onChange(of: model.widgetRequests) { _, _ in expand() }
        .onChange(of: stateKey) { _, _ in
            if model.widgetTask?.needsThePerson == true { expand() }
            scheduleCollapse()
        }
        .onChange(of: model.composerText) { _, _ in scheduleCollapse() }
    }

    // MARK: Compact

    private var compactButton: some View {
        Button(action: expand) {
            SonnyBrandMark(size: WidgetTheme.composerMarkSize)
                .foregroundStyle(WidgetTheme.textStrong)
                .overlay(alignment: .topTrailing) {
                    if model.isTaskRunning {
                        Circle().fill(WidgetTheme.primaryAction).frame(width: 7, height: 7).offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(CompactWidgetButtonStyle())
        .frame(width: WidgetTheme.compactSize, height: WidgetTheme.compactSize)
        .widgetGlassPill()
        .accessibilityLabel("Open Sonny")
        .help("Open Sonny")
    }

    private func expand() {
        collapse?.cancel()
        isCompact = false
        composerFocused = true
        scheduleCollapse()
    }

    /// Collapses an idle widget: nothing typed, not listening, and no task on show.
    private func scheduleCollapse() {
        collapse?.cancel()
        collapse = Task {
            try? await Task.sleep(for: Self.collapseDelay)
            guard !Task.isCancelled, isIdle else { return }
            isCompact = true
        }
    }

    private var isIdle: Bool {
        model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.voice == .idle
            && model.widgetTask == nil
            && model.followUp == nil
            && model.desk.notices.isEmpty
    }

    private var stateKey: String {
        guard let task = model.widgetTask else { return "none" }
        return "\(task.id)-\(String(describing: task.phase).prefix(24))"
    }

    // MARK: Composer

    private var composerIsBusy: Bool {
        model.isFollowedTaskRunning
    }

    private var composerPill: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let followUp = model.followUp {
                HStack(spacing: 4) {
                    Text("Following up: \(followUp.goal)")
                        .font(WidgetType.captionSmall)
                        .foregroundStyle(WidgetTheme.textFull)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button(action: model.clearFollowUp) {
                        Image(systemName: "xmark")
                            .font(WidgetType.headlineChip)
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Don't follow up")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(WidgetTheme.neutralButtonFill)
                .clipShape(Capsule())
                .frame(height: 18)
            }
            composerField
        }
        .padding(.leading, 14)
        .padding(.trailing, composerIsBusy ? 14 : WidgetTheme.composerEdgeInset)
        .frame(width: WidgetTheme.panelWidth)
        .frame(minHeight: WidgetTheme.composerHeight)
        .widgetGlassPill()
        .overlay {
            if model.isPrivate {
                Capsule()
                    .stroke(WidgetTheme.privateModeOutline, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var composerField: some View {
        HStack(spacing: 10) {
            // The logo is the private-mode toggle (Bhavya's 336959ca): on, the next task isn't
            // kept on this Mac and the gateway deletes it when it ends.
            Button { model.isPrivate.toggle() } label: {
                SonnyBrandMark(size: WidgetTheme.composerMarkSize)
                    .foregroundStyle(composerIsBusy ? WidgetTheme.textFaint : WidgetTheme.textFull)
                    .frame(width: WidgetTheme.controlSize, height: WidgetTheme.controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(composerIsBusy || model.voice != .idle)
            .accessibilityLabel("Don't save this task")
            .accessibilityValue(model.isPrivate ? "On" : "Off")
            .accessibilityAddTraits(model.isPrivate ? [.isButton, .isSelected] : .isButton)
            .help(model.isPrivate ? "This task won't be saved" : "Don't save this task")

            ZStack(alignment: .leading) {
                if model.composerText.isEmpty {
                    Text(placeholder)
                        .font(WidgetType.pillQuery)
                        .foregroundStyle(WidgetTheme.helperText)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $model.composerText)
                    .textFieldStyle(.plain)
                    .font(WidgetType.pillQuery)
                    .foregroundStyle(WidgetTheme.textFull)
                    .disabled(composerIsBusy || model.voice != .idle)
                    .focused($composerFocused)
                    .onSubmit(model.submitComposer)
                    .accessibilityLabel(placeholder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !composerIsBusy {
                Button(action: model.submitComposer) {
                    HStack(spacing: 3) {
                        Text("Start")
                        Image(systemName: "chevron.right").font(WidgetType.headlineChip)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(WidgetTheme.textStrong)
                .font(WidgetType.headlineChip)
                .padding(.horizontal, 12)
                .frame(height: WidgetTheme.startButtonHeight)
                .widgetCapsuleBackground(tint: WidgetTheme.primaryAction)
                .disabled(!model.canSubmit)
                .opacity(model.canSubmit ? 1 : 0.5)
            }
        }
        .frame(height: WidgetTheme.composerHeight)
    }

    private var placeholder: String {
        switch model.voice {
        case .recording: "Listening…"
        case .transcribing: "Working out what you said…"
        case .idle: composerIsBusy ? "Sonny is on it…" : "Ask Sonny to do something"
        }
    }

    // MARK: Voice

    private var voiceControl: some View {
        // Ticks only while recording, so VoiceOver on the mic button hears how long is left.
        TimelineView(.animation(minimumInterval: 1, paused: !isRecording)) { context in
            voiceControl(now: context.date)
        }
    }

    private func voiceControl(now: Date) -> some View {
        HStack(spacing: 8) {
            if case .recording(let startedAt) = model.voice {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let remaining = VoiceRecordingCountdown.remaining(startedAt: startedAt, now: context.date)
                    Text(VoiceRecordingCountdown.label(remaining: remaining))
                        .font(WidgetType.captionMedium)
                        .monospacedDigit()
                        .foregroundStyle(VoiceRecordingCountdown.isWarning(remaining: remaining) ? WidgetTheme.attention : WidgetTheme.textMuted)
                        .frame(minWidth: VoiceRecordingCountdown.labelReservedWidth, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            Button(action: model.toggleVoice) {
                Group {
                    switch model.voice {
                    case .idle: Image(systemName: "mic")
                    case .recording: Image(systemName: "stop.fill")
                    case .transcribing: WidgetSpinner()
                    }
                }
                .font(WidgetType.captionMedium)
                .foregroundStyle(WidgetTheme.textStrong)
            }
            .buttonStyle(.plain)
            .frame(width: WidgetTheme.satelliteControlSize, height: WidgetTheme.satelliteControlSize)
            .widgetGlassCircle()
            .disabled(model.voice == .transcribing || composerIsBusy)
            .accessibilityLabel("Voice input")
            .accessibilityValue(voiceValue(now: now))
        }
        .padding(.leading, isRecording ? 10 : 2)
        .padding(.trailing, 2)
        .frame(height: WidgetTheme.composerHeight)
        .widgetGlassPill()
    }

    private var isRecording: Bool {
        if case .recording = model.voice { return true }
        return false
    }

    private func voiceValue(now: Date) -> String {
        switch model.voice {
        case .idle:
            "Start listening"
        case .recording(let startedAt):
            "Listening, \(VoiceRecordingCountdown.accessibilityValue(remaining: VoiceRecordingCountdown.remaining(startedAt: startedAt, now: now))). Press to send."
        case .transcribing:
            "Working out what you said"
        }
    }

    // MARK: Notices

    private var versionNotice: String? {
        switch model.clientVersion {
        case .current: nil
        case .updateAvailable: "A new version of Sonny is ready. Update when you can."
        case .tooOld: ClientVersionCopy.tooOldMessage
        }
    }

    private func icon(for kind: DeskNotice.Kind) -> String {
        switch kind {
        case .unattendedRun: "clock.arrow.circlepath"
        case .missedSchedule: "clock.badge.exclamationmark"
        case .watcherStopped: "eye.slash"
        }
    }
}

/// One line of news under the panel, with a dismiss button when it can be dismissed.
struct WidgetNoticeStrip: View {
    let message: String
    let icon: String
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(WidgetType.icon)
                .foregroundStyle(WidgetTheme.textMuted)
            Text(message)
                .font(WidgetType.body)
                .foregroundStyle(WidgetTheme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(WidgetType.iconSmall).foregroundStyle(WidgetTheme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: WidgetTheme.panelWidth, alignment: .leading)
        .widgetGlassPanel()
    }
}

/// The compact logo's press: a restrained scale with no layout change, so it can't feed the
/// panel's resize (the loop Bhavya's commit removed). Reduce Motion turns it off.
private struct CompactWidgetButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
