import Foundation

/// The shape a command takes once Sonny has asked something about it and the user has answered
/// (SONNY-248).
///
/// A clarified command is the user's request followed by the exchange that clarified it:
///
/// ```text
/// zip my three largest files
///
/// Clarification question: Which folder should I scan?
/// Clarification answer: The Desktop
/// ```
///
/// **One type owns the shape because three different readers need it and they must not each carry
/// their own copy.** The composer writes it; the dispatch path asks whether a command carries an
/// exchange, because a command that does is no longer an instant command; and every surface that
/// shows a task's command to the user asks for the request back out of it, because the exchange is
/// the planner's business and not something to read in a sentence about your own task. Those three
/// questions are the same knowledge, and a per-site copy of it is how a format starts meaning two
/// things.
///
/// **The exchange lives in the command string rather than beside it, and that is a choice with a
/// reason.** A field holding the exchange separately would need a lifecycle — cleared for a new
/// task, kept across a retry of a clarified one — and every door that starts a task would have to
/// get that right. Carried in the string, it travels wherever the command travels: a retry
/// resubmits it without knowing it exists, and a genuinely new command cannot inherit it because it
/// is a different string.
///
/// **Repeated clarification accumulates rather than overwrites.** `composed` is called with the
/// text the paused run was submitted with, which for a second question is already request + first
/// pair — so the pairs stack up in the order the conversation happened and the request stays at the
/// head of all of them.
public enum ClarifiedCommand {
    /// The line prefixes. Public because they are the format, and a test asserting the composed
    /// shape should assert against the same constant the composer used rather than a second literal
    /// that can drift away from it.
    public static let questionLabel = "Clarification question:"
    public static let answerLabel = "Clarification answer:"

    /// Builds the prompt a clarified run is planned from.
    ///
    /// - Parameter request: What the paused run was submitted with. Empty is allowed and degrades to
    ///   the exchange alone — the shape this produced for *every* clarification before SONNY-248,
    ///   kept as the honest answer for a question that was not raised by a real run, since inventing
    ///   a request would be worse than having none.
    public static func composed(request: String, question: String, answer: String) -> String {
        let exchange = """
        \(questionLabel) \(question)
        \(answerLabel) \(answer)
        """
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else {
            return exchange
        }
        return "\(trimmedRequest)\n\n\(exchange)"
    }

    /// Whether this command carries a clarification exchange.
    ///
    /// **Asked by the dispatch path so that a clarified command never goes back through
    /// `InstantCommandResolver`.** The resolver matches on prefixes, and a request it once answered
    /// with a question still carries that prefix once the request is restored to the front — so `=`,
    /// clarified and answered, would resolve again as a calculator expression whose expression is
    /// the transcript of the conversation about it. The resolver already had its turn on this
    /// command and asked for more; the more is a planner's to read.
    ///
    /// Matched at the start of a line, so a request that merely mentions the words in passing is not
    /// mistaken for one. A user who types the label at the start of a line of their own is
    /// misread — and misread in the safe direction, which is that their command is planned rather
    /// than resolved locally.
    public static func carriesExchange(_ command: String) -> Bool {
        exchangeLineIndex(in: lines(of: command)) != nil
    }

    /// The request, for a surface that shows a task's command to the user.
    ///
    /// Command Center's running indicator, the widget's offer to carry on with an unfinished task,
    /// the Tasks list and the follow-up chip all name a task by its command. A user reading any of
    /// them should see what they asked for, not the scaffolding Sonny wrapped around it — the
    /// founder's standing rule that the product does not explain its own workings applies to a label
    /// as much as to a paragraph. Truncation alone does not cover it: those surfaces squeeze a
    /// command onto one line and cut it to fit, so a *short* request leaves room for the exchange to
    /// show through behind it.
    ///
    /// Returns the command unchanged when it carries no exchange, and when the exchange is all there
    /// is — a label is never made blank by this, since a blank one tells the user strictly less than
    /// the wrong one did.
    public static func request(in command: String) -> String {
        let commandLines = lines(of: command)
        guard let index = exchangeLineIndex(in: commandLines) else {
            return command
        }
        let request = commandLines[..<index]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return request.isEmpty ? command : request
    }

    private static func lines(of command: String) -> [Substring] {
        command.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The first line that opens an exchange, or `nil` when none does.
    private static func exchangeLineIndex(in commandLines: [Substring]) -> Int? {
        commandLines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(questionLabel)
        }
    }
}
