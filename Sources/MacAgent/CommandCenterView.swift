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
            HStack(spacing: 0) {
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

                    HStack(spacing: 6) {
                        Text("Sonny")
                            .font(SonnyType.sidebarWordmark)
                            .foregroundStyle(SonnyTheme.text)
                        // Wireframe shows a dropdown affordance next to the wordmark
                        // (`9-MainAppHomeScreen.svg:33`). Built as static chrome matching the
                        // wireframe's visual — no menu exists behind it; nothing in Sonny's
                        // current scope defines what it would open.
                        Image(systemName: "chevron.down")
                            .font(SonnyType.icon(9, weight: .semibold))
                            .foregroundStyle(SonnyTheme.muted)
                    }
                }

                Spacer(minLength: 8)

                // Wireframe search affordance (`9-MainAppHomeScreen.svg:38`). Same treatment as
                // the chevron above — static, no search feature exists behind it yet.
                Image(systemName: "magnifyingglass")
                    .font(SonnyType.icon(13, weight: .medium))
                    .foregroundStyle(SonnyTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.sidebarIcon))
                    .sonnySidebarIconShadow()
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

    var body: some View {
        VStack(spacing: 0) {
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

                        // Wireframe has exactly three status groups (In Progress / Done /
                        // Canceled, `9-MainAppHomeScreen.svg`) — per direct feedback (2026-07-18),
                        // the live-running task now renders as this list's own "In Progress"
                        // group instead of a separate block above it, and there's no separate
                        // idle "No active task" placeholder; the group simply isn't there when
                        // nothing is running. Gated on `isRunning || isAwaitingApproval`
                        // specifically, not the broader `hasTaskActivity` — once a run finishes,
                        // it belongs in the Done/Canceled history below, not lingering up here.
                        if viewModel.isRunning || viewModel.isAwaitingApproval {
                            InProgressTaskGroup(viewModel: viewModel)
                        }

                        TaskHistoryGroupedPanel(
                            records: viewModel.taskHistoryRecords,
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
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            CommandCenterComposerFooter(viewModel: viewModel)
        }
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
/// an approval UI. No approval/permission controls live here either — per direct instruction,
/// that's meant to surface as a system notification instead (the wireframes already have 2
/// notification designs for exactly this; not yet built, see docs/sonny-ui-backend-gaps.md). In
/// the meantime the menu-bar popover still renders the full `AgentTaskActivityView`, including
/// the real Approve/Deny controls, since it observes the same shared `AgentViewModel` — a pending
/// approval is never actually unreachable, just not visible on this page.
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

    private var statusText: String {
        let command = viewModel.command.isEmpty
            ? "Untitled task"
            : viewModel.command.sentenceCapitalized.truncatedForRowDisplay()
        return viewModel.isAwaitingApproval ? "Waiting for approval: \(command)" : "Running: \(command)"
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
private struct TaskStatusGroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(SonnyType.itemTitle)
                .foregroundStyle(SonnyTheme.sidebarNavText)
            Text("\(count)")
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskStatusGroupHeader(title: "In Progress", count: 1)

            CommandCenterRunningIndicator(viewModel: viewModel)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
        }
    }
}

private struct TaskHistoryGroupedPanel: View {
    let records: [CompletedTaskRecord]
    let onSelect: (CompletedTaskRecord) -> Void

    private var sections: [TaskHistorySection] {
        TaskHistoryGrouping.groupedByOutcome(records: records)
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
                        TaskStatusGroupHeader(title: section.title, count: section.records.count)

                        VStack(spacing: 0) {
                            ForEach(section.records, id: \.startedAt) { record in
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

    init(routine: StoredRoutine) {
        name = routine.name

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
        // All-time, `.completed`-only (matching the Insights breakdown's own definition of "a real
        // task happened here") — not windowed to the breakdown's trailing 30 days, since this is a
        // simple running count, not a recent-trend chart, and the store's 10,000-record cap is
        // already generously large for this to matter at v1 scale.
        taskCount = taskHistoryRecords.filter { $0.outcomeStatus == .completed && $0.workspaceName == workspace.name }.count
        taskCountText = "\(taskCount) task\(taskCount == 1 ? "" : "s")"
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

private struct RoutinesView: View {
    @ObservedObject var viewModel: AgentViewModel
    @State private var composerFocusRequest = 0
    @State private var selectedRoutine: StoredRoutine?

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
                                        run: { viewModel.runRoutineWidget(routine) },
                                        openDetail: { selectedRoutine = routine }
                                    )
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

                if viewModel.isRunning || viewModel.isAwaitingApproval {
                    CommandCenterRunningIndicator(viewModel: viewModel)
                }
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
        .sheet(item: $selectedRoutine) { routine in
            RoutineDetailView(routine: routine)
        }
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

                Button(action: run) {
                    Text("Run")
                }
                .buttonStyle(CommandCenterRowActionStyle())
                .disabled(isRunning)
                .accessibilityLabel("Run \(presentation.name)")
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
    @State private var composerFocusRequest = 0

    private let columns = [
        GridItem(.adaptive(minimum: 356, maximum: 356), spacing: 14, alignment: .top)
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
                                        markAsTeam: { viewModel.markWorkspaceAsTeam(workspace) }
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

                if viewModel.isRunning || viewModel.isAwaitingApproval {
                    CommandCenterRunningIndicator(viewModel: viewModel)
                }
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
        .onAppear {
            viewModel.refreshTaskHistory()
        }
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
    let markAsTeam: () -> Void

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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SonnyType.microEmphasis)
            .foregroundStyle(SonnyTheme.text.opacity(configuration.isPressed ? 0.68 : 0.92))
            .padding(.horizontal, 11)
            .frame(height: 23)
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

private enum CommandCenterPalette {
    static let collectionSurface = SonnyTheme.collectionSurface
    static let cardSurface = SonnyTheme.surfaceRaised
    static let buttonSurface = SonnyTheme.surfaceRaised
    static let composerSurface = SonnyTheme.collectionSurface
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
