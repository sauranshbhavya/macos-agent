import Foundation

/// One synthesized action, as it happened (spec §13.6).
///
/// **Written by the engine as the action executes, never reconstructed afterwards.** That is the
/// difference between an audit surface and a summary: a reconstruction can only say what the code
/// believes it did, while this is written by the containment layer at the moment it decided, from
/// the same values the decision used. If the journal and the run ever disagree, the journal is the
/// one that was there.
public struct VisionActionJournalEntry: Codable, Equatable, Sendable {
    /// How this action was authorized, in the user's terms.
    public enum ApprovalState: String, Codable, CaseIterable, Equatable, Sendable {
        /// It ran without asking — Normal or Power, ordinary consequence class.
        case ranWithoutAsking = "ran_without_asking"
        /// The user was asked and allowed it.
        case approved
        /// A previous approval in this same session still covered it (the SONNY-62 rule).
        case coveredByEarlierApproval = "covered_by_earlier_approval"
    }

    public var timestamp: Date
    public var appDisplayName: String
    public var appBundleIdentifier: String
    public var actionType: String
    /// What the action was aimed at, in the model's own words — the visible control label, or the
    /// field being typed into. Screen-derived and therefore untrusted, which is why it is recorded
    /// as *observed* rather than presented as fact.
    public var targetDescription: String
    /// The point inside the captured image, when the action used one. `nil` for typing, key presses
    /// and pointer-relative scrolls.
    public var imageX: Int?
    public var imageY: Int?
    /// The tier this action was assessed at, including any mid-loop escalation — so a record of a
    /// destructive click says tier 3 rather than the session's baseline.
    public var riskTier: CapabilityRiskTier
    public var consequence: CapabilityRiskEscalation.Consequence
    public var approvalState: ApprovalState
    /// What the loop observed *after* acting: the outcome the substrate reported, or the
    /// corrective note the model was given. §13.6 asks for observation-after specifically, and it is
    /// the field that turns "Sonny clicked at 400,300" into something a person can evaluate.
    public var observationAfter: String
    /// What redaction found and covered on the capture that led to this action.
    ///
    /// **The surviving half of the transcript's egress story.** SONNY-96 contracted the transcript as
    /// journal entries joined to the V2 ledger's screenshots — and the founder deleted that ledger on
    /// 2026-08-14, along with per-run egress recording. What is kept is what protection was applied,
    /// which is a fact about Sonny's own behaviour rather than a copy of the user's screen.
    public var redactionSummary: [RedactionReportEntry]

    public init(
        timestamp: Date,
        appDisplayName: String,
        appBundleIdentifier: String,
        actionType: String,
        targetDescription: String,
        imageX: Int? = nil,
        imageY: Int? = nil,
        riskTier: CapabilityRiskTier,
        consequence: CapabilityRiskEscalation.Consequence,
        approvalState: ApprovalState,
        observationAfter: String,
        redactionSummary: [RedactionReportEntry] = []
    ) {
        self.timestamp = timestamp
        self.appDisplayName = appDisplayName
        self.appBundleIdentifier = appBundleIdentifier
        self.actionType = actionType
        self.targetDescription = targetDescription
        self.imageX = imageX
        self.imageY = imageY
        self.riskTier = riskTier
        self.consequence = consequence
        self.approvalState = approvalState
        self.observationAfter = observationAfter
        self.redactionSummary = redactionSummary
    }
}

/// Everything one screen-control session did, addressable as one record.
public struct VisionSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var goal: String
    public var appDisplayName: String
    public var startedAt: Date
    public var endedAt: Date?
    /// The §13.5 reason code the session ended with, or `nil` while it is still running.
    public var endReasonCode: String?
    public var endSummary: String?
    public var entries: [VisionActionJournalEntry]

    public init(
        id: String = UUID().uuidString,
        goal: String,
        appDisplayName: String,
        startedAt: Date,
        endedAt: Date? = nil,
        endReasonCode: String? = nil,
        endSummary: String? = nil,
        entries: [VisionActionJournalEntry] = []
    ) {
        self.id = id
        self.goal = goal
        self.appDisplayName = appDisplayName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReasonCode = endReasonCode
        self.endSummary = endSummary
        self.entries = entries
    }
}

/// The action journal — the eleventh local store, on the shared pattern exactly.
///
/// **A sibling store rather than an extension of an existing one, and the reasoning is recorded here
/// because SONNY-96 asks for one decision with reasons.** The ticket offered "extend V2's store or
/// add a sibling"; V2's store no longer exists — the founder deleted the Data-Sent-to-AI ledger on
/// 2026-08-14 — so extending it was never available. Of the stores that do exist, `TaskHistoryStore`
/// was the only plausible host, and folding a per-action journal into it would have been wrong twice
/// over: task history is a bounded 10,000-record recency window feeding streak and insight
/// statistics, and a session's worth of action entries riding inside one of those records would let
/// one vision session evict a fortnight of history. Retention parity is achieved by matching its cap
/// and eviction rule, not by sharing its file.
public struct VisionSessionJournalStore: @unchecked Sendable {
    /// Matched to `TaskHistoryStore.maxItems`' *spirit* rather than its number: retention parity
    /// means a journal outlives nothing its task record does not, and sessions are far heavier per
    /// record than a task row. Oldest-first eviction by `startedAt`, the same rule task history uses.
    public static let maxSessions = 500

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
                .appendingPathComponent("vision-sessions.json")
        }
    }

    public func loadAll() throws -> [VisionSessionRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [VisionSessionRecord].self,
            from: data,
            decoder: .visionJournalISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "vision-sessions", write: write)
    }

    public func record(withID id: String) throws -> VisionSessionRecord? {
        try loadAll().first { $0.id == id }
    }

    /// Insert or replace one session's record.
    ///
    /// Whole-record writes rather than append-an-entry, because a session's entries only ever grow
    /// and the alternative — a partial write per action — is a file rewritten a dozen times a
    /// session for no benefit a reader can see.
    public func save(_ record: VisionSessionRecord) throws {
        var records = try loadAll()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try write(evicted(records))
    }

    public func deleteAll() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func evicted(_ records: [VisionSessionRecord]) -> [VisionSessionRecord] {
        guard records.count > Self.maxSessions else {
            return records
        }
        return Array(records.sorted { $0.startedAt < $1.startedAt }.suffix(Self.maxSessions))
    }

    private func write(_ records: [VisionSessionRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(records, encoder: .visionJournalPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var visionJournalPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var visionJournalISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
