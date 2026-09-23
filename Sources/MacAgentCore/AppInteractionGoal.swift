import Foundation

/// What the user asked Sonny to get done inside one app (V2 plan §5, `InteractionGoal`).
///
/// Built only through `validated`, so every goal the runtime sees has already been checked. The
/// planner proposes these fields; nothing in them is authority. `target` and `text` are the only
/// strings the runtime will ever type into the app, which keeps the model from composing text of
/// its own.
public struct AppInteractionGoal: Equatable, Sendable {
    /// The app as the user named it, e.g. "WhatsApp".
    public let app: String
    /// The outcome in plain words, e.g. "Open the chat with Mom and leave the message unsent".
    public let objective: String
    /// A name Sonny may type to find something, such as a chat or contact.
    public let target: String?
    /// The exact text to leave in a text field. Milestone A never sends it.
    public let text: String?

    public static let maxTextLength = 2_000
    public static let maxTargetLength = 100
    public static let maxObjectiveLength = 500

    private init(app: String, objective: String, target: String?, text: String?) {
        self.app = app
        self.objective = objective
        self.target = target
        self.text = text
    }

    public static func validated(
        app: String,
        objective: String,
        target: String?,
        text: String?
    ) throws(AppInteractionGoalError) -> AppInteractionGoal {
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { throw .missingApp }
        guard !objective.isEmpty else { throw .missingObjective }
        guard objective.count <= maxObjectiveLength else { throw .objectiveTooLong }

        let target = target?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let target {
            guard target.count <= maxTargetLength else { throw .targetTooLong }
            guard !target.containsLineBreak else { throw .targetHasLineBreak }
        }

        // Trimmed because the provider trims what it reads back, and verification compares the
        // two exactly.
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let text {
            guard text.count <= maxTextLength else { throw .textTooLong }
            // In a chat app Return sends. Milestone A refuses a line break instead of deciding how
            // each app wants one typed (founders, 2026-09-23).
            guard !text.containsLineBreak else { throw .textHasLineBreak }
        }
        guard target != nil || text != nil else { throw .nothingToDo }
        return AppInteractionGoal(app: app, objective: objective, target: target, text: text)
    }
}

public enum AppInteractionGoalError: Error, Equatable, Sendable {
    case missingApp
    case missingObjective
    case objectiveTooLong
    case targetTooLong
    case targetHasLineBreak
    case textTooLong
    case textHasLineBreak
    case nothingToDo

    /// Wording for the person who asked, naming what to change.
    public var userMessage: String {
        switch self {
        case .missingApp:
            return "I couldn't tell which app to use. Name the app and try again."
        case .missingObjective, .nothingToDo:
            return "I couldn't tell what to do in that app. Say who it's for and what to write."
        case .objectiveTooLong:
            return "That request is too long for me to follow in one go. Try a shorter one."
        case .targetTooLong:
            return "That name is too long to search for. Try a shorter one."
        case .targetHasLineBreak:
            return "That name has a line break in it. Try it on one line."
        case .textTooLong:
            return "That message is longer than \(AppInteractionGoal.maxTextLength) characters. Try a shorter one."
        case .textHasLineBreak:
            return "I can only draft a message on one line for now. Try it without line breaks."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var containsLineBreak: Bool { contains(where: \.isNewline) }
}

extension AppInteractionGoalError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
