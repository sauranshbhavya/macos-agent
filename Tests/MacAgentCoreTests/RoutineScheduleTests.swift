import Foundation
import Testing
@testable import MacAgentCore

/// Branch 10 checkpoint 2 — the schedule data model only. Nothing fires yet; the scheduler that
/// reads these fields lands in checkpoint 3.
@Suite
struct RoutineScheduleTests {
    // MARK: - Legacy decode

    /// The whole reason `schedule` and `recentRunDates` are Optional. A routines.json written
    /// before this branch has neither key, and synthesized `Decodable` calls `decode(_:forKey:)`
    /// — not `decodeIfPresent` — for any non-Optional property, so a Swift-side default literal
    /// would *not* have protected existing files. Same reasoning as `StoredWorkspace.teamType`.
    @Test
    func routineJSONWrittenBeforeSchedulingStillDecodes() throws {
        let legacy = """
        {
          "name": "Morning",
          "steps": [
            {
              "id": "open",
              "operation": "open_app",
              "description": "Open Safari.",
              "appName": "Safari"
            }
          ]
        }
        """

        let routine = try JSONDecoder().decode(StoredRoutine.self, from: Data(legacy.utf8))

        #expect(routine.name == "Morning")
        #expect(routine.schedule == nil)
        #expect(routine.recentRunDates == nil)
        #expect(routine.effectiveRecentRunDates.isEmpty)
        #expect(routine.isScheduled == false)
    }

    @Test
    func scheduleSurvivesAnEncodeDecodeRoundTrip() throws {
        let schedule = RoutineSchedule(
            cadence: .weekly,
            hour: 9,
            minute: 30,
            weekday: 2,
            isEnabled: true,
            unattendedTrusted: true,
            lastRunAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let routine = StoredRoutine(name: "Morning", steps: [.fixture], schedule: schedule)

        let data = try JSONEncoder().encode(routine)
        let decoded = try JSONDecoder().decode(StoredRoutine.self, from: data)

        #expect(decoded == routine)
        #expect(decoded.schedule == schedule)
    }

    // MARK: - The catch-up anchor

    /// The correctness requirement behind `lastRunAt`, not a nicety. Enabling a 9am daily routine
    /// at 3pm must not read as "this morning's 9am run was missed" — otherwise turning scheduling
    /// on is itself the trigger for an unattended run, which is exactly the surprise the whole
    /// per-routine opt-in exists to prevent. The anchor starts at the moment of enabling.
    @Test
    func enablingScheduleAnchorsTheCatchUpBaselineToTheMomentItWasEnabled() {
        let threePM = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        #expect(schedule.lastRunAt == nil)

        schedule.setEnabled(true, now: threePM)

        #expect(schedule.isEnabled)
        #expect(schedule.lastRunAt == threePM)
    }

    /// Re-enabling re-anchors: a routine disabled for three weeks and switched back on must not
    /// treat those three weeks as a backlog of missed occurrences.
    @Test
    func reEnablingReAnchorsRatherThanKeepingTheStaleBaseline() {
        let firstEnable = Date(timeIntervalSince1970: 1_700_000_000)
        let reEnable = firstEnable.addingTimeInterval(21 * 24 * 60 * 60)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)

        schedule.setEnabled(true, now: firstEnable)
        schedule.setEnabled(false, now: firstEnable.addingTimeInterval(60))
        schedule.setEnabled(true, now: reEnable)

        #expect(schedule.lastRunAt == reEnable)
    }

    /// Only an off → on transition re-anchors. Calling `setEnabled(true)` on an already-enabled
    /// schedule (an idempotent UI write, a re-save from some other edit) must leave the baseline
    /// alone, or every incidental save would silently erase the pending catch-up window.
    @Test
    func enablingAnAlreadyEnabledScheduleLeavesTheBaselineAlone() {
        let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        schedule.setEnabled(true, now: enabledAt)

        schedule.setEnabled(true, now: enabledAt.addingTimeInterval(9 * 60 * 60))

        #expect(schedule.lastRunAt == enabledAt)
    }

    /// Disabling keeps the old anchor rather than clearing it — clearing would make a
    /// disable/re-enable pair indistinguishable from a never-enabled schedule, and `setEnabled`'s
    /// re-anchor on the way back on is what actually protects the catch-up window.
    @Test
    func disablingDoesNotClearTheBaseline() {
        let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        schedule.setEnabled(true, now: enabledAt)

        schedule.setEnabled(false, now: enabledAt.addingTimeInterval(3_600))

        #expect(schedule.lastRunAt == enabledAt)
    }

    // MARK: - Catch-up windows

    /// Bounded by duration, deliberately not "the rest of the scheduled period": for a daily 9am
    /// routine the latter would still allow a catch-up fire at 11:59pm, which is the same
    /// unexpected-unattended-firing problem that ruled out unbounded catch-up in the first place.
    /// A morning routine at 11am is fine; at 11pm it is not.
    @Test
    func catchUpWindowsAreBoundedByDurationAndGrowWithCadence() {
        #expect(RoutineCadence.daily.catchUpWindow == 3 * 60 * 60)
        #expect(RoutineCadence.weekly.catchUpWindow == 24 * 60 * 60)
        #expect(RoutineCadence.monthly.catchUpWindow == 3 * 24 * 60 * 60)

        // The ordering is the actual invariant — a longer cadence tolerates a longer delay before
        // a catch-up stops making sense in the context it was scheduled for.
        let windows = RoutineCadence.allCases.map(\.catchUpWindow)
        #expect(windows == windows.sorted())
        // No window may reach its own cadence length, or catch-up degenerates into "fire whenever".
        #expect(RoutineCadence.daily.catchUpWindow < 24 * 60 * 60)
    }

    // MARK: - Validation

    @Test
    func savingRejectsOutOfRangeAndCadenceMismatchedSchedules() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        #expect(throws: AutomationStoreError.invalidSchedule("Run time must be a real time of day.")) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .daily, hour: 24, minute: 0)))
        }
        #expect(throws: AutomationStoreError.invalidSchedule("Run time must be a real time of day.")) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .daily, hour: 9, minute: 60)))
        }
        #expect(throws: AutomationStoreError.invalidSchedule("A weekly routine needs a weekday.")) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0)))
        }
        #expect(throws: AutomationStoreError.invalidSchedule("A monthly routine needs a day of the month.")) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0)))
        }
    }

    /// Day 29-31 is accepted rather than rejected: "run this on the 31st" is a legitimate thing to
    /// ask for, and resolving it in a 30-day month is the scheduler's date math (checkpoint 3), not
    /// a reason to refuse the schedule.
    /// The opposite boundary from the cases above. Without these, widening `(1...7)` to `(1...8)`
    /// or `(1...31)` to `(1...32)` would fail no test at all, and a weekday of 8 — not a real
    /// `Calendar` value — would be accepted and silently never match an occurrence.
    @Test
    func savingRejectsValuesJustPastEitherEndOfEveryValidRange() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let badTime = AutomationStoreError.invalidSchedule("Run time must be a real time of day.")
        let badWeekday = AutomationStoreError.invalidSchedule("A weekly routine needs a weekday.")
        let badDay = AutomationStoreError.invalidSchedule("A monthly routine needs a day of the month.")

        #expect(throws: badTime) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .daily, hour: -1, minute: 0)))
        }
        #expect(throws: badTime) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .daily, hour: 9, minute: -1)))
        }
        #expect(throws: badWeekday) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 0)))
        }
        #expect(throws: badWeekday) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 8)))
        }
        #expect(throws: badDay) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 0)))
        }
        #expect(throws: badDay) {
            try store.save(routine(schedule: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 32)))
        }
    }

    /// The inclusive ends must stay accepted — a range check tightened too far is as wrong as one
    /// left too loose, and nothing above would catch `(1...7)` becoming `(2...6)`.
    @Test
    func savingAcceptsEveryValueAtTheInclusiveEndsOfEachRange() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        try store.save(routine(schedule: RoutineSchedule(cadence: .daily, hour: 0, minute: 0)))
        try store.save(routine(schedule: RoutineSchedule(cadence: .daily, hour: 23, minute: 59)))
        try store.save(routine(schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 1)))
        try store.save(routine(schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 7)))
        try store.save(routine(schedule: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 1)))

        #expect(try store.routine(named: "Morning").schedule?.dayOfMonth == 1)
    }

    @Test
    func savingAcceptsMonthEndDaysThatDoNotExistInEveryMonth() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        try store.save(routine(schedule: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 31)))

        #expect(try store.routine(named: "Morning").schedule?.dayOfMonth == 31)
    }

    @Test
    func savingAnUnscheduledRoutineStillWorks() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        try store.save(StoredRoutine(name: "Morning", steps: [.fixture]))

        #expect(try store.routine(named: "Morning").schedule == nil)
    }

    // MARK: - Run history

    @Test
    func recordingRunsAppendsInOrderAndKeepsTheMostRecentWithinTheCap() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try store.save(StoredRoutine(name: "Morning", steps: [.fixture]))
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<(StoredRoutine.recentRunDateLimit + 10) {
            try store.recordRun(routineNamed: "Morning", at: base.addingTimeInterval(Double(index) * 86_400))
        }

        let dates = try store.routine(named: "Morning").effectiveRecentRunDates
        #expect(dates.count == StoredRoutine.recentRunDateLimit)
        // Trimming drops the *oldest*, so the newest run must survive — a cap that discarded the
        // newest would silently break any streak computed from this list.
        #expect(dates.last == base.addingTimeInterval(Double(StoredRoutine.recentRunDateLimit + 9) * 86_400))
        #expect(dates == dates.sorted())
    }

    /// `recordRun` sorts rather than assuming its input arrives in order, but the cap test above
    /// feeds a strictly increasing sequence — insertion order already equals sorted order there, so
    /// deleting the sort would break nothing. This is the case that actually exercises it: a
    /// backdated timestamp (a clock adjustment between runs, a catch-up recorded after a later
    /// manual run) must land in its correct position, because the trim below drops from the front
    /// on the assumption that the front is the oldest.
    @Test
    func recordingABackdatedRunKeepsHistorySortedInsteadOfAppendingItAtTheEnd() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try store.save(StoredRoutine(name: "Morning", steps: [.fixture]))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let later = base.addingTimeInterval(86_400)

        try store.recordRun(routineNamed: "Morning", at: later)
        try store.recordRun(routineNamed: "Morning", at: base)

        #expect(try store.routine(named: "Morning").effectiveRecentRunDates == [base, later])
    }

    /// The consequence of the above at the cap boundary: with history already full, a backdated
    /// run must be the entry that gets dropped — never the newest real run. An unsorted list would
    /// trim from the wrong end and silently delete the most recent run instead.
    @Test
    func aBackdatedRunAtTheCapIsDroppedRatherThanEvictingTheNewestRun() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try store.save(StoredRoutine(name: "Morning", steps: [.fixture]))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<StoredRoutine.recentRunDateLimit {
            try store.recordRun(routineNamed: "Morning", at: base.addingTimeInterval(Double(index) * 86_400))
        }
        let newest = base.addingTimeInterval(Double(StoredRoutine.recentRunDateLimit - 1) * 86_400)

        try store.recordRun(routineNamed: "Morning", at: base.addingTimeInterval(-86_400))

        let dates = try store.routine(named: "Morning").effectiveRecentRunDates
        #expect(dates.count == StoredRoutine.recentRunDateLimit)
        #expect(dates.last == newest)
        #expect(dates.contains(base.addingTimeInterval(-86_400)) == false)
    }

    /// Recording a run is not the same event as the scheduler firing: a manual run should show up
    /// in history (it is a real run, and the streak badge counts it) without moving the catch-up
    /// baseline, which only the scheduler owns.
    @Test
    func recordingARunDoesNotMoveTheCatchUpBaseline() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        schedule.setEnabled(true, now: enabledAt)
        try store.save(routine(schedule: schedule))

        try store.recordRun(routineNamed: "Morning", at: enabledAt.addingTimeInterval(7_200))

        let saved = try store.routine(named: "Morning")
        #expect(saved.effectiveRecentRunDates.count == 1)
        #expect(saved.schedule?.lastRunAt == enabledAt)
    }

    // MARK: - Redefining an existing routine

    /// `SaveRoutineCapabilityAdapter` builds a fresh `StoredRoutine(name:steps:)` for every save,
    /// and `save` replaces the dictionary entry wholesale — so "save a routine called Morning
    /// that opens Safari" against an already-scheduled Morning used to silently discard its
    /// schedule and its entire run history.
    ///
    /// That overwrite is already tier 3, so the user does approve *something* — but what the
    /// approval copy tells them is that the routine's steps would be replaced. Losing an
    /// unattended-trust opt-in and a streak is not what they agreed to, and nothing would have
    /// told them it happened.
    @Test
    func redefiningARoutineKeepsItsScheduleAndRunHistory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, unattendedTrusted: true)
        schedule.setEnabled(true, now: enabledAt)
        try store.save(routine(schedule: schedule))
        try store.recordRun(routineNamed: "Morning", at: enabledAt.addingTimeInterval(86_400))

        // Exactly what the save-routine adapter constructs: name + steps, nothing else.
        try store.save(
            StoredRoutine(
                name: "Morning",
                steps: [AgentStep(id: "mail", operation: .openApp, description: "Open Mail.", appName: "Mail")]
            )
        )

        let saved = try store.routine(named: "Morning")
        #expect(saved.steps.map(\.appName) == ["Mail"])
        #expect(saved.schedule == schedule)
        #expect(saved.schedule?.unattendedTrusted == true)
        #expect(saved.effectiveRecentRunDates.count == 1)
    }

    /// The counterpart: `setSchedule` is the explicit way to change or clear a schedule, so
    /// preserving-on-nil in `save` never becomes a trap where scheduling can't be turned off.
    @Test
    func setScheduleIsTheExplicitWayToChangeOrClearASchedule() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try store.save(StoredRoutine(name: "Morning", steps: [.fixture]))

        try store.setSchedule(routineNamed: "Morning", to: RoutineSchedule(cadence: .daily, hour: 7, minute: 15))
        #expect(try store.routine(named: "Morning").schedule?.hour == 7)

        try store.setSchedule(routineNamed: "Morning", to: nil)
        #expect(try store.routine(named: "Morning").schedule == nil)
    }

    @Test
    func setScheduleValidatesAndRejectsAnUnknownRoutine() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try store.save(StoredRoutine(name: "Morning", steps: [.fixture]))

        #expect(throws: AutomationStoreError.invalidSchedule("A weekly routine needs a weekday.")) {
            try store.setSchedule(routineNamed: "Morning", to: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0))
        }
        #expect(throws: AutomationStoreError.missingRoutine("Ghost")) {
            try store.setSchedule(routineNamed: "Ghost", to: RoutineSchedule(cadence: .daily, hour: 9, minute: 0))
        }
    }

    @Test
    func recordingARunForAnUnknownRoutineThrowsRatherThanSilentlyDoingNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        #expect(throws: AutomationStoreError.missingRoutine("Ghost")) {
            try store.recordRun(routineNamed: "Ghost", at: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    private func routine(schedule: RoutineSchedule) -> StoredRoutine {
        StoredRoutine(name: "Morning", steps: [.fixture], schedule: schedule)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutineScheduleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension AgentStep {
    static let fixture = AgentStep(
        id: "open",
        operation: .openApp,
        description: "Open Safari.",
        appName: "Safari"
    )
}
