import MacAgentCore
import SwiftUI

enum CommandCenterDestination: String, CaseIterable, Identifiable {
    case tasks
    case insights
    case routines
    case workspaces
    case settings

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }

    var systemImage: String {
        switch self {
        case .tasks:
            return "checklist"
        case .insights:
            return "chart.bar.xaxis"
        case .routines:
            return "repeat"
        case .workspaces:
            return "rectangle.3.group"
        case .settings:
            return "gearshape"
        }
    }
}

struct CommandCenterView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var selection: CommandCenterDestination

    init(
        viewModel: AgentViewModel,
        initialSelection: CommandCenterDestination = .tasks
    ) {
        self.viewModel = viewModel
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(SonnyTheme.border)
                .frame(width: 1)

            destinationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(SonnyTheme.ink)
        .foregroundStyle(SonnyTheme.text)
        .tint(SonnyTheme.accent)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshSavedItems()
            viewModel.refreshClipboardHistoryNotice()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(SonnyTheme.accent.opacity(0.16))
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(SonnyTheme.accent.opacity(0.42), lineWidth: 1)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SonnyTheme.accent)
                }
                .frame(width: 36, height: 36)

                Text("Sonny")
                    .font(SonnyType.panelTitle)
                    .foregroundStyle(SonnyTheme.text)
            }

            VStack(spacing: 5) {
                ForEach(CommandCenterDestination.allCases) { destination in
                    sidebarButton(destination)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 226)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }

    private func sidebarButton(_ destination: CommandCenterDestination) -> some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(destination.title)
                    .font(SonnyType.body)
                Spacer(minLength: 8)
                if destination == .tasks, viewModel.activeTaskCount > 0 {
                    Text("\(viewModel.activeTaskCount)")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.ink)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(SonnyTheme.accent)
                        .clipShape(Capsule())
                        .accessibilityLabel("One active task")
                }
            }
            .foregroundStyle(isSelected(destination) ? SonnyTheme.text : SonnyTheme.muted)
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected(destination) ? SonnyTheme.surfaceRaised : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected(destination) ? SonnyTheme.border : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.title)
    }

    private func isSelected(_ destination: CommandCenterDestination) -> Bool {
        selection == destination
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch selection {
        case .tasks:
            TasksFoundationView(viewModel: viewModel)
        case .insights:
            CommandCenterPlaceholderView(
                title: "Insights",
                systemImage: CommandCenterDestination.insights.systemImage,
                message: "Current-task usage will be wired here in Checkpoint 4."
            )
        case .routines:
            RoutinesView(viewModel: viewModel)
        case .workspaces:
            WorkspacesView(viewModel: viewModel)
        case .settings:
            SettingsFoundationView()
        }
    }
}

private struct TasksFoundationView: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                CommandCenterPageHeader(
                    title: "Tasks",
                    subtitle: "Your current Sonny task, live across both surfaces."
                )

                if viewModel.hasTaskActivity {
                    AgentTaskActivityView(viewModel: viewModel, showsStartupWhenEmpty: false)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No active task", systemImage: "checkmark.circle")
                            .font(SonnyType.bodyEmphasis)
                            .foregroundStyle(SonnyTheme.text)
                        Text("Start a command below or from the menu-bar cockpit. The same task will appear here immediately.")
                            .font(SonnyType.body)
                            .foregroundStyle(SonnyTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Persistent task history is planned for a future update.")
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.muted)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SonnyTheme.surfaceRaised.opacity(0.46))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(SonnyTheme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CommandCenterComposerFooter(viewModel: viewModel)
        }
        .background(SonnyTheme.ink)
    }
}

struct RoutineRowPresentation: Equatable {
    let name: String
    let stepCount: Int
    let stepCountText: String
    let detailText: String

    init(routine: StoredRoutine) {
        name = routine.name
        stepCount = routine.steps.count
        stepCountText = "\(routine.steps.count)"

        let visibleLabels = routine.steps.prefix(2).map(AgentActivityPresentation.operationTitle)
        let remainingCount = routine.steps.count - visibleLabels.count
        let visibleText = visibleLabels.joined(separator: " · ")
        if remainingCount > 0 {
            detailText = "\(visibleText) · +\(remainingCount) more"
        } else if visibleText.isEmpty {
            detailText = "No saved steps"
        } else {
            detailText = visibleText
        }
    }
}

struct WorkspaceCardPresentation: Equatable {
    let name: String
    let initial: String
    let savedItemCount: Int
    let savedItemCountText: String
    let appsText: String?
    let urlsText: String?

    init(workspace: StoredWorkspace) {
        name = workspace.name
        initial = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .first.map { String($0).uppercased() } ?? "W"
        savedItemCount = workspace.apps.count + workspace.urls.count
        savedItemCountText = "\(savedItemCount) saved item\(savedItemCount == 1 ? "" : "s")"
        appsText = workspace.apps.isEmpty ? nil : workspace.apps.joined(separator: ", ")
        urlsText = workspace.urls.isEmpty ? nil : workspace.urls.map(Self.shortURL).joined(separator: ", ")
    }

    private static func shortURL(_ rawValue: String) -> String {
        guard let url = URL(string: rawValue), let host = url.host else {
            return rawValue
        }
        return host.replacingOccurrences(of: "www.", with: "", options: .anchored)
    }
}

private struct RoutinesView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var composerFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                CommandCenterPageHeader(title: "Routines")

                VStack(spacing: 0) {
                    CollectionHeader(
                        title: "All routines",
                        actionTitle: "New routine",
                        action: beginNewRoutine
                    )

                    Rectangle()
                        .fill(SonnyTheme.border)
                        .frame(height: 1)

                    if viewModel.savedRoutines.isEmpty {
                        CollectionEmptyState(
                            systemImage: "repeat",
                            title: "No routines yet",
                            message: "Ask Sonny to save a repeatable sequence, then it will appear here."
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(viewModel.savedRoutines.enumerated()), id: \.element.name) { index, routine in
                                    RoutineRow(
                                        presentation: RoutineRowPresentation(routine: routine),
                                        isLast: index == viewModel.savedRoutines.count - 1,
                                        isRunning: viewModel.isRunning || viewModel.isAwaitingApproval,
                                        run: { viewModel.runRoutineWidget(routine) }
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(CommandCenterPalette.collectionSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(SonnyTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CommandCenterComposerFooter(
                viewModel: viewModel,
                focusRequest: composerFocusRequest
            )
        }
        .background(SonnyTheme.ink)
    }

    private func beginNewRoutine() {
        viewModel.command = "Create a routine called "
        composerFocusRequest += 1
    }
}

private struct RoutineRow: View {
    let presentation: RoutineRowPresentation
    let isLast: Bool
    let isRunning: Bool
    let run: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(CommandCenterPalette.routineIconBackground)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CommandCenterPalette.routineIconForeground)
                        .frame(width: 10, height: 10)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.name)
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                        .lineLimit(1)
                    Text(presentation.detailText)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 14)

                HStack(spacing: 6) {
                    Circle()
                        .fill(SonnyTheme.warning)
                        .frame(width: 8, height: 8)
                    Text(presentation.stepCountText)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.warning)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(presentation.stepCount) saved steps")

                Button(action: run) {
                    Text("Run")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel("Run \(presentation.name)")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if !isLast {
                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(height: 1)
            }
        }
        .background(CommandCenterPalette.cardSurface)
    }
}

private struct WorkspacesView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var composerFocusRequest = 0

    private let columns = [
        GridItem(.adaptive(minimum: 356, maximum: 356), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                CommandCenterPageHeader(title: "Workspaces")

                VStack(spacing: 0) {
                    CollectionHeader(
                        title: "All workspaces",
                        actionTitle: "Create workspace",
                        action: beginNewWorkspace
                    )

                    Rectangle()
                        .fill(SonnyTheme.border)
                        .frame(height: 1)

                    if viewModel.savedWorkspaces.isEmpty {
                        CollectionEmptyState(
                            systemImage: "rectangle.3.group",
                            title: "No workspaces yet",
                            message: "Ask Sonny to group apps and safe URLs for one-click opening."
                        )
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(viewModel.savedWorkspaces, id: \.name) { workspace in
                                    WorkspaceCard(
                                        presentation: WorkspaceCardPresentation(workspace: workspace),
                                        accent: SonnyTheme.accent,
                                        isRunning: viewModel.isRunning || viewModel.isAwaitingApproval,
                                        open: { viewModel.openWorkspaceWidget(workspace) }
                                    )
                                }
                            }
                            .padding(18)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(CommandCenterPalette.collectionSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(SonnyTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CommandCenterComposerFooter(
                viewModel: viewModel,
                focusRequest: composerFocusRequest
            )
        }
        .background(SonnyTheme.ink)
    }

    private func beginNewWorkspace() {
        viewModel.command = "Create a workspace called "
        composerFocusRequest += 1
    }
}

private struct WorkspaceCard: View {
    let presentation: WorkspaceCardPresentation
    let accent: Color
    let isRunning: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(presentation.initial)
                .font(SonnyType.avatar)
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .background(accent.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(presentation.name)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .padding(.top, 14)

            Text(presentation.savedItemCountText)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                if let appsText = presentation.appsText {
                    Label(appsText, systemImage: "app.dashed")
                }
                if let urlsText = presentation.urlsText {
                    Label(urlsText, systemImage: "link")
                }
            }
            .font(SonnyType.micro)
            .foregroundStyle(SonnyTheme.muted)
            .lineLimit(1)
            .padding(.top, 12)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button(action: open) {
                    Text("Open")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel("Open \(presentation.name)")
            }
        }
        .padding(18)
        .frame(maxWidth: 356, minHeight: 190, maxHeight: 190, alignment: .topLeading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CollectionHeader: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
            Spacer()
            Button(action: action) {
                Label(actionTitle, systemImage: "plus")
            }
            .buttonStyle(CommandCenterHeaderActionStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
    }
}

private struct CollectionEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(SonnyTheme.muted)
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
            Text(message)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(24)
    }
}

private struct CommandCenterComposerFooter: View {
    @ObservedObject var viewModel: AgentViewModel
    var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SonnyTheme.border)
                .frame(height: 1)

            AgentCommandComposerView(
                viewModel: viewModel,
                autoFocus: false,
                focusRequest: focusRequest
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .background(CommandCenterPalette.composerSurface)
    }
}

private struct CommandCenterHeaderActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.microEmphasis)
            .foregroundStyle(SonnyTheme.text.opacity(configuration.isPressed ? 0.7 : 0.92))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CommandCenterPalette.buttonSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.46)
    }
}

private struct CommandCenterRowActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.microEmphasis)
            .foregroundStyle(SonnyTheme.text.opacity(configuration.isPressed ? 0.68 : 0.92))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(CommandCenterPalette.buttonSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.46)
    }
}

private enum CommandCenterPalette {
    static let collectionSurface = SonnyTheme.collectionSurface
    static let cardSurface = SonnyTheme.surfaceRaised
    static let buttonSurface = SonnyTheme.surfaceRaised
    static let composerSurface = SonnyTheme.collectionSurface
    static let routineIconBackground = SonnyTheme.accent.opacity(0.18)
    static let routineIconForeground = SonnyTheme.accent
}

private struct CommandCenterPlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CommandCenterPageHeader(title: title, subtitle: "The shared product shell is ready for this section.")

            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(SonnyTheme.accent)
                Text(message)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
            }
            .padding(18)
            .frame(maxWidth: 520, alignment: .leading)
            .background(SonnyTheme.surfaceRaised.opacity(0.42))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }
}

private struct CommandCenterPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SonnyType.hero)
                .foregroundStyle(SonnyTheme.text)
            if let subtitle {
                Text(subtitle)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
            }
        }
    }
}

private struct SettingsFoundationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CommandCenterPageHeader(
                title: "Settings",
                subtitle: "Preferences, privacy, and permissions will live here."
            )

            VStack(spacing: 0) {
                deferredRow(
                    title: "Preferences",
                    detail: "Clipboard history and command preferences",
                    systemImage: "switch.2"
                )
                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(height: 1)
                deferredRow(
                    title: "Privacy & Permissions",
                    detail: "Permission readiness and local-data controls",
                    systemImage: "hand.raised"
                )
            }
            .frame(maxWidth: 620)
            .background(SonnyTheme.surfaceRaised.opacity(0.34))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("Real preferences and privacy controls will be wired in Checkpoint 3.")
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }

    private func deferredRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text.opacity(0.74))
                Text(detail)
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
            }
            Spacer()
            Text("Checkpoint 3")
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(
                    Capsule()
                        .stroke(SonnyTheme.border, lineWidth: 1)
                )
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Available in a later checkpoint")
    }
}
