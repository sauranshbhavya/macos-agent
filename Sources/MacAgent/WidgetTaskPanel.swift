import MacAgentCore
import SwiftUI

/// The panel above the composer for one task: what it's doing, what it needs from the person, or
/// how it ended. Every button answers this task by its own id.
struct WidgetTaskPanel: View {
    @ObservedObject var model: SonnyAppModel
    let task: TaskSnapshot
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(18)
        .frame(width: WidgetTheme.panelWidth, alignment: .leading)
        .widgetGlassPanel()
    }

    private var header: some View {
        Text(task.goal)
            .font(WidgetType.captionMedium)
            .foregroundStyle(WidgetTheme.textMuted)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch task.phase {
        case .queued:
            working("Waiting for another task to finish.")
        case .connecting:
            working("Connecting to Sonny's server…")
        case .running, .observing, .acting, .reconciling:
            working(task.progress ?? "Working…")
        case .awaitingApproval(let commit):
            approval(commit)
        case .awaitingAnswer(let ask):
            question(ask)
        case .paused(.outcomeUnknown(_, _, let title)):
            unknownOutcome(title)
        case .completed(let summary):
            ended(summary, icon: "checkmark.circle.fill", tint: WidgetTheme.allowAction)
        case .failed(let failure):
            ended(failure.message, icon: "exclamationmark.triangle.fill", tint: WidgetTheme.errorGlyph)
        case .cancelled:
            ended("Stopped.", icon: "stop.circle", tint: WidgetTheme.textMuted)
        }
    }

    // MARK: States

    private func working(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WidgetSpinner()
                Text(line)
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetTheme.textFull)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Stop") { model.cancel(task.id) }
                    .buttonStyle(WidgetPanelButtonStyle(tint: nil))
                    .keyboardShortcut(.cancelAction)
            }
            steps
        }
    }

    @ViewBuilder
    private var steps: some View {
        if !task.actions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(task.actions.suffix(4), id: \.actionID) { action in
                    HStack(spacing: 6) {
                        Image(systemName: Self.icon(for: action.status))
                            .font(WidgetType.iconSmall)
                            .foregroundStyle(action.status == .done ? WidgetTheme.allowAction : WidgetTheme.textMuted)
                            .frame(width: 12)
                        Text(action.title)
                            .font(WidgetType.body)
                            .foregroundStyle(WidgetTheme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func approval(_ commit: PreparedCommit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(commit.preview.title)
                .font(WidgetType.iconLarge)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)
            if !commit.preview.details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(commit.preview.details.prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(WidgetType.body)
                            .foregroundStyle(WidgetTheme.textStrong)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WidgetTheme.neutralButtonFill, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(Self.effectLine(commit.effect))
                .font(WidgetType.captionSmall)
                .foregroundStyle(WidgetTheme.attention)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Don't") { model.decide(commit, approved: false) }
                    .buttonStyle(WidgetPanelButtonStyle(tint: nil))
                    .keyboardShortcut(.cancelAction)
                Button("Do it") { model.decide(commit, approved: true) }
                    .buttonStyle(WidgetPanelButtonStyle(tint: WidgetTheme.allowAction))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func question(_ ask: AskBody) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.question)
                .font(WidgetType.iconLarge)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)
            if let choices = ask.choices, !choices.isEmpty {
                WrappingChoices(choices: choices) { model.answer(task.id, with: $0) }
            }
            HStack(spacing: 8) {
                TextField("Your answer", text: $answer)
                    .textFieldStyle(.plain)
                    .font(WidgetType.pillQuery)
                    .foregroundStyle(WidgetTheme.textFull)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(WidgetTheme.neutralButtonFill, in: Capsule())
                    .onSubmit(sendAnswer)
                Button("Answer", action: sendAnswer)
                    .buttonStyle(WidgetPanelButtonStyle(tint: WidgetTheme.primaryAction))
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop") { model.cancel(task.id) }
                    .buttonStyle(WidgetPanelButtonStyle(tint: nil))
            }
        }
    }

    private func sendAnswer() {
        model.answer(task.id, with: answer)
        answer = ""
    }

    private func unknownOutcome(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sonny may already have done this: \(title)")
                .font(WidgetType.iconLarge)
                .foregroundStyle(WidgetTheme.textFull)
                .fixedSize(horizontal: false, vertical: true)
            Text("Check whether it happened, then continue or stop.")
                .font(WidgetType.body)
                .foregroundStyle(WidgetTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Stop") { model.resolvePause(task.id, .stop) }
                    .buttonStyle(WidgetPanelButtonStyle(tint: nil))
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { model.resolvePause(task.id, .continueTask) }
                    .buttonStyle(WidgetPanelButtonStyle(tint: WidgetTheme.primaryAction))
            }
        }
    }

    private func ended(_ text: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(WidgetType.iconLarge)
                    .foregroundStyle(tint)
                Text(text)
                    .font(WidgetType.caption)
                    .foregroundStyle(WidgetTheme.textFull)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            steps
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // A private task's transcript is gone from the gateway, so there is nothing to follow.
                if !task.isPrivate, task.phase != .cancelled {
                    Button("Follow up") { model.followUp(on: task.id, goal: task.goal) }
                        .buttonStyle(WidgetPanelButtonStyle(tint: nil))
                }
                Button("Done", action: model.dismissFinishedTask)
                    .buttonStyle(WidgetPanelButtonStyle(tint: WidgetTheme.primaryAction))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Words

    static func icon(for status: OutcomeStatus?) -> String {
        switch status {
        case .done?: "checkmark"
        case .failed?, .stale?: "xmark"
        case .refused?, .declined?: "hand.raised"
        case .skipped?: "arrow.turn.down.right"
        case .outcomeUnknown?: "questionmark"
        case nil: "circle.dotted"
        }
    }

    static func effectLine(_ effect: Effect) -> String {
        switch effect {
        case .observe, .navigate: "Looks around"
        case .editLocal: "Changes your files or settings"
        case .create: "Makes something new"
        case .destructive: "Deletes or overwrites"
        case .external: "Sends to someone else"
        case .financial: "Spends money"
        case .credential: "Needs your password"
        case .unknown: "Effect unclear"
        }
    }
}

/// A question's choices as buttons, wrapping onto more rows as needed.
private struct WrappingChoices: View {
    let choices: [String]
    let pick: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(alignment: .leading, spacing: 6) { buttons }
        }
    }

    private var buttons: some View {
        ForEach(Array(choices.prefix(6).enumerated()), id: \.offset) { _, choice in
            Button(choice) { pick(choice) }
                .buttonStyle(WidgetPanelButtonStyle(tint: nil))
        }
    }
}

/// The widget's panel buttons: a tinted capsule for the action the panel is for, neutral for the
/// rest.
struct WidgetPanelButtonStyle: ButtonStyle {
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WidgetType.captionMedium)
            .foregroundStyle(WidgetTheme.textFull)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .widgetCapsuleBackground(tint: tint)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}
