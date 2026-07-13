import AppKit
import MacAgentCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AgentViewModel
    let openCommandCenter: () -> Void

    init(viewModel: AgentViewModel, openCommandCenter: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.openCommandCenter = openCommandCenter
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            SonnyTheme.glassShade
            LinearGradient(
                colors: [
                    SonnyTheme.accent.opacity(0.10),
                    Color.clear,
                    SonnyTheme.cream.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 14) {
                header
                AgentCommandComposerView(viewModel: viewModel, autoFocus: true)
                if viewModel.showClipboardHistoryNotice {
                    ClipboardHistoryNotice(viewModel: viewModel)
                }
                SavedItemsPanel(viewModel: viewModel)
                AgentTaskActivityView(viewModel: viewModel, showsStartupWhenEmpty: true)
            }
            .padding(20)

            if viewModel.showPermissionPanel {
                SystemStatusPanel(viewModel: viewModel)
                    .frame(width: 384)
                    .padding(.top, 84)
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .frame(width: 600, height: 740)
        .background(.clear)
        .foregroundStyle(SonnyTheme.text)
        .tint(SonnyTheme.accent)
        .environment(\.sonnyPointerCursorsEnabled, viewModel.usePointerCursors)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshSavedItems()
            viewModel.refreshClipboardHistoryNotice()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SonnyMark()

            VStack(alignment: .leading, spacing: 0) {
                Text("Sonny")
                    .font(SonnyType.brand)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(1)
                Text("Ask. Check. Done.")
                    .font(SonnyType.tagline)
                    .foregroundStyle(SonnyTheme.muted)
            }
            Spacer()
            Button(action: openCommandCenter) {
                Label("Open Sonny", systemImage: "rectangle.split.2x1")
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary))
            .help("Open Sonny in a window")

            Button {
                viewModel.togglePermissionPanel()
            } label: {
                Label("Status", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary))
            .help("Show model, voice, and permission status")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(SonnyIconButtonStyle())
            .help("Quit")
        }
    }
}

struct AgentCommandComposerView: View {
    @ObservedObject var viewModel: AgentViewModel
    let autoFocus: Bool
    let focusRequest: Int
    @FocusState private var commandFocused: Bool

    init(viewModel: AgentViewModel, autoFocus: Bool = false, focusRequest: Int = 0) {
        self.viewModel = viewModel
        self.autoFocus = autoFocus
        self.focusRequest = focusRequest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ask Sonny")
                    .font(SonnyType.eyebrow)
                    .foregroundStyle(SonnyTheme.muted)
                TextField("Open Safari, zip files, convert docs...", text: $viewModel.command)
                    .textFieldStyle(.plain)
                    .font(SonnyType.command)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(SonnyTheme.input)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                commandFocused ? SonnyTheme.accent.opacity(0.72) : SonnyTheme.border,
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(viewModel.isRunning)
                    .focused($commandFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        viewModel.start()
                    }

                if let recentTask = viewModel.recentTaskAffordanceText {
                    RecentTaskAffordance(text: recentTask)
                }

                if !viewModel.voiceTranscript.isEmpty {
                    Label("Voice command received", systemImage: "waveform")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    DryRunToggle(isOn: $viewModel.dryRun)
                        .disabled(viewModel.isRunning || viewModel.isAwaitingApproval)

                    Button {
                        viewModel.toggleVoiceRecording()
                    } label: {
                        Label(viewModel.voiceButtonTitle, systemImage: viewModel.voiceButtonIcon)
                    }
                    .disabled(!viewModel.canUseVoice && !viewModel.isRecordingVoice)
                    .buttonStyle(
                        SonnyButtonStyle(
                            tone: viewModel.isRecordingVoice ? .danger : .secondary,
                            width: 86
                        )
                    )
                    .help("Click to speak, or hold Control-Option-Space")

                    HotKeyHint(title: viewModel.voiceHotKeyReady ? "Ctrl-Opt-Space" : "Unavailable")
                }
                .frame(width: 320, alignment: .leading)

                Spacer(minLength: 12)

                if viewModel.canCancel {
                    Button {
                        viewModel.cancelCurrentRun()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 86))
                } else {
                    Button {
                        viewModel.reset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(viewModel.isRunning)
                    .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 80))
                }

                Button {
                    viewModel.start()
                } label: {
                    Label(viewModel.primaryButtonTitle, systemImage: viewModel.primaryButtonIcon)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!viewModel.canSubmit)
                .buttonStyle(SonnyButtonStyle(tone: .primary, width: 92))
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if autoFocus {
                commandFocused = true
            }
        }
        .onChange(of: focusRequest) { _, _ in
            commandFocused = true
        }
    }
}

private struct RecentTaskAffordance: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(SonnyType.icon(13))
                .foregroundStyle(SonnyTheme.accent)
                .frame(width: 16)

            Text("Recent task")
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.text)

            Text(text)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SonnyTheme.surfaceRaised.opacity(0.84))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ClipboardHistoryNotice: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clipboard")
                .font(SonnyType.icon(16))
                .foregroundStyle(SonnyTheme.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Clipboard history")
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.text)
                Text("Sonny can watch copied text system-wide, excluding password-manager entries flagged ConcealedType or TransientType, and keeps a capped local history.")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $viewModel.clipboardHistoryEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Enable clipboard history")

            Button {
                viewModel.applyClipboardHistoryNoticeChoice()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary, width: 82))
        }
        .padding(12)
        .background(SonnyTheme.surfaceRaised.opacity(0.84))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SonnyMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            SonnyTheme.cream.opacity(0.10),
                            SonnyTheme.accent.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(SonnyTheme.accent.opacity(0.38), lineWidth: 1)
                )
            Image(systemName: "wand.and.stars.inverse")
                .font(SonnyType.icon(17))
                .foregroundStyle(SonnyTheme.accent)
        }
        .frame(width: 42, height: 42)
    }
}

private struct HotKeyHint: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "keyboard")
            .font(SonnyType.micro)
            .foregroundStyle(SonnyTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .frame(width: 112, height: 34)
            .background(SonnyTheme.surfaceRaised.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct DryRunToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Dry run")
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .frame(width: 44, alignment: .leading)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(width: 54)
        }
        .frame(width: 106, height: 34, alignment: .leading)
    }
}

private struct SystemStatusPanel: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var showDeleteLocalDataConfirmation = false

    var body: some View {
        Panel(title: "Status", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    StatusChip(
                        title: viewModel.hasAPIKey ? "OpenAI ready" : "Needs key",
                        systemImage: viewModel.hasAPIKey ? "checkmark.seal" : "key.slash",
                        tone: viewModel.hasAPIKey ? .ready : .warning
                    )
                    StatusChip(title: viewModel.modelName, systemImage: "brain", tone: .neutral)
                    StatusChip(title: viewModel.transcriptionModelName, systemImage: "waveform", tone: .neutral)
                    StatusChip(
                        title: viewModel.voiceHotKeyReady ? viewModel.voiceHotKeyStatus : "Hotkey unavailable",
                        systemImage: "keyboard",
                        tone: viewModel.voiceHotKeyReady ? .neutral : .warning
                    )
                }

                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(height: 1)

                ScrollView {
                    PermissionReadinessRows(items: viewModel.permissionItems)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 248)

                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(height: 1)

                localDataDeletionControl
            }
        }
        .confirmationDialog(
            "Delete Sonny Local Data?",
            isPresented: $showDeleteLocalDataConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Local Data", role: .destructive) {
                viewModel.deleteLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes saved routines, workspaces, clipboard history, snippets, recent artifacts, Shortcut run history, task history, and clipboard settings. Generated files and API keys are not deleted.")
        }
    }

    private var localDataDeletionControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "trash")
                    .font(SonnyType.icon(14))
                    .foregroundStyle(SonnyTheme.danger)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Local data")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.text)
                    Text("Saved routines, workspaces, clipboard history, snippets, recent artifacts, Shortcut run history, task history, and clipboard settings.")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    showDeleteLocalDataConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(SonnyButtonStyle(tone: .danger, width: 96))
                .disabled(viewModel.isRunning)
                .help("Delete local Sonny data")
            }

            if let message = viewModel.localDataDeletionStatusMessage {
                Label(message, systemImage: message.hasPrefix("Deleted") ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(SonnyType.micro)
                    .foregroundStyle(message.hasPrefix("Deleted") ? SonnyTheme.accent : SonnyTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PermissionReadinessRows: View {
    let items: [PermissionReadinessItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: item.state))
                        .font(SonnyType.caption)
                        .foregroundStyle(color(for: item.state))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(SonnyType.caption)
                            .foregroundStyle(SonnyTheme.text)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.muted)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func icon(for state: PermissionReadinessState) -> String {
        switch state {
        case .ready:
            return "checkmark.circle"
        case .needsAction:
            return "exclamationmark.triangle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func color(for state: PermissionReadinessState) -> Color {
        switch state {
        case .ready:
            return SonnyTheme.accent
        case .needsAction:
            return SonnyTheme.warning
        case .unknown:
            return SonnyTheme.muted
        }
    }
}

private struct StatusChip: View {
    let title: String
    let systemImage: String
    let tone: Tone

    enum Tone {
        case ready
        case warning
        case neutral
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(SonnyType.caption)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 9)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var foreground: Color {
        switch tone {
        case .ready:
            return SonnyTheme.accent
        case .warning:
            return SonnyTheme.warning
        case .neutral:
            return SonnyTheme.muted
        }
    }

    private var background: Color {
        switch tone {
        case .ready:
            return SonnyTheme.accent.opacity(0.12)
        case .warning:
            return SonnyTheme.warning.opacity(0.14)
        case .neutral:
            return SonnyTheme.surfaceRaised
        }
    }
}

private struct SavedItemsPanel: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        if !viewModel.savedRoutines.isEmpty || !viewModel.savedWorkspaces.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                SavedColumn(
                    title: "Routines",
                    systemImage: "repeat",
                    emptyLabel: "No routines",
                    items: viewModel.savedRoutines.map { routine in
                        SavedItem(
                            title: routine.name,
                            subtitle: "\(routine.steps.count) step\(routine.steps.count == 1 ? "" : "s")",
                            details: routine.steps.prefix(4).map(AgentActivityPresentation.operationTitle),
                            actionTitle: "Run",
                            actionIcon: "play",
                            action: { viewModel.runRoutineWidget(routine) }
                        )
                    }
                )

                SavedColumn(
                    title: "Workspaces",
                    systemImage: "rectangle.3.group",
                    emptyLabel: "No workspaces",
                    items: viewModel.savedWorkspaces.map { workspace in
                        let appCount = workspace.apps.count
                        let urlCount = workspace.urls.count
                        return SavedItem(
                            title: workspace.name,
                            subtitle: "\(appCount) app\(appCount == 1 ? "" : "s"), \(urlCount) URL\(urlCount == 1 ? "" : "s")",
                            details: workspaceDetails(workspace),
                            actionTitle: "Open",
                            actionIcon: "arrow.up.right",
                            action: { viewModel.openWorkspaceWidget(workspace) }
                        )
                    }
                )
            }
        }
    }

    private func workspaceDetails(_ workspace: StoredWorkspace) -> [String] {
        let apps = workspace.apps.isEmpty ? [] : ["Apps: \(workspace.apps.joined(separator: ", "))"]
        let urls = workspace.urls.isEmpty ? [] : ["URLs: \(workspace.urls.joined(separator: ", "))"]
        return apps + urls
    }
}

private struct SavedItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let details: [String]
    let actionTitle: String
    let actionIcon: String
    let action: () -> Void
}

private struct SavedColumn: View {
    let title: String
    let systemImage: String
    let emptyLabel: String
    let items: [SavedItem]

    var body: some View {
        Panel(title: title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 10) {
                if items.isEmpty {
                    Text(emptyLabel)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                } else {
                    ForEach(items.prefix(3)) { item in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(SonnyType.itemTitle)
                                        .foregroundStyle(SonnyTheme.text)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(SonnyType.micro)
                                        .foregroundStyle(SonnyTheme.muted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button(action: item.action) {
                                    Label(item.actionTitle, systemImage: item.actionIcon)
                                }
                                .buttonStyle(SonnyMiniButtonStyle())
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(item.details, id: \.self) { detail in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .stroke(SonnyTheme.accent.opacity(0.58), lineWidth: 1)
                                            .frame(width: 6, height: 6)
                                        Text(detail)
                                            .font(SonnyType.micro)
                                            .foregroundStyle(SonnyTheme.muted)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }
}

struct AgentTaskActivityView: View {
    @ObservedObject var viewModel: AgentViewModel
    let showsStartupWhenEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.isPreparingVoiceRecording || viewModel.isRecordingVoice || viewModel.isTranscribingVoice {
                VoiceStatusPanel(viewModel: viewModel)
            }

            if viewModel.isRunning {
                BusyPanel(logStore: viewModel.logStore)
            }

            if let error = viewModel.errorMessage {
                ErrorBanner(message: error)
            }

            if let question = viewModel.clarificationQuestion {
                ClarificationPanel(viewModel: viewModel, question: question)
            }

            RunDetailsView(
                viewModel: viewModel,
                logStore: viewModel.logStore,
                showsStartupWhenEmpty: showsStartupWhenEmpty
            )
        }
    }
}

private struct RunDetailsView: View {
    @ObservedObject var viewModel: AgentViewModel
    @ObservedObject var logStore: AgentLogStore
    let showsStartupWhenEmpty: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let plan = viewModel.plan {
                        PlanPanel(plan: plan, stepStatuses: viewModel.stepStatuses)
                    }

                    if !viewModel.previews.isEmpty {
                        PreviewPanel(previews: viewModel.previews)
                    }

                    if let approvalRequest = viewModel.approvalRequest {
                        ApprovalPanel(request: approvalRequest)
                    }

                    if showsStartupWhenEmpty
                        && logStore.events.isEmpty
                        && viewModel.plan == nil
                        && viewModel.previews.isEmpty
                        && viewModel.finalSummary.isEmpty {
                        StartupPanel()
                    } else {
                        if !logStore.events.isEmpty {
                            LogPanel(logStore: logStore)
                        }
                    }

                    if shouldShowUsageSummary {
                        UsageSummaryBadge(summary: viewModel.taskUsageSummary)
                    }

                    if !viewModel.finalSummary.isEmpty {
                        SummaryPanel(
                            summary: viewModel.finalSummary,
                            suggestions: viewModel.suggestions,
                            copy: viewModel.copySummary,
                            runSuggestion: viewModel.runSuggestion
                        )
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("run-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: logStore.events.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.finalSummary) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var shouldShowUsageSummary: Bool {
        viewModel.taskUsageSummary.requestCount > 0
            || viewModel.approvalRequest != nil
            || viewModel.plan != nil
            || !viewModel.previews.isEmpty
            || !viewModel.finalSummary.isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("run-bottom", anchor: .bottom)
            }
        }
    }
}

private struct PlanPanel: View {
    let plan: AgentPlan
    let stepStatuses: [String: AgentStepStatus]

    var body: some View {
        Panel(title: "Plan", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text(plan.summary)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                    .lineSpacing(2)

                ForEach(plan.steps) { step in
                    let status = stepStatuses[step.id] ?? .pending
                    HStack(alignment: .top, spacing: 8) {
                        StepStatusIcon(status: status)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AgentActivityPresentation.planStepTitle(step))
                                .font(SonnyType.caption)
                                .foregroundStyle(SonnyTheme.text.opacity(0.9))
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(AgentActivityPresentation.statusTitle(status))
                                .font(SonnyType.micro)
                                .foregroundStyle(SonnyTheme.muted)
                        }
                    }
                }
            }
        }
    }
}

private struct StepStatusIcon: View {
    let status: AgentStepStatus

    var body: some View {
        Image(systemName: icon)
            .font(SonnyType.caption)
            .foregroundStyle(color)
            .frame(width: 16)
            .help(AgentActivityPresentation.statusTitle(status))
    }

    private var icon: String {
        switch status {
        case .pending:
            return "circle"
        case .running:
            return "play.circle"
        case .complete:
            return "checkmark.circle"
        case .failed:
            return "xmark.octagon"
        case .canceled:
            return "minus.circle"
        }
    }

    private var color: Color {
        switch status {
        case .pending:
            return SonnyTheme.muted
        case .running:
            return SonnyTheme.info
        case .complete:
            return SonnyTheme.accent
        case .failed:
            return SonnyTheme.danger
        case .canceled:
            return SonnyTheme.warning
        }
    }
}

private struct PreviewPanel: View {
    let previews: [ActionPreview]

    var body: some View {
        Panel(title: "Preview", systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(previews) { preview in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(preview.title)
                            .font(SonnyType.bodyEmphasis)
                            .foregroundStyle(SonnyTheme.text)
                            .lineSpacing(2)

                        ForEach(preview.details, id: \.self) { detail in
                            Text(detail)
                                .font(SonnyType.caption)
                                .foregroundStyle(SonnyTheme.muted)
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(preview.sideEffects, id: \.self) { sideEffect in
                            Label(
                                AgentActivityPresentation.previewSideEffect(sideEffect),
                                systemImage: "exclamationmark.triangle"
                            )
                                .font(SonnyType.caption)
                                .foregroundStyle(SonnyTheme.warning)
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct ApprovalPanel: View {
    let request: RiskApprovalRequest

    var body: some View {
        Panel(title: "Approval", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(request.assessment.effectiveTier.displayName, systemImage: "exclamationmark.triangle")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.warning)
                    Text(request.requirement.displayName)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                }

                ForEach(request.approvalCopy.lines, id: \.self) { line in
                    Text(line)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.text.opacity(0.88))
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct LogPanel: View {
    @ObservedObject var logStore: AgentLogStore

    var body: some View {
        Panel(title: "Activity", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(logStore.events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: AgentActivityPresentation.eventIcon(event.phase))
                            .font(SonnyType.icon(12))
                            .foregroundStyle(phaseColor(event.phase))
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AgentActivityPresentation.eventTitle(event))
                                .font(SonnyType.micro)
                                .foregroundStyle(phaseColor(event.phase))
                            Text(AgentActivityPresentation.eventMessage(event))
                                .font(SonnyType.caption)
                                .foregroundStyle(SonnyTheme.text.opacity(0.88))
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func phaseColor(_ phase: AgentPhase) -> Color {
        switch phase {
        case .plan:
            return SonnyTheme.cream.opacity(0.72)
        case .validate:
            return SonnyTheme.accent
        case .risk:
            return SonnyTheme.warning
        case .preview:
            return SonnyTheme.accent
        case .confirm:
            return SonnyTheme.warning
        case .act:
            return SonnyTheme.cream.opacity(0.86)
        case .observe:
            return SonnyTheme.accent
        case .summarize:
            return SonnyTheme.muted
        }
    }
}

private struct StartupPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .font(SonnyType.panelIcon)
                    .foregroundStyle(SonnyTheme.accent)
                Text("Ready when you are")
                    .font(SonnyType.hero)
                    .foregroundStyle(SonnyTheme.text)
            }

            StartupCapabilities()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 8)
    }
}

private struct StartupCapabilities: View {
    private let items = [
        ("Finder context", "Use selected Finder folders safely."),
        ("Chain actions", "Zip, save, reveal, and open in one request."),
        ("Routines", "Teach repeatable local workflows."),
        ("Workspaces", "Launch saved app and URL sets."),
        ("Voice", "Hold the hotkey, speak, release.")
    ]

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ], alignment: .leading, spacing: 12) {
            ForEach(items, id: \.0) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "checkmark.circle")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.accent)
                        .frame(width: 14)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.0)
                            .font(SonnyType.itemTitle)
                            .foregroundStyle(SonnyTheme.text.opacity(0.92))
                        Text(item.1)
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.muted)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct UsageSummaryBadge: View {
    let summary: TaskUsageSummary

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "chart.bar")
                .font(SonnyType.icon(13))
                .foregroundStyle(SonnyTheme.accent)
                .frame(width: 16)

            Text(usageText)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SonnyTheme.surfaceRaised.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var usageText: String {
        guard summary.requestCount > 0 else {
            return "Local usage: no AI requests for this task."
        }

        var parts: [String] = [
            "Local usage: \(summary.requestCount) AI request\(summary.requestCount == 1 ? "" : "s")"
        ]

        if summary.reportedTotalTokens > 0 {
            parts.append("\(summary.reportedTotalTokens.formatted()) reported token\(summary.reportedTotalTokens == 1 ? "" : "s")")
        }

        if summary.estimatedTotalTokens > 0 {
            parts.append("about \(summary.estimatedTotalTokens.formatted()) estimated token\(summary.estimatedTotalTokens == 1 ? "" : "s")")
        }

        if summary.audioDurationSeconds > 0 {
            parts.append("\(formattedAudioDuration) audio")
        }

        return parts.joined(separator: ", ") + "."
    }

    private var formattedAudioDuration: String {
        let value = summary.audioDurationSeconds
        if value >= 10 {
            return "\(Int(value.rounded()))s"
        }
        return String(format: "%.1fs", value)
    }
}

private struct BusyPanel: View {
    @ObservedObject var logStore: AgentLogStore

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(latestMessage)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SonnyTheme.info.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var latestMessage: String {
        guard let event = logStore.events.last else {
            return "Working..."
        }
        return "\(event.phase.rawValue): \(event.message)"
    }
}

private struct VoiceStatusPanel: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        HStack(spacing: 10) {
            if viewModel.isTranscribingVoice {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(SonnyTheme.danger)
            }
            Text(message)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SonnyTheme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var message: String {
        if viewModel.isTranscribingVoice {
            return "Transcribing voice command..."
        }
        if viewModel.isPreparingVoiceRecording {
            return "Getting microphone ready..."
        }
        return "Recording voice command..."
    }
}

private struct SummaryPanel: View {
    let summary: String
    let suggestions: [RunSuggestion]
    let copy: () -> Void
    let runSuggestion: (RunSuggestion) -> Void

    var body: some View {
        Panel(title: "Summary", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: copy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SonnyButtonStyle(tone: .secondary))

                    ForEach(suggestions) { suggestion in
                        Button {
                            runSuggestion(suggestion)
                        } label: {
                            Label(suggestion.title, systemImage: icon(for: suggestion))
                        }
                        .buttonStyle(SonnyButtonStyle(tone: .secondary))
                    }
                }
            }
        }
    }

    private func icon(for suggestion: RunSuggestion) -> String {
        switch suggestion.kind {
        case .revealInFinder:
            return "folder"
        case .openFile:
            return "doc.text"
        }
    }
}

private struct ClarificationPanel: View {
    @ObservedObject var viewModel: AgentViewModel
    let question: String

    var body: some View {
        Panel(title: "Clarify", systemImage: "questionmark.bubble") {
            VStack(alignment: .leading, spacing: 8) {
                Text(question)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Answer", text: $viewModel.clarificationAnswer)
                        .textFieldStyle(.plain)
                        .font(SonnyType.body)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(SonnyTheme.input)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(SonnyTheme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit {
                            viewModel.submitClarification()
                        }
                    Button {
                        viewModel.submitClarification()
                    } label: {
                        Label("Continue", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(SonnyButtonStyle(tone: .primary))
                    .disabled(viewModel.clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(SonnyTheme.danger)
            Text(message)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SonnyTheme.danger.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: title, systemImage: systemImage)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 8)
    }
}

private struct PanelHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: systemImage)
                .font(SonnyType.panelIcon)
                .foregroundStyle(SonnyTheme.accent)
                .frame(width: 18, alignment: .center)
            Text(title)
                .font(SonnyType.panelTitle)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
        }
    }
}

enum SonnyType {
    static let brand = inter(42, weight: .semibold)
    static let hero = inter(28, weight: .semibold)
    static let panelTitle = inter(23, weight: .semibold)
    static let tagline = inter(12)
    static let eyebrow = inter(11, weight: .medium)
    static let command = inter(15)
    static let body = inter(13)
    static let bodyEmphasis = inter(13, weight: .medium)
    static let itemTitle = inter(12, weight: .medium)
    static let caption = inter(12)
    static let micro = inter(11)
    static let microEmphasis = inter(11, weight: .medium)
    static let avatar = inter(14, weight: .medium)
    static let code = inter(11)
    static let panelIcon = Font.system(size: 14)

    static func icon(_ size: CGFloat) -> Font {
        .system(size: size)
    }

    private static func inter(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Inter", size: size).weight(weight)
    }
}

enum SonnyTheme {
    static let ink = Color(red: 9 / 255, green: 9 / 255, blue: 9 / 255)
    static let collectionSurface = Color(red: 15 / 255, green: 16 / 255, blue: 17 / 255)
    static let surfaceRaised = Color(red: 22 / 255, green: 23 / 255, blue: 26 / 255)
    static let border = Color(red: 37 / 255, green: 38 / 255, blue: 43 / 255)
    static let cardBorder = Color(red: 26 / 255, green: 27 / 255, blue: 32 / 255)
    static let text = Color(red: 1, green: 1, blue: 1)
    static let muted = Color(red: 149 / 255, green: 150 / 255, blue: 153 / 255)
    static let accent = Color(red: 92 / 255, green: 132 / 255, blue: 254 / 255)

    // Compatibility aliases keep established surfaces on the same rebranded tokens.
    static let cream = text
    static let paper = text.opacity(0.92)
    static let bronze = accent
    static let stone = muted

    static let glassShade = ink.opacity(0.88)
    static let panelTint = collectionSurface.opacity(0.88)
    static let input = collectionSurface
    static let warning = Color(red: 242 / 255, green: 190 / 255, blue: 0 / 255)
    static let danger = Color(red: 0.973, green: 0.169, blue: 0.376)
    static let info = text.opacity(0.92)
}

enum SonnyRadius {
    static let container: CGFloat = 4
    static let themeSwatch: CGFloat = 5
    static let routineIcon: CGFloat = 6
    static let panelCard: CGFloat = 6
    static let workspaceCard: CGFloat = 8
    static let sidebarIcon: CGFloat = 10
    static let window: CGFloat = 16
    static let pill: CGFloat = 20
    static let tagPill: CGFloat = 48
}

private struct SonnyPointerCursorsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var sonnyPointerCursorsEnabled: Bool {
        get { self[SonnyPointerCursorsEnabledKey.self] }
        set { self[SonnyPointerCursorsEnabledKey.self] = newValue }
    }
}

private struct SonnyPointerCursorModifier: ViewModifier {
    @Environment(\.sonnyPointerCursorsEnabled) private var isEnabled
    @Environment(\.isEnabled) private var isControlEnabled
    @State private var didPushCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                if isEnabled, isControlEnabled, isHovering, !didPushCursor {
                    NSCursor.pointingHand.push()
                    didPushCursor = true
                } else if didPushCursor, (!isHovering || !isEnabled || !isControlEnabled) {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .onChange(of: isEnabled) { _, newValue in
                if !newValue, didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .onChange(of: isControlEnabled) { _, newValue in
                if !newValue, didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .onDisappear {
                if didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
    }
}

extension View {
    func sonnyPointerCursor() -> some View {
        modifier(SonnyPointerCursorModifier())
    }

    func glassPanel(cornerRadius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(SonnyTheme.panelTint)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct SonnyButtonStyle: ButtonStyle {
    let tone: Tone
    var width: CGFloat? = nil

    enum Tone {
        case primary
        case secondary
        case danger
    }

    init(tone: Tone, width: CGFloat? = nil) {
        self.tone = tone
        self.width = width
    }

    func makeBody(configuration: Configuration) -> some View {
        if let width {
            label(configuration)
                .frame(width: width, height: 34)
                .background(background.opacity(configuration.isPressed ? 0.72 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .sonnyPointerCursor()
        } else {
            label(configuration)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background.opacity(configuration.isPressed ? 0.72 : 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .sonnyPointerCursor()
        }
    }

    private func label(_ configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.caption)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var foreground: Color {
        switch tone {
        case .primary:
            return SonnyTheme.ink
        case .secondary:
            return SonnyTheme.text
        case .danger:
            return SonnyTheme.text
        }
    }

    private var background: Color {
        switch tone {
        case .primary:
            return SonnyTheme.accent
        case .secondary:
            return SonnyTheme.surfaceRaised
        case .danger:
            return SonnyTheme.danger.opacity(0.58)
        }
    }

    private var border: Color {
        switch tone {
        case .primary:
            return SonnyTheme.accent.opacity(0.88)
        case .secondary:
            return SonnyTheme.border
        case .danger:
            return SonnyTheme.danger.opacity(0.7)
        }
    }
}

private struct SonnyIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.icon(14))
            .foregroundStyle(SonnyTheme.muted)
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? SonnyTheme.surfaceRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .sonnyPointerCursor()
    }
}

private struct SonnyMiniButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.micro)
            .foregroundStyle(SonnyTheme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(SonnyTheme.surfaceRaised.opacity(configuration.isPressed ? 0.55 : 0.86))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .sonnyPointerCursor()
    }
}
