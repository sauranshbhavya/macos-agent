import Foundation

public enum AIUsageCallKind: String, Codable, Equatable, Sendable {
    case planner
    case webResearchSynthesis = "web_research_synthesis"
    case transcription
    /// One `POST /v1/screen/analyze` — **one iteration of a screen-control session, not a session**
    /// (SONNY-131).
    ///
    /// **It had no case at all until this ticket, and the omission was total**: nothing on the vision
    /// path recorded usage, so the most expensive call the product makes was the one thing its own
    /// per-task summary said nothing about. Screen control is also SONNY-17's only paid line, so the
    /// gap was in the direction that matters.
    ///
    /// **Per iteration rather than per session**, because that is what a usage record is everywhere
    /// else here — one provider call — and because a session's twelve iterations are twelve separate
    /// upstream requests with twelve separate costs. A user's summary saying "12 screen-control
    /// calls" is the truth; saying "1" would hide the term that grows.
    ///
    /// The wire value is `screen_control` rather than `screen.analyze`, because it names the *thing
    /// the user did* and stays stable when the route's path changes. `AIUsageRecord.model` carries
    /// the route name (`SonnyModelRoute.screenAnalyze.usageModelName`), which is where a path
    /// belongs.
    ///
    /// **The reason above used to say these raw values are "persisted in `CompletedTaskRecord`", and
    /// nothing persists them** (PR #144, F2). `CompletedTaskRecord` has no usage field
    /// (`grep -cin usage Sources/MacAgentCore/TaskHistoryStore.swift` → 0, exit 1) and
    /// `TaskUsageRecorder` is an in-memory array reset per run, so no raw value has ever reached a
    /// file. The *choice* is unchanged and still right; what was wrong was calling a durability
    /// constraint as the reason for it. **A later session reading the old sentence would have written
    /// a migration or a decode-tolerance test for values nothing writes** — SONNY-133's most likely,
    /// since this branch's proposal comment on that ticket repeated it. The constraint becomes real
    /// the day something persists usage, which is that ticket's; until then this is a name chosen to
    /// age well rather than one already committed to.
    case screenControl = "screen_control"

    public var displayName: String {
        switch self {
        case .planner:
            return "Planner"
        case .webResearchSynthesis:
            return "Web research"
        case .transcription:
            return "Transcription"
        case .screenControl:
            return "Screen control"
        }
    }
}

public enum AIUsageTokenSource: String, Codable, Equatable, Sendable {
    case reported
    case estimated
}

public struct AIUsageTokenCounts: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    public var resolvedTotalTokens: Int? {
        if let totalTokens {
            return totalTokens
        }
        switch (inputTokens, outputTokens) {
        case (.some(let input), .some(let output)):
            return input + output
        case (.some(let input), .none):
            return input
        case (.none, .some(let output)):
            return output
        case (.none, .none):
            return nil
        }
    }
}

public struct AIUsageRecord: Codable, Equatable, Sendable {
    public var kind: AIUsageCallKind
    public var model: String
    public var tokenSource: AIUsageTokenSource?
    public var tokenCounts: AIUsageTokenCounts
    public var audioDurationSeconds: Double?

    public init(
        kind: AIUsageCallKind,
        model: String,
        tokenSource: AIUsageTokenSource? = nil,
        tokenCounts: AIUsageTokenCounts = AIUsageTokenCounts(inputTokens: nil, outputTokens: nil, totalTokens: nil),
        audioDurationSeconds: Double? = nil
    ) {
        self.kind = kind
        self.model = model
        self.tokenSource = tokenSource
        self.tokenCounts = tokenCounts
        self.audioDurationSeconds = audioDurationSeconds
    }

    public static func responses(
        kind: AIUsageCallKind,
        model: String,
        reportedUsage: AIUsageTokenCounts?,
        estimatedInputText: String,
        estimatedOutputText: String
    ) -> AIUsageRecord {
        if let reportedUsage {
            return AIUsageRecord(
                kind: kind,
                model: model,
                tokenSource: .reported,
                tokenCounts: reportedUsage
            )
        }

        let inputTokens = AIUsageEstimator.estimateTextTokens(estimatedInputText)
        let outputTokens = AIUsageEstimator.estimateTextTokens(estimatedOutputText)
        return AIUsageRecord(
            kind: kind,
            model: model,
            tokenSource: .estimated,
            tokenCounts: AIUsageTokenCounts(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: inputTokens + outputTokens
            )
        )
    }
}

/// What this run has spent, as the app itself counted it.
///
/// **This is an approximation, and the server's metering event is the billable truth** (SONNY-133;
/// `docs/sonny-backend-api-contract.md` §11 states it as a rule: "Server-side metering is the
/// billable truth; where the two disagree the server is authoritative, and the local summary must
/// not silently go blank"). Both halves matter and they pull in opposite directions, so both are
/// written down here rather than left to be inferred:
///
/// - **Where the two disagree, the server wins.** Since SONNY-133 every call is recorded server-side
///   in `sonny.metering_event`, from the gateway's own view of the exchange — which provider served,
///   what it reported, how long it took, whether the caller was still there. Nothing on this side
///   ever reports a number *to* the server: §2.4.1 forbids it ("a client-reported bill is not a
///   bill"), so this summary cannot become the bill by accident.
/// - **And it must keep populating anyway.** A summary that quietly stopped filling looks exactly
///   like a task that cost nothing, and it is the surface a user can actually see. It is fed by the
///   four recording clients — `OpenAIPlanner`, `WebResearchSynthesizer`, `OpenAITranscriber` and
///   `SonnyVisionModelClient` — through the recorder each run owns, and
///   `PlannerConstructionTests.whatARunRecordsReachesThePublishedUsageSummary` pins the whole path
///   out to `AgentViewModel.taskUsageSummary`.
///
/// **Two honest reasons the two sides will differ, so a difference is not read as a defect.** A call
/// the gateway refused before reaching a provider is recorded there and not here, because this side
/// records beside a reply it received; and a retry that re-ran under one idempotency key is metered
/// once on the server (§9.2's at-most-once claim) and counted twice here, because this side saw two
/// calls. Neither is a discrepancy to chase — the server's number is the one that decides anything.
///
/// **Nothing persists this.** It lives in memory for the length of one run: `TaskUsageRecorder` is a
/// lock around an array with `reset()` per run, and `CompletedTaskRecord` has no usage field. So no
/// raw value here is frozen by a file format, and the server's table is the first thing anywhere
/// that keeps usage past a process (PR #144's F2 corrected the claim that it was otherwise).
public struct TaskUsageSummary: Codable, Equatable, Sendable {
    public static let empty = TaskUsageSummary(records: [])

    public var records: [AIUsageRecord]

    public init(records: [AIUsageRecord]) {
        self.records = records
    }

    public var requestCount: Int {
        records.count
    }

    public var reportedInputTokens: Int {
        tokenSum(source: .reported, keyPath: \.inputTokens)
    }

    public var reportedOutputTokens: Int {
        tokenSum(source: .reported, keyPath: \.outputTokens)
    }

    public var reportedTotalTokens: Int {
        tokenTotalSum(source: .reported)
    }

    public var estimatedInputTokens: Int {
        tokenSum(source: .estimated, keyPath: \.inputTokens)
    }

    public var estimatedOutputTokens: Int {
        tokenSum(source: .estimated, keyPath: \.outputTokens)
    }

    public var estimatedTotalTokens: Int {
        tokenTotalSum(source: .estimated)
    }

    public var audioDurationSeconds: Double {
        records
            .compactMap(\.audioDurationSeconds)
            .reduce(0, +)
    }

    public var hasEstimatedTokens: Bool {
        records.contains { $0.tokenSource == .estimated }
    }

    public var hasUsageDetails: Bool {
        reportedTotalTokens > 0 || estimatedTotalTokens > 0 || audioDurationSeconds > 0
    }

    private func tokenSum(source: AIUsageTokenSource, keyPath: KeyPath<AIUsageTokenCounts, Int?>) -> Int {
        records
            .filter { $0.tokenSource == source }
            .compactMap { $0.tokenCounts[keyPath: keyPath] }
            .reduce(0, +)
    }

    private func tokenTotalSum(source: AIUsageTokenSource) -> Int {
        records
            .filter { $0.tokenSource == source }
            .compactMap { $0.tokenCounts.resolvedTotalTokens }
            .reduce(0, +)
    }
}

public protocol TaskUsageRecording: Sendable {
    func record(_ record: AIUsageRecord)
    func snapshot() -> TaskUsageSummary
    func reset()
}

public final class TaskUsageRecorder: TaskUsageRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [AIUsageRecord] = []

    public init() {}

    public func record(_ record: AIUsageRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    public func snapshot() -> TaskUsageSummary {
        lock.lock()
        let snapshot = TaskUsageSummary(records: records)
        lock.unlock()
        return snapshot
    }

    public func reset() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }
}

public struct NoopTaskUsageRecorder: TaskUsageRecording {
    public static let shared = NoopTaskUsageRecorder()

    public init() {}

    public func record(_ record: AIUsageRecord) {}

    public func snapshot() -> TaskUsageSummary {
        .empty
    }

    public func reset() {}
}

public enum AIUsageEstimator {
    public static func estimateTextTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 0
        }
        return max(1, Int(ceil(Double(trimmed.count) / 4.0)))
    }
}

public enum AIUsagePayloadParser {
    public static func responsesUsage(from data: Data) throws -> AIUsageTokenCounts? {
        // Usage is optional telemetry read before the response is parsed for real. A malformed
        // body must not throw a raw Foundation error from here and pre-empt the caller's own,
        // far more descriptive parse failure.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let usage = dictionary["usage"],
              !(usage is NSNull),
              let usageObject = usage as? [String: Any] else {
            return nil
        }

        return tokenCounts(from: usageObject)
    }

    public static func transcriptionUsage(from data: Data) throws -> AIUsageRecord? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let usage = dictionary["usage"],
              !(usage is NSNull),
              let usageObject = usage as? [String: Any] else {
            return nil
        }

        let tokenCounts = tokenCounts(from: usageObject)
        let hasTokenUsage = tokenCounts.inputTokens != nil
            || tokenCounts.outputTokens != nil
            || tokenCounts.totalTokens != nil
        let durationSeconds = doubleValue(for: ["seconds", "duration_seconds", "duration"], in: usageObject)

        guard hasTokenUsage || durationSeconds != nil else {
            return nil
        }

        return AIUsageRecord(
            kind: .transcription,
            model: "",
            tokenSource: hasTokenUsage ? .reported : nil,
            tokenCounts: tokenCounts,
            audioDurationSeconds: durationSeconds
        )
    }

    private static func tokenCounts(from usageObject: [String: Any]) -> AIUsageTokenCounts {
        AIUsageTokenCounts(
            inputTokens: intValue(for: ["input_tokens", "prompt_tokens"], in: usageObject),
            outputTokens: intValue(for: ["output_tokens", "completion_tokens"], in: usageObject),
            totalTokens: intValue(for: ["total_tokens"], in: usageObject)
        )
    }

    private static func intValue(for keys: [String], in object: [String: Any]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? Double {
                return Int(value)
            }
            if let value = object[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }

    private static func doubleValue(for keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double {
                return value
            }
            if let value = object[key] as? Int {
                return Double(value)
            }
            if let value = object[key] as? String, let doubleValue = Double(value) {
                return doubleValue
            }
        }
        return nil
    }
}
