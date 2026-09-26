import Foundation

/// What a usage record was for. Transcription is the one model call the Mac makes itself; every
/// other call is the gateway's, and the gateway meters it.
public enum AIUsageCallKind: String, Codable, Equatable, Sendable {
    case transcription
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
}
