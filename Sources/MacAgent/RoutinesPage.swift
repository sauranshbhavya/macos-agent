import MacAgentCore
import SwiftUI

/// Routines saved as goals (decision 9), each run planned again from its goal, and the pages Sonny
/// is watching. A routine on a schedule runs unattended.
struct RoutinesPage: View {
    @ObservedObject var model: SonnyAppModel
    @State private var editing: RoutineGoal?
    @State private var deleting: RoutineGoal?

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.lg) {
            CommandCenterPageHeader(title: "Routines")
            ScrollView {
                VStack(alignment: .leading, spacing: SonnySpacing.md) {
                    if model.desk.routines.isEmpty {
                        CollectionEmptyState(
                            systemImage: "clock.arrow.circlepath",
                            title: "No routines yet",
                            message: "Ask Sonny to save one, for example: save a routine called Morning that opens my calendar.",
                            action: .init(title: "Ask Sonny", run: model.showWidget)
                        )
                    } else {
                        ForEach(model.desk.routines) { routine in
                            routineRow(routine)
                            SettingsDivider()
                        }
                    }
                    if !model.desk.watchers.isEmpty {
                        Text("Watching")
                            .font(SonnyType.settingsSectionLabel)
                            .foregroundStyle(SonnyTheme.text)
                            .padding(.top, SonnySpacing.lg)
                        ForEach(model.desk.watchers) { watcher in
                            watcherRow(watcher)
                            SettingsDivider()
                        }
                    }
                }
                .padding(SonnySpacing.lg)
            }
            .commandCenterPanel()
        }
        .commandCenterPageFrame()
        .sheet(item: $editing) { routine in
            RoutineScheduleSheet(model: model, routine: routine) { editing = nil }
        }
        .confirmationDialog(
            "Delete the routine \"\(deleting?.name ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let routine = deleting { Task { await model.desk.deleteRoutine(routine) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private func routineRow(_ routine: RoutineGoal) -> some View {
        HStack(alignment: .top, spacing: SonnySpacing.md) {
            VStack(alignment: .leading, spacing: SonnySpacing.xs) {
                Text(routine.name)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                Text(routine.goal)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.timingLine(routine))
                    .font(SonnyType.micro)
                    .foregroundStyle(routine.timing?.isEnabled == true ? SonnyTheme.accent : SonnyTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Run now") { model.run(routine) }
                .buttonStyle(SonnyButtonStyle(tone: .secondary))
                .disabled(model.isFollowedTaskRunning)
            Button("Schedule") { editing = routine }
                .buttonStyle(SonnyButtonStyle(tone: .secondary))
            Button {
                deleting = routine
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(SonnyButtonStyle(tone: .tertiary, width: SonnyMetrics.controlRegular))
            .accessibilityLabel("Delete \(routine.name)")
        }
        .padding(.vertical, SonnySpacing.sm)
    }

    private func watcherRow(_ watcher: StandingWatcher) -> some View {
        HStack(spacing: SonnySpacing.md) {
            VStack(alignment: .leading, spacing: SonnySpacing.xs) {
                Text(watcher.subject)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                Text(watcher.url.absoluteString)
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop watching") { model.desk.stopWatching(watcher) }
                .buttonStyle(SonnyButtonStyle(tone: .secondary))
        }
        .padding(.vertical, SonnySpacing.sm)
    }

    static func timingLine(_ routine: RoutineGoal, now: Date = Date()) -> String {
        guard let timing = routine.timing else {
            return routine.schedule.map { "Not scheduled · you said \u{201C}\($0)\u{201D}" } ?? "Not scheduled"
        }
        guard timing.isEnabled else { return "\(RoutineScheduleDisplay.cadenceLabel(for: timing)) · off" }
        let next = RoutineScheduleDisplay.nextRunText(for: timing, now: now).map { " · next \($0)" } ?? ""
        return "\(RoutineScheduleDisplay.cadenceLabel(for: timing))\(next)"
    }
}

/// Sets when a routine runs on its own.
private struct RoutineScheduleSheet: View {
    @ObservedObject var model: SonnyAppModel
    let routine: RoutineGoal
    let close: () -> Void
    @State private var isOn: Bool
    @State private var cadence: RoutineCadence
    @State private var time: Date
    @State private var weekday: Int
    @State private var dayOfMonth: Int

    init(model: SonnyAppModel, routine: RoutineGoal, close: @escaping () -> Void) {
        self.model = model
        self.routine = routine
        self.close = close
        let calendar = Calendar.autoupdatingCurrent
        let timing = routine.timing
        _isOn = State(initialValue: timing?.isEnabled ?? true)
        _cadence = State(initialValue: timing?.cadence ?? .daily)
        _time = State(initialValue: calendar.date(from: DateComponents(hour: timing?.hour ?? 9, minute: timing?.minute ?? 0)) ?? Date())
        _weekday = State(initialValue: timing?.weekday ?? calendar.component(.weekday, from: Date()))
        _dayOfMonth = State(initialValue: timing?.dayOfMonth ?? calendar.component(.day, from: Date()))
    }

    var body: some View {
        VStack(spacing: 0) {
            SonnyDialogHeader(title: "Schedule \(routine.name)", closeLabel: "Close schedule") { close() }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(title: "Run on a schedule", detail: "Runs on its own at the time below", isOn: $isOn)
                SettingsDivider()
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(title: "How often", detail: "Daily, weekly or monthly")
                } trailing: {
                    Picker("", selection: $cadence) {
                        ForEach(RoutineCadence.allCases, id: \.self) { cadence in
                            Text(cadence.rawValue.capitalized).tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if cadence == .weekly {
                    SettingsDivider()
                    SettingsAdaptiveControlRow {
                        SettingsControlLabel(title: "Day", detail: "The day of the week")
                    } trailing: {
                        Picker("", selection: $weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(Calendar.autoupdatingCurrent.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: SonnyMetrics.settingsControlWidth)
                    }
                }
                if cadence == .monthly {
                    SettingsDivider()
                    SettingsAdaptiveControlRow {
                        SettingsControlLabel(title: "Day", detail: "The day of the month")
                    } trailing: {
                        Picker("", selection: $dayOfMonth) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: SonnyMetrics.settingsControlWidth)
                    }
                }
                SettingsDivider()
                SettingsAdaptiveControlRow {
                    SettingsControlLabel(title: "Time", detail: "When it runs")
                } trailing: {
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, SonnySpacing.xxl)
            HStack {
                if routine.timing != nil {
                    Button("Remove schedule", role: .destructive) {
                        Task { await model.desk.setTiming(nil, for: routine) }
                        close()
                    }
                    .buttonStyle(SonnyButtonStyle(tone: .danger))
                }
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SonnyButtonStyle(tone: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(SonnyButtonStyle(tone: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(SonnySpacing.xl)
        }
        .sonnyDialogFrame(.regular)
    }

    private func save() {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
        let timing = RoutineSchedule.newlyCreated(
            cadence: cadence,
            hour: parts.hour ?? 9,
            minute: parts.minute ?? 0,
            weekday: cadence == .weekly ? weekday : nil,
            dayOfMonth: cadence == .monthly ? dayOfMonth : nil,
            isEnabled: isOn,
            now: Date()
        )
        Task { await model.desk.setTiming(timing, for: routine) }
        close()
    }
}
