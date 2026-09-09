import MacAgentCore
import SwiftUI

// MARK: - Routine detail view

/// Per `docs/sonny-founder-design-decisions.md`'s Routines section: clicking into a routine opens
/// a detail view, presented here via `.sheet(item:)`. **This view used to carry its own System B
/// (liquid-glass) token set as a deliberate exception to the two-system split** — recorded then as
/// the founders' intent for "one consistent way to watch Sonny work, whichever surface the user is
/// on." Branch `ui-ux-claude` reverses that: the same intent is now met by giving this sheet the
/// widget's step-log *grammar* (an icon slot plus a label) rendered in System A's own tokens,
/// rather than by importing System B's material into a flat window that has no vibrancy behind it
/// to blend against. `docs/sonny-ui-modernization-2026-09-08.md` decision 7 records this as a
/// reversal of a recorded founder decision and flags it for founder review. `SonnyDialogHeader` and
/// `sonnyDialogFrame(.regular)` are the same chrome every other System A sheet uses.
struct RoutineDetailView: View {
    let routine: StoredRoutine
    @ObservedObject var viewModel: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var unattendedAdvisory: String?
    @State private var showDeleteRoutineConfirmation = false
    /// Uncommitted schedule edits. Nil means "showing what is saved".
    ///
    /// Checkpoint 5 wrote every control straight through to the store. Manual testing found that
    /// disorienting: the schedule mutated as you poked at controls, and there was no moment of
    /// having *set* it — nothing separated exploring the options from committing to them. This
    /// draft is discarded if the panel is dismissed, which is acceptable precisely because the
    /// confirm control below is gated on the draft actually differing from what is saved: an
    /// untouched panel offers nothing to confirm, so there is nothing to lose silently.
    @State private var draft: ScheduleDraft?

    /// Always holds a valid value for every cadence, so switching cadence can never leave a field
    /// unfilled — the schedule's own `weekday`/`dayOfMonth` are Optional because a daily schedule
    /// genuinely has neither, but a draft is a composition surface and carries both throughout.
    private struct ScheduleDraft: Equatable {
        var cadence: RoutineCadence
        var hour: Int
        var minute: Int
        var weekday: Int
        var dayOfMonth: Int

        init(from schedule: RoutineSchedule, now: Date, calendar: Calendar) {
            cadence = schedule.cadence
            hour = schedule.hour
            minute = schedule.minute
            weekday = schedule.weekday ?? calendar.component(.weekday, from: now)
            dayOfMonth = schedule.dayOfMonth ?? calendar.component(.day, from: now)
        }

        /// A new schedule starts daily at 9am — the wireframe's own example time.
        init(now: Date, calendar: Calendar) {
            cadence = .daily
            hour = 9
            minute = 0
            weekday = calendar.component(.weekday, from: now)
            dayOfMonth = calendar.component(.day, from: now)
        }
    }

    /// The sheet is presented with a snapshot, so toggling anything here would otherwise leave the
    /// controls showing stale state. Read the live record back out of the view model instead.
    private var live: StoredRoutine {
        viewModel.savedRoutines.first { $0.name == routine.name } ?? routine
    }

    /// The header's subtitle: the same cadence label the Routines row shows
    /// (`RoutineRowPresentation`), so the two surfaces describe one schedule the same way.
    private var cadenceSentence: String {
        guard let schedule = live.schedule else {
            return "Runs only when you ask"
        }
        return RoutineScheduleDisplay.cadenceLabel(for: schedule)
    }

    var body: some View {
        let now = Date()
        let calendar = Calendar.current

        VStack(alignment: .leading, spacing: 0) {
            SonnyDialogHeader(
                title: routine.name,
                subtitle: cadenceSentence,
                closeLabel: "Close routine"
            ) {
                dismiss()
            }

            SettingsDivider()
                .padding(.horizontal, SonnySpacing.xxl)

            ScrollView {
                VStack(alignment: .leading, spacing: SonnySpacing.xl) {
                    stepsSection
                    scheduleSection(now: now, calendar: calendar)
                    unattendedTrustControl
                    actionsRow(now: now, calendar: calendar)
                }
                .padding(SonnySpacing.xxl)
            }
        }
        .sonnyDialogFrame(.regular)
    }

    /// The widget's step-log grammar (icon slot plus label) in System A tokens, per
    /// `docs/sonny-ui-modernization-2026-09-08.md` decision 7.
    @ViewBuilder
    private var stepsSection: some View {
        if routine.steps.isEmpty {
            HStack(spacing: 0) {
                Text("No steps saved")
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.textTertiary)
                Spacer(minLength: 0)
            }
            .frame(height: SonnyMetrics.compactRowHeight)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(routine.steps) { step in
                    RoutineDetailStepRow(step: step)
                }
            }
        }
    }

    /// Schedule authoring — **designed rather than matched.**
    ///
    /// `11-MainAppRoutines.svg` specifies the list side thoroughly (cadence headers, "Weekly · Mon"
    /// text, row toggles) but contains no cadence picker, time picker, or create affordance
    /// anywhere. CLAUDE.md makes wireframe fidelity the baseline for a page that has one, so this
    /// is a stated exception rather than an unremarked addition: the wireframe shows what a
    /// schedule *looks like*, never how one is made, and without a creation path nothing else on
    /// this branch can be reached at all.
    ///
    /// Edits accumulate in a local draft and land only on an explicit confirm — checkpoint 5's
    /// write-through was reversed after manual testing found ambient mutation disorienting, with
    /// no moment of having *set* the schedule. The confirm (now "Save schedule" in the shared
    /// actions row below, alongside Remove and Delete) is gated on the draft differing from what is
    /// saved, so an untouched panel offers nothing to confirm.
    ///
    /// The controls are structurally unable to produce a schedule `validate()` would reject:
    /// weekday is offered only for weekly, day-of-month only for monthly, both bounded to the
    /// accepted ranges, and the draft carries a valid value for every cadence so switching can
    /// never leave a field unfilled. `validate()` stays the backstop; the UI should never reach it.
    ///
    /// The unattended-trust toggle below and Remove (in the actions row) stay outside the draft and
    /// act immediately, because neither is a field of a schedule being composed: the toggle is a
    /// distinct safety decision about a schedule that already exists — keeping it immediate means
    /// its tier-3 advisory describes real saved state rather than a hypothetical — and Remove is a
    /// discrete action, not an edit.
    @ViewBuilder
    private func scheduleSection(now: Date, calendar: Calendar) -> some View {
        let (_, shown) = scheduleDraftPair(now: now, calendar: calendar)

        VStack(alignment: .leading, spacing: SonnySpacing.md) {
            Text("Schedule")
                .font(SonnyType.settingsSectionLabel)
                .foregroundStyle(SonnyTheme.text)

            // Why Sonny switched this schedule off, on the surface with room for a sentence — the
            // Routines row only has space to say that something needs attention. Reuses
            // `scheduleNote`'s type ramp with the warning colour so it reads as a state the user
            // has to resolve rather than as another piece of guidance.
            //
            // Matches `RoutineActivation` directly (SONNY-46) rather than testing a reason field
            // for nil: the reason and the switched-off-ness are one value now, so this sentence
            // cannot appear on a schedule that is still running.
            if case .pausedBySonny(let pausedReason)? = live.schedule?.activation {
                Text("Sonny paused this schedule: \(pausedReason) Switch it back on once you have reviewed it.")
                    .font(SonnyType.micro)
                    .foregroundStyle(SonnyTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let shown {
                scheduleRow("Repeats") {
                    Picker("", selection: cadenceBinding(shown)) {
                        ForEach(RoutineCadence.allCases, id: \.self) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .tint(SonnyTheme.accent)
                    .frame(width: 208)
                }

                scheduleRow("At") {
                    DatePicker("", selection: timeBinding(shown, calendar: calendar), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .tint(SonnyTheme.accent)
                        .frame(width: 92)
                }

                switch shown.cadence {
                case .daily:
                    EmptyView()
                case .weekly:
                    scheduleRow("On") {
                        Picker("", selection: fieldBinding(shown, \.weekday)) {
                            // 1...7 is exactly the range `validate()` accepts, indexed by the same
                            // Sunday == 1 convention `Calendar` uses.
                            ForEach(1...7, id: \.self) { weekday in
                                Text(calendar.weekdaySymbols[weekday - 1]).tag(weekday)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(SonnyTheme.accent)
                        .frame(width: 132)
                    }
                case .monthly:
                    scheduleRow("On day") {
                        Picker("", selection: fieldBinding(shown, \.dayOfMonth)) {
                            ForEach(1...31, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(SonnyTheme.accent)
                        .frame(width: 132)
                    }
                }
            } else {
                scheduleNote("This routine only runs when you ask it to.")
            }
        }
    }

    /// The saved schedule as a draft, and the draft actually shown (the uncommitted edit if there
    /// is one, otherwise the saved value) — the one pair of values the schedule section and the
    /// actions row both need, computed once so the two can never disagree about them.
    private func scheduleDraftPair(now: Date, calendar: Calendar) -> (saved: ScheduleDraft?, shown: ScheduleDraft?) {
        let saved = live.schedule.map { ScheduleDraft(from: $0, now: now, calendar: calendar) }
        return (saved, draft ?? saved)
    }

    private func isDirty(shown: ScheduleDraft, saved: ScheduleDraft?) -> Bool {
        guard let saved else {
            // A draft with nothing saved behind it is a schedule being created — always committable.
            return true
        }
        return shown != saved
    }

    private func commitDraft(_ shown: ScheduleDraft) {
        viewModel.commitScheduleDraft(
            for: live,
            cadence: shown.cadence,
            hour: shown.hour,
            minute: shown.minute,
            weekday: shown.weekday,
            dayOfMonth: shown.dayOfMonth
        )
        // Fall back to reflecting saved state, so the confirm control immediately reads as clean.
        draft = nil
    }

    private func scheduleRow<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: SonnySpacing.md) {
            Text(label)
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.muted)
                // One shared column width across every row so the controls line up rather than
                // stepping in and out with the label text. Sized for "On day", the longest.
                .frame(width: 62, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }

    private func scheduleNote(_ text: String) -> some View {
        Text(text)
            .font(SonnyType.micro)
            .foregroundStyle(SonnyTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cadenceBinding(_ shown: ScheduleDraft) -> Binding<RoutineCadence> {
        Binding(
            get: { shown.cadence },
            set: { newCadence in
                var updated = shown
                updated.cadence = newCadence
                draft = updated
            }
        )
    }

    private func timeBinding(_ shown: ScheduleDraft, calendar: Calendar) -> Binding<Date> {
        Binding(
            get: {
                calendar.date(bySettingHour: shown.hour, minute: shown.minute, second: 0, of: Date()) ?? Date()
            },
            set: { newTime in
                let parts = calendar.dateComponents([.hour, .minute], from: newTime)
                var updated = shown
                updated.hour = parts.hour ?? shown.hour
                updated.minute = parts.minute ?? shown.minute
                draft = updated
            }
        )
    }

    private func fieldBinding(
        _ shown: ScheduleDraft,
        _ keyPath: WritableKeyPath<ScheduleDraft, Int>
    ) -> Binding<Int> {
        Binding(
            get: { shown[keyPath: keyPath] },
            set: { newValue in
                var updated = shown
                updated[keyPath: keyPath] = newValue
                draft = updated
            }
        )
    }

    /// The per-routine trust opt-in, deliberately here rather than on the Routines row.
    ///
    /// The row's trailing slot belongs to the schedule toggle per the wireframe, and there is no
    /// space for a second switch — but the real reason is that this is a consequential safety
    /// decision (it lets any run of this routine, scheduled or manual, bypass the tier-2 gate per
    /// SONNY-54), and it deserves the context of the step list it is granting that permission
    /// over. Label copy is the founder-chosen wording (2026-08-06, Q5), restructured off an em dash
    /// per this branch's copy rule — no test pins the old wording (`grep -rn "Trust this routine"
    /// Tests/` finds nothing), so this is a styling-branch wording change rather than a founder
    /// override.
    @ViewBuilder
    private var unattendedTrustControl: some View {
        if live.schedule != nil {
            VStack(alignment: .leading, spacing: SonnySpacing.sm) {
                Toggle(isOn: Binding(
                    get: { live.schedule?.unattendedTrusted == true },
                    set: { unattendedAdvisory = viewModel.setRoutineUnattendedTrust(live, to: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trust this routine: runs tier-2 steps without asking, scheduled or manual.")
                            .font(SonnyType.bodyEmphasis)
                            .foregroundStyle(SonnyTheme.text)
                            // Founder-chosen wording (2026-08-06, Q5) is a full sentence: let it
                            // wrap rather than truncate in this fixed-width panel.
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Applies both to scheduled runs and runs you start yourself. Steps that need your explicit approval still ask first.")
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(SonnyTheme.accent)

                // Best-effort heads-up, never a gate: blocking the opt-in for a tier-3 routine
                // would be the save-time tier gating this branch explicitly rejected.
                //
                // Contained rather than loose: at four lines, unbroken yellow body copy read as an
                // error state rather than a note. Icon-plus-text inside a tinted, stroked block is
                // the shape `CommandCenterStorageNotice` and `CommandCenterAttentionPanel` already
                // use for exactly this job on the System A side.
                if let unattendedAdvisory {
                    HStack(alignment: .top, spacing: SonnySpacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(SonnyType.icon(SonnyMetrics.iconRow, weight: .semibold))
                            .foregroundStyle(SonnyTheme.warning)

                        Text(unattendedAdvisory)
                            .font(SonnyType.micro)
                            .foregroundStyle(SonnyTheme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, SonnySpacing.sm)
                    .padding(.vertical, SonnySpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SonnyTheme.warning.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: SonnyRadius.control)
                            .strokeBorder(SonnyTheme.warning.opacity(0.35), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.control))
                }
            }
        }
    }

    /// The shared actions row: Run now, the schedule's own Save/Add/Remove (their visibility
    /// depending on whether a schedule exists or is being composed, unchanged from before this
    /// pass), and Delete routine. Consolidating these onto one row (`docs/sonny-ui-modernization-
    /// 2026-09-08.md`'s brief) is a layout change, not a behaviour one: every button still calls
    /// exactly the view-model method it always called.
    @ViewBuilder
    private func actionsRow(now: Date, calendar: Calendar) -> some View {
        let (saved, shown) = scheduleDraftPair(now: now, calendar: calendar)

        HStack(spacing: SonnySpacing.sm) {
            // The hoisted term, not a fourth hand-rolled copy: during a clarification pause the
            // two-term version left this a live button that silently did nothing, and `dismiss()`
            // below closed the sheet so the action read as accepted.
            Button {
                viewModel.runRoutineWidget(live)
                dismiss()
            } label: {
                if viewModel.isTaskInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Run now")
                }
            }
            .buttonStyle(SonnyButtonStyle(tone: .primary, size: .regular))
            .disabled(viewModel.isTaskInFlight)
            .accessibilityLabel("Run \(live.name) now")

            if let shown {
                // Gated on the draft actually differing from what is saved, so an untouched panel
                // offers nothing to confirm and a dirty one visibly does. That is what makes
                // discarding on dismiss safe without a confirmation dialog.
                Button(live.schedule == nil ? "Save schedule" : "Save changes") {
                    commitDraft(shown)
                }
                .buttonStyle(SonnyButtonStyle(tone: .secondary, size: .regular))
                .disabled(!isDirty(shown: shown, saved: saved))

                if live.schedule != nil {
                    // Immediate rather than part of the draft: removing a schedule is a discrete
                    // action, not a field edit. No confirmation dialog — unlike Delete routine
                    // below, a removed schedule is recoverable by making another one.
                    Button {
                        viewModel.setRoutineSchedule(live, to: nil)
                        draft = nil
                        unattendedAdvisory = nil
                    } label: {
                        Label("Remove schedule", systemImage: "trash")
                    }
                    .buttonStyle(SonnyButtonStyle(tone: .tertiary, size: .small))
                    .help("Remove this routine's schedule")
                }
            } else {
                Button("Add a schedule") {
                    draft = ScheduleDraft(now: now, calendar: calendar)
                }
                .buttonStyle(SonnyButtonStyle(tone: .secondary, size: .regular))
            }

            Spacer(minLength: 0)

            // Deleting the whole routine, distinct from Remove above, which only clears the
            // schedule. That one deliberately has no confirmation because a removed schedule is
            // recoverable by making another; this deletes the routine's steps and run history too,
            // which nothing can bring back, so it gets a confirmation dialog.
            Button {
                showDeleteRoutineConfirmation = true
            } label: {
                Label("Delete routine", systemImage: "trash")
            }
            .buttonStyle(SonnyButtonStyle(tone: .danger, size: .regular))
            .disabled(viewModel.isRunning || viewModel.isAwaitingApproval)
            .help("Delete this routine")
            .accessibilityLabel("Delete \(live.name)")
            .confirmationDialog(
                "Delete \(live.name)?",
                isPresented: $showDeleteRoutineConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete routine", role: .destructive) {
                    viewModel.deleteRoutine(live)
                    // Nothing auto-closes this sheet when its routine disappears — `live` falls
                    // back to the stale presentation snapshot — so the dismiss has to be explicit.
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // The title already names the routine; repeating the quoted name here read as
                // noisy in a dialog this small (manual pass, 2026-07-30).
                Text("This deletes its saved steps, schedule, and run history. Past task history mentioning this routine is not deleted.")
            }
        }
    }
}

private struct RoutineDetailStepRow: View {
    let step: AgentStep

    /// Icon slot matching the floating widget's own row grammar (§3.3.2: "icon slot... + label
    /// text") — `docs/sonny-founder-design-decisions.md` asks for "one consistent... experience"
    /// across both surfaces, not a plain numbered list. Resolves the step's real app icon the same
    /// way `WorkspaceAppIconStack` already does; falls back to a plain glyph when the step has no
    /// app (or it isn't installed).
    private var resolvedIcon: NSImage? {
        guard let appName = step.appName else { return nil }
        return WorkspaceAppIconResolver.shared.icon(forAppName: appName)
    }

    var body: some View {
        HStack(alignment: .center, spacing: SonnySpacing.sm) {
            ZStack {
                if let resolvedIcon {
                    Image(nsImage: resolvedIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(SonnyType.icon(SonnyMetrics.iconRow))
                        .foregroundStyle(SonnyTheme.textTertiary)
                }
            }
            .frame(width: 20, height: 20)

            Text(AgentActivityPresentation.operationTitle(step))
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.text)
                .lineLimit(1)
                .help(AgentActivityPresentation.operationTitle(step))

            Spacer(minLength: SonnySpacing.sm)

            if !step.description.isEmpty {
                Text(step.description)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(step.description)
            }
        }
        .frame(height: SonnyMetrics.compactRowHeight)
    }
}
