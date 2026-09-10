import Foundation
import MacAgentCore
import SwiftUI

/// The redesigned "receipt" of one completed run, shown in the Tasks page's pane beside the list
/// rather than in a sheet (row 11, the founders' ask of 2026-09-09: "the finished task is viewed in
/// a pane beside the list, Mail-style, instead of a sheet; the receipt is redesigned").
///
/// What it renders is still the static receipt `TaskLogDetailDialog` used to show — command,
/// outcome, timestamps, workspace, what it produced — not a live replay of what happened step by
/// step. That 2026-07-18 direction ("logs + summary + activity should just be a flow as to how that
/// thing worked under the hood") is unchanged; only where the receipt lives has moved.
struct TaskReceiptView: View {
    @ObservedObject var viewModel: AgentViewModel
    let record: CompletedTaskRecord?
    /// Resolved by the caller before this view exists, and re-resolved by the caller whenever the
    /// selection changes — never looked up in here. See `TaskScreenRecordState`'s doc comment for
    /// why that is the whole design; it is unchanged from the sheet this pane replaces.
    let screenRecord: TaskScreenRecordState
    /// Driven by both this pane's own overflow menu and the page's ⌫ shortcut, so the two share one
    /// dialog rather than each owning a copy that could show different words for the same task.
    @Binding var showDeleteConfirmation: Bool
    /// Clears the page's selection (the founders' ask of 2026-09-09: "there is no way to close that
    /// view when a task is chosen"). No `.keyboardShortcut(.cancelAction)` on the control this
    /// drives — the page already clears the selection on Escape through its own `.onExitCommand`,
    /// and a second Escape-bound control here would leave SwiftUI's key routing to decide which one
    /// fires, which this pane has no way to test.
    let onClose: () -> Void
    let onDeleteTask: () -> Void
    let onDeleteScreenRecord: () -> Void

    @State private var showScreenRecordDeleteConfirmation = false
    @State private var planDetail: StoredTaskPlanDetail?

    var body: some View {
        if let record {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(for: record)
                    actionsRow(for: record)
                    resultSection(for: record)
                    plannedSection
                    visionSessionSection
                }
                .padding(SonnySpacing.xxl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Loaded once per selection rather than read as a computed property: a plain `var`
            // would decrypt `TaskPlanDetailStore` on every render this pane happens to take, for a
            // file the user is not looking at any differently than a moment ago.
            .task(id: record.id) {
                planDetail = viewModel.storedPlanDetail(for: record)
            }
        } else {
            CollectionEmptyState(
                systemImage: "checkmark.circle",
                title: "No task selected",
                message: "Choose a task from the list.",
                minHeight: 180
            )
        }
    }

    // MARK: - Header

    private func header(for record: CompletedTaskRecord) -> some View {
        HStack(alignment: .top, spacing: SonnySpacing.md) {
            VStack(alignment: .leading, spacing: SonnySpacing.sm) {
                Text(record.command.isEmpty ? "Untitled task" : record.command.sentenceCapitalized)
                    .font(SonnyType.settingsContentTitle)
                    .foregroundStyle(SonnyTheme.text)
                    .lineLimit(3)
                    .help(record.command)

                // One line where the pane is wide enough, two where it is not; every phrase is
                // `fixedSize`, so "Completed in 8s" can never break in the middle (founder,
                // 2026-09-10: the pane read as cluttered, and this row was half of why).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SonnySpacing.sm) {
                        SonnyBadge(text: statusBadgeText(for: record), tone: statusBadgeTone(for: record))
                        metadataPhrases(for: record)
                    }
                    VStack(alignment: .leading, spacing: SonnySpacing.xs) {
                        SonnyBadge(text: statusBadgeText(for: record), tone: statusBadgeTone(for: record))
                        HStack(spacing: SonnySpacing.sm) {
                            metadataPhrases(for: record)
                        }
                    }
                }
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
            }

            Spacer(minLength: SonnySpacing.md)

            closeButton
        }
        .padding(.bottom, SonnySpacing.xl)
    }

    /// The phrases after the badge, each on one line: when it started, how long it took, the
    /// workspace, and "Scheduled" when a routine ran it.
    @ViewBuilder
    private func metadataPhrases(for record: CompletedTaskRecord) -> some View {
        Text(TaskHistoryDateFormatter.relativeTimestamp(for: record.startedAt, now: Date()))
            .fixedSize()
        Text("·")
        Text(taskStatusText(for: record))
            .fixedSize()
        if let workspaceName = record.workspaceName {
            Text("·")
            Text(workspaceName)
                .lineLimit(1)
        }
        if record.effectiveTrigger == .scheduled {
            Text("·")
            Text("Scheduled")
                .fixedSize()
        }
    }

    /// The `SonnyDialogCloseButton` shape (`ContentView.swift`), rebuilt rather than reused: that
    /// control's own `.keyboardShortcut(.cancelAction)` would compete with the page's
    /// `.onExitCommand`, which already clears the selection on Escape (`onClose`'s own doc comment).
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(SonnyType.icon(SonnyMetrics.iconButton, weight: .semibold))
                .foregroundStyle(SonnyTheme.muted)
                .frame(width: SonnyMetrics.controlRegular, height: SonnyMetrics.controlRegular)
                .contentShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
        }
        .buttonStyle(.plain)
        .sonnyPointerCursor()
        .sonnyHoverHighlight(cornerRadius: SonnyRadius.control)
        .accessibilityLabel("Close task")
    }

    private func statusBadgeTone(for record: CompletedTaskRecord) -> SonnyBadge.Tone {
        switch record.outcomeStatus {
        case .completed: return .success
        case .failed: return .danger
        case .canceled: return .neutral
        default: return .neutral
        }
    }

    /// The wireframe's own section vocabulary ("Done", "Failed", "Canceled") rather than a second
    /// set of words for the same three outcomes.
    private func statusBadgeText(for record: CompletedTaskRecord) -> String {
        switch record.outcomeStatus {
        case .completed: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        default: return record.outcomeStatus.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - Actions

    /// Leading: what you can do *with* the task. Trailing: what you can do *to* it — kept apart the
    /// same way the sheet this pane replaces kept "Run again"/"Follow up" away from "Delete task",
    /// so an ordinary action and a destructive one are never adjacent and read as two kinds of
    /// thing rather than a row of similar-looking options.
    ///
    /// A button's label is never truncated: each is `fixedSize`, and `ViewThatFits` drops to two
    /// rows when the pane is too narrow for one (founder, 2026-09-10: "Run ag…", "Edit an…" and
    /// "Follow…" were the other half of what read as clutter).
    private func actionsRow(for record: CompletedTaskRecord) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SonnySpacing.sm) {
                taskActionButtons(for: record)
                Spacer(minLength: SonnySpacing.md)
                moreActionsMenu(for: record)
            }
            VStack(alignment: .leading, spacing: SonnySpacing.sm) {
                HStack(spacing: SonnySpacing.sm) {
                    taskActionButtons(for: record)
                }
                HStack {
                    Spacer(minLength: 0)
                    moreActionsMenu(for: record)
                }
            }
        }
        .padding(.bottom, SonnySpacing.xl)
    }

    @ViewBuilder
    private func taskActionButtons(for record: CompletedTaskRecord) -> some View {
        if TaskDetailPresentation.showsTaskActions(for: record) {
            Button(TaskDetailPresentation.runAgainActionLabel) {
                viewModel.runTaskAgain(record)
            }
            .buttonStyle(SonnyButtonStyle(tone: .primary, size: .small))
            .fixedSize()
            .sonnyPointerCursor()
            .disabled(viewModel.isTaskInFlight)
            .accessibilityLabel(TaskDetailPresentation.runAgainActionLabel)
            .help(TaskDetailPresentation.runAgainActionLabel)

            Button(TaskDetailPresentation.editAndRunActionLabel) {
                viewModel.editTaskAndRunAgain(record)
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary, size: .small))
            .fixedSize()
            .sonnyPointerCursor()
            .disabled(viewModel.isTaskInFlight)
            .accessibilityLabel(TaskDetailPresentation.editAndRunActionLabel)
            .help(TaskDetailPresentation.editAndRunActionLabel)

            Button(FollowUpPresentation.actionLabel) {
                viewModel.followUpOnTask(record)
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary, size: .small))
            .fixedSize()
            .sonnyPointerCursor()
            .disabled(viewModel.isTaskInFlight)
            .accessibilityLabel(FollowUpPresentation.actionLabel)
            .help(FollowUpPresentation.actionLabel)
        }
    }

    private func moreActionsMenu(for record: CompletedTaskRecord) -> some View {
        SonnyOverflowMenu(accessibilityLabel: "More actions for this task") {
            Button(TaskDeletePresentation.taskActionLabel, role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .confirmationDialog(
            TaskDeletePresentation.taskConfirmationTitle(for: record),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(TaskDeletePresentation.taskConfirmButtonLabel, role: .destructive, action: onDeleteTask)
            Button("Cancel", role: .cancel) {}
        } message: {
            // Reads the resolved state, which this view already has, rather than the record's
            // bare link — the same reason the old sheet's message did.
            if let message = TaskDeletePresentation.taskConfirmationMessage(for: screenRecord) {
                Text(message)
            }
        }
    }

    // MARK: - What this task produced

    /// **Full length, no cap** (row 11) — the pane scrolls as a whole now, so the fixed-height
    /// sheet's line-count estimate and its own inner scroll area have nothing left to size.
    @ViewBuilder
    private func resultSection(for record: CompletedTaskRecord) -> some View {
        if let resultText = TaskDetailPresentation.resultText(for: record) {
            SettingsDivider()
                .padding(.bottom, SonnySpacing.lg)

            VStack(alignment: .leading, spacing: SonnySpacing.sm) {
                Text(TaskDetailPresentation.resultSectionTitle)
                    .font(SonnyType.settingsSectionLabel)
                    .foregroundStyle(SonnyTheme.text)

                Text(resultText)
                    .font(SonnyType.body)
                    .lineSpacing(SonnySpacing.xs / 2)
                    .foregroundStyle(SonnyTheme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, SonnySpacing.xl)
        }
    }

    // MARK: - What Sonny planned

    /// The stored plan's summary only — never its steps. Those stay context for the planner, per
    /// `TaskDetailPresentation.plannedSectionTitle`'s doc comment and the founder decision it cites;
    /// see `founder_questions` for whether that should change.
    @ViewBuilder
    private var plannedSection: some View {
        if let summary = planDetail?.planSummary, !summary.isEmpty {
            SettingsDivider()
                .padding(.bottom, SonnySpacing.lg)

            VStack(alignment: .leading, spacing: SonnySpacing.sm) {
                Text(TaskDetailPresentation.plannedSectionTitle)
                    .font(SonnyType.settingsSectionLabel)
                    .foregroundStyle(SonnyTheme.text)

                Text(summary)
                    .font(SonnyType.body)
                    .lineSpacing(SonnySpacing.xs / 2)
                    .foregroundStyle(SonnyTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, SonnySpacing.xl)
        }
    }

    // MARK: - What Sonny did on screen

    /// The sheet's `visionSessionSection`, moved over intact: the unreadable arm, the app name and
    /// action count, the entry rows. What changed is only where the delete action lives — inside a
    /// `SonnyOverflowMenu` at this header's trailing edge (row 11's "hamburger menu for … especially
    /// destructive actions" ask) rather than an inline danger button — and that the entry list no
    /// longer carries its own capped `ScrollView`, since the whole pane scrolls now.
    @ViewBuilder
    private var visionSessionSection: some View {
        if TaskDeletePresentation.showsScreenRecordSection(screenRecord) {
            SettingsDivider()
                .padding(.bottom, SonnySpacing.lg)

            VStack(alignment: .leading, spacing: SonnySpacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(TaskDeletePresentation.screenRecordSectionTitle)
                        .font(SonnyType.settingsSectionLabel)
                        .foregroundStyle(SonnyTheme.text)

                    Spacer(minLength: SonnySpacing.md)

                    if TaskDeletePresentation.showsScreenRecordDeleteAction(screenRecord) {
                        SonnyOverflowMenu(accessibilityLabel: "More actions for what Sonny did on screen") {
                            Button(TaskDeletePresentation.screenRecordActionLabel, role: .destructive) {
                                showScreenRecordDeleteConfirmation = true
                            }
                        }
                        .confirmationDialog(
                            TaskDeletePresentation.screenRecordConfirmationTitle,
                            isPresented: $showScreenRecordDeleteConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(
                                TaskDeletePresentation.screenRecordConfirmButtonLabel,
                                role: .destructive,
                                action: onDeleteScreenRecord
                            )
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(TaskDeletePresentation.screenRecordConfirmationMessage)
                        }
                    }
                }

                if case .unreadable(let journalLoadFailure) = screenRecord {
                    // A load failure is a real, visible problem and gets the load-failure wording,
                    // never silently-empty state — the repo's own rule.
                    Text(journalLoadFailure)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .present(let session) = screenRecord {
                    Text("\(session.appDisplayName) · \(session.entries.count) action\(session.entries.count == 1 ? "" : "s")")
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(session.entries.enumerated()), id: \.offset) { _, entry in
                            visionEntryRow(entry)
                            SettingsDivider()
                        }
                    }
                }
            }
            .padding(.bottom, SonnySpacing.xl)
        }
    }

    private func visionEntryRow(_ entry: VisionActionJournalEntry) -> some View {
        VStack(alignment: .leading, spacing: SonnySpacing.xs) {
            HStack(spacing: SonnySpacing.sm) {
                Text(entry.actionType.capitalized)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.text)
                if !entry.targetDescription.isEmpty {
                    Text(entry.targetDescription)
                        .font(SonnyType.caption)
                        .foregroundStyle(SonnyTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: SonnySpacing.sm)
                Text("\(entry.riskTier.displayName) · \(approvalText(entry.approvalState))")
                    .font(SonnyType.mono)
                    .foregroundStyle(entry.consequence == .advisory ? SonnyTheme.muted : SonnyTheme.warning)
                    .lineLimit(1)
            }
            Text(entry.observationAfter)
                .font(SonnyType.caption)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, SonnySpacing.sm)
        .accessibilityElement(children: .combine)
    }

    private func approvalText(_ state: VisionActionJournalEntry.ApprovalState) -> String {
        switch state {
        case .ranWithoutAsking:
            return "ran without asking"
        case .approved:
            return "you approved it"
        case .coveredByEarlierApproval:
            return "covered by your earlier approval"
        }
    }
}
