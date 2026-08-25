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
        \(questionLabel) \(foldingLineBreaks(in: question))
        \(answerLabel) \(answer)
        """
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else {
            return exchange
        }
        return "\(trimmedRequest)\n\n\(exchange)"
    }

    /// The plain command a clarification answer completes, for a question the instant resolver
    /// asked (SONNY-281).
    ///
    /// **The resolver's questions are raised on a bare prefix, and the answer is the rest of the
    /// command.** `=` asks what to calculate; `calc`, `switch to`, `run shortcut` and `snippet save`
    /// each ask for the thing that would have followed them. The user answered the operand the
    /// resolver was missing, so the command they meant is the prefix with the answer after it —
    /// `= 2 + 2` — and that is a plain command: dispatched through the same door typed text goes
    /// through, resolved by the same rule, and carrying no exchange for a label to strip or a retry
    /// to re-ask. `composed` is the other shape, for a question the planner asked, where the answer
    /// means whatever the planner's question made it mean and only the planner can apply it.
    ///
    /// **An answer that restates the request is the whole command.** The question tells a user what
    /// the command looks like — "Use the format snippet save ;trigger = expansion." says so in as
    /// many words — so an answer that begins with the request is the user writing the command out,
    /// not asking for the request twice: `calc` answered `calc 2 + 2` runs `calc 2 + 2`, not
    /// `calc calc 2 + 2`. Case-insensitive, because the resolver's own prefixes are.
    ///
    /// **This composes; it does not decide.** Whether the completed command is what the user meant
    /// is not a property of the string — "I could not find a Shortcut named Foo. Which Shortcut
    /// should I run?" wants a replacement, and `run shortcut Foo Send Report` completes nothing. The
    /// caller asks the resolver whether the completion resolves to a plan and falls back to
    /// `composed` when it does not; `AgentViewModel.submitClarification` is where that is decided
    /// and where the reasons are.
    ///
    /// Degrades the way `composed` does: an empty request is the answer alone, and an empty answer
    /// is the request alone — never a dangling space.
    public static func completed(request: String, answer: String) -> String {
        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else {
            return trimmedRequest
        }
        // The restatement rule, and it is also what makes an empty request the answer alone: every
        // string begins with the empty one, so a separate emptiness check would be a second rule
        // saying the same thing.
        guard !trimmedAnswer.lowercased().hasPrefix(trimmedRequest.lowercased()) else {
            return trimmedAnswer
        }
        return "\(trimmedRequest) \(trimmedAnswer)"
    }

    /// Whether this command carries a clarification exchange.
    ///
    /// **Asked by the dispatch path so that a clarified command never goes back through
    /// `InstantCommandResolver`.** The resolver matches on prefixes, and a request it once answered
    /// with a question still carries that prefix once the request is restored to the front — so `=`,
    /// clarified and answered, would resolve again as a calculator expression whose expression is
    /// the transcript of the conversation about it. The resolver already had its turn on this
    /// command and asked for more; the more is a planner's to read — **unless the resolver is the
    /// one that asked** (SONNY-281). Then the answer is offered back to it first, as the rest of the
    /// command it was missing, and it is only an answer that does not complete the command that is
    /// composed into an exchange at all: see `completed(request:answer:)` and
    /// `AgentViewModel.submitClarification`. A command that carries an exchange and reaches the
    /// dispatch path is therefore one the resolver either did not ask about or could not complete.
    ///
    /// **Here a false positive is cheap, which is not true of `request(in:)` below** — the two used
    /// to share one sentence about failing "in the safe direction", and only this half of it was
    /// ever true (PR #109 review F3). Reading a command as clarified when it is not costs it the
    /// instant resolver: the command is planned instead, which is slower and correct.
    public static func carriesExchange(_ command: String) -> Bool {
        exchangeStart(in: command) != nil
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
    /// **That premise is load-bearing in both directions, which is how the re-check found a defect
    /// in the fix itself.** Tightening the match to a pair made `composed`'s output the definition of
    /// what counts — so a question `composed` wrote across two lines stopped being an exchange, and
    /// both of this ticket's symptoms returned for it. `composed` folds the question onto one line
    /// now. Read the two together: neither half is correct alone.
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
        guard let start = exchangeStart(in: command) else {
            return command
        }
        let request = command[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
        return request.isEmpty ? command : request
    }

    /// Every run of line-break characters in the question, replaced by the two literal characters
    /// `\n`, so the question occupies exactly one line (PR #109 re-check).
    ///
    /// **This is what makes the pair rule's premise true.** `exchangeStart` counts a question
    /// line only when the *next* line opens the answer, justified as "the shape `composed` always
    /// writes" — and `composed` did not always write it. The question is interpolated verbatim;
    /// `AgentActionExecutor.clarificationQuestion(in:)` only *end*-trims it
    /// (`trimmingCharacters(in: .whitespacesAndNewlines)` removes nothing interior); and
    /// `AgentStep.question` is model-authored free text. A planner question wrapping onto two lines
    /// therefore pushed the answer off the question's next line, the pair stopped matching, and both
    /// of SONNY-248's symptoms returned for that question: the clarified command went back through
    /// `InstantCommandResolver`, and the resume offer named Sonny's question rather than the user's
    /// request — the founder's original report, reached by a second route.
    ///
    /// **`CharacterSet.newlines`, deliberately wider than `\n`.** It covers LF, VT, FF, CR, CRLF,
    /// NEL (U+0085) and the Unicode line and paragraph separators (U+2028, U+2029). A plan arrives as
    /// JSON-serialised UTF-8, so every one of those survives the wire intact and any of them can
    /// begin a line where this string is read back; folding only `\n` would leave six ways in.
    ///
    /// **The question and not the answer.** The answer is the user's own words, and a multi-line one
    /// is already safe: it *follows* its question line, so the pair still matches and everything
    /// after it belongs to the answer. Folding it would edit what the user typed for no gain — and
    /// F3's whole lesson is that this file's output is a payload, not only a caption. The request is
    /// not folded either, for the same reason and more strongly: on a second clarification the
    /// request *is* the previous composed command, whose line structure is the thing being preserved.
    ///
    /// **Runs collapse to one marker** rather than one per character, so a question of nothing but
    /// line breaks cannot expand the prompt.
    ///
    /// **Second implementation of one rule, named rather than left to be discovered.**
    /// `PriorTaskContext.foldingLineBreaks` does the same job for the planner's prior-task block, and
    /// its doc comment is where this reasoning was worked out — including why the marker is `\n`
    /// rather than a separator character that could rebuild a delimiter. The invariant that must not
    /// drift between them is the character set. SONNY-262 is the ticket to consolidate them.
    private static func foldingLineBreaks(in value: String) -> String {
        guard value.rangeOfCharacter(from: .newlines) != nil else {
            return value
        }
        return value
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .joined(separator: "\\n")
    }

    /// Where the first exchange begins, as an index into `command`, or `nil` when none does.
    ///
    /// **A line here is a line by `Character.isNewline`, which is the same set `composed` folds**
    /// (PR #109 re-check, second round). This used to split on `"\n"` alone while `composed` folded
    /// `CharacterSet.newlines` — a writer and a reader disagreeing about what a line is, which made
    /// the wide fold unearned and the test asserting it vacuous for seven of its eight cases: a
    /// question carrying VT, FF, CR, NEL, U+2028 or U+2029 never split the pair here, so folding
    /// those changed nothing a test could see. A battery mutant narrowing the fold to `"\n"`
    /// survived the whole suite and is what surfaced it. Both halves take the same set now, so the
    /// fold is load-bearing for every one of them and the disagreement cannot come back on one side.
    ///
    /// `Character.isNewline` rather than a `CharacterSet` membership test on scalars, because Swift
    /// makes CRLF a single `Character`: iterating characters treats it as one break rather than two.
    ///
    /// **A question line counts only when an answer line follows it** (PR #109 review F3). A lone
    /// `Clarification question:` line is not an exchange: `composed` never writes one, and treating
    /// it as an exchange would truncate a user's own command at a line that merely happened to start
    /// that way — and `request(in:)`'s output is resubmitted by Run again, not only displayed.
    ///
    /// **"`composed` never writes one" is an invariant `composed` has to actually hold, and for one
    /// round it did not** (PR #109 re-check). It interpolates a model-authored question that only
    /// ever gets *end*-trimmed, so a question wrapping onto two lines wrote exactly the shape this
    /// rejects. `composed` folds line breaks out of the question now, which is what makes the
    /// sentence above true rather than merely intended — see `foldingLineBreaks`.
    ///
    /// Returns an index into the original string rather than a line number, so `request(in:)` can
    /// **slice** the command instead of re-joining split pieces. Re-joining normalises every line
    /// break it split on, which was lossless while both were `"\n"` and would silently rewrite a
    /// user's CR or U+2028 the moment the set widened — an edit to a payload, which is the one thing
    /// F3 established this file must not do.
    private static func exchangeStart(in command: String) -> String.Index? {
        let lineRanges = lineRanges(of: command)
        for (position, range) in lineRanges.enumerated() {
            guard command[range].trimmingCharacters(in: .whitespaces).hasPrefix(questionLabel) else {
                continue
            }
            let next = position + 1
            guard next < lineRanges.count,
                  command[lineRanges[next]].trimmingCharacters(in: .whitespaces).hasPrefix(answerLabel) else {
                continue
            }
            return range.lowerBound
        }
        return nil
    }

    /// Every line of `command`, as ranges into it, split on `Character.isNewline`.
    private static func lineRanges(of command: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var lineStart = command.startIndex
        var index = command.startIndex
        while index < command.endIndex {
            let next = command.index(after: index)
            if command[index].isNewline {
                ranges.append(lineStart..<index)
                lineStart = next
            }
            index = next
        }
        ranges.append(lineStart..<command.endIndex)
        return ranges
    }
}
