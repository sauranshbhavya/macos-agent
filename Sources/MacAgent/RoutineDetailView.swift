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

// MARK: - Routine detail view

/// Per `docs/sonny-founder-design-decisions.md`'s Routines section: clicking into a routine opens
/// a detail view styled like the floating widget (liquid glass), embedded inside the main app
/// window rather than the literal floating widget window — presented here via `.sheet(item:)`.
struct RoutineDetailView: View {
    let routine: StoredRoutine
    @ObservedObject var viewModel: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var unattendedAdvisory: String?

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
    /// There is no draft state: every control writes through to the store immediately, so what is
    /// on screen is always what is saved. That also means the pickers only ever exist once a
    /// schedule does, which is what keeps them structurally unable to produce an invalid one —
    /// weekday is offered only for weekly, day-of-month only for monthly, and both are bounded to
    /// what `validate()` accepts. `validate()` stays as the backstop; the UI should never reach it.
    @ViewBuilder
    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule")
                .font(RoutineDetailType.sectionLabel)
                .foregroundStyle(RoutineDetailTheme.text)

            if let schedule = live.schedule {
                scheduleRow("Repeats") {
                    Picker("", selection: cadenceBinding(schedule)) {
                        ForEach(RoutineCadence.allCases, id: \.self) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                scheduleRow("At") {
                    DatePicker("", selection: timeBinding(schedule), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }

                switch schedule.cadence {
                case .daily:
                    EmptyView()
                case .weekly:
                    scheduleRow("On") {
                        Picker("", selection: weekdayBinding(schedule)) {
                            // 1...7 is exactly the range `validate()` accepts, and the symbols are
                            // indexed by the same Sunday == 1 convention `Calendar` uses.
                            ForEach(1...7, id: \.self) { weekday in
                                Text(Calendar.current.weekdaySymbols[weekday - 1]).tag(weekday)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                case .monthly:
                    scheduleRow("Day") {
                        Picker("", selection: dayOfMonthBinding(schedule)) {
                            ForEach(1...31, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }

                // Day 29-31 does not exist in every month. CP2 accepts those values on purpose and
                // the scheduler clamps to the last day, but that is worth saying out loud rather
                // than leaving the user to discover it in February.
                if schedule.cadence == .monthly, let day = schedule.dayOfMonth, day > 28 {
                    Text("Months without a \(day)\(ordinalSuffix(day)) run on their last day.")
                        .font(RoutineDetailType.micro)
                        .foregroundStyle(RoutineDetailTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Remove schedule") {
                    viewModel.setRoutineSchedule(live, to: nil)
                    unattendedAdvisory = nil
                }
                .buttonStyle(.plain)
                .font(RoutineDetailType.micro)
                .foregroundStyle(RoutineDetailTheme.mutedText)
                .sonnyPointerCursor()
            } else {
                Text("This routine only runs when you ask it to.")
                    .font(RoutineDetailType.micro)
                    .foregroundStyle(RoutineDetailTheme.mutedText)

                Button("Add a schedule") {
                    // Built through `newlyCreated` rather than the initializer so the catch-up
                    // baseline is anchored to now — otherwise creating a 9am schedule in the
                    // afternoon reads as "this morning was missed" and fires immediately.
                    viewModel.setRoutineSchedule(
                        live,
                        to: .newlyCreated(cadence: .daily, hour: 9, minute: 0, now: Date())
                    )
                }
                .buttonStyle(.plain)
                .font(RoutineDetailType.sectionLabel)
                .foregroundStyle(SonnyTheme.accent)
                .sonnyPointerCursor()
            }
        }
        .padding(.top, 6)
    }

    private func scheduleRow<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(RoutineDetailType.body)
                .foregroundStyle(RoutineDetailTheme.mutedText)
                .frame(width: 56, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private func cadenceBinding(_ schedule: RoutineSchedule) -> Binding<RoutineCadence> {
        Binding(
            get: { schedule.cadence },
            set: { newCadence in
                var updated = schedule
                // Fills in whatever the new cadence requires, so switching to Weekly or Monthly
                // can never leave a schedule `validate()` would reject.
                updated.setCadence(newCadence, now: Date())
                viewModel.setRoutineSchedule(live, to: updated)
            }
        )
    }

    private func timeBinding(_ schedule: RoutineSchedule) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: schedule.hour,
                    minute: schedule.minute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newTime in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newTime)
                var updated = schedule
                updated.hour = parts.hour ?? schedule.hour
                updated.minute = parts.minute ?? schedule.minute
                viewModel.setRoutineSchedule(live, to: updated)
            }
        )
    }

    private func weekdayBinding(_ schedule: RoutineSchedule) -> Binding<Int> {
        Binding(
            get: { schedule.weekday ?? Calendar.current.component(.weekday, from: Date()) },
            set: { newWeekday in
                var updated = schedule
                updated.weekday = newWeekday
                viewModel.setRoutineSchedule(live, to: updated)
            }
        )
    }

    private func dayOfMonthBinding(_ schedule: RoutineSchedule) -> Binding<Int> {
        Binding(
            get: { schedule.dayOfMonth ?? Calendar.current.component(.day, from: Date()) },
            set: { newDay in
                var updated = schedule
                updated.dayOfMonth = newDay
                viewModel.setRoutineSchedule(live, to: updated)
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
                if let unattendedAdvisory {
                    Text(unattendedAdvisory)
                        .font(RoutineDetailType.micro)
                        .foregroundStyle(SonnyTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
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
