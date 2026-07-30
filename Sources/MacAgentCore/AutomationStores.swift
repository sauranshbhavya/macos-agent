import Foundation

public struct StoredRoutine: Codable, Equatable, Sendable, Identifiable {
    /// How many past run timestamps a routine keeps. Enough to compute a streak of any length a
    /// user would recognise as one, small enough that the whole routines dictionary stays cheap to
    /// read — every `RoutineStore` write rewrites it.
    public static let recentRunDateLimit = 60

    public var name: String
    public var steps: [AgentStep]
    /// `schedule` and `recentRunDates` below are both Optional so a routines.json written before
    /// this branch still decodes — synthesized `Decodable` calls `decodeIfPresent` for Optional
    /// properties, where a non-Optional property with a Swift-side default would still call
    /// `decode(_:forKey:)` and throw `keyNotFound`. Same reasoning as `StoredWorkspace.teamType`.
    public var schedule: RoutineSchedule?
    /// Timestamps of past runs, oldest first, capped at `recentRunDateLimit`. Includes manual
    /// runs: the streak badge counts a run as a run regardless of what triggered it. Deliberately
    /// separate from `schedule?.lastRunAt`, which is the scheduler's catch-up baseline and moves
    /// only when the scheduler says so — enabling a schedule anchors the baseline without
    /// recording a run, and a manual run records history without moving the baseline.
    public var recentRunDates: [Date]?

    public init(
        name: String,
        steps: [AgentStep],
        schedule: RoutineSchedule? = nil,
        recentRunDates: [Date]? = nil
    ) {
        self.name = name
        self.steps = steps
        self.schedule = schedule
        self.recentRunDates = recentRunDates
    }

    /// Run history as callers want to read it. "No key on disk" and "recorded, then trimmed to
    /// empty" are not distinctions any reader of this list cares about — both mean no runs.
    public var effectiveRecentRunDates: [Date] {
        recentRunDates ?? []
    }

    /// Has a schedule that is actually turned on. A saved-but-disabled schedule is not scheduled.
    public var isScheduled: Bool {
        schedule?.isEnabled == true
    }

    public var plan: AgentPlan {
        AgentPlan(
            summary: "Run routine \(name).",
            requiresConfirmation: true,
            steps: steps
        )
    }

    /// Matches `RoutineStore`'s existing name-keyed dictionary and `RoutinesView`'s
    /// `ForEach(..., id: \.element.name)` — routine names are already the real identity here.
    public var id: String { name }
}

public enum WorkspaceTeamType: String, Codable, Equatable, Sendable {
    case solo
    case team
}

public struct StoredWorkspace: Codable, Equatable, Sendable {
    public var name: String
    public var apps: [String]
    public var urls: [String]
    public var teamType: WorkspaceTeamType?

    public init(name: String, apps: [String], urls: [String], teamType: WorkspaceTeamType? = nil) {
        self.name = name
        self.apps = apps
        self.urls = urls
        self.teamType = teamType
    }

    /// `teamType` is Optional so legacy on-disk JSON missing the key still decodes (synthesized
    /// `Decodable` calls `decodeIfPresent` for Optional properties) — a non-optional property with
    /// a Swift-side default would NOT protect existing files, since synthesized decoding still
    /// calls `decode(_:forKey:)` and throws `keyNotFound` regardless of any default literal.
    public var effectiveTeamType: WorkspaceTeamType {
        teamType ?? .solo
    }
}

public enum AutomationStoreError: Error, LocalizedError, Equatable {
    case missingName(String)
    case missingRoutine(String)
    case missingWorkspace(String)
    case emptyRoutine
    case emptyWorkspace
    case unsafeRoutineStep(String)
    case invalidSchedule(String)

    public var errorDescription: String? {
        switch self {
        case .missingName(let kind):
            return "\(kind) needs a name."
        case .missingRoutine(let name):
            return "No routine named \(name) is saved."
        case .missingWorkspace(let name):
            return "No workspace named \(name) is saved."
        case .emptyRoutine:
            return "A routine needs at least one saved step."
        case .emptyWorkspace:
            return "A workspace needs at least one app or URL."
        case .unsafeRoutineStep(let operation):
            return "Routines cannot contain \(operation) steps."
        case .invalidSchedule(let reason):
            return reason
        }
    }
}

/// Every mutating method here is a *single synchronous call* that loads, mutates and writes without
/// suspending. That is the property that makes routine-store writes safe, and it is load-bearing as
/// of branch 10: the scheduler's timer is this codebase's first background writer, so for the first
/// time two writers can genuinely want the same record. Until now every writer was user-initiated
/// and therefore serialized by human pace, which is why the identical read-modify-write shape in
/// the other stores has never been reachable.
///
/// A lock is deliberately *not* the fix. All callers are `@MainActor` (`AgentViewModel` and the
/// capability adapters), so the actor already serializes whole synchronous calls against each
/// other; a lock would add nothing. What a lock would *also* not fix is the real hazard, so state
/// it plainly: **never read a routine, `await` anything, then write it back.** A read-modify-write
/// spanning a suspension point can interleave with another main-actor task and silently drop the
/// loser's write, and no amount of locking inside these methods prevents that. If a caller needs a
/// new kind of mutation, add a method here rather than reading, awaiting and saving at the call
/// site.
public struct RoutineStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("routines.json")
        }
    }

    /// Creates a routine, or redefines an existing one's steps.
    ///
    /// Carries forward the existing schedule and run history whenever the incoming routine leaves
    /// them nil. `SaveRoutineCapabilityAdapter` builds a fresh `StoredRoutine(name:steps:)` for
    /// every save, so without this a user saying "save a routine called Morning that opens Safari"
    /// over an already-scheduled Morning would silently lose its schedule, its unattended-trust
    /// opt-in, and its whole streak. That overwrite is tier 3, so they do approve something — but
    /// the approval copy tells them the *steps* would be replaced, which is not the same consent.
    ///
    /// Use `setSchedule(routineNamed:to:)` to change or clear a schedule; passing nil here means
    /// "I am not talking about scheduling", not "remove it".
    public func save(_ routine: StoredRoutine) throws {
        try routine.schedule?.validate()
        var routines = try loadAll()
        let key = normalized(routine.name)
        var merged = routine
        if let existing = routines[key] {
            merged.schedule = routine.schedule ?? existing.schedule
            merged.recentRunDates = routine.recentRunDates ?? existing.recentRunDates
        }
        routines[key] = merged
        try write(routines)
    }

    /// The one way to change or clear a routine's schedule — nil genuinely means "unschedule".
    /// Exists so `save`'s preserve-on-nil behavior can never become a trap where scheduling is
    /// impossible to turn off.
    public func setSchedule(routineNamed rawName: String, to schedule: RoutineSchedule?) throws {
        try schedule?.validate()
        let key = try normalizedName(rawName, kind: "Routine")
        var routines = try loadAll()
        guard var routine = routines[key] else {
            throw AutomationStoreError.missingRoutine(rawName)
        }
        routine.schedule = schedule
        routines[key] = routine
        try write(routines)
    }

    /// Moves the scheduler's catch-up baseline past a handled occurrence.
    ///
    /// Called for *every* resolved occurrence, not just successful ones — a run, a tier-3 skip, a
    /// clarification skip and a too-stale skip all advance it. Without that, the next tick would
    /// resolve the same occurrence again and the scheduler would retry a routine it just refused,
    /// or re-report the same missed run, once per tick forever.
    ///
    /// A no-op for a routine with no schedule rather than an error: a schedule can legitimately be
    /// cleared between the decision and the write.
    public func advanceScheduleBaseline(routineNamed rawName: String, to occurrence: Date) throws {
        let key = try normalizedName(rawName, kind: "Routine")
        var routines = try loadAll()
        guard var routine = routines[key], routine.schedule != nil else {
            return
        }
        routine.schedule?.lastRunAt = occurrence
        routines[key] = routine
        try write(routines)
    }

    /// Appends a run timestamp to the routine's history, trimming to `recentRunDateLimit`.
    ///
    /// Deliberately does not touch `schedule?.lastRunAt`: a manual run is a real run for streak
    /// purposes but must not move the scheduler's catch-up baseline, or clicking Run at 8am would
    /// silently cancel that day's scheduled 9am occurrence. The scheduler owns that field.
    ///
    /// Throws rather than no-oping for an unknown name — a silently dropped write here would
    /// present as a streak that mysteriously never advances.
    public func recordRun(routineNamed rawName: String, at date: Date = Date()) throws {
        let key = try normalizedName(rawName, kind: "Routine")
        var routines = try loadAll()
        guard var routine = routines[key] else {
            throw AutomationStoreError.missingRoutine(rawName)
        }
        // Sorted rather than assumed-monotonic: a clock adjustment between runs would otherwise
        // leave the list out of order, and the trim below drops from the front on the assumption
        // that the front is the oldest.
        var dates = (routine.recentRunDates ?? []) + [date]
        dates.sort()
        routine.recentRunDates = Array(dates.suffix(StoredRoutine.recentRunDateLimit))
        routines[key] = routine
        try write(routines)
    }

    public func routine(named rawName: String) throws -> StoredRoutine {
        let name = try normalizedName(rawName, kind: "Routine")
        guard let routine = try loadAll()[name] else {
            throw AutomationStoreError.missingRoutine(rawName)
        }
        return routine
    }

    public func loadAll() throws -> [String: StoredRoutine] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode([String: StoredRoutine].self, from: data)
        return decoded.migratingLegacyPlaintext(store: "routines", write: write)
    }

    private func write(_ routines: [String: StoredRoutine]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(routines, encoder: .prettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct WorkspaceStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("workspaces.json")
        }
    }

    public func save(_ workspace: StoredWorkspace) throws {
        var workspaces = try loadAll()
        workspaces[normalized(workspace.name)] = workspace
        try write(workspaces)
    }

    public func workspace(named rawName: String) throws -> StoredWorkspace {
        let name = try normalizedName(rawName, kind: "Workspace")
        guard let workspace = try loadAll()[name] else {
            throw AutomationStoreError.missingWorkspace(rawName)
        }
        return workspace
    }

    public func loadAll() throws -> [String: StoredWorkspace] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode([String: StoredWorkspace].self, from: data)
        return decoded.migratingLegacyPlaintext(store: "workspaces", write: write)
    }

    private func write(_ workspaces: [String: StoredWorkspace]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(workspaces, encoder: .prettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private func normalizedName(_ rawName: String?, kind: String) throws -> String {
    guard let rawName else {
        throw AutomationStoreError.missingName(kind)
    }
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AutomationStoreError.missingName(kind)
    }
    return normalized(trimmed)
}

func normalized(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
