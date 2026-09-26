import Foundation

public enum AgentPhase: String, Codable, CaseIterable, Sendable {
    case plan
    case validate
    case risk
    case preview
    case confirm
    case act
    case observe
    case summarize
}

public struct ActionPreview: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var details: [String]
    public var writes: [String]
    public var opens: [String]
    public var conversions: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        details: [String] = [],
        writes: [String] = [],
        opens: [String] = [],
        conversions: [String] = []
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.writes = writes
        self.opens = opens
        self.conversions = conversions
    }
}

public struct AgentRunResult: Equatable, Sendable {
    public var plan: AgentPlan
    public var previews: [ActionPreview]
    public var summary: String
    public var suggestions: [RunSuggestion]

    public init(
        plan: AgentPlan,
        previews: [ActionPreview],
        summary: String,
        suggestions: [RunSuggestion] = []
    ) {
        self.plan = plan
        self.previews = previews
        self.summary = summary
        self.suggestions = suggestions
    }

}

public struct RunSuggestion: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: RunSuggestionKind
    public var value: String

    public init(
        id: UUID = UUID(),
        title: String,
        kind: RunSuggestionKind,
        value: String
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.value = value
    }
}

public enum RunSuggestionKind: String, Codable, Equatable, Sendable {
    case revealInFinder
    case openFile
}
