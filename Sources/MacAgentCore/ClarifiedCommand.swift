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
    /// **Here a false positive is cheap, which is not true of `request(in:)` below** — the two used
    /// to share one sentence about failing "in the safe direction", and only this half of it was
    /// ever true (PR #109 review F3). Reading a command as clarified when it is not costs it the
    /// instant resolver: the command is planned instead, which is slower and correct.
    public static func carriesExchange(_ command: String) -> Bool {
        exchangeLineIndex(in: lines(of: command)) != nil
    }

    /// The request half of a clarified command — **read by labels and by two payloads, which is why
    /// a false positive here is not cheap** (PR #109 review F3).
    ///
    /// The labels: Command Center's running indicator, the widget's offer to carry on with an
    /// unfinished task, the Tasks list, and the follow-up chip. A user reading any of them should see
    /// what they asked for, not the scaffolding Sonny wrapped around it — the founder's standing rule
    /// that the product does not explain its own workings applies to a label as much as to a
    /// paragraph. Truncation alone does not cover it: those surfaces squeeze a command onto one line
    /// and cut it to fit, so a *short* request leaves room for the exchange to show through behind it.
    ///
    /// **The payloads, and they are the reason this doc comment was wrong before:** the task-history
    /// row's command is what `runTaskAgain` resubmits, and — through `followUpOnTask`, which builds a
    /// `PriorTaskContext` from the row — what reaches a later planner inside `plannerContextText`. So
    /// this does not merely shorten a caption. Reading an exchange that is not there **truncates a
    /// command**, and the truncated half is what Run again would send.
    ///
    /// **Which is why the match is the whole pair.** A `Clarification question:` line counts only
    /// when the next line opens with `Clarification answer:` — the shape `composed` always writes,
    /// and one a user would have to type across two consecutive lines to collide with. It used to be
    /// a single line prefix, and a command whose own text happened to begin a line that way lost
    /// everything after it.
    ///
    /// **The residual, since the class is not closed:** a user who really does write both labels on
    /// consecutive lines is still truncated, and so is one whose *answer* runs to several lines and
    /// begins one of them with the question label. Both are unguessable-delimiter problems of the
    /// same family as SONNY-234's, and neither is worth a random tag for a string this one is.
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
    ///
    /// **A question line counts only when an answer line follows it** (PR #109 review F3). A lone
    /// `Clarification question:` line is not an exchange: `composed` never writes one, and treating
    /// it as an exchange would truncate a user's own command at a line that merely happened to start
    /// that way — and `request(in:)`'s output is resubmitted by Run again, not only displayed.
    private static func exchangeLineIndex(in commandLines: [Substring]) -> Int? {
        commandLines.indices.first { index in
            guard commandLines[index].trimmingCharacters(in: .whitespaces).hasPrefix(questionLabel) else {
                return false
            }
            let next = index + 1
            guard next < commandLines.count else {
                return false
            }
            return commandLines[next].trimmingCharacters(in: .whitespaces).hasPrefix(answerLabel)
        }
    }
}
