import Foundation

/// A routine saved as a goal (V2 plan decision 9): its name, the goal in the person's words, and
/// when it runs. Each run is a new task that plans the goal again.
public struct RoutineGoal: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var goal: String
    /// When it runs, as the person said it when the routine was saved.
    public var schedule: String?
    /// When it runs, as set on the Routines page. A scheduled run is unattended.
    public var timing: RoutineSchedule?
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, goal: String, schedule: String?, timing: RoutineSchedule? = nil, savedAt: Date) {
        self.id = id
        self.name = name
        self.goal = goal
        self.schedule = schedule
        self.timing = timing
        self.savedAt = savedAt
    }
}

/// Where routines live: one encrypted file under V2's own folder, nothing read from V1's stores.
public actor RoutineGoalStore {
    private let file: EncryptedListFile<RoutineGoal>
    private var cached: [RoutineGoal]?

    /// `fileURL` nil keeps routines in memory, for tests.
    public init(fileURL: URL?, encryption: LocalStorageEncryption = .shared) {
        file = EncryptedListFile(url: fileURL, encryption: encryption, name: "routines")
    }

    /// Every routine, by name. Throws when the file is there but can't be read; then `save` and
    /// `delete` refuse too, and the next call reads the file again.
    public func all() throws -> [RoutineGoal] {
        if let cached { return cached }
        let loaded = try file.read()
        cached = loaded
        return loaded
    }

    public func routine(named name: String) throws -> RoutineGoal? {
        try all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func delete(_ id: UUID) throws {
        try write(all().filter { $0.id != id })
    }

    /// Saves a routine, replacing one with the same name.
    public func save(_ routine: RoutineGoal) throws {
        var routines = try all().filter { $0.name.caseInsensitiveCompare(routine.name) != .orderedSame }
        routines.append(routine)
        routines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try write(routines)
    }

    private func write(_ routines: [RoutineGoal]) throws {
        try file.write(routines)
        cached = routines
    }
}

/// `save_routine` v1. Replacing a routine of the same name is destructive, so it asks.
struct SaveRoutineCapability: Capability {
    let name = "save_routine"
    let version = 1
    let store: RoutineGoalStore
    let now: @Sendable () -> Date

    func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        let values = OperationArgs(args)
        let name = try values.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = try values.text("goal").trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = try values.optionalText("schedule")
        let existing = try await store.routine(named: name)
        return PreparedAction(
            actionID: actionID,
            effect: existing == nil ? .create : .destructive,
            targetIdentity: "routine:\(name.lowercased())",
            content: [goal, schedule ?? ""].joined(separator: "\n"),
            preview: ApprovalPreview(
                title: existing == nil ? "Save the routine \"\(name)\"" : "Replace the routine \"\(name)\"",
                details: [goal] + (schedule.map { ["Runs \($0)"] } ?? [])
            ),
            retry: .idempotent,
            payload: RoutineGoal(id: existing?.id ?? UUID(), name: name, goal: goal, schedule: schedule, timing: existing?.timing, savedAt: now())
        )
    }

    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        guard let routine = prepared.payload as? RoutineGoal else { return .failed(.executionError, "save_routine was prepared elsewhere.") }
        do {
            try await store.save(routine)
            return .done("Saved the routine \"\(routine.name)\".")
        } catch {
            return .failed(.executionError, "The routine couldn't be saved.")
        }
    }
}
