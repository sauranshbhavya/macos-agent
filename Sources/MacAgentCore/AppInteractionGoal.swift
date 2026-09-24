import Foundation

/// What the user asked Sonny to get done inside one app (V2 plan §5, `InteractionGoal`).
///
/// Built only through `validated`, so every goal the runtime sees has already been checked. The
/// planner proposes these fields; nothing in them is authority. `target` and `text` are the only
/// strings the runtime will ever type into the app, which keeps the model from composing text of
/// its own.
public struct AppInteractionGoal: Equatable, Sendable {
    /// The app as the user named it, e.g. "Notes".
    public let app: String
    /// The outcome in plain words, e.g. "A new note that says buy milk".
    public let objective: String
    /// A name Sonny may type to find something, such as a chat or contact.
    public let target: String?
    /// The exact text to leave in a text field. It may run over several lines: it is set as the
    /// field's value, never typed, so no Return is pressed.
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
    case nothingToDo
    /// The request names something to find, such as a folder or a note, and the milestone's goal
    /// is a new note in whichever folder is open.
    case targetNotSupported

    /// Wording for the person who asked, naming what to change.
    public var userMessage: String {
        switch self {
        case .missingApp:
            return "I couldn't tell which app to use. Name the app and try again."
        case .missingObjective, .nothingToDo:
            return "I couldn't tell what to write. Say what it should say."
        case .objectiveTooLong:
            return "That request is too long for me to follow in one go. Try a shorter one."
        case .targetTooLong:
            return "That name is too long to search for. Try a shorter one."
        case .targetHasLineBreak:
            return "That name has a line break in it. Try it on one line."
        case .textTooLong:
            return "That's longer than \(AppInteractionGoal.maxTextLength) characters. Try something shorter."
        case .targetNotSupported:
            return "I can only make a new note in the folder that's open in Notes."
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
