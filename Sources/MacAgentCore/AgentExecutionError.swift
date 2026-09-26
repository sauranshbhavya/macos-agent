import Foundation

/// Why an adapter body couldn't run what it was given.
public enum AgentExecutionError: Error, LocalizedError, Equatable {
    case emptyCommand
    /// The planner answered that it cannot do this. The associated value is the planner's own
    /// reason, kept for the log and for whoever inspects the error; what the user reads is
    /// `errorDescription`, which is this repository's sentence and never the planner's (SONNY-447).
    case unsupported(String)
    case missingPath(String)
    case invalidPlan(String)
    case noMatchingFiles(String)
    case missingClarificationQuestion

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Enter a natural-language command first."
        case .unsupported:
            // **This repository's words, whatever the planner wrote** (SONNY-447). The reason used
            // to be returned here verbatim, so the model's own sentence — "Unsupported: there is no
            // registered weather lookup tool available." on the founders' pass, test 16 — was the
            // failure banner. The rule on `EntitlementCopy`, `SignInCopy` and `SonnyBackendCopy`
            // applies at least as strongly to a sentence a model authored: rendered as Sonny's own,
            // it is a hole in the no-explanatory-copy rule that no reviewer here ever reads. A
            // clarification question is the deliberate exception, because it is the question.
            return Self.unsupportedRequestSentence
        case .missingPath(let operation):
            return "\(operation) needs a folder path."
        case .invalidPlan(let detail):
            return "The generated plan is invalid: \(detail)"
        case .noMatchingFiles(let detail):
            return detail
        case .missingClarificationQuestion:
            return "The planner asked for clarification but did not include a question."
        }
    }

    /// The one sentence a refused request shows, wherever the refusal came from.
    public static let unsupportedRequestSentence = "Sonny can't do that yet."
}
