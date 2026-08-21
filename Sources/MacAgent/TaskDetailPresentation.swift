import CoreGraphics
import Foundation
import MacAgentCore

/// One of the task-detail sheet's optional blocks, in render order.
///
/// **A list rather than a set of booleans, because the sheet's height is now a sum over it.** Two
/// optional sections make the old `record.visionSessionID == nil ? 320 : 560` ternary a four-case
/// arithmetic, and row D is still adding controls to the same dialog — a third would make it eight.
/// So the branch is replaced by a total: each present section contributes its own height and the
/// base contributes the rest.
enum TaskDetailSection: Equatable {
    /// What the task produced (row E, SONNY-147/148).
    case result
    /// What Sonny did on screen (row I, SONNY-96; row D's delete lives inside it).
    case screenRecord
}

/// What the task-detail sheet renders and how tall it is, kept out of the SwiftUI body so it can be
/// tested. This repository has no view-rendering tests, so anything left inside a `body` is guarded
/// only by the manual checklist — the same reasoning `TaskDeletePresentation` was built on, and this
/// is its sibling for row E rather than an addition to it.
enum TaskDetailPresentation {
    // MARK: - The result block

    /// The section's own label.
    ///
    /// One noun, matching the sheet's existing vocabulary for naming a piece of information —
    /// "Status", "Started", "Completed", "Workspace" — rather than the sentence the screen-record
    /// section uses. Two sentence-shaped titles a line apart ("What Sonny did on screen" above
    /// something like "What Sonny did") would read as a superset and its subset. Proposed on session
    /// judgment with no wireframe to defer to; SONNY-109 settles the final words, as it does for row
    /// D's delete labels.
    static let resultSectionTitle = "Result"

    /// The text to render, or `nil` when there is nothing to render.
    ///
    /// **`nil` covers two different histories on purpose**, exactly as `TaskScreenRecordState.none`
    /// does for the section below it: a record written before row E kept results at all, and a
    /// record whose stored result is empty. Neither may produce a heading with nothing under it. An
    /// empty state would say the task produced nothing, when for every record written before row E
    /// the truth is that Sonny was not keeping results yet — and the no-explanatory-copy rule of
    /// 2026-08-14 forbids the sentence that would tell the two apart. Every pre-existing record is
    /// in this case, so it is the common path on day one rather than an edge.
    static func resultText(for record: CompletedTaskRecord) -> String? {
        guard let text = record.result?.text, !text.isEmpty else {
            return nil
        }
        return text
    }

    static func showsResultSection(_ record: CompletedTaskRecord) -> Bool {
        resultText(for: record) != nil
    }

    // MARK: - The two things you can do with a task

    static let runAgainActionLabel = "Run again"

    /// Whether "Run again" and "Follow up" are offered — one predicate, because they are the same
    /// question: is there a command to act on.
    ///
    /// **The outcome status is deliberately not consulted.** Both are offered for completed, failed
    /// and cancelled records alike — failed is the case run-again is most useful for — and every
    /// record this sheet can open is one of those three, because `recordTaskHistoryIfTerminal`
    /// writes no row for any other status. Gating on the status would be a filter that never
    /// filters, and one a later reader would have to check against that write path to understand.
    ///
    /// **What it does check is that there is something to act on.** A record whose command is empty
    /// renders as "Untitled task": dispatching it is refused by `canSubmit`, and arming a follow-up
    /// on it would install a trusted block whose `Previous command:` line is blank. Offering a
    /// control that cannot work is worse than not offering it, the same call
    /// `TaskDeletePresentation.showsScreenRecordDeleteAction` already makes for an unreadable
    /// journal.
    static func showsTaskActions(for record: CompletedTaskRecord) -> Bool {
        !record.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Which sections render

    static func sections(
        for record: CompletedTaskRecord,
        screenRecord: TaskScreenRecordState
    ) -> [TaskDetailSection] {
        var sections: [TaskDetailSection] = []
        if showsResultSection(record) {
            sections.append(.result)
        }
        if TaskDeletePresentation.showsScreenRecordSection(screenRecord) {
            sections.append(.screenRecord)
        }
        return sections
    }

    // MARK: - Height

    /// The sheet with no optional section at all — header, the four detail rows, and the footer.
    /// Unchanged from the number this dialog has always used for that case, so a task with neither
    /// section looks exactly as it did before row E.
    static let baseHeight: CGFloat = 320

    /// The screen-record section's contribution, preserving the 560 this dialog used for it. Its own
    /// content is internally bounded — a `ScrollView` capped at 180 — so it is a constant rather
    /// than something derived from how many actions the session took.
    static let screenRecordSectionHeight: CGFloat = 240

    /// The result block's chrome: its divider, the padding above and below it, its title, and the
    /// gap between the title and the text.
    static let resultSectionChrome: CGFloat = 54

    /// One line of `SonnyType.body` (Inter 13) with its leading.
    static let resultLineHeight: CGFloat = 18

    /// Characters that fit on one line of the result block: the sheet is 420 wide with 28 of
    /// horizontal padding a side, so the text is laid out in 364 points, and Inter 13's average
    /// advance is a little over 6.6 points. An estimate, deliberately — see `resultLineCount`.
    static let resultCharactersPerLine = 54

    /// The most lines of result the sheet grows for. Beyond this the block scrolls.
    ///
    /// Six rather than the nineteen a full 1,000-character result would need, because a sheet that
    /// grew to nine hundred points for one long summary would be worse than a short scroll. Six
    /// lines is roughly 320 characters, which is past every summary this product's adapters produce
    /// and past most of what a screen-control session writes.
    static let resultMaximumLines = 6

    /// How many lines the stored result will take, estimated.
    ///
    /// **An estimate, and the block is built so that both ways of being wrong are mild.** Nothing
    /// outside a live layout pass can know where text wraps, so this counts explicit line breaks and
    /// divides each paragraph by `resultCharactersPerLine`. Under-count and the block scrolls;
    /// over-count and the sheet's existing `Spacer(minLength: 20)` absorbs the slack above the
    /// footer. The alternative — a fixed allowance for the section — is wrong in a way that is not
    /// mild: it clips every long result or leaves most of a hundred points of white under every
    /// short one, and this dialog's acceptance bar is explicitly "no clipped content and no large
    /// empty gap".
    static func resultLineCount(for text: String) -> Int {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = paragraphs.reduce(0) { total, paragraph in
            total + max(1, Int(ceil(Double(paragraph.count) / Double(resultCharactersPerLine))))
        }
        return min(max(1, lines), resultMaximumLines)
    }

    /// The height of the result block's text area — what the view gives its scrolling content, so a
    /// result longer than the estimate scrolls inside the space the sheet actually reserved for it.
    static func resultTextHeight(for text: String) -> CGFloat {
        CGFloat(resultLineCount(for: text)) * resultLineHeight
    }

    static func height(of section: TaskDetailSection, resultText: String?) -> CGFloat {
        switch section {
        case .result:
            return resultSectionChrome + resultTextHeight(for: resultText ?? "")
        case .screenRecord:
            return screenRecordSectionHeight
        }
    }

    /// The sheet's height: the base plus every present section's own contribution.
    static func sheetHeight(
        for record: CompletedTaskRecord,
        screenRecord: TaskScreenRecordState
    ) -> CGFloat {
        let text = resultText(for: record)
        return sections(for: record, screenRecord: screenRecord)
            .reduce(baseHeight) { $0 + height(of: $1, resultText: text) }
    }
}
