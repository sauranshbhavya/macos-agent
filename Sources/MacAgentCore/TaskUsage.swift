import Foundation

public enum AIUsageCallKind: String, Codable, Equatable, Sendable {
    case planner
    case webResearchSynthesis = "web_research_synthesis"
    case transcription

    public var displayName: String {
        switch self {
        case .planner:
            return "Planner"
        case .webResearchSynthesis:
            return "Web research"
        case .transcription:
            return "Transcription"
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
