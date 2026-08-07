import AppKit
import Foundation
import MacAgentCore
import SwiftUI

enum CommandCenterDestination: String, CaseIterable, Identifiable {
    case tasks
    case insights
    case routines
    case workspaces

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
        }
    }
}

struct CommandCenterView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var selection: CommandCenterDestination
    // Settings is no longer a sidebar destination (2026-07-18 direction, following the Claude
    // desktop app's pattern: a bottom-left account row opens a menu, whose one real item today
    // opens Settings as its own dialog) — this drives that dialog's presentation instead of
    // `selection`.
    @State private var isSettingsPresented = false
    // Profile is a real, separate dialog from Settings (2026-07-18) — its actual content is
    // deliberately undecided ("I will need to plan what it does later"), so it ships as an honest
    // placeholder rather than guessed-at content.
    @State private var isProfilePresented = false
    // Drives the bottom account row's own popover (see `profileRow`'s doc comment for why this
    // is a custom `Button`/`.popover()` pair instead of a native `Menu`).
    @State private var isAccountMenuPresented = false
    // Drives "Learn more"'s side flyout within the account menu popover.
    @State private var isLearnMoreExpanded = false
    // Debounces the open/close of that flyout — see `handleLearnMoreHoverChange`.
    @State private var learnMoreHoverTask: Task<Void, Never>?

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
        .environment(\.sonnyPointerCursorsEnabled, viewModel.usePointerCursors)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshSavedItems()
            viewModel.refreshTaskHistory()
            viewModel.refreshClipboardHistoryNotice()
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsDialogView(viewModel: viewModel, isPresented: $isSettingsPresented)
        }
        .sheet(isPresented: $isProfilePresented) {
            ProfileDialogView(isPresented: $isProfilePresented)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.container)
                        .fill(SonnyTheme.accent.opacity(0.16))
                    RoundedRectangle(cornerRadius: SonnyRadius.container)
                        .stroke(SonnyTheme.accent.opacity(0.42), lineWidth: 1)
                    Image(systemName: "wand.and.stars")
                        .font(SonnyType.icon(10, weight: .medium))
                        .foregroundStyle(SonnyTheme.accent)
                }
                .frame(width: 20, height: 20)
                .sonnyLogoGlow()

                Text("Sonny")
                    .font(SonnyType.sidebarWordmark)
                    .foregroundStyle(SonnyTheme.text)
            }

            VStack(spacing: 2) {
                ForEach(CommandCenterDestination.allCases) { destination in
                    sidebarButton(destination)
                }
            }

            Spacer()

            profileRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(width: 275)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
    }

    /// Bottom-left account row (Claude desktop app's pattern, 2026-07-18 direction) — opens a menu
    /// whose only real item today is "Settings"; everything else Claude's own menu shows (Language,
    /// Get help, Upgrade plan, Log out, ...) has no backend behind it in Sonny yet. No real accounts
    /// system exists either — this shows the same macOS account name as the Tasks-page greeting,
    /// not a real signed-in identity.
    ///
    /// Built with a plain `Button` + `.popover()`, not `Menu` — a native macOS `Menu` whose custom
    /// label's first element is a composite icon-like view (a `ZStack` combining a filled shape and
    /// overlaid text, as the avatar below is) silently dropped every sibling after it in this
    /// codebase's testing (2026-07-18: confirmed twice — a `frame(maxWidth:)` fix did not resolve
    /// it). `SettingsThemeDropdown` still uses `Menu` safely because its label is plain `Text`, no
    /// composite icon. `Button`'s label always renders exactly as authored, with no such AppKit
    /// bridging ambiguity, so it sidesteps the bug entirely rather than working around it.
    private var profileRow: some View {
        Button {
            isAccountMenuPresented = true
        } label: {
            HStack(spacing: 10) {
                profileAvatar

                Text(profileName)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.sidebarNavText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(SonnyType.icon(9, weight: .semibold))
                    .foregroundStyle(SonnyTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
        .accessibilityLabel("Account: \(profileName)")
        .popover(isPresented: $isAccountMenuPresented, arrowEdge: .top) {
            accountMenuContent
        }
    }

    private var profileAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SonnyRadius.container)
                .fill(SonnyTheme.accent.opacity(0.18))
            Text(WorkspaceAvatarInitial.from(name: profileName))
                .font(SonnyType.microEmphasis)
                .foregroundStyle(SonnyTheme.accent)
        }
        .frame(width: 24, height: 24)
    }

    private var accountMenuContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            accountMenuRow(title: "Profile", systemImage: "person.crop.circle") {
                isAccountMenuPresented = false
                isProfilePresented = true
            }

            accountMenuRow(title: "Settings", systemImage: "gearshape") {
                isAccountMenuPresented = false
                isSettingsPresented = true
            }

            Rectangle()
                .fill(SonnyTheme.border)
                .frame(height: 1)
                .padding(.vertical, 4)

            // Disabled, not a no-op — signals "this exists, isn't wired up yet" the same way the
            // Settings theme dropdown's Light/System options already do, rather than a silent dead
            // click. Real destination (docs/sonny-ui-backend-gaps.md): Sonny's own website help
            // page, once one exists.
            accountMenuRow(title: "Get help", systemImage: "questionmark.circle", isEnabled: false) {}

            // "Learn more" itself is enabled — hovering it opens the flyout, matching native
            // NSMenu submenu behavior and the Claude reference, but only after a short dwell delay
            // (2026-07-18: a bare cursor flick across the row was opening it instantly, which read
            // as accidental/twitchy — Claude's own menu waits for a deliberate pause first, so this
            // does too). A click still works too as a harmless, accessibility-friendly fallback.
            // The 4 sub-items inside stay disabled since none has a real URL yet.
            accountMenuRow(title: "Learn more", systemImage: "info.circle", showsDisclosure: true) {
                isLearnMoreExpanded = true
            }
            .onHover(perform: handleLearnMoreHoverChange)
            .popover(isPresented: $isLearnMoreExpanded, arrowEdge: .trailing) {
                learnMoreFlyoutContent
                    .onHover(perform: handleLearnMoreHoverChange)
            }
        }
        .padding(6)
        .frame(width: 210)
        .background(SonnyTheme.surfaceRaised)
    }

    /// Shared by the "Learn more" trigger row and its flyout content — opens after a short
    /// deliberate-pause delay (not instantly, so a mouse just passing over the row doesn't pop it
    /// open) and closes after a short grace delay once hover leaves both, canceled if hover
    /// resumes on either one before the grace period elapses (so crossing the small gap between
    /// the row and the flyout doesn't slam it shut mid-move).
    private func handleLearnMoreHoverChange(isHovering: Bool) {
        learnMoreHoverTask?.cancel()
        if isHovering {
            guard !isLearnMoreExpanded else { return }
            learnMoreHoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled {
                    isLearnMoreExpanded = true
                }
            }
        } else {
            learnMoreHoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                if !Task.isCancelled {
                    isLearnMoreExpanded = false
                }
            }
        }
    }

    private var learnMoreFlyoutContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            // All 4 named per direct instruction ("docs, usage policy, privacy policy, etc.") —
            // each disabled since none has a real URL yet; see docs/sonny-ui-backend-gaps.md.
            accountMenuRow(title: "Documentation", systemImage: "doc.text", isEnabled: false) {}
            accountMenuRow(title: "Usage policy", systemImage: "doc.plaintext", isEnabled: false) {}
            accountMenuRow(title: "Privacy policy", systemImage: "hand.raised", isEnabled: false) {}
            accountMenuRow(title: "Terms of service", systemImage: "doc.badge.gearshape", isEnabled: false) {}
        }
        .padding(6)
        .frame(width: 200)
        .background(SonnyTheme.surfaceRaised)
    }

    private func accountMenuRow(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        showsDisclosure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(SonnyType.icon(12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(SonnyType.body)
                Spacer(minLength: 8)
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(SonnyType.icon(9, weight: .semibold))
                }
            }
            .foregroundStyle(isEnabled ? SonnyTheme.sidebarNavText : SonnyTheme.muted)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
    }

    /// Same source/toggle as the Tasks-page greeting (`TasksFoundationView.greeting`) — one
    /// name-formatting rule for the whole app (2026-07-18: reverted an earlier "always full name"
    /// version per direct instruction to match the greeting exactly instead).
    private var profileName: String {
        let fullName = NSFullUserName()
        guard !fullName.isEmpty else { return "Account" }
        return viewModel.displayFullNames
            ? fullName
            : (fullName.components(separatedBy: .whitespaces).first ?? fullName)
    }

    private func sidebarButton(_ destination: CommandCenterDestination) -> some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(SonnyType.icon(14, weight: .medium))
                    .foregroundStyle(SonnyTheme.muted)
                    .frame(width: 18)
                Text(destination.title)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.sidebarNavText)
                Spacer(minLength: 8)
                if destination == .tasks, viewModel.activeTaskCount > 0 {
                    // Shape/fill match the wireframe's rounded-rect badge (`rx=4`, `#151619`) —
                    // its "22" count itself doesn't map to anything Sonny has (likely a Linear
                    // inbox-unread placeholder), so the conditional active-task display stays.
                    Text("\(viewModel.activeTaskCount)")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.text)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(SonnyTheme.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
                        .accessibilityLabel("One active task")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .fill(isSelected(destination) ? SonnyTheme.surfaceRaised : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(isSelected(destination) ? SonnyTheme.border : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight()
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
            InsightsView(viewModel: viewModel)
        case .routines:
            RoutinesView(viewModel: viewModel)
        case .workspaces:
            WorkspacesView(viewModel: viewModel)
        }
    }
}

private struct TasksFoundationView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var selectedLogEntry: TaskLogEntry?
    /// Collapse state is seeded once, at view-identity creation, from the persisted preference —
    /// not reloaded in `onAppear`, which fires again every time the user switches back to this
    /// page and would throw away an in-session collapse if the write ever lagged.
    ///
    /// **Four lines of this page's collapse wiring are not covered by any test, and all four fail
    /// silently.** `TaskSectionCollapsePresentation.swift` is fully pinned (twelve mutations, all
    /// red), but this repository has no view-rendering tests and no view-inspection dependency, so
    /// nothing catches a view that stops calling the type correctly. Enumerated so a green suite is
    /// never read as full coverage — each was confirmed green-under-mutation by PR #31's reviewer:
    ///
    /// 1. `State(initialValue: collapseStore.load())` below — seed a fresh
    ///    `TaskSectionCollapseState()` instead and nothing is ever *read back*.
    /// 2. `collapseStore.save(collapseState)` in `toggleSection` — drop it and nothing is ever
    ///    *written*. (1) and (2) each break the "persists across launches" criterion on their own.
    /// 3. `count: section.count` in `TaskHistoryGroupedPanel` — swap it for
    ///    `section.visibleRecords.count` and every collapsed section reads 0, breaking the
    ///    separate "a collapsed header still shows its count" criterion.
    /// 4. `disclosure:` on that same header — pass `nil` and Done/Failed/Canceled lose the chevron
    ///    and stop being clickable at all, removing the feature from three of the four sections.
    ///
    /// What guards them is SONNY-49's manual-test checklist, not the suite: item 2 covers (1) and
    /// (2), item 3 covers (3), item 1 covers (4). Adding a view-inspection dependency would pin
    /// them and is deliberately not done here — that is an architectural decision reserved for the
    /// user, not a ticket-level one.
    @State private var collapseState: TaskSectionCollapseState
    private let collapseStore: TaskSectionCollapseStore

    init(viewModel: AgentViewModel, collapseStore: TaskSectionCollapseStore = TaskSectionCollapseStore()) {
        self.viewModel = viewModel
        self.collapseStore = collapseStore
        _collapseState = State(initialValue: collapseStore.load())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CommandCenterPageHeader(title: greeting)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Wireframe "Frame 6" toolbar row (`9-MainAppHomeScreen.svg`) — the
                    // "Personal" scope pill on its leading edge is a deliberately rejected
                    // persistent-active-workspace affordance (see the task-to-workspace
                    // association decision in the changelog), so only the trailing
                    // filter/search icons are built here.
                    TasksToolbarRow()

                    // Outside the In Progress group on purpose: that group only exists while a
                    // task is active, so nesting the storage notice inside it would hide a
                    // corrupt store whenever nothing happens to be running.
                    CommandCenterStorageNotice(viewModel: viewModel, insets: .tasksPage)

                    // Wireframe has exactly three status groups (In Progress / Done /
                    // Canceled, `9-MainAppHomeScreen.svg`) — per direct feedback (2026-07-18),
                    // the live-running task now renders as this list's own "In Progress"
                    // group instead of a separate block above it, and there's no separate
                    // idle "No active task" placeholder; the group simply isn't there when
                    // nothing is running. Gated narrowly on `isRunning || isAwaitingApproval`
                    // rather than on any broader "has this task left traces" notion — once a
                    // run finishes it belongs in the Done/Canceled history below, not up here.
                    if viewModel.isRunning || viewModel.isAwaitingApproval {
                        InProgressTaskGroup(
                            viewModel: viewModel,
                            isExpanded: collapseState.isExpanded(TaskSectionCollapseState.inProgressSectionID),
                            onToggle: { toggleSection(TaskSectionCollapseState.inProgressSectionID) }
                        )
                    }

                    TaskHistoryGroupedPanel(
                        records: displayedRecords,
                        collapseState: collapseState,
                        onToggleSection: toggleSection,
                        onSelect: { selectedLogEntry = TaskLogEntry(record: $0) }
                    )
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CommandCenterPalette.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))

            // Pinned below the scroll area rather than placed in the list flow like the storage
            // notice above: an approval the user has to act on must not be scrollable out of
            // sight. Self-gates on its own state, so an idle page renders nothing here.
            CommandCenterAttentionPanel(viewModel: viewModel)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
        .onAppear {
            viewModel.refreshTaskHistory()
        }
        .sheet(item: $selectedLogEntry) { entry in
            TaskLogDetailDialog(record: entry.record)
        }
    }

    /// Wireframe shows a time-of-day greeting ("Good Afternoon, User") in this exact slot
    /// (`9-MainAppHomeScreen.svg`) rather than a static page title. `NSFullUserName()` is the
    /// same macOS-account name source `DocumentConverter` already uses elsewhere in this codebase;
    /// `displayFullNames` (Settings) governs full vs. first-name-only, matching that toggle's
    /// existing meaning rather than inventing a second name-formatting rule.
    private var greeting: String {
        TaskGreetingFormatter.greeting(
            hour: Calendar.current.component(.hour, from: Date()),
            fullName: NSFullUserName(),
            displayFullNames: viewModel.displayFullNames
        )
    }

    /// Display-only windowing (inspired by Wispr Flow's ~90-day home-page history) — this page's
    /// own list only shows the last 90 days. Nothing is deleted: `viewModel.taskHistoryRecords`
    /// itself is untouched, so Insights and everything else still sees the complete history.
    private var displayedRecords: [CompletedTaskRecord] {
        TaskHistoryDisplayWindow.withinWindow(viewModel.taskHistoryRecords, now: Date())
    }

    /// The write is unconditional and immediate rather than debounced or deferred to `onDisappear`:
    /// a collapse the user makes and then quits on must survive, and one small array write per
    /// click is not worth a coalescing mechanism. The `save` below is unpinned point (2) of the
    /// four enumerated on `collapseState` above — removing it leaves the suite green and the
    /// preference permanently unwritten.
    private func toggleSection(_ sectionID: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            collapseState.toggle(sectionID)
        }
        collapseStore.save(collapseState)
    }
}

private struct TasksToolbarRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            // Filter icon deliberately dropped (2026-07-18 review) — no filter feature exists or
            // is planned yet. Search stays as a real, named backlog item: see
            // docs/sonny-ui-backend-gaps.md for the task-search feature this button needs wired up.
            Image(systemName: "magnifyingglass")
                .font(SonnyType.icon(12, weight: .medium))
                .foregroundStyle(SonnyTheme.muted)
        }
        .padding(.leading, 30)
        .padding(.trailing, 24)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SonnyTheme.cardBorder).frame(height: 0.5)
        }
    }
}

/// Compact "something is happening" line (2026-07-18 direction) — replaces the rich
/// Plan/Preview/step-log/Approval surface that used to render inline on Tasks/Routines/
/// Workspaces, which was explicitly "not at all" wanted there; "logs + summary + activity should
/// just be a flow as to how that thing worked under the hood," nothing more, and definitely not
/// an approval UI. No approval/permission controls live here either — the real Approve/Deny
/// controls now live in the floating widget (`FloatingWidgetView`, §3.3.3), which observes the
/// same shared `AgentViewModel`, so a pending approval is never actually unreachable, just not
/// visible on this page. If neither the widget nor Command Center is frontmost when an approval
/// or error occurs, `SonnyNotificationService` posts a native macOS notification as the fallback.
private struct CommandCenterRunningIndicator: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(SonnyTheme.accent)

            Text(statusText)
                .font(SonnyType.itemTitle)
                .foregroundStyle(SonnyTheme.sidebarNavText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            if viewModel.canCancel {
                Button("Cancel") {
                    viewModel.cancelCurrentRun()
                }
                .buttonStyle(CommandCenterRowActionStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }

    // `viewModel.command` is not what's shown here on purpose — it's cleared the instant `start()`
    // captures it (so the composer/widget field is ready for the next input), which would make
    // every single running task read as "Untitled task" regardless of what was actually submitted.
    // `runningCommandDisplayText` is the command that's actually driving this run.
    private var statusText: String {
        let display = viewModel.runningCommandDisplayText
        let command = display.isEmpty
            ? "Untitled task"
            : display.sentenceCapitalized.truncatedForRowDisplay()
        return viewModel.isAwaitingApproval ? "Waiting for approval: \(command)" : "Running: \(command)"
    }
}

/// Local-storage health banner (System A). Separate from the task-failure path on purpose: this
/// reports that one of Sonny's own encrypted stores could not be read or written, which is not a
/// statement about whatever task the user last ran. Unlike `CommandCenterRunningIndicator`, this
/// is rendered unconditionally by its pages and self-gates on `localStorageNotice` — a corrupt
/// store must stay visible whether or not a task happens to be running.
private struct CommandCenterStorageNotice: View {
    /// Outer spacing lives here rather than on the call site so a page with no notice gets no
    /// stray gap — the `else { EmptyView() }` below plus zero applied padding keeps this view
    /// genuinely absent from its parent stack's layout when there is nothing to say.
    struct Insets {
        static let none = Insets(horizontal: 0, bottom: 0)
        static let tasksPage = Insets(horizontal: 30, bottom: 12)

        var horizontal: CGFloat
        var bottom: CGFloat
    }

    @ObservedObject var viewModel: AgentViewModel
    var insets: Insets = .none

    var body: some View {
        if let message = viewModel.scheduledRunNotice {
            noticeRow(
                icon: "clock.arrow.circlepath",
                tint: SonnyTheme.accent,
                message: message
            ) {
                viewModel.scheduledRunNotice = nil
            }
        } else if let message = viewModel.localStorageNotice {
            noticeRow(
                icon: "externaldrive.badge.exclamationmark",
                tint: SonnyTheme.warning,
                message: message
            ) {
                viewModel.localStorageNotice = nil
            }
        } else {
            EmptyView()
        }
    }

    /// Both notices share one row treatment. The scheduler's takes precedence when both are set:
    /// it reports something that already happened without the user present, which is more urgent
    /// than an ambient storage problem that will still be true after they dismiss this.
    @ViewBuilder
    private func noticeRow(
        icon: String,
        tint: Color,
        message: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)

            Text(message)
                .font(SonnyType.itemTitle)
                .foregroundStyle(SonnyTheme.sidebarNavText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button("Dismiss", action: dismiss)
                .buttonStyle(CommandCenterRowActionStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(tint.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
        .padding(.horizontal, insets.horizontal)
        .padding(.bottom, insets.bottom)
    }
}

/// Command Center's own permission / clarification / failure surface (System A).
///
/// Until branch 10 these three states rendered *only* in the floating widget, which was fine while
/// every task was started by a user who was looking at it. Scheduled routines break that
/// assumption: a run fires with nobody watching, and the system-notification fallback is
/// unreachable by deliberate decision (the widget is a permanent overlay with no dismiss action),
/// so without a Command-Center-native surface an unattended run that needs approval or fails would
/// be silently stuck. `docs/sonny-ui-backend-roadmap.md` names this a hard prerequisite for
/// background execution, not polish.
///
/// The widget is deliberately **not** changed to compensate: it keeps showing all three states for
/// every task regardless of origin, so both surfaces can show controls for the same task at once.
/// That redundancy is the intended trade — the widget is always visible, Command Center is a window
/// that may be closed, so for an unattended run the widget is the more reliable surface, not the
/// less. See `AgentViewModel.hasVisibleWidgetPanel`.
///
/// Rendered unconditionally by its pages and self-gating on its own state, same as
/// `CommandCenterStorageNotice` — never wrapped in a caller-side condition. Nesting a self-gating
/// strip inside `if isRunning || isAwaitingApproval` was a real shipped bug on the storage notice.
///
/// Deliberately origin-agnostic: it never reads `activeTaskOrigin`, which is what lets a third
/// `TaskOrigin` case for scheduled runs land later without touching this view.
private struct CommandCenterAttentionPanel: View {
    @ObservedObject var viewModel: AgentViewModel

    /// Mirrors `FloatingWidgetView`'s private `state` precedence exactly (permission >
    /// clarification > failure, and failure only once the run has actually stopped). Both surfaces
    /// observe the same view model, so if these two disagreed about which state wins they would
    /// show contradictory controls for one task.
    private enum AttentionState {
        case permission(RiskApprovalRequest)
        case clarification(String)
        case failure(String)
    }

    private var state: AttentionState? {
        if let approvalRequest = viewModel.approvalRequest {
            return .permission(approvalRequest)
        }
        if let question = viewModel.clarificationQuestion {
            return .clarification(question)
        }
        if let error = viewModel.errorMessage, !viewModel.isRunning {
            return .failure(error)
        }
        return nil
    }

    var body: some View {
        if let state {
            VStack(alignment: .leading, spacing: 10) {
                switch state {
                case .permission(let request):
                    permissionContent(request)
                case .clarification(let question):
                    clarificationContent(question)
                case .failure(let message):
                    failureContent(message)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CommandCenterPalette.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                    .stroke(accentColor.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
        } else {
            EmptyView()
        }
    }

    private var accentColor: Color {
        switch state {
        case .failure:
            return SonnyTheme.danger
        default:
            return SonnyTheme.warning
        }
    }

    @ViewBuilder
    private func permissionContent(_ request: RiskApprovalRequest) -> some View {
        header(icon: "exclamationmark.triangle", title: "Approval needed")

        // The same first-approval explainer the widget shows. Included here rather than left as a
        // widget-only moment because which surface the user happens to be looking at the first
        // time Sonny asks shouldn't decide whether they get the explanation.
        if !viewModel.hasCompletedFirstApproval {
            Text("Sonny always asks first for actions like this — you decide, every time.")
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
        }

        // `approvalCopy.lines` is the same five-line disclosure the risk engine builds for every
        // surface — what/why/involves/data-leaves-device/undo. Rendered in full here rather than
        // condensed to the resource name: Command Center has the vertical room the widget's
        // single-line treatment doesn't, and this may be the only surface an unattended run's
        // approval is ever read on.
        ForEach(Array(request.approvalCopy.lines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.sidebarNavText)
                .fixedSize(horizontal: false, vertical: true)
        }

        // What raised this above its default tier — "the zip already exists", "this snippet
        // trigger would be replaced". The widget added this line last branch; without it the
        // panel asks for approval on a raised tier while showing nothing about what raised it.
        let escalationReasons = request.assessment.escalations.map(\.reason).joined(separator: " ")
        if !escalationReasons.isEmpty {
            Text(escalationReasons)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Spacer(minLength: 0)

            // Same entry points the widget's own permission panel uses — `start()` routes to the
            // private `approvePendingRun()` through its `isAwaitingApproval` guard, and there is
            // no separate deny method. Calling anything else here would fork the approval path.
            Button("Deny") {
                viewModel.cancelCurrentRun()
            }
            .buttonStyle(CommandCenterRowActionStyle())

            Button("Allow") {
                viewModel.start()
            }
            .buttonStyle(CommandCenterRowActionStyle())
        }
    }

    @ViewBuilder
    private func clarificationContent(_ question: String) -> some View {
        header(icon: "questionmark.circle", title: "Clarification needed")

        Text(question)
            .font(SonnyType.micro)
            .foregroundStyle(SonnyTheme.sidebarNavText)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
            TextField(
                "",
                text: $viewModel.clarificationAnswer,
                prompt: Text("Type your answer…").foregroundStyle(SonnyTheme.muted)
            )
            .textFieldStyle(.plain)
            .font(SonnyType.caption)
            .foregroundStyle(SonnyTheme.text)
            .padding(.horizontal, 10)
            .frame(height: 23)
            .background(CommandCenterPalette.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
            .onSubmit { viewModel.submitClarification() }

            Button("Send") {
                viewModel.submitClarification()
            }
            .buttonStyle(CommandCenterRowActionStyle())
            .disabled(viewModel.clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func failureContent(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SonnyTheme.danger)

            Text(message)
                .font(SonnyType.itemTitle)
                .foregroundStyle(SonnyTheme.sidebarNavText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            // `errorMessage` also carries pre-flight errors (empty-command validation, voice
            // transcription failures) that never reached a real submission, and `retryLastCommand`
            // silently no-ops for those — so gate on `hasRetryableCommand` rather than shipping a
            // dead button, same as the widget's failure panel.
            if viewModel.hasRetryableCommand {
                Button("Retry") {
                    viewModel.retryLastCommand(origin: .commandCenter)
                }
                .buttonStyle(CommandCenterRowActionStyle())
            }

            Button("Dismiss") {
                viewModel.errorMessage = nil
            }
            .buttonStyle(CommandCenterRowActionStyle())
        }
    }

    /// Permission and clarification share this header; failure has its own single-line layout with
    /// the message inline, so it deliberately does not use this.
    @ViewBuilder
    private func header(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SonnyTheme.warning)

            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            Spacer(minLength: 12)
        }
    }
}

private struct InsightsView: View {
    @ObservedObject var viewModel: AgentViewModel

    private var summary: TaskHistoryInsightsSummary {
        TaskHistoryInsights.summarize(records: viewModel.taskHistoryRecords, now: Date())
    }

    private var workspaceBreakdown: [WorkspaceTaskBreakdownEntry] {
        WorkspaceTaskBreakdown.summarize(records: viewModel.taskHistoryRecords, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CommandCenterPageHeader(title: "Insights")

            CommandCenterAttentionPanel(viewModel: viewModel)

            CommandCenterStorageNotice(viewModel: viewModel)

            // Insights was the one page with no running indicator, so a task started from
            // Routines/Workspaces/Tasks was invisible here — the widget hides its own panel for
            // a `.commandCenter`-origin task, so there was no "something is happening" signal
            // anywhere while the user sat on this page.
            if viewModel.isRunning || viewModel.isAwaitingApproval {
                CommandCenterRunningIndicator(viewModel: viewModel)
            }

            ScrollView {
                // No "Overview" (or other) section-group label — neither the wireframe nor
                // founder-decisions doc calls for one, and it was previously applied to only
                // one of these four sections rather than consistently to all of them.
                VStack(alignment: .leading, spacing: 16) {
                    InsightsOverviewBento(summary: summary)

                    WeeklyCompletionChart(counts: summary.weeklyCompletedCounts)

                    WorkspaceBreakdownPanel(entries: workspaceBreakdown)

                    TaskHistoryListPanel(
                        records: RecentCompletedTasks.recent(from: viewModel.taskHistoryRecords, limit: 3),
                        title: "Recently Completed",
                        emptyTitle: "No activity yet",
                        emptyMessage: "Completed Sonny tasks will appear here."
                    )
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CommandCenterPalette.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
        .onAppear {
            viewModel.refreshTaskHistory()
        }
    }
}

/// Literal wireframe layout (`14-MainAppInsights.svg`) originally had 4 equal-width stat cards;
/// "Avg. cycle time" was dropped per direct instruction (2026-07-18) as not adding much value,
/// leaving 3.
private struct InsightsOverviewBento: View {
    let summary: TaskHistoryInsightsSummary

    var body: some View {
        HStack(spacing: 12) {
            InsightStatCard(stat: .completedThisWeek(summary))
            InsightStatCard(stat: .completionRate(summary))
            InsightStatCard(stat: .currentStreak(summary))
        }
    }
}

private struct InsightStatCard: View {
    let stat: InsightStatPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(stat.label)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)

            Text(stat.value)
                .font(SonnyType.heroStat)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(stat.delta)
                .font(SonnyType.micro)
                .foregroundStyle(stat.isPositiveDelta ? SonnyTheme.success : SonnyTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }
}

private struct WeeklyCompletionChart: View {
    let counts: [Int]
    @State private var hoveredDayIndex: Int?

    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private var maxCount: Int { counts.max() ?? 0 }
    private var peakIndex: Int? {
        guard maxCount > 0 else {
            return nil
        }
        return counts.firstIndex(of: maxCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tasks Completed This Week")
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 9) {
                        GeometryReader { proxy in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(index == peakIndex ? SonnyTheme.accent : SonnyTheme.chartBarMuted)
                                    .frame(
                                        width: 24,
                                        height: barHeight(for: counts[safe: index] ?? 0, availableHeight: proxy.size.height)
                                    )
                                    .opacity((counts[safe: index] ?? 0) == 0 ? 0 : 1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(height: 112)

                        // Swaps to the exact count on hover (2026-07-18) — a native `.help()`
                        // tooltip was tried first here and didn't render at all in the real app,
                        // so this replaces it with a plain state-driven label change: no floating
                        // overlay to mis-position, guaranteed to render exactly where the day
                        // label already sits.
                        Text(hoveredDayIndex == index ? "\(counts[safe: index] ?? 0) task\((counts[safe: index] ?? 0) == 1 ? "" : "s")" : day)
                            .font(SonnyType.micro)
                            .foregroundStyle(hoveredDayIndex == index ? SonnyTheme.text : SonnyTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        hoveredDayIndex = isHovering ? index : (hoveredDayIndex == index ? nil : hoveredDayIndex)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(dayTaskCountDescription(day: day, index: index))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }

    private func barHeight(for count: Int, availableHeight: CGFloat) -> CGFloat {
        guard maxCount > 0, count > 0 else {
            return 0
        }
        return max(12, CGFloat(count) / CGFloat(maxCount) * availableHeight)
    }

    private func dayTaskCountDescription(day: String, index: Int) -> String {
        let count = counts[safe: index] ?? 0
        return "\(day): \(count) completed task\(count == 1 ? "" : "s")"
    }
}

private struct WorkspaceBreakdownPanel: View {
    let entries: [WorkspaceTaskBreakdownEntry]

    private static let swatchColors: [Color] = [
        SonnyTheme.accent,
        SonnyTheme.success,
        SonnyTheme.warning,
        SonnyTheme.danger,
        SonnyTheme.muted
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Breakdown by Workspace")
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No workspace activity yet")
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                    Text("Tasks completed in a saved workspace over the last 30 days will appear here.")
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        WorkspaceBreakdownRow(
                            entry: entry,
                            swatchColor: Self.swatchColors[index % Self.swatchColors.count]
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }
}

private struct WorkspaceBreakdownRow: View {
    let entry: WorkspaceTaskBreakdownEntry
    let swatchColor: Color

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(swatchColor)
                .frame(width: 8, height: 8)

            Text(entry.workspaceName)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(SonnyTheme.cardBorder)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(swatchColor)
                        .frame(width: proxy.size.width * entry.fractionOfTotal)
                }
            }
            .frame(height: 6)

            Text(percentageText)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.workspaceName): \(percentageText)")
    }

    private var percentageText: String {
        "\(Int((entry.fractionOfTotal * 100).rounded()))%"
    }
}

private struct TaskHistoryListPanel: View {
    let records: [CompletedTaskRecord]
    let title: String
    let emptyTitle: String
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(emptyTitle)
                        .font(SonnyType.bodyEmphasis)
                        .foregroundStyle(SonnyTheme.text)
                    Text(emptyMessage)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        InsightsRecentActivityRow(record: record)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.panelCard))
    }
}

/// Insights' own "Recently completed" row (`14-MainAppInsights.svg`) — a plain solid-color
/// status dot, no icon cutout, distinct from the Tasks page's richer ring/checkmark treatment
/// in `TaskHistoryRow`. `RecentCompletedTasks.recent` already filters to `.completed` only, so
/// this only ever needs the one, green, dot.
private struct InsightsRecentActivityRow: View {
    let record: CompletedTaskRecord

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(SonnyTheme.success)
                .frame(width: 14, height: 14)

            Text(record.command.isEmpty ? "Untitled task" : record.command.sentenceCapitalized.truncatedForRowDisplay())
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            Text(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(record.command), " +
            "\(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))"
        )
    }
}

/// Wireframe status-group band: lighter than the rows beneath it (`#16171A` vs. rows' `#0F1011`,
/// which is the surrounding panel's own background — rows need no fill of their own). Title/count
/// keep the wireframe's two-tone hierarchy: a brighter medium-weight label next to a dimmer
/// regular-weight count, not one uniform muted string. Shared by every status group on this page,
/// including the live "In Progress" group, so all of them look like one continuous list.
private struct CommandCenterGroupHeader: View {
    struct Disclosure {
        let isExpanded: Bool
        let toggle: () -> Void
    }

    let title: String
    let count: Int
    /// Makes the header a collapse toggle (SONNY-49). Set only by the Tasks page's status groups;
    /// `nil` — the default, and what the Routines page's cadence groups still get — keeps the
    /// header exactly what it was: a plain, non-interactive band with no chevron and no button
    /// wrapper. The chevron sits on the *trailing* edge rather than before the title so the
    /// wireframe's title/count position is untouched, and because both System A chevrons that
    /// already exist (the sidebar profile row, the account menu's disclosure rows) are trailing.
    var disclosure: Disclosure? = nil

    var body: some View {
        if let disclosure {
            Button(action: disclosure.toggle) {
                band(disclosure: disclosure)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sonnyPointerCursor()
            .sonnyHoverHighlight(cornerRadius: 0)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityValue(disclosure.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(disclosure.isExpanded ? "Collapses this section" : "Expands this section")
        } else {
            band(disclosure: nil)
        }
    }

    private func band(disclosure: Disclosure?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(SonnyType.itemTitle)
                .foregroundStyle(SonnyTheme.sidebarNavText)
            Text("\(count)")
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)

            if let disclosure {
                // The `Spacer` is what makes the HStack greedy; without a disclosure the row stays
                // content-sized and the outer `.frame(alignment: .leading)` left-aligns it exactly
                // as before. One `chevron.right` rotated to point down when expanded, rather than
                // swapping to `chevron.down`, so the transition is a rotation and not a glyph pop.
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(SonnyType.icon(9, weight: .semibold))
                    .foregroundStyle(SonnyTheme.muted)
                    .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 36)
        .background(SonnyTheme.surfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SonnyTheme.cardBorder).frame(height: 1)
        }
    }
}

/// The live-running task, presented as this list's own "In Progress" group instead of a separate
/// block above it (2026-07-18 direction: the wireframe's stacked list has exactly three groups —
/// In Progress / Done / Canceled — so the live task belongs inside that same list, not floating
/// beside it). `activeTaskCount` is already a 0-or-1 concept elsewhere in this file (the sidebar
/// badge), so the count here is always 1 — this group only renders while something is active.
private struct InProgressTaskGroup: View {
    @ObservedObject var viewModel: AgentViewModel
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommandCenterGroupHeader(
                title: TaskSectionCollapseState.inProgressSectionID,
                count: 1,
                disclosure: .init(isExpanded: isExpanded, toggle: onToggle)
            )

            // Deliberately NOT gated on `isExpanded` (user decision, 2026-08-06, PR #31 review
            // F1). This indicator carries the app's only cancel control for a plain running task:
            // `cancelCurrentRun()` has exactly three call sites repo-wide, and the other two —
            // `CommandCenterAttentionPanel`'s Deny and the widget's `onDeny` — fire only on an
            // approval, so nothing else can stop a run that isn't waiting for one. The indicator
            // convention exists precisely so a running task always shows something; a persisted
            // collapse preference must not be able to silently remove this page's primary cancel
            // affordance on every future run.
            //
            // Enumerated rather than summarized, because the earlier version of this comment
            // subtracted without enumerating. What survives a collapsed "In Progress": the header
            // and its count, this indicator's spinner, its "Running: <command>" /
            // "Waiting for approval: <command>" text, and its Cancel button (itself gated on
            // `viewModel.canCancel`). What collapse hides is the section's *task rows* — and this
            // section has none today, so collapsing it currently changes nothing on screen beyond
            // the chevron's rotation and the persisted preference. `CommandCenterAttentionPanel`
            // sits outside the scroll area and self-gates, so approvals were never affected by
            // this either way.
            CommandCenterRunningIndicator(viewModel: viewModel)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
        }
    }
}

private struct TaskHistoryGroupedPanel: View {
    let records: [CompletedTaskRecord]
    let collapseState: TaskSectionCollapseState
    let onToggleSection: (String) -> Void
    let onSelect: (CompletedTaskRecord) -> Void

    private var sections: [TaskSectionPresentation] {
        TaskSectionPresentation.sections(
            for: TaskHistoryGrouping.groupedByOutcome(records: records),
            collapse: collapseState
        )
    }

    var body: some View {
        if records.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No completed tasks yet")
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                Text("Run or cancel a Sonny task and it will appear here.")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        // `section.count`, not `section.visibleRecords.count` — the count is the
                        // whole point of a collapsed header, so a task that completes while "Done"
                        // is folded away still bumps the number the user can see. This line and
                        // the `disclosure:` argument beneath it are unpinned points (3) and (4) of
                        // the four enumerated on `TasksFoundationView.collapseState`: the wrong
                        // count reads 0 on every collapsed section, and a `nil` disclosure removes
                        // the chevron from Done/Failed/Canceled entirely. Both leave the suite green.
                        CommandCenterGroupHeader(
                            title: section.title,
                            count: section.count,
                            disclosure: .init(
                                isExpanded: section.isExpanded,
                                toggle: { onToggleSection(section.id) }
                            )
                        )

                        VStack(spacing: 0) {
                            ForEach(section.visibleRecords, id: \.startedAt) { record in
                                TaskHistoryRow(record: record, onSelect: { onSelect(record) })
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Shared by `TaskHistoryRow` and `TaskLogDetailDialog` so the row and its detail dialog always
/// agree on what a given outcome looks like.
@ViewBuilder
private func taskStatusIcon(for status: PriorTaskOutcomeStatus) -> some View {
    switch status {
    case .completed:
        // Wireframe "Done": filled indigo circle with a dark checkmark cutout.
        ZStack {
            Circle().fill(SonnyTheme.taskDone)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(SonnyTheme.ink)
        }
    case .canceled:
        // Wireframe "Canceled": filled blue-gray circle with a dark X cutout.
        ZStack {
            Circle().fill(SonnyTheme.taskCanceled)
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(SonnyTheme.ink)
        }
    case .failed:
        // No wireframe evidence for a failure treatment — this screen only shows
        // In Progress/Done/Canceled. Reusing In Progress's stroked-ring shape, recolored to
        // the established danger token, as the most defensible reading absent a direct source.
        Circle()
            .strokeBorder(SonnyTheme.danger, lineWidth: 1.5)
    default:
        Circle()
            .fill(SonnyTheme.muted)
    }
}

private func taskStatusText(for record: CompletedTaskRecord) -> String {
    let duration = TaskHistoryDurationFormatter.short(record.completedAt.timeIntervalSince(record.startedAt))
    switch record.outcomeStatus {
    case .completed:
        return "Completed in \(duration)"
    case .failed:
        return "Failed after \(duration)"
    case .canceled:
        return "Canceled after \(duration)"
    default:
        return record.outcomeStatus.rawValue.replacingOccurrences(of: "_", with: " ")
    }
}

/// A row now opens `TaskLogDetailDialog` on click/tap (2026-07-18 direction: the rich live
/// Plan/Preview/step-log surface that used to render inline on Tasks/Routines/Workspaces was
/// "not at all" what was wanted — that detail now only lives behind a click, and only shows a
/// static receipt of what already happened, not a live replay).
private struct TaskHistoryRow: View {
    let record: CompletedTaskRecord
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            taskStatusIcon(for: record.outcomeStatus)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.command.isEmpty ? "Untitled task" : record.command.sentenceCapitalized.truncatedForRowDisplay())
                    .font(SonnyType.itemTitle)
                    .foregroundStyle(SonnyTheme.sidebarNavText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(taskStatusText(for: record))
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let workspaceName = record.workspaceName {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(SonnyTheme.sidebarNavText)
                    Text(workspaceName)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(
                    Capsule().stroke(SonnyTheme.border, lineWidth: 1)
                )
            }

            Text(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 30)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SonnyTheme.border).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .sonnyPointerCursor()
        .sonnyHoverHighlight(cornerRadius: 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(record.command), \(taskStatusText(for: record))\(record.workspaceName.map { ", \($0)" } ?? ""), " +
            "\(TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens task details")
    }
}

/// Identifiable wrapper so `CompletedTaskRecord` (a plain `MacAgentCore` model with no UI-layer
/// concerns baked in) can drive `.sheet(item:)` without adding an `Identifiable` conformance to
/// the persisted model itself. `startedAt` plus `command` is unique enough for this — real
/// collisions would need two records with the exact same command starting in the same instant.
private struct TaskLogEntry: Identifiable {
    let record: CompletedTaskRecord
    var id: String { "\(record.startedAt.timeIntervalSince1970)-\(record.command)" }
}

/// A static "receipt" of one completed run — command, outcome, timestamps, workspace — not a live
/// replay of what happened step by step (2026-07-18 direction: "logs + summary + activity should
/// just be a flow as to how that thing worked under the hood," deliberately less detailed than the
/// old inline Plan/Preview/step-log surface). `CompletedTaskRecord` doesn't persist the actual
/// result/output text today, only the pass/fail signal — see docs/sonny-ui-backend-gaps.md if a
/// richer "what did it actually produce" narrative is wanted here later.
private struct TaskLogDetailDialog: View {
    let record: CompletedTaskRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(SonnyType.icon(11, weight: .semibold))
                        .foregroundStyle(SonnyTheme.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 12)
                .accessibilityLabel("Close")
                // Standard macOS escape-hatch for a close button, and an independent way to
                // dismiss if the click itself is ever the thing not registering.
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            HStack(spacing: 10) {
                taskStatusIcon(for: record.outcomeStatus)
                    .frame(width: 16, height: 16)
                Text(record.command.isEmpty ? "Untitled task" : record.command.sentenceCapitalized)
                    .font(SonnyType.settingsContentTitle)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 20)

            SettingsDivider()
                .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 0) {
                detailRow(label: "Status", value: taskStatusText(for: record))
                SettingsDivider()
                detailRow(label: "Started", value: TaskHistoryDateFormatter.relativeTimestamp(for: record.startedAt, now: Date()))
                SettingsDivider()
                detailRow(label: "Completed", value: TaskHistoryDateFormatter.relativeTimestamp(for: record.completedAt, now: Date()))
                if let workspaceName = record.workspaceName {
                    SettingsDivider()
                    detailRow(label: "Workspace", value: workspaceName)
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 20)
        }
        .frame(width: 420, height: 320, alignment: .top)
        .background(SonnyTheme.ink)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.container)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(SonnyType.itemTitle)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
    }
}

private struct InsightStatPresentation: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let delta: String
    let isPositiveDelta: Bool

    static func completedThisWeek(_ summary: TaskHistoryInsightsSummary) -> Self {
        let difference = summary.completedThisWeek - summary.previousWeekCompleted
        return Self(
            id: "completed-this-week",
            label: "Completed This Week",
            value: "\(summary.completedThisWeek)",
            delta: deltaCountText(difference),
            isPositiveDelta: difference > 0
        )
    }

    static func completionRate(_ summary: TaskHistoryInsightsSummary) -> Self {
        let currentPercent = Int((summary.completionRate * 100).rounded())
        let previousPercent = Int((summary.previousWeekCompletionRate * 100).rounded())
        let difference = currentPercent - previousPercent
        return Self(
            id: "completion-rate",
            label: "Completion Rate",
            value: "\(currentPercent)%",
            delta: deltaPercentText(difference),
            isPositiveDelta: difference > 0
        )
    }

    static func currentStreak(_ summary: TaskHistoryInsightsSummary) -> Self {
        let days = summary.currentStreakDays
        let delta: String
        if days == 0 {
            delta = "No active streak"
        } else if summary.hasCompletedToday {
            delta = "Active today"
        } else {
            delta = "Keep it going today"
        }
        return Self(
            id: "current-streak",
            label: "Current Streak",
            value: "\(days) day\(days == 1 ? "" : "s")",
            delta: delta,
            // Always neutral, never green — unlike the other 2 cards, this delta isn't a
            // vs.-last-week comparison, so it doesn't get the "improved" color treatment.
            isPositiveDelta: false
        )
    }

    private static func deltaCountText(_ difference: Int) -> String {
        if difference > 0 {
            return "+\(difference) vs last week"
        }
        if difference < 0 {
            return "\(difference) vs last week"
        }
        return "No change"
    }

    private static func deltaPercentText(_ difference: Int) -> String {
        if difference > 0 {
            return "+\(difference)%"
        }
        if difference < 0 {
            return "\(difference)%"
        }
        return "No change"
    }
}

/// Not `private` — unlike its neighbors below, this has real branching (hour boundaries, name
/// splitting, empty-name fallback) worth covering directly rather than only through the view.
enum TaskGreetingFormatter {
    static func greeting(hour: Int, fullName: String, displayFullNames: Bool) -> String {
        let period: String
        switch hour {
        case 5..<12: period = "Morning"
        case 12..<17: period = "Afternoon"
        case 17..<22: period = "Evening"
        default: period = "Night"
        }
        guard !fullName.isEmpty else { return "Good \(period)" }
        let name = displayFullNames
            ? fullName
            : (fullName.components(separatedBy: .whitespaces).first ?? fullName)
        return "Good \(period), \(name)"
    }
}

private enum TaskHistoryDurationFormatter {
    static func short(_ rawDuration: TimeInterval) -> String {
        let duration = max(0, rawDuration)
        if duration < 60 {
            return "\(Int(duration.rounded()))s"
        }
        if duration < 60 * 60 {
            return "\(Int((duration / 60).rounded()))m"
        }
        if duration < 24 * 60 * 60 {
            let hours = duration / (60 * 60)
            return formatted(hours) + "h"
        }
        let days = duration / (24 * 60 * 60)
        return formatted(days) + "d"
    }

    private static func formatted(_ value: Double) -> String {
        if value >= 10 || value.rounded() == value {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}

private enum TaskHistoryDateFormatter {
    static func relativeTimestamp(
        for date: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        return dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    /// Capitalizes only the first character, leaving the rest of the string untouched — unlike
    /// `.capitalized`, which would incorrectly title-case every word of a typed command sentence.
    /// Applied only where a raw command is displayed as a row title; the stored value itself is
    /// never mutated.
    var sentenceCapitalized: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    /// Simple word-boundary truncation for row display — an interim measure (2026-07-18) while
    /// real AI-based command summarization (the way a chat app auto-titles a conversation) is
    /// tracked as a backend gap in docs/sonny-ui-backend-gaps.md. Breaks at the last space before
    /// `maxLength` rather than mid-word; `.lineLimit(1)` stays on these rows too as a layout
    /// safety net, but its own truncation doesn't respect word boundaries the way this does.
    func truncatedForRowDisplay(maxLength: Int = 60) -> String {
        guard count > maxLength else { return self }
        let prefix = self.prefix(maxLength)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}

struct RoutineRowPresentation: Equatable {
    let name: String
    let detailText: String
    let streak: Int?
    let nextRunText: String?
    let isEnabled: Bool
    let isScheduleable: Bool
    /// Set when Sonny switched this routine's schedule off itself. The row shows that it needs
    /// attention; the reason itself is long enough that it belongs in the detail view, where
    /// there is room for a sentence.
    ///
    /// Reads `RoutineActivation` (SONNY-46), so this and `isEnabled` above cannot both be true —
    /// a "Paused" caption on a routine that is still firing on time, suppressing the next-run
    /// caption, is now unrepresentable in the model rather than merely unreachable in practice.
    let isPaused: Bool

    init(routine: StoredRoutine, now: Date) {
        name = routine.name
        isScheduleable = routine.schedule != nil
        isEnabled = routine.isScheduled
        isPaused = routine.schedule?.isPausedBySonny == true

        // The wireframe's second line is the routine's cadence ("Daily", "Weekly · Mon"), not its
        // step list. An unscheduled routine has no cadence to show, so it keeps the step summary
        // rather than leaving the line blank.
        if let schedule = routine.schedule {
            detailText = RoutineScheduleDisplay.cadenceLabel(for: schedule)
        } else {
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

        let streakCount = RoutineStreak.current(for: routine, now: now)
        // Hidden rather than shown as "0" — the badge is a reward, and a zero badge on every
        // never-run routine is visual noise that makes the real ones harder to spot.
        streak = streakCount > 0 ? streakCount : nil
        nextRunText = routine.schedule.flatMap {
            RoutineScheduleDisplay.nextRunText(for: $0, now: now)
        }
    }
}

struct WorkspaceAppIconPresentation: Equatable {
    let appName: String
    let icon: NSImage?

    @MainActor
    init(appName: String, resolver: any WorkspaceAppIconResolving) {
        self.appName = appName
        self.icon = resolver.icon(forAppName: appName)
    }

    /// Icon content isn't part of this presentation's logical identity — whether an icon resolves
    /// depends on what's installed on the machine rendering it, and two presentations for the same
    /// app name should compare equal regardless (this also keeps tests deterministic without
    /// depending on real installed apps).
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.appName == rhs.appName
    }
}

/// How many completed tasks a workspace has, and how that reads.
///
/// Shared by the card and the detail sheet rather than computed twice: two surfaces disagreeing
/// about what "3 tasks" counts is the kind of drift a user notices and cannot explain.
enum WorkspaceTaskCount {
    /// All-time, `.completed`-only (matching the Insights breakdown's own definition of "a real
    /// task happened here") — not windowed to the breakdown's trailing 30 days, since this is a
    /// simple running count, not a recent-trend chart, and the store's 10,000-record cap is
    /// already generously large for this to matter at v1 scale.
    static func count(forWorkspaceNamed name: String, in records: [CompletedTaskRecord]) -> Int {
        records.filter { $0.outcomeStatus == .completed && $0.workspaceName == name }.count
    }

    static func text(_ count: Int) -> String {
        "\(count) task\(count == 1 ? "" : "s")"
    }
}

struct WorkspaceCardPresentation: Equatable {
    let name: String
    let effectiveTeamType: WorkspaceTeamType
    let isDefaultTeamType: Bool
    let taskCount: Int
    let taskCountText: String
    let appIcons: [WorkspaceAppIconPresentation]
    let urlsText: String?

    @MainActor
    init(
        workspace: StoredWorkspace,
        taskHistoryRecords: [CompletedTaskRecord],
        iconResolver: any WorkspaceAppIconResolving = WorkspaceAppIconResolver.shared
    ) {
        name = workspace.name
        effectiveTeamType = workspace.effectiveTeamType
        isDefaultTeamType = workspace.teamType == nil
        taskCount = WorkspaceTaskCount.count(forWorkspaceNamed: workspace.name, in: taskHistoryRecords)
        taskCountText = WorkspaceTaskCount.text(taskCount)
        appIcons = workspace.apps.map { WorkspaceAppIconPresentation(appName: $0, resolver: iconResolver) }
        urlsText = workspace.urls.isEmpty ? nil : workspace.urls.map(Self.shortURL).joined(separator: ", ")
    }

    private static func shortURL(_ rawValue: String) -> String {
        guard let url = URL(string: rawValue), let host = url.host else {
            return rawValue
        }
        return host.replacingOccurrences(of: "www.", with: "", options: .anchored)
    }
}

/// One stored scope entry, with the command that would remove it.
///
/// The command is built here rather than in the view body so that what every affordance actually
/// sends is pinned by a pure test — this repo has no SwiftUI view-inspection harness, so anything
/// composed inside a `body` is unassertable.
struct WorkspaceScopeEntryPresentation: Equatable {
    let value: String
    let removeCommand: String
    /// States the real removal unit, not a single-entry promise — see `removalUnits`.
    let removeAccessibilityLabel: String
    /// Non-nil when other stored entries leave with this one. Rendered *visibly*, because an
    /// accessibility label alone tells a sighted user nothing before they tap.
    let sharedRemovalNote: String?
    /// Non-nil when `WorkspaceScope` classified this entry inert: it is stored, it is shown, and it
    /// can never match anything. Carries the evaluator's own reason.
    let inertNote: String?
}

/// One dimension of a workspace's boundary, as the detail sheet renders it.
///
/// **The empty case is the one that matters, and "empty" is the evaluator's word, not a count of
/// stored strings.** `WorkspaceScope` reports `.unconstrained` whenever its *canonical* list is
/// empty, and its own doc comment spells out that this includes the case where every entry the user
/// configured turned out to be inert. Deriving this from `entries.isEmpty` — which this shipped with
/// first — is the same two-notions-of-empty defect SONNY-40 removed from the consent path one commit
/// earlier, reintroduced under a different name on the surface whose entire job is telling the user
/// whether a dimension restricts. It is worse here than there: the user reads a dimension as
/// restricting when nothing is, and the sheet withholds the one sentence that would say otherwise.
struct WorkspaceScopeSectionPresentation: Equatable {
    let title: String
    /// Stored entries verbatim, in stored order. Deliberately *not* shortened the way the card
    /// shortens a URL to its host: the card is a glance, this sheet is the one place the whole
    /// boundary is meant to be inspectable, and an abbreviated entry is one the user cannot check
    /// against the entry a consent prompt named.
    let entries: [WorkspaceScopeEntryPresentation]
    /// Whether this dimension constrains anything, read from `WorkspaceScope`'s canonical list.
    /// **Not** `!entries.isEmpty`: a list of nothing but inert entries has rows and restricts
    /// nothing.
    let isRestricted: Bool
    /// Non-nil exactly when `isRestricted` is false — including when there are rows to show.
    let notRestrictedText: String?
    /// A *completable prefix*, in `beginNewWorkspace`'s idiom, because the entry being added does
    /// not exist yet for the sheet to name. The user finishes it in the widget composer.
    let addCommand: String
    let addAccessibilityLabel: String
}

/// Everything the workspace detail sheet renders, computed as data.
///
/// Net-new UI with no wireframe — `13-MainAppWorkspaces.svg` is a card grid only — built as the
/// stated, reasoned exception recorded in `docs/sonny-branch-b-plan.md` §11 and
/// `docs/sonny-founder-design-decisions.md`. **System A only**: liquid glass was tried for
/// workspace surfaces and explicitly reverted as too distracting from content, so this does not
/// inherit the routine-detail view's System-B-inside-System-A treatment.
struct WorkspaceDetailPresentation: Equatable {
    let name: String
    let avatarInitial: String
    let effectiveTeamType: WorkspaceTeamType
    let isDefaultTeamType: Bool
    let teamTypeText: String
    let taskCount: Int
    let taskCountText: String
    let apps: WorkspaceScopeSectionPresentation
    let urls: WorkspaceScopeSectionPresentation
    let fileLocations: WorkspaceScopeSectionPresentation
    /// A single line explaining what an unrestricted dimension means, shown once rather than
    /// repeated under every empty list. Present only when at least one dimension is unrestricted —
    /// a fully-configured workspace needs no explanation of a state it is not in.
    let unrestrictedFootnote: String?

    /// Fixed order — apps, URLs, file locations — matching the order `edit_workspace`'s consent
    /// prompts report a mixed edit in, so the two surfaces read the same way round.
    var sections: [WorkspaceScopeSectionPresentation] { [apps, urls, fileLocations] }

    /// The accessibility label for the sheet's mark-as-team control, owned here rather than built in
    /// the view body — its Add and Remove siblings are pure and tested, and this one was not.
    let markAsTeamAccessibilityLabel: String

    /// `catalog` and `whitelist` are injectable purely so a test can pin behaviour without depending
    /// on what happens to be installed or on the real home directory. Production always takes the
    /// defaults, which is what makes the sheet's answer and the evaluator's answer the same answer.
    init(
        workspace: StoredWorkspace,
        taskHistoryRecords: [CompletedTaskRecord],
        catalog: MacAppCatalog = .default,
        whitelist: PathWhitelist = PathWhitelist()
    ) {
        name = workspace.name
        avatarInitial = WorkspaceAvatarInitial.from(name: workspace.name)
        effectiveTeamType = workspace.effectiveTeamType
        isDefaultTeamType = workspace.teamType == nil
        teamTypeText = workspace.effectiveTeamType == .team ? "Team workspace" : "Just you"
        taskCount = WorkspaceTaskCount.count(forWorkspaceNamed: workspace.name, in: taskHistoryRecords)
        taskCountText = WorkspaceTaskCount.text(taskCount)
        markAsTeamAccessibilityLabel = "Mark \(workspace.name) as a team workspace"

        // Built once, and it is the single source of truth for every "does this restrict anything"
        // question below. `WorkspaceScopeInertEntry`'s own doc comment names this sheet as its
        // intended consumer — "so a dropped entry is never mistaken for one that matched nothing".
        let scope = WorkspaceScope(workspace: workspace, catalog: catalog, whitelist: whitelist)

        apps = Self.section(
            title: "Apps",
            noun: "the app",
            kind: .app,
            values: workspace.apps,
            workspaceName: workspace.name,
            isRestricted: !scope.appKeys.isEmpty,
            notRestrictedText: "Not restricted — this workspace does not limit which apps a task can use.",
            scope: scope,
            catalog: catalog,
            whitelist: whitelist
        )
        urls = Self.section(
            title: "URLs",
            noun: "the URL",
            kind: .webDomain,
            values: workspace.urls,
            workspaceName: workspace.name,
            isRestricted: !scope.webDomains.isEmpty,
            notRestrictedText: "Not restricted — this workspace does not limit which sites a task can open.",
            scope: scope,
            catalog: catalog,
            whitelist: whitelist
        )
        // `effectiveFileLocations`, never the raw Optional: "no key on disk" and "explicitly
        // emptied" are the same thing to every reader outside `WorkspaceStore.save`, and both mean
        // this dimension restricts nothing.
        fileLocations = Self.section(
            title: "File locations",
            noun: "the folder",
            kind: .fileLocation,
            values: workspace.effectiveFileLocations,
            workspaceName: workspace.name,
            isRestricted: !scope.fileRoots.isEmpty,
            notRestrictedText: "Not restricted — this workspace does not limit which folders a task can touch.",
            scope: scope,
            catalog: catalog,
            whitelist: whitelist
        )
        unrestrictedFootnote = [apps, urls, fileLocations].contains { !$0.isRestricted }
            ? "An unrestricted list means this workspace says nothing about that kind of thing — Sonny neither "
                + "limits it here nor treats it as specially allowed."
            : nil
    }

    /// The sentence shown when an open sheet's workspace is no longer stored. Owned here for the
    /// same reason as `markAsTeamAccessibilityLabel`.
    static func unavailableText(name: String) -> String {
        "“\(name)” is no longer saved."
    }

    private static func section(
        title: String,
        noun: String,
        kind: ScopedResourceKind,
        values: [String],
        workspaceName: String,
        isRestricted: Bool,
        notRestrictedText: String,
        scope: WorkspaceScope,
        catalog: MacAppCatalog,
        whitelist: PathWhitelist
    ) -> WorkspaceScopeSectionPresentation {
        let inertReasons = Dictionary(
            scope.inertEntries.filter { $0.kind == kind }.map { ($0.value, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        let units = removalUnits(kind: kind, values: values, catalog: catalog, whitelist: whitelist)

        return WorkspaceScopeSectionPresentation(
            title: title,
            entries: values.indices.map { index in
                let value = values[index]
                let alsoRemoved = units[index]
                return WorkspaceScopeEntryPresentation(
                    value: value,
                    removeCommand: "In my \(workspaceName) workspace, remove \(noun) \(value)",
                    removeAccessibilityLabel: alsoRemoved.isEmpty
                        ? "Remove \(value) from \(workspaceName)"
                        : "Remove \(value) from \(workspaceName), which also removes "
                            + alsoRemoved.joined(separator: ", "),
                    sharedRemovalNote: alsoRemoved.isEmpty
                        ? nil
                        : "Removing this also removes \(alsoRemoved.joined(separator: ", ")).",
                    // The evaluator's own words for *why*, never a paraphrase: a second explanation
                    // of inertness is a second thing that can disagree with the classification it
                    // is explaining.
                    inertNote: inertReasons[value].map { "Not in effect — \($0)" }
                )
            },
            isRestricted: isRestricted,
            notRestrictedText: isRestricted ? nil : notRestrictedText,
            // Trailing space is load-bearing: the composer opens with the caret after it so the
            // user types only the entry.
            addCommand: "In my \(workspaceName) workspace, add \(noun) ",
            addAccessibilityLabel: "Add \(noun) to \(workspaceName)"
        )
    }

    /// For each stored entry, the *other* stored entries that leave with it when it is removed.
    ///
    /// `edit_workspace` matches a removal request at a coarser grain than a row — by host for URLs,
    /// by catalog key for apps — and the adapter's own comment says a workspace "may legitimately
    /// hold both" URLs on one host, so several rows sharing one removal unit is an expected state.
    /// A per-entry Remove button promising single-entry removal would be lying on the one surface
    /// built to make the boundary trustworthy.
    ///
    /// Computed by asking the evaluator twice rather than by re-deriving its keys, which are not
    /// visible outside `MacAgentCore` and must not be copied here. A scope built from entry A is
    /// asked about entry B and vice versa, and only a **symmetric** match counts as one unit. One
    /// direction alone would over-group: `verdict(for:)` is folder *containment* and a dot-suffix
    /// host match, so `github.com` accepts `api.github.com` and `~/Documents` accepts
    /// `~/Documents/X`, neither in reverse. Symmetry turns those deliberately asymmetric rules back
    /// into the equality the adapter's removal matching actually uses.
    private static func removalUnits(
        kind: ScopedResourceKind,
        values: [String],
        catalog: MacAppCatalog,
        whitelist: PathWhitelist
    ) -> [[String]] {
        let scopes = values.map { value in
            WorkspaceScope(
                workspace: singleEntryWorkspace(kind: kind, value: value),
                catalog: catalog,
                whitelist: whitelist
            )
        }
        let resources = values.map { resource(kind: kind, value: $0) }

        return values.indices.map { index in
            values.indices.compactMap { other -> String? in
                guard other != index,
                      let mine = resources[index],
                      let theirs = resources[other],
                      scopes[index].verdict(for: theirs) == .inScope,
                      scopes[other].verdict(for: mine) == .inScope else {
                    return nil
                }
                return values[other]
            }
        }
    }

    private static func singleEntryWorkspace(kind: ScopedResourceKind, value: String) -> StoredWorkspace {
        switch kind {
        case .app:
            return StoredWorkspace(name: "", apps: [value], urls: [])
        case .webDomain:
            return StoredWorkspace(name: "", apps: [], urls: [value])
        case .fileLocation:
            return StoredWorkspace(name: "", apps: [], urls: [], fileLocations: [value])
        }
    }

    /// A stored entry as the resource the evaluator compares. URLs become their *host*, which is
    /// what `WorkspaceScope` matches; an entry `SafeURL` rejects has no host, so it groups with
    /// nothing — correctly, since it can never match anything either.
    private static func resource(kind: ScopedResourceKind, value: String) -> ScopedResource? {
        switch kind {
        case .app:
            return .app(value)
        case .webDomain:
            guard let host = (try? SafeURL.validateWebURL(value))?.host else {
                return nil
            }
            return .webDomain(host)
        case .fileLocation:
            return .fileLocation(value)
        }
    }
}

private struct RoutinesView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var selectedRoutine: StoredRoutine?

    private var sections: [RoutineCadenceSection] {
        RoutineGrouping.groupedByCadence(routines: viewModel.savedRoutines)
    }

    var body: some View {
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
                            // Cadence-grouped per `11-MainAppRoutines.svg`, which has Daily /
                            // Weekly / Monthly headings with counts rather than one flat list.
                            ForEach(sections) { section in
                                CommandCenterGroupHeader(title: section.title, count: section.routines.count)

                                ForEach(Array(section.routines.enumerated()), id: \.element.name) { index, routine in
                                    RoutineRow(
                                        presentation: RoutineRowPresentation(routine: routine, now: Date()),
                                        isLast: index == section.routines.count - 1,
                                        setEnabled: { viewModel.setRoutineScheduleEnabled(routine, to: $0) },
                                        openDetail: { selectedRoutine = routine }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CommandCenterPalette.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))

            CommandCenterAttentionPanel(viewModel: viewModel)

            // Self-gates on `localStorageNotice`, deliberately outside the running check: a
            // corrupt store is worth reporting whether or not a task happens to be in flight,
            // and Command Center is the reliable surface for it since the widget never raises
            // itself for a storage notice.
            CommandCenterStorageNotice(viewModel: viewModel)

            if viewModel.isRunning || viewModel.isAwaitingApproval {
                CommandCenterRunningIndicator(viewModel: viewModel)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
        .sheet(item: $selectedRoutine) { routine in
            RoutineDetailView(routine: routine, viewModel: viewModel)
        }
    }

    // Command Center has no composer of its own — pre-fill the command and bring the widget
    // forward so the user finishes typing the routine name there.
    private func beginNewRoutine() {
        viewModel.command = "Create a routine called "
        viewModel.widgetPresentationRequest += 1
    }
}

private struct RoutineRow: View {
    let presentation: RoutineRowPresentation
    let isLast: Bool
    let setEnabled: (Bool) -> Void
    let openDetail: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: SonnyRadius.routineIcon)
                        .fill(CommandCenterPalette.routineIconBackground)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CommandCenterPalette.routineIconForeground)
                        .frame(width: 12, height: 12)
                }
                .frame(width: 30, height: 30)

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

                // The wireframe's `streak` layer: a 10pt #F2BE00 dot and the count beside it.
                // Wired to real per-occurrence run history, never to `steps.count` — a step count
                // does not decay the way a streak does, which is the documented prior mistake here.
                if let streak = presentation.streak {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(SonnyTheme.warning)
                            .frame(width: 10, height: 10)
                        Text("\(streak)")
                            .font(SonnyType.caption)
                            .foregroundStyle(SonnyTheme.warning)
                    }
                    .accessibilityLabel("\(streak) run streak")
                }

                // One slot, two mutually exclusive occupants. `nextRunText` returns nil for a
                // disabled schedule, and a paused schedule is disabled — so this fills a slot the
                // wireframe leaves empty in exactly that state rather than adding a line to a row
                // whose 56pt height has room for neither. Warning colour is the row's existing
                // one, already carried by the streak badge; no new token.
                if presentation.isPaused {
                    Text("Paused")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.warning)
                        .lineLimit(1)
                        .accessibilityLabel("Paused — needs your attention")
                } else if let nextRun = presentation.nextRunText {
                    Text(nextRun)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                        .lineLimit(1)
                }

                // Replaces the old Run button, which was an original addition never in the
                // wireframe — this slot is the toggle's. Running a routine by hand now lives in
                // the detail view, which the row opens on tap.
                if presentation.isScheduleable {
                    // `set:` takes the closure inline rather than passing `setEnabled` directly:
                    // the bare function reference converts to a `@Sendable` parameter and trips
                    // Swift 6's data-race check, since the closure captures the main-actor view
                    // model. Both this view and the handler are already main-actor isolated.
                    Toggle("", isOn: Binding(
                        get: { presentation.isEnabled },
                        set: { isOn in setEnabled(isOn) }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(SonnyTheme.accent)
                        .accessibilityLabel("Run \(presentation.name) on schedule")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .contentShape(Rectangle())
            .onTapGesture(perform: openDetail)
            .sonnyPointerCursor()
            .sonnyHoverHighlight(cornerRadius: 0)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens routine details")

            if !isLast {
                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(height: 1)
            }
        }
    }
}

private struct WorkspacesView: View {
    @ObservedObject var viewModel: AgentViewModel
    /// The *name*, not the record. `.sheet(item:)` captures its value, so holding a
    /// `StoredWorkspace` would freeze the sheet against a snapshot taken when it opened — and this
    /// sheet's whole job is showing a boundary the user is editing, so it has to re-render when the
    /// edit lands. Looking the name up in `savedWorkspaces` on every render is what keeps it live.
    @State private var selectedWorkspaceName: SelectedWorkspaceName?

    private var selectedWorkspace: StoredWorkspace? {
        guard let selectedWorkspaceName else {
            return nil
        }
        return viewModel.savedWorkspaces.first { $0.name == selectedWorkspaceName.name }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 356, maximum: 356), spacing: 14, alignment: .top)
    ]

    var body: some View {
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
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(Array(viewModel.savedWorkspaces.enumerated()), id: \.element.name) { index, workspace in
                                WorkspaceCard(
                                    presentation: WorkspaceCardPresentation(
                                        workspace: workspace,
                                        taskHistoryRecords: viewModel.taskHistoryRecords
                                    ),
                                    accent: CommandCenterPalette.workspaceAvatarColors[
                                        index % CommandCenterPalette.workspaceAvatarColors.count
                                    ],
                                    isRunning: viewModel.isRunning || viewModel.isAwaitingApproval,
                                    open: { viewModel.openWorkspaceWidget(workspace) },
                                    beginTaskHere: { viewModel.beginTaskInWorkspace(workspace) },
                                    markAsTeam: { viewModel.markWorkspaceAsTeam(workspace) },
                                    delete: { viewModel.deleteWorkspace(workspace) },
                                    openDetail: {
                                        selectedWorkspaceName = SelectedWorkspaceName(name: workspace.name)
                                    }
                                )
                            }
                        }
                        .padding(30)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CommandCenterPalette.collectionSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))

            CommandCenterAttentionPanel(viewModel: viewModel)

            // Self-gates on `localStorageNotice`, deliberately outside the running check: a
            // corrupt store is worth reporting whether or not a task happens to be in flight,
            // and Command Center is the reliable surface for it since the widget never raises
            // itself for a storage notice.
            CommandCenterStorageNotice(viewModel: viewModel)

            if viewModel.isRunning || viewModel.isAwaitingApproval {
                CommandCenterRunningIndicator(viewModel: viewModel)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SonnyTheme.ink)
        .sheet(item: $selectedWorkspaceName) { selected in
            // Resolved from the live list, and dismissed rather than shown stale if the workspace
            // is gone — deleting from underneath an open sheet is reachable, since delete is on the
            // card behind it.
            if let workspace = selectedWorkspace {
                WorkspaceDetailView(
                    presentation: WorkspaceDetailPresentation(
                        workspace: workspace,
                        taskHistoryRecords: viewModel.taskHistoryRecords
                    ),
                    accent: CommandCenterPalette.workspaceAvatarColors[
                        accentIndex(for: workspace.name)
                    ],
                    isRunning: viewModel.isRunning || viewModel.isAwaitingApproval,
                    markAsTeam: { viewModel.markWorkspaceAsTeam(workspace) },
                    compose: { viewModel.composeWorkspaceScopeEdit($0) }
                )
            } else {
                // Structurally required — the live lookup is Optional — rather than a path anything
                // reaches today: the only delete affordance is on the card this sheet covers, and
                // no capability deletes a workspace. Rendering a sentence instead of nothing means
                // that if a future delete path does open, the sheet says so rather than going
                // blank; deliberately not an `onAppear` self-dismiss, which is state mutation
                // during presentation for a case that cannot currently occur.
                WorkspaceDetailUnavailableView(name: selected.name)
            }
        }
        .onAppear {
            viewModel.refreshTaskHistory()
        }
    }

    /// The sheet's avatar has to be the colour the card already gave this workspace, and the card's
    /// colour comes from its position in the grid — so the index is recovered by name rather than
    /// captured, which would go stale the moment the list reorders under an open sheet.
    private func accentIndex(for name: String) -> Int {
        let position = viewModel.savedWorkspaces.firstIndex { $0.name == name } ?? 0
        return position % CommandCenterPalette.workspaceAvatarColors.count
    }

    // Command Center has no composer of its own — pre-fill the command and bring the widget
    // forward so the user finishes typing the workspace name there.
    private func beginNewWorkspace() {
        viewModel.command = "Create a workspace called "
        viewModel.widgetPresentationRequest += 1
    }
}

/// Identifiable wrapper so a workspace *name* can drive `.sheet(item:)`, for the same reason
/// `TaskLogEntry` exists: the persisted model stays free of UI-layer conformances.
private struct SelectedWorkspaceName: Identifiable {
    let name: String
    var id: String { name }
}

/// Shown when an open detail sheet's workspace is no longer in the store. System A, like the sheet
/// it stands in for.
private struct WorkspaceDetailUnavailableView: View {
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(WorkspaceDetailPresentation.unavailableText(name: name))
                .font(SonnyType.itemTitle)
                .foregroundStyle(SonnyTheme.text)
                .multilineTextAlignment(.center)

            Button("Close") {
                dismiss()
            }
            .buttonStyle(CommandCenterRowActionStyle())
            .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 460, height: 200)
        .background(SonnyTheme.ink)
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
    }
}

private struct WorkspaceCard: View {
    let presentation: WorkspaceCardPresentation
    let accent: Color
    let isRunning: Bool
    let open: () -> Void
    let beginTaskHere: () -> Void
    let markAsTeam: () -> Void
    let delete: () -> Void
    let openDetail: () -> Void
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceAvatar(name: presentation.name, color: accent)

            Text(presentation.name)
                .font(SonnyType.avatar)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .padding(.top, 14)

            teamTypeRow
                .padding(.top, 2)

            Text(presentation.taskCountText)
                .font(SonnyType.micro)
                .foregroundStyle(SonnyTheme.muted)
                .padding(.top, 3)

            if let urlsText = presentation.urlsText {
                Label(urlsText, systemImage: "link")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
                    .padding(.top, 12)
            }

            Spacer(minLength: 12)

            HStack {
                WorkspaceAppIconStack(icons: presentation.appIcons, accent: accent)
                Spacer()
                // Labeled like the card's other controls, not icon-only. Delete stays *here* rather
                // than moving into the detail sheet SONNY-41 added: the original reasoning was that
                // building a detail view purely to host a delete button would invent a surface to
                // solve a placement problem, and that argument survives its own premise changing. A
                // detail view now exists — but it exists because a workspace's *boundary* is
                // materially more content than a card can show, which is a reason delete never had.
                // Moving delete into it would be the same invention in reverse: hiding a
                // one-click destructive action one level deeper for symmetry alone.
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(CommandCenterRowActionStyle(tone: .danger))
                .disabled(isRunning)
                .accessibilityLabel("Delete \(presentation.name)")
                .help("Delete \(presentation.name)")
                .confirmationDialog(
                    "Delete “\(presentation.name)”?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete Workspace", role: .destructive) {
                        delete()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // The title already names the workspace; pronouns keep this small dialog
                    // readable (manual pass, 2026-07-30).
                    Text("This deletes its saved apps and URLs. Past task history mentioning this workspace is not deleted.")
                }

                // The "started from its card" half of the founder binding decision. Sits beside
                // Open rather than replacing or branching it — Open still runs the workspace in one
                // click, this one starts nothing and hands the user a bound composer. Deliberately
                // *not* an Open-vs-Switch branch or an "Active" badge: those are the rejected
                // persistent-active-workspace wireframe elements and stay unbuilt.
                Button(action: beginTaskHere) {
                    Text("New task")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel(
                    AgentActivityPresentation.newTaskInWorkspaceLabel(workspaceName: presentation.name)
                )

                Button(action: open) {
                    Text("Open")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel("Open \(presentation.name)")
            }
        }
        .padding(18)
        // Wireframe's measured 190pt fits the no-saved-URL case; the 36pt avatar (replacing an
        // 18pt icon stack in this slot) plus a populated `urlsText` row together exceed that
        // budget, which `.clipShape` below would silently cut off the footer instead of growing
        // the card. Worst case (empty icon-stack fallback + urlsText + full teamTypeRow) measures
        // ~209pt via actual Inter line-height metrics — 216 leaves real margin, not a ~1pt one.
        .frame(maxWidth: 356, minHeight: 190, maxHeight: 216, alignment: .topLeading)
        .background(CommandCenterPalette.cardSurface)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard))
        // Whole-card tap opens the detail sheet, matching the routine row's `openDetail` gesture.
        // Applied *after* `.clipShape` so the hit area is the card's real rounded bounds, and it
        // collides with none of the four controls above — a SwiftUI `Button` consumes its own tap
        // before an ancestor gesture sees it, which is what keeps Delete, New task, Open and Mark
        // as team working unchanged. Purely additive: no existing affordance moved or changed.
        .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard))
        .onTapGesture(perform: openDetail)
        .sonnyPointerCursor()
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens workspace details")
    }

    @ViewBuilder
    private var teamTypeRow: some View {
        switch presentation.effectiveTeamType {
        case .team:
            Text("Team workspace")
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
        case .solo:
            HStack(spacing: 4) {
                // Wireframe specifies 12px for this label (`13-MainAppWorkspaces.svg:225`);
                // `.caption` applied uniformly across the row rather than leaving the "Mark as
                // team" affordance (a real Sonny feature, no wireframe equivalent) at the old 11px.
                Text("Just you")
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)

                if presentation.isDefaultTeamType {
                    Text("·")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)

                    Button(action: markAsTeam) {
                        Text("Mark as team")
                            .font(SonnyType.caption)
                            .foregroundStyle(SonnyTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .sonnyPointerCursor()
                    .sonnyHoverHighlight(cornerRadius: 3)
                    .accessibilityLabel("Mark \(presentation.name) as a team workspace")
                }
            }
        }
    }
}

/// The workspace detail sheet: the surface that makes a boundary something the user can look at.
///
/// **System A throughout** — `SonnyTheme` / `SonnyType` / `SonnyRadius`, flat, opaque, Inter, zero
/// shadows, no translucent material anywhere. It deliberately does *not* borrow the routine-detail
/// view's System-B-inside-System-A treatment: liquid glass was tried for workspace surfaces and
/// explicitly reverted as too visually distracting from content
/// (`docs/sonny-founder-design-decisions.md`, Workspaces). The two token sets are not mixed here.
///
/// **Editing never writes from this view.** Every scope affordance hands the widget composer a
/// ready-made `edit_workspace` command and brings the widget forward; the capability then raises
/// its own consent — tier 2 to add, tier 3 to remove, with the two distinct removal reasons
/// SONNY-40 built. Writing straight to the store from here would be a second write path with its
/// own notions of matching and escalation, and would silently skip the approval the same edit
/// raises from the command line. The one direct write on this sheet is *mark as team*, which is a
/// display badge rather than a boundary and already has its own ratified store call.
private struct WorkspaceDetailView: View {
    let presentation: WorkspaceDetailPresentation
    let accent: Color
    let isRunning: Bool
    let markAsTeam: () -> Void
    let compose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(SonnyType.icon(11, weight: .semibold))
                        .foregroundStyle(SonnyTheme.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 12)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            header
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 20)

            SettingsDivider()
                .padding(.horizontal, 28)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(presentation.sections.enumerated()), id: \.offset) { index, section in
                        if index > 0 {
                            SettingsDivider()
                        }
                        sectionView(section)
                    }

                    if let footnote = presentation.unrestrictedFootnote {
                        SettingsDivider()
                        Text(footnote)
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 460, height: 560, alignment: .top)
        .background(SonnyTheme.ink)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.container)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            WorkspaceAvatar(name: presentation.name, color: accent)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.name)
                    .font(SonnyType.settingsContentTitle)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Text(presentation.teamTypeText)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)

                    Text("·")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)

                    Text(presentation.taskCountText)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)

                    if presentation.isDefaultTeamType {
                        Text("·")
                            .font(SonnyType.caption)
                            .foregroundStyle(SonnyTheme.muted)

                        Button(action: markAsTeam) {
                            Text("Mark as team")
                                .font(SonnyType.caption)
                                .foregroundStyle(SonnyTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .sonnyPointerCursor()
                        .sonnyHoverHighlight(cornerRadius: 3)
                        .accessibilityLabel(presentation.markAsTeamAccessibilityLabel)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func sectionView(_ section: WorkspaceScopeSectionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Label plus control, so it goes through the adaptive row rather than a fixed `HStack`
            // — a narrow, non-fullscreen Command Center is the case a hand-rolled row breaks in.
            SettingsAdaptiveControlRow {
                Text(section.title)
                    .font(SonnyType.itemTitle)
                    .foregroundStyle(SonnyTheme.text)
            } trailing: {
                Button {
                    compose(section.addCommand)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel(section.addAccessibilityLabel)
            }

            // Entries and the not-restricted sentence are *independent*, not an either/or. A
            // dimension whose every entry is inert has rows to show and restricts nothing, and that
            // is exactly the state where the user needs to see both — the rows, marked as not in
            // effect, and the sentence saying the dimension is unrestricted.
            if !section.entries.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // Offset-keyed rather than value-keyed: a legacy `workspaces.json` can hold the
                    // same string twice, and a duplicate `id` silently drops rows.
                    ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                        entryRow(entry)
                    }
                }
            }

            if let notRestrictedText = section.notRestrictedText {
                Text(notRestrictedText)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    /// One stored entry, its removal control, and anything true about it that the value alone does
    /// not say.
    ///
    /// The value is **not truncated**. The ticket's stated reason for rendering entries verbatim is
    /// character-for-character checkability against the entry a consent prompt named, and an elided
    /// middle defeats exactly that for long paths and long URLs — the entries where checking matters
    /// most. Truncation is a convention elsewhere in this file, but elsewhere it is cosmetic. It
    /// wraps instead, and is selectable so it can be copied and compared.
    ///
    /// `SettingsAdaptiveControlRow` rather than a hand-rolled `HStack`, per
    /// `.claude/rules/macagent-ui-conventions.md`, matching the section header beside it.
    private func entryRow(_ entry: WorkspaceScopeEntryPresentation) -> some View {
        SettingsAdaptiveControlRow {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.value)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let inertNote = entry.inertNote {
                    Text(inertNote)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let sharedRemovalNote = entry.sharedRemovalNote {
                    Text(sharedRemovalNote)
                        .font(SonnyType.micro)
                        .foregroundStyle(SonnyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } trailing: {
            Button {
                compose(entry.removeCommand)
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .buttonStyle(CommandCenterRowActionStyle(tone: .danger))
            .disabled(isRunning)
            .accessibilityLabel(entry.removeAccessibilityLabel)
            .help(entry.sharedRemovalNote ?? entry.removeAccessibilityLabel)
        }
    }
}

enum WorkspaceAvatarInitial {
    static func from(name: String) -> String {
        guard let firstCharacter = name.trimmingCharacters(in: .whitespaces).first else {
            return "?"
        }
        return String(firstCharacter).uppercased()
    }
}

private struct WorkspaceAvatar: View {
    let name: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .fill(color.opacity(0.18))
            Text(WorkspaceAvatarInitial.from(name: name))
                .font(SonnyType.avatar)
                .foregroundStyle(color)
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}

private struct WorkspaceAppIconStack: View {
    let icons: [WorkspaceAppIconPresentation]
    let accent: Color

    private let iconSize: CGFloat = 18
    private let overlap: CGFloat = 10
    private let maxVisible = 2

    var body: some View {
        if icons.isEmpty {
            RoundedRectangle(cornerRadius: SonnyRadius.workspaceCard)
                .fill(accent.opacity(0.18))
                .overlay(
                    Image(systemName: "rectangle.3.group")
                        .foregroundStyle(accent)
                )
                .frame(width: 36, height: 36)
        } else {
            let visible = Array(icons.prefix(maxVisible))
            ZStack(alignment: .leading) {
                // Reversed paint order: the wireframe draws the leftmost icon last (on top) —
                // ZStack paints later ForEach elements on top, so iterate index 1 before index 0
                // while keeping each icon's own offset tied to its original (unreversed) index.
                ForEach(Array(visible.enumerated().reversed()), id: \.offset) { index, icon in
                    iconTile(for: icon)
                        .offset(x: CGFloat(index) * overlap)
                }
            }
            .frame(
                width: iconSize + CGFloat(max(visible.count - 1, 0)) * overlap,
                height: iconSize,
                alignment: .leading
            )
        }
    }

    @ViewBuilder
    private func iconTile(for icon: WorkspaceAppIconPresentation) -> some View {
        // Wireframe (`13-MainAppWorkspaces.svg:233,236`) renders real app icons bare, full-bleed,
        // with no background chip or border behind them — only the no-icon-resolved fallback
        // needs a visible tile to sit inside.
        if let nsImage = icon.icon {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: iconSize, height: iconSize)
                .background(SonnyTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SonnyTheme.cardBorder, lineWidth: 1)
                )
                .accessibilityHidden(true)
        }
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
        .padding(.leading, 30)
        .padding(.trailing, 24)
        .frame(height: 36)
    }
}

private struct CollectionEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(SonnyType.icon(20))
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

private struct CommandCenterHeaderActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.itemTitle)
            .foregroundStyle(SonnyTheme.text.opacity(configuration.isPressed ? 0.7 : 0.92))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CommandCenterPalette.buttonSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(SonnyTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
            .sonnyPointerCursor()
            .sonnyHoverHighlight()
            .opacity(isEnabled ? 1 : 0.46)
    }
}

private struct CommandCenterRowActionStyle: ButtonStyle {
    /// `.danger` carries the same treatment "Delete Local Data" and the routine panel's danger
    /// buttons already use — danger-tinted label and border over the normal surface — at this
    /// style's own row-action scale, rather than importing `SonnyButtonStyle`'s larger filled
    /// block into a card footer built around 23pt controls.
    enum Tone {
        case neutral
        case danger
    }

    @Environment(\.isEnabled) private var isEnabled
    var tone: Tone = .neutral

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.microEmphasis)
            .foregroundStyle(foreground.opacity(configuration.isPressed ? 0.68 : 0.92))
            .padding(.horizontal, 11)
            .frame(height: 23)
            .background(CommandCenterPalette.buttonSurface)
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.container)
                    .stroke(border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
            .sonnyPointerCursor()
            .sonnyHoverHighlight()
            .opacity(isEnabled ? 1 : 0.46)
    }

    private var foreground: Color {
        switch tone {
        case .neutral:
            return SonnyTheme.text
        case .danger:
            return SonnyTheme.danger
        }
    }

    private var border: Color {
        switch tone {
        case .neutral:
            return SonnyTheme.cardBorder
        case .danger:
            return SonnyTheme.danger.opacity(0.45)
        }
    }
}

private enum CommandCenterPalette {
    static let collectionSurface = SonnyTheme.collectionSurface
    static let cardSurface = SonnyTheme.surfaceRaised
    static let buttonSurface = SonnyTheme.surfaceRaised
    // Flat #242E52 per the wireframe (not a translucent accent tint) — SonnyTheme.chartBarMuted
    // is already exactly this hex, just previously unused here.
    static let routineIconBackground = SonnyTheme.chartBarMuted
    static let routineIconForeground = SonnyTheme.accent
    // Wireframe assigns each workspace card a distinct avatar color (`13-MainAppWorkspaces.svg`:
    // Personal=accent, Build in Public=warning, Client Work=success) rather than one fixed color
    // for every card — cycled by grid position, same pattern as Insights' workspace-breakdown swatches.
    static let workspaceAvatarColors: [Color] = [SonnyTheme.accent, SonnyTheme.warning, SonnyTheme.success]
}

private struct CommandCenterPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SonnyType.pageTitle)
                .foregroundStyle(SonnyTheme.text)
            if let subtitle {
                Text(subtitle)
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
            }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case preferences
    case notifications
    case usage
    case security
    case data

    var id: Self { self }

    var title: String {
        switch self {
        case .preferences:
            return "Preferences"
        case .notifications:
            return "Notifications"
        case .usage:
            return "Usage"
        case .security:
            return "Security & Access"
        case .data:
            return "Data"
        }
    }
}

/// Settings, presented as its own dialog (2026-07-18 direction, matching the Claude desktop app's
/// Settings pattern) rather than a sidebar destination — opened from `CommandCenterView`'s bottom
/// account row. The 4-category sidebar (My Account header, then plain unbadged/un-iconed rows) is
/// the wireframe's own `10-MainAppSettings.svg` structure almost exactly, with "Usage" standing in
/// for that wireframe's "Profile" row per direct instruction (identity now lives in the account
/// row that opens this dialog, so a separate in-dialog Profile page would be redundant).
struct SettingsDialogView: View {
    @ObservedObject var viewModel: AgentViewModel
    @Binding var isPresented: Bool
    @State private var selection: SettingsSection = .preferences

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(SonnyType.icon(11, weight: .semibold))
                        .foregroundStyle(SonnyTheme.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 12)
                .accessibilityLabel("Close Settings")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            HStack(alignment: .top, spacing: 0) {
                settingsSidebar

                Rectangle()
                    .fill(SonnyTheme.border)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                ScrollView {
                    Group {
                        switch selection {
                        case .preferences:
                            SettingsPreferencesPage(viewModel: viewModel)
                        case .notifications:
                            SettingsNotificationsPage()
                        case .usage:
                            SettingsUsagePage()
                        case .security:
                            SettingsSecurityAccessPage(viewModel: viewModel)
                        case .data:
                            SettingsDataPage(viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SonnyTheme.collectionSurface)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Widened from an initial 760pt (2026-07-18 review): at 760pt, the content pane (dialog
        // width minus the 226pt sidebar minus 80pt of padding) left "Use pointer cursors" too
        // narrow to keep its description on one line, so it fell back to `SettingsAdaptiveControlRow`'s
        // stacked layout while "Display full names" (a shorter description) stayed inline —
        // an inconsistent, mismatched look across two rows in the same section.
        .frame(width: 880, height: 620)
        .background(SonnyTheme.ink)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.container)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(SonnyType.icon(12, weight: .medium))
                Text("Settings")
                    .font(SonnyType.itemTitle)
            }
            .foregroundStyle(SonnyTheme.muted)
            .padding(.horizontal, 11)
            .padding(.bottom, 2)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Text(section.title)
                        .font(SonnyType.body)
                        .foregroundStyle(selection == section ? SonnyTheme.text : SonnyTheme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: SonnyRadius.container)
                                .fill(selection == section ? SonnyTheme.surfaceRaised : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight()
                .accessibilityLabel(section.title)
            }

            Spacer()
        }
        .padding(14)
        .frame(width: 226, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(SonnyTheme.border)
            .frame(height: 1)
    }
}

/// Placeholder (2026-07-18) — a real, separate dialog from `SettingsDialogView`, but its content
/// is deliberately undecided ("I will need to plan what it does later"). Reuses the same close-X
/// chrome as the Settings dialog for visual consistency between the account row's two menu items.
struct ProfileDialogView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(SonnyType.icon(11, weight: .semibold))
                        .foregroundStyle(SonnyTheme.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 12)
                .accessibilityLabel("Close Profile")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 6) {
                Text("Profile")
                    .font(SonnyType.settingsContentTitle)
                    .foregroundStyle(SonnyTheme.text)
                Text("Not designed yet — check back soon.")
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(40)
        }
        .frame(width: 480, height: 360)
        .background(SonnyTheme.ink)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.container)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
    }
}

private struct SettingsPreferencesPage: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Preferences", subtitle: "Manage your preferences")
                .padding(.bottom, 20)

            SettingsDivider()

            SettingsSectionBlock(title: "Display") {
                SettingsToggleRow(
                    title: "Display full names",
                    detail: "Show full names of users instead of shorter display names.",
                    isOn: $viewModel.displayFullNames
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Use pointer cursors",
                    detail: "Change the cursor to a pointer when hovering over any interactive element.",
                    isOn: $viewModel.usePointerCursors
                )
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            SettingsDivider()

            SettingsSectionBlock(title: "Theme") {
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(
                        title: "Interface theme",
                        detail: "Select or customize your interface color scheme."
                    )
                } trailing: {
                    SettingsThemeDropdown()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
    }
}

private struct SettingsSecurityAccessPage: View {
    @ObservedObject var viewModel: AgentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Security & Access", subtitle: "Review local readiness")
                .padding(.bottom, 20)

            SettingsDivider()

            // Previously a one-time dismissible notice inside the now-removed menu-bar popover —
            // that was this setting's only UI anywhere, and dismissing it was the actual action
            // that let clipboard monitoring start (see AgentViewModel.refreshClipboardHistoryNotice's
            // `noticeDismissed && isEnabled` gate). A persistent Settings toggle replaces it here,
            // reusing the same commit path (`applyClipboardHistoryNoticeChoice`) so every interaction
            // still both persists the choice and starts/stops monitoring, not just cosmetically
            // flips a switch.
            SettingsSectionBlock(title: "Clipboard History") {
                SettingsToggleRow(
                    title: "Watch clipboard history",
                    detail: "Sonny can watch copied text system-wide, excluding password-manager entries flagged ConcealedType or TransientType, and keeps a capped local history.",
                    isOn: Binding(
                        get: { viewModel.clipboardHistoryEnabled },
                        set: { newValue in
                            viewModel.clipboardHistoryEnabled = newValue
                            viewModel.applyClipboardHistoryNoticeChoice()
                        }
                    )
                )
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            SettingsDivider()

            SettingsSectionBlock(title: "Permission Readiness") {
                VStack(alignment: .leading, spacing: 14) {
                    PermissionReadinessRows(items: viewModel.permissionItems)

                    Button {
                        viewModel.refreshPermissions()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(CommandCenterRowActionStyle())
                    .accessibilityLabel("Refresh permission readiness")
                }
                .padding(.vertical, 16)
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: 760, alignment: .topLeading)
        .onAppear {
            viewModel.refreshPermissions()
        }
    }
}

/// Split out of Security & Access into its own page (2026-07-18 direction) — deleting local data
/// is a distinct, destructive action that deserves its own dedicated spot, not a subsection of a
/// permissions-readiness page.
private struct SettingsDataPage: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var showDeleteLocalDataConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Data", subtitle: "Manage Sonny's local data")
                .padding(.bottom, 20)

            SettingsDivider()

            SettingsSectionBlock(title: "Local Data") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsAdaptiveControlRow {
                        // Single trash icon now lives on the button itself — a second one here
                        // next to the label made the row read as too bold/heavy (2026-07-18).
                        SettingsControlLabel(
                            title: "Delete Sonny local data",
                            detail: "Saved routines, workspaces, clipboard history, snippets, recent artifacts, Shortcut run history, task history, and clipboard settings."
                        )
                    } trailing: {
                        Button {
                            showDeleteLocalDataConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(SonnyButtonStyle(tone: .danger, width: 96))
                        .disabled(viewModel.isRunning)
                        .help("Delete local Sonny data")
                    }

                    LocalDataDeletionStatusMessage(message: viewModel.localDataDeletionStatusMessage)
                }
                .padding(.vertical, 16)
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: 760, alignment: .topLeading)
        .localDataDeletionConfirmationDialog(isPresented: $showDeleteLocalDataConfirmation, viewModel: viewModel)
    }
}

/// Placeholder content (2026-07-18) — real content for this tab is pending direction on what it
/// should actually show; see docs/sonny-ui-backend-gaps.md. Deliberately honest about having
/// nothing configurable yet rather than inventing controls with no real behavior behind them.
private struct SettingsNotificationsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Notifications", subtitle: "Manage how Sonny notifies you")
                .padding(.bottom, 20)

            SettingsDivider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing to configure yet")
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                Text("Sonny uses native macOS notifications today — there are no in-app notification preferences yet.")
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
    }
}

/// Placeholder content (2026-07-18) — real content for this tab is pending direction on what it
/// should actually show; see docs/sonny-ui-backend-gaps.md. Sonny already records approximate
/// per-task usage (`TaskUsageRecorder`), but there's no aggregate summary view anywhere yet, and
/// no credits/billing system to weigh it against — showing fabricated numbers here would be worse
/// than showing nothing.
private struct SettingsUsagePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageTitle(title: "Usage", subtitle: "See how much you've used Sonny")
                .padding(.bottom, 20)

            SettingsDivider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Usage summary coming soon")
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                Text("Sonny tracks approximate usage per task today, but a full summary isn't built yet.")
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: 700, alignment: .topLeading)
    }
}

private struct SettingsAdaptiveControlRow<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                leading
                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                leading
                    .frame(maxWidth: .infinity, alignment: .leading)

                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
    }
}

private struct SettingsControlLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsPageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(SonnyType.settingsContentTitle)
                .foregroundStyle(SonnyTheme.text)
            Text(subtitle)
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.muted)
        }
        .padding(.bottom, 2)
    }
}

// Flat by design — the wireframe's Preferences/Privacy body is one continuous bordered panel
// (provided by the caller's ScrollView background) with hairline dividers between blocks and
// between rows within a block, not per-section cards. `SettingsSectionBlock` only groups a
// title with its rows now; `SettingsDivider()` between blocks/rows is the caller's job, since
// this view has no way to know how many un-typed children `content` actually contains.
private struct SettingsSectionBlock<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(SonnyType.settingsSectionLabel)
                .foregroundStyle(SonnyTheme.text)

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsAdaptiveControlRow {
            SettingsControlLabel(title: title, detail: detail)
        } trailing: {
            SonnySettingsToggle(isOn: $isOn)
                .accessibilityLabel(title)
        }
    }
}

private struct SonnySettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: SonnyRadius.pill)
                    .fill(isOn ? SonnyTheme.accent : SonnyTheme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: SonnyRadius.pill)
                            .stroke(isOn ? SonnyTheme.accent : SonnyTheme.cardBorder, lineWidth: 1)
                    )

                Circle()
                    .fill(SonnyTheme.text)
                    .frame(width: 14, height: 14)
                    .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 0)
                    .padding(3)
            }
            .frame(width: 30, height: 20)
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight(cornerRadius: SonnyRadius.pill)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Wireframe's rendered state (`10-MainAppSettings.svg`) is a single closed dropdown — only
/// "Dark" ever appears as visible text; "Light"/a third option live in the CSS export's hidden
/// expand-list, not as permanently visible swatches. A native `Menu` matches that affordance
/// (closed by default, opens on click) rather than three always-visible buttons.
private struct SettingsThemeDropdown: View {
    var body: some View {
        Menu {
            Button("Dark") {}
            Button("Light (Soon)") {}
                .disabled(true)
            Button("System (Soon)") {}
                .disabled(true)
        } label: {
            // No explicit trailing chevron here — `Menu` already renders its own native
            // disclosure indicator, so an added one showed up as a second, redundant arrow
            // (2026-07-18). "Aa" dropped too, per direct instruction — not needed.
            HStack(spacing: 6) {
                Text("Dark")
                    .font(SonnyType.body)
                    .foregroundStyle(SonnyTheme.text)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(width: 200, height: 37)
            .background(
                RoundedRectangle(cornerRadius: SonnyRadius.themeSwatch)
                    .fill(Color(red: 0x1D / 255, green: 0x1F / 255, blue: 0x24 / 255))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SonnyRadius.themeSwatch)
                    .stroke(Color(red: 0x2A / 255, green: 0x2C / 255, blue: 0x31 / 255), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        // Applied after `.menuStyle`, not inside the label — wrapping the whole `Menu` rather
        // than adding another view inside its label's HStack, to stay well clear of the
        // composite-label rendering issue documented on `profileRow`.
        .sonnyHoverHighlight(cornerRadius: SonnyRadius.themeSwatch)
        .accessibilityLabel("Interface theme, Dark selected. Light and System coming soon.")
    }
}
