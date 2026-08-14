import Foundation

// MARK: - Record vocabulary

/// What the destination provider does with a payload after serving the request. Declared per
/// provider at registration (see `PlannerProvider.retentionPosture`) so the fact lives next to
/// the provider it describes, and `.unknown` is the honest default for any provider that never
/// declared one — the ledger states ignorance rather than guessing.
public enum ProviderRetentionPosture: String, Codable, Equatable, Sendable {
    case notRetained = "not_retained"
    case retainedTemporarily = "retained_temporarily"
    case unknown

    public var displayName: String {
        switch self {
        case .notRetained:
            return "Not retained by the provider"
        case .retainedTemporarily:
            return "Retained temporarily by the provider"
        case .unknown:
            return "Retention posture unknown"
        }
    }
}

/// Order-of-magnitude size of the user-supplied content in one egress payload. A size class
/// rather than a byte count because the number the user needs is "how much of mine left", not a
/// figure that varies per encoding detail.
public enum AIEgressPayloadSizeClass: String, Codable, CaseIterable, Equatable, Sendable {
    case underOneKB = "under_1kb"
    case underTenKB = "under_10kb"
    case underHundredKB = "under_100kb"
    case overHundredKB = "over_100kb"

    public init(byteCount: Int) {
        switch byteCount {
        case ..<1_024:
            self = .underOneKB
        case ..<10_240:
            self = .underTenKB
        case ..<102_400:
            self = .underHundredKB
        default:
            self = .overHundredKB
        }
    }

    public var displayName: String {
        switch self {
        case .underOneKB: return "Under 1 KB"
        case .underTenKB: return "Under 10 KB"
        case .underHundredKB: return "Under 100 KB"
        case .overHundredKB: return "Over 100 KB"
        }
    }
}

/// One egress event: one payload that left the device for one provider. §14.5's checklist items
/// that describe the *egress itself* live here (context sources, redaction summary,
/// provider/model, retained-status, size); the two run-outcome items (local actions taken,
/// artifacts created) join from the run's own result at the surface, exactly as the ticket
/// records.
public struct AIEgressEntry: Codable, Equatable, Sendable {
    /// Planner prompts are the only kind produced today; the three vision kinds exist so row I's
    /// call sites plug into a vocabulary that already names them, not so anything fakes them now.
    public enum Kind: String, Codable, Equatable, Sendable {
        case plannerPrompt = "planner_prompt"
        case screenshot
        case ocrText = "ocr_text"
        case fileExcerpt = "file_excerpt"

        public var displayName: String {
            switch self {
            case .plannerPrompt: return "Planner prompt"
            case .screenshot: return "Screenshot"
            case .ocrText: return "Screen text"
            case .fileExcerpt: return "File excerpt"
            }
        }
    }

    public var kind: Kind
    public var sentAt: Date
    public var providerID: String
    public var providerName: String
    /// The model identifier the payload was addressed to, when the planner states one. `nil`
    /// renders as unspecified — never invented.
    public var model: String?
    public var retentionPosture: ProviderRetentionPosture
    public var payloadSizeClass: AIEgressPayloadSizeClass
    /// Which of the user's things fed this payload ("command", "prior task context"; vision
    /// entries add screens/files).
    public var contextSources: [String]
    /// SONNY-89's per-class redaction report for this payload. Empty when nothing was detected —
    /// or when the payload kind is not redacted at all (planner prompts are not; the planner
    /// prompt is untouched by this branch per the ticket's never-touch list).
    public var redactionSummary: [RedactionReportEntry]

    public init(
        kind: Kind,
        sentAt: Date,
        providerID: String,
        providerName: String,
        model: String?,
        retentionPosture: ProviderRetentionPosture,
        payloadSizeClass: AIEgressPayloadSizeClass,
        contextSources: [String],
        redactionSummary: [RedactionReportEntry] = []
    ) {
        self.kind = kind
        self.sentAt = sentAt
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
        self.retentionPosture = retentionPosture
        self.payloadSizeClass = payloadSizeClass
        self.contextSources = contextSources
        self.redactionSummary = redactionSummary
    }
}

/// The Data-Sent-to-AI record for one run: every payload that left the device, written by the
/// layer that performed the egress at the moment it happened — never reconstructed afterwards.
/// `runStartedAt` carries the same instant `CompletedTaskRecord.startedAt` records for the same
/// run, which is the join the task-detail surface reads; a run with no record here is a run
/// that sent nothing.
public struct AIEgressRecord: Codable, Equatable, Sendable {
    public var runID: UUID
    public var runStartedAt: Date
    public var entries: [AIEgressEntry]

    public init(runID: UUID, runStartedAt: Date, entries: [AIEgressEntry]) {
        self.runID = runID
        self.runStartedAt = runStartedAt
        self.entries = entries
    }
}

// MARK: - Store

/// Ninth local store, exactly on the shared pattern: defaulted
/// `encryption: LocalStorageEncryption = .shared`, `SONNYENC1\n` header via that encryption,
/// legacy-plaintext migration on load, count-capped like `TaskHistoryStore`. Deletion reaches it
/// through `LocalDataDeletionService.defaultStoreFileURLs` (§14.7), and its retention follows
/// task history's: the same record-count cap today, and row D's recorded 30-day retention
/// decision lands on both together when that row builds it.
public struct AIEgressStore: @unchecked Sendable {
    public static let maxItems = 10_000

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
                .appendingPathComponent("ai-egress-ledger.json")
        }
    }

    /// Appends one egress entry to its run's record, creating the record on the run's first
    /// egress. Called at egress time by the recording layer.
    public func append(_ entry: AIEgressEntry, runID: UUID, runStartedAt: Date) throws {
        var records = try loadAll()
        if let index = records.firstIndex(where: { $0.runID == runID }) {
            records[index].entries.append(entry)
        } else {
            records.append(AIEgressRecord(runID: runID, runStartedAt: runStartedAt, entries: [entry]))
        }
        try write(capped(records))
    }

    public func loadAll() throws -> [AIEgressRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [AIEgressRecord].self,
            from: data,
            decoder: .aiEgressISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "AI egress ledger", write: write)
    }

    /// The task-detail join read: the record `CompletedTaskRecord.egressRunID` names, or nil for
    /// a run that sent nothing — absence IS the honest empty record.
    public func record(forRunID runID: UUID) throws -> AIEgressRecord? {
        try loadAll().first { $0.runID == runID }
    }

    private func capped(_ records: [AIEgressRecord]) -> [AIEgressRecord] {
        guard records.count > Self.maxItems else {
            return records
        }
        return Array(
            records
                .sorted { $0.runStartedAt < $1.runStartedAt }
                .suffix(Self.maxItems)
        )
    }

    private func write(_ records: [AIEgressRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(records, encoder: .aiEgressPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var aiEgressPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var aiEgressISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Recording seam

/// Writes egress entries as they happen. One conformer per run — the run identity lives in the
/// recorder, so the layers that perform egress only ever say *what* left, never re-derive whose
/// run it was.
public protocol AIEgressRecording: Sendable {
    func record(_ entry: AIEgressEntry) async
}

/// The store-backed recorder for one run. A ledger write failure must not fail the run — the
/// ledger is transparency, not a gate — but it must not be silent either: the failure surfaces
/// through `onWriteFailure` (a visible error message in the app), following the accurate-write-
/// failure-wording convention rather than the load-failure banner.
public final class AIEgressLedgerRecorder: AIEgressRecording {
    private let store: AIEgressStore
    private let runID: UUID
    private let runStartedAt: Date
    private let onWriteFailure: @MainActor @Sendable (String) -> Void

    public init(
        store: AIEgressStore,
        runID: UUID,
        runStartedAt: Date,
        onWriteFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.store = store
        self.runID = runID
        self.runStartedAt = runStartedAt
        self.onWriteFailure = onWriteFailure
    }

    public func record(_ entry: AIEgressEntry) async {
        do {
            try store.append(entry, runID: runID, runStartedAt: runStartedAt)
        } catch {
            let message = "Sonny could not record this run's Data-Sent-to-AI entry: \(error.localizedDescription)"
            await MainActor.run { [onWriteFailure] in
                onWriteFailure(message)
            }
        }
    }
}

// MARK: - The planner egress layer

/// The layer that performs planner egress. Every planner the registry constructs is wrapped in
/// one of these (`PlannerProviderRegistry.makePlanner` takes the recorder as a non-defaulted
/// parameter, so a construction site cannot forget), and the entry is written *before*
/// delegation — a prompt that leaves the device and then fails on the response still left the
/// device, and its record must exist. This is what makes "an egress with no ledger entry is a
/// bug by construction" structural: the only production path to a network planner runs through
/// the registry, and the registry cannot hand one out unwrapped.
public final class EgressRecordingPlanner: Planning {
    private let wrapped: any Planning
    private let provider: PlannerProvider
    private let recorder: any AIEgressRecording
    private let now: @Sendable () -> Date

    public init(
        wrapping wrapped: any Planning,
        provider: PlannerProvider,
        recorder: any AIEgressRecording,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.wrapped = wrapped
        self.provider = provider
        self.recorder = recorder
        self.now = now
    }

    public func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        await recorder.record(entry(command: command, priorTaskContext: priorTaskContext))
        return try await wrapped.plan(command: command, priorTaskContext: priorTaskContext)
    }

    private func entry(command: String, priorTaskContext: PriorTaskContext?) -> AIEgressEntry {
        var contextSources = ["command"]
        // Sized over the user-supplied content — the command plus the exact prior-context text
        // the planner embeds — not over the planner's own fixed scaffold, which is Sonny's text,
        // not the user's.
        var userContentBytes = command.utf8.count
        if let priorTaskContext {
            contextSources.append("prior task context")
            userContentBytes += priorTaskContext.plannerContextText.utf8.count
        }
        return AIEgressEntry(
            kind: .plannerPrompt,
            sentAt: now(),
            providerID: provider.id,
            providerName: provider.displayName,
            model: wrapped.plannerModelIdentifier,
            retentionPosture: provider.retentionPosture,
            payloadSizeClass: AIEgressPayloadSizeClass(byteCount: userContentBytes),
            contextSources: contextSources
        )
    }
}
