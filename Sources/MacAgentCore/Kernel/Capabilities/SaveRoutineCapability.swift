import Foundation

/// A routine saved as a goal (V2 plan decision 9): its name, the goal in the person's words, and
/// when it runs. Each run is a new task that plans the goal again.
public struct RoutineGoal: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var goal: String
    public var schedule: String?
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, goal: String, schedule: String?, savedAt: Date) {
        self.id = id
        self.name = name
        self.goal = goal
        self.schedule = schedule
        self.savedAt = savedAt
    }
}

/// Where routines live: one encrypted file under V2's own folder, nothing read from V1's stores.
public actor RoutineGoalStore {
    private let fileURL: URL?
    private let encryption: LocalStorageEncryption
    private var cached: [RoutineGoal]?

    /// `fileURL` nil keeps routines in memory, for tests.
    public init(fileURL: URL?, encryption: LocalStorageEncryption = .shared) {
        self.fileURL = fileURL
        self.encryption = encryption
    }

    public static func inApplicationSupport() throws -> RoutineGoalStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return RoutineGoalStore(fileURL: base.appendingPathComponent("Sonny/V2/routines.json"))
    }

    public func all() -> [RoutineGoal] {
        if let cached { return cached }
        var loaded: [RoutineGoal] = []
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           case .encrypted(let routines)? = try? encryption.decode([RoutineGoal].self, from: data) {
            loaded = routines
        }
        cached = loaded
        return loaded
    }

    public func routine(named name: String) -> RoutineGoal? {
        all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves a routine, replacing one with the same name.
    public func save(_ routine: RoutineGoal) throws {
        var routines = all().filter { $0.name.caseInsensitiveCompare(routine.name) != .orderedSame }
        routines.append(routine)
        routines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encryption.encode(routines).write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
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
        let existing = await store.routine(named: name)
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
            payload: RoutineGoal(id: existing?.id ?? UUID(), name: name, goal: goal, schedule: schedule, savedAt: now())
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
