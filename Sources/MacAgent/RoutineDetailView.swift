import MacAgentCore
import SwiftUI

// MARK: - System B tokens (routine detail view only)
//
// This is a fully separate token set from System A (SonnyTheme/SonnyType/SonnyRadius in
// ContentView.swift) — per docs/sonny-design-system-reference.md §3 and
// docs/sonny-founder-design-decisions.md's Routines section, the routine detail view is styled
// like the floating widget's liquid-glass material embedded inside the main app window, not a
// variant of System A. Do not extend SonnyTheme/SonnyType/SonnyRadius to serve this view, and do
// not reuse these System B tokens outside this deliberate System-B-inside-System-A case.

enum RoutineDetailTheme {
    static let basePanel = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)
    static let hairline = Color(red: 0xA6 / 255, green: 0xA6 / 255, blue: 0xA6 / 255)
    static let text = Color.white
    static let mutedText = Color.white.opacity(0.55)

    /// §3's exact radius/shadow-offset recipe only covers two specific components — the floating
    /// widget's own panels (34px radius, 18px shadow offset) and the system notification banner
    /// (20px radius, 8px offset). Neither is literally "the routine detail view," which isn't in
    /// that doc at all. `docs/sonny-founder-design-decisions.md`'s own language is "styled like the
    /// floating widget" specifically, not the notification, so the floating widget's values are
    /// used here as the more defensible default — an explicit, stated choice, not a silent
    /// assumption. Worth a visual check alongside the actual floating widget once branch 11 exists.
    static let panelRadius: CGFloat = 34
    static let shadowOffset: CGFloat = 18
}

enum RoutineDetailType {
    /// §3.1 calls out a recurring non-standard weight value, 510 — Apple's own "Medium" optical-
    /// weight instance in SF Pro's variable-font axis, distinct from the generic CSS 500. SwiftUI's
    /// `Font.Weight` has no matching custom numeric axis value to set directly, so `.medium`
    /// (SwiftUI's own closest built-in token) is used wherever §3.1 specifies 510.
    static let mediumWeight: Font.Weight = .medium

    /// SF Pro / SF Pro Display come from `design: .default` — that's already San Francisco on
    /// Apple platforms, so no custom font name needs registering (unlike System A's Inter, which
    /// is a bundled, non-system font loaded via `Font.custom`).
    static let title = Font.system(size: 20, weight: .semibold, design: .default)
    static let sectionLabel = Font.system(size: 13, weight: mediumWeight, design: .default)
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let micro = Font.system(size: 11, weight: .regular, design: .default)
}

/// Reusable liquid-glass panel background matching §3.1/§3.2's recipe as closely as SwiftUI's
/// drawing primitives allow. Two parts are approximations rather than literal ports, since CSS and
/// SwiftUI have no exact equivalents for them: the blend-mode-layered gradient fill (approximated
/// with `.blendMode` on stacked translucent layers) and the inset "inner glass highlight" shadows
/// (CSS `inset` shadows have no SwiftUI counterpart; approximated with edge-fading gradient
/// overlays). Worth a visual check, not guaranteed pixel-identical to the CSS export.
private struct LiquidGlassPanelBackground: ViewModifier {
    let cornerRadius: CGFloat
    let shadowOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                // §3.1's exact recipe: the opaque base layer carries `lighten`; both translucent
                // `rgba(26,26,26,.5)` layers carry `luminosity`. `.compositingGroup()` isolates
                // this stack so the blend modes composite against each other, not whatever's
                // drawn behind the sheet.
                ZStack {
                    RoutineDetailTheme.basePanel
                        .blendMode(.lighten)
                    RoutineDetailTheme.basePanel.opacity(0.5)
                        .blendMode(.luminosity)
                    RoutineDetailTheme.basePanel.opacity(0.5)
                        .blendMode(.luminosity)
                }
                .compositingGroup()
            )
            .overlay(
                // Approximates the inset "inner glass highlight" (`inset 0 40px 10px -40px #1A1A1A`
                // on both top and bottom edges) via edge-fading gradients, since SwiftUI has no
                // inset-shadow primitive.
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, Color.black.opacity(0.08)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                }
                .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(RoutineDetailTheme.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // The 3-pass hairline rim from §3.2 (±1.25px offset passes plus the 0.5px outline
            // stroke already applied above as an overlay, the more precise translation for a
            // zero-blur/zero-offset CSS shadow pass). §3.2's outline color is fully opaque —
            // SwiftUI's blur-based `.shadow` still softens what CSS's spread-based passes render
            // sharp, but the color itself shouldn't be additionally dimmed on top of that.
            .shadow(color: RoutineDetailTheme.hairline, radius: 0.5, x: 1.25, y: 0)
            .shadow(color: RoutineDetailTheme.hairline, radius: 0.5, x: -1.25, y: 0)
            // The outer drop shadow: `0px <offset>px 48px rgba(0,0,0,.45)`.
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: shadowOffset)
    }
}

private extension View {
    func liquidGlassPanel(cornerRadius: CGFloat, shadowOffset: CGFloat) -> some View {
        modifier(LiquidGlassPanelBackground(cornerRadius: cornerRadius, shadowOffset: shadowOffset))
    }
}

/// Button chrome for this panel's actions, in System B tokens.
///
/// Follows the treatment Settings → Privacy & Permissions already uses for "Delete Local Data" —
/// real button chrome, a danger tone, a trash icon and a short verb — rather than inventing a third
/// destructive pattern. It is a re-implementation rather than a reuse of `SonnyButtonStyle`
/// deliberately: that style is System A (Inter, `SonnyTheme` colors) and this panel is the
/// documented System-B-inside-System-A case, so importing it would mix the two systems that
/// CLAUDE.md says not to mix. The *pattern* is the shared thing; the tokens are not.
private struct RoutineDetailActionStyle: ButtonStyle {
    enum Tone {
        case primary
        case danger
    }

    @Environment(\.isEnabled) private var isEnabled
    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RoutineDetailType.sectionLabel)
            .foregroundStyle(foreground.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(background.opacity(configuration.isPressed ? 0.7 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.4)
            .sonnyPointerCursor()
    }

    private var foreground: Color {
        switch tone {
        case .primary:
            return .white
        case .danger:
            return SonnyTheme.danger
        }
    }

    private var background: Color {
        switch tone {
        case .primary:
            return SonnyTheme.accent
        case .danger:
            return Color.white.opacity(0.06)
        }
    }

    private var border: Color {
        switch tone {
        case .primary:
            return .clear
        case .danger:
            return SonnyTheme.danger.opacity(0.45)
        }
    }
}

// MARK: - Routine detail view

/// Per `docs/sonny-founder-design-decisions.md`'s Routines section: clicking into a routine opens
/// a detail view styled like the floating widget (liquid glass), embedded inside the main app
/// window rather than the literal floating widget window — presented here via `.sheet(item:)`.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            closeButtonRow
            header

            Rectangle()
                .fill(RoutineDetailTheme.hairline.opacity(0.2))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(routine.steps) { step in
                        RoutineDetailStepRow(step: step)
                    }

                    scheduleControls
                    unattendedTrustControl
                    runControl
                    deleteRoutineControl

                    Spacer(minLength: 24)
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 480)
        .liquidGlassPanel(cornerRadius: RoutineDetailTheme.panelRadius, shadowOffset: RoutineDetailTheme.shadowOffset)
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
    /// It follows what this view already establishes — System B tokens from this file (which
    /// deliberately keeps its own copy rather than sharing `SonnyWidgetTheme.swift`, per
    /// `.claude/rules/macagent-ui-conventions.md`), label-plus-control rows matching the toggle
    /// below, and native controls, which this view already uses for its switch and buttons.
    ///
    /// Edits accumulate in a local draft and land only on an explicit confirm — checkpoint 5's
    /// write-through was reversed after manual testing found ambient mutation disorienting, with
    /// no moment of having *set* the schedule. The confirm is gated on the draft differing from
    /// what is saved, so an untouched panel offers nothing to confirm.
    ///
    /// The controls are structurally unable to produce a schedule `validate()` would reject:
    /// weekday is offered only for weekly, day-of-month only for monthly, both bounded to the
    /// accepted ranges, and the draft carries a valid value for every cadence so switching can
    /// never leave a field unfilled. `validate()` stays the backstop; the UI should never reach it.
    ///
    /// Two things stay outside the draft and act immediately, because neither is a field of a
    /// schedule being composed: the unattended-trust toggle below (a distinct safety decision about
    /// a schedule that already exists — keeping it immediate means its tier-3 advisory describes
    /// real saved state rather than a hypothetical) and Remove (a discrete action, not an edit).
    @ViewBuilder
    private var scheduleControls: some View {
        let calendar = Calendar.current
        let now = Date()
        let saved = live.schedule.map { ScheduleDraft(from: $0, now: now, calendar: calendar) }
        let shown = draft ?? saved

        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule")
                .font(RoutineDetailType.sectionLabel)
                .foregroundStyle(RoutineDetailTheme.text)

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
                    .font(RoutineDetailType.micro)
                    .foregroundStyle(SonnyTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let shown {
                scheduleRow("Repeats") {
                    Picker("", selection: cadenceBinding(shown, now: now, calendar: calendar)) {
                        ForEach(RoutineCadence.allCases, id: \.self) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 208)
                }

                scheduleRow("At") {
                    DatePicker("", selection: timeBinding(shown, calendar: calendar), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
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
                        .frame(width: 132)
                    }
                }

                // Day 29-31 does not exist in every month. The data model accepts those days on
                // purpose and the scheduler clamps to the last day — worth saying rather than
                // leaving the user to discover it in February.
                if shown.cadence == .monthly, shown.dayOfMonth > 28 {
                    scheduleNote("Months without a \(shown.dayOfMonth)\(ordinalSuffix(shown.dayOfMonth)) run on their last day.")
                }

                HStack(spacing: 10) {
                    // Gated on the draft actually differing from what is saved, so an untouched
                    // panel offers nothing to confirm and a dirty one visibly does. That is what
                    // makes discarding on dismiss safe without a confirmation dialog.
                    Button(live.schedule == nil ? "Save schedule" : "Save changes") {
                        commitDraft(shown)
                    }
                    .buttonStyle(RoutineDetailActionStyle(tone: .primary))
                    .disabled(!isDirty(shown: shown, saved: saved))

                    if live.schedule != nil {
                        // Immediate rather than part of the draft: removing a schedule is a
                        // discrete action, not a field edit. No confirmation dialog — unlike
                        // Delete Local Data, which this borrows its danger treatment from, a
                        // removed schedule is recoverable by making another one.
                        Button {
                            viewModel.setRoutineSchedule(live, to: nil)
                            draft = nil
                            unattendedAdvisory = nil
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(RoutineDetailActionStyle(tone: .danger))
                        .help("Remove this routine's schedule")
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            } else {
                scheduleNote("This routine only runs when you ask it to.")

                Button("Add a schedule") {
                    draft = ScheduleDraft(now: now, calendar: calendar)
                }
                .buttonStyle(RoutineDetailActionStyle(tone: .primary))
            }
        }
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
        HStack(spacing: 12) {
            Text(label)
                .font(RoutineDetailType.body)
                .foregroundStyle(RoutineDetailTheme.mutedText)
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
            .font(RoutineDetailType.micro)
            .foregroundStyle(RoutineDetailTheme.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cadenceBinding(
        _ shown: ScheduleDraft,
        now: Date,
        calendar: Calendar
    ) -> Binding<RoutineCadence> {
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

    private func ordinalSuffix(_ value: Int) -> String {
        switch value {
        case 1, 21, 31: return "st"
        case 2, 22: return "nd"
        case 3, 23: return "rd"
        default: return "th"
        }
    }

    /// The per-routine unattended-run opt-in, deliberately here rather than on the Routines row.
    ///
    /// The row's trailing slot belongs to the schedule toggle per the wireframe, and there is no
    /// space for a second switch — but the real reason is that this is a consequential safety
    /// decision (it lets a scheduled trigger bypass the tier-2 gate a manual click keeps), and it
    /// deserves the context of the step list it is granting that permission over.
    @ViewBuilder
    private var unattendedTrustControl: some View {
        if live.schedule != nil {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { live.schedule?.unattendedTrusted == true },
                    set: { unattendedAdvisory = viewModel.setRoutineUnattendedTrust(live, to: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run without asking me")
                            .font(RoutineDetailType.sectionLabel)
                            .foregroundStyle(RoutineDetailTheme.text)
                        Text("Lets this routine run on its schedule while you are away.")
                            .font(RoutineDetailType.micro)
                            .foregroundStyle(RoutineDetailTheme.mutedText)
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
                // use for exactly this job on the System A side — the same pattern, in this
                // panel's own tokens.
                if let unattendedAdvisory {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SonnyTheme.warning)

                        Text(unattendedAdvisory)
                            .font(RoutineDetailType.micro)
                            .foregroundStyle(RoutineDetailTheme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SonnyTheme.warning.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(SonnyTheme.warning.opacity(0.35), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(.top, 4)
        }
    }

    /// Running a routine by hand lives here now. The wireframe's own row has no Run button at all
    /// and reserves that slot for the schedule time and toggle, so keeping one there would have
    /// crowded out the thing the wireframe actually specifies.
    private var runControl: some View {
        Button {
            viewModel.runRoutineWidget(live)
            dismiss()
        } label: {
            Text("Run now")
                .font(RoutineDetailType.sectionLabel)
                .foregroundStyle(RoutineDetailTheme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRunning || viewModel.isAwaitingApproval)
        .sonnyPointerCursor()
        .accessibilityLabel("Run \(live.name) now")
    }

    /// Deleting the whole routine, distinct from "Remove" above, which only clears the schedule.
    /// That one deliberately has no confirmation because a removed schedule is recoverable by
    /// making another; this deletes the routine's steps and run history too, which nothing can
    /// bring back, so it gets the same confirmation dialog "Delete Local Data" uses.
    private var deleteRoutineControl: some View {
        Button {
            showDeleteRoutineConfirmation = true
        } label: {
            Label("Delete routine", systemImage: "trash")
        }
        .buttonStyle(RoutineDetailActionStyle(tone: .danger))
        .disabled(viewModel.isRunning || viewModel.isAwaitingApproval)
        .help("Delete this routine")
        .accessibilityLabel("Delete \(live.name)")
        .confirmationDialog(
            "Delete “\(live.name)”?",
            isPresented: $showDeleteRoutineConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Routine", role: .destructive) {
                viewModel.deleteRoutine(live)
                // Nothing auto-closes this sheet when its routine disappears — `live` falls back
                // to the stale presentation snapshot — so the dismiss has to be explicit.
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The title already names the routine; repeating the quoted name here read as noisy
            // in a dialog this small (manual pass, 2026-07-30).
            Text("This deletes its saved steps, schedule, and run history. Past task history mentioning this routine is not deleted.")
        }
    }

    /// This view is presented via `.sheet(item:)` with no other dismiss affordance anywhere in the
    /// wireframe/founder-decisions source for it — without this, the sheet had no way to close at
    /// all (found during manual QA, 2026-07-24). `.keyboardShortcut(.cancelAction)` matches
    /// `TaskLogDetailDialog`'s own close button, an independent Escape-key path in case the click
    /// itself is ever the thing not registering.
    private var closeButtonRow: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(RoutineDetailType.sectionLabel)
                    .foregroundStyle(RoutineDetailTheme.mutedText)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(routine.name)
                .font(RoutineDetailType.title)
                .foregroundStyle(RoutineDetailTheme.text)
                .lineLimit(1)

            Text("\(routine.steps.count) saved step\(routine.steps.count == 1 ? "" : "s")")
                .font(RoutineDetailType.micro)
                .foregroundStyle(RoutineDetailTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

private struct RoutineDetailStepRow: View {
    let step: AgentStep

    /// Icon slot matching the floating widget's own row grammar (§3.3.2: "icon slot... + label
    /// text") — `docs/sonny-founder-design-decisions.md` asks for "one consistent... experience"
    /// across both surfaces, not a plain numbered list wearing glass chrome. Resolves the step's
    /// real app icon the same way `WorkspaceAppIconStack` already does; falls back to a step
    /// glyph when the step has no app (or it isn't installed).
    private var resolvedIcon: NSImage? {
        guard let appName = step.appName else { return nil }
        return WorkspaceAppIconResolver.shared.icon(forAppName: appName)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if let resolvedIcon {
                    Image(nsImage: resolvedIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: AgentActivityPresentation.eventIcon(.act))
                        .font(RoutineDetailType.sectionLabel)
                        .foregroundStyle(RoutineDetailTheme.mutedText)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(AgentActivityPresentation.operationTitle(step))
                    .font(RoutineDetailType.body)
                    .foregroundStyle(RoutineDetailTheme.text)

                if !step.description.isEmpty {
                    Text(step.description)
                        .font(RoutineDetailType.micro)
                        .foregroundStyle(RoutineDetailTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
