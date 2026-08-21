import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// What the task-detail sheet renders and how tall it is (row E, SONNY-148).
///
/// **What this suite can and cannot reach, stated rather than implied.** This repository has no
/// SwiftUI inspection harness, so nothing here proves a pixel. What it does prove is every decision
/// the body defers to it: which sections render, what the result block says, and the sheet's height
/// in all four combinations. What is left to the manual checklist is the rendering itself — that the
/// text really wraps, that nothing is clipped, and that no gap opens above the footer.
@MainActor
struct TaskDetailPresentationTests {
    // MARK: - Whether the result block renders at all

    /// **The common path on day one.** Every record written before row E has no stored result, and
    /// it must render nothing at all rather than an empty state — a heading with nothing under it
    /// would tell those users their task produced nothing, when the truth is that Sonny was not
    /// keeping results yet, and the no-explanatory-copy rule forbids the sentence that would say so.
    @Test
    func aRecordFromBeforeRowERendersNoResultBlock() {
        let record = makeRecord(result: nil)

        #expect(TaskDetailPresentation.resultText(for: record) == nil)
        #expect(!TaskDetailPresentation.showsResultSection(record))
        #expect(TaskDetailPresentation.sections(for: record, screenRecord: .none).isEmpty)
    }

    /// The other history that lands in the same `nil`: a run that stored a result whose text is
    /// empty. Distinguishable in the store — `result != nil` — and deliberately not distinguishable
    /// here, because a heading over nothing is the thing being avoided either way.
    @Test
    func aStoredButEmptyResultAlsoRendersNothing() {
        let record = makeRecord(result: .codeAuthored(""))

        #expect(record.result != nil, "the record really does carry a result; only its text is empty")
        #expect(TaskDetailPresentation.resultText(for: record) == nil)
        #expect(!TaskDetailPresentation.showsResultSection(record))
    }

    /// Whitespace is not content. `StoredTaskResult` trims on the way in, so a summary of spaces
    /// arrives here empty — asserted rather than assumed, because the trim living in the other type
    /// is exactly the kind of thing a later edit moves.
    @Test
    func aWhitespaceOnlyResultRendersNothing() {
        #expect(TaskDetailPresentation.resultText(for: makeRecord(result: .codeAuthored("   \n  "))) == nil)
    }

    @Test
    func aRecordWithAResultRendersItVerbatim() {
        let record = makeRecord(result: .codeAuthored("Zipped 3 files to ~/Desktop/large-files.zip."))

        #expect(TaskDetailPresentation.resultText(for: record) == "Zipped 3 files to ~/Desktop/large-files.zip.")
        #expect(TaskDetailPresentation.showsResultSection(record))
        #expect(TaskDetailPresentation.sections(for: record, screenRecord: .none) == [.result])
    }

    /// A failed task shows the failure it stored — the case the whole field is most useful for.
    @Test
    func aFailedTaskShowsTheFailureTextItStored() {
        var record = makeRecord(result: .codeAuthored("Could not calculate that expression."))
        record.outcomeStatus = .failed

        #expect(TaskDetailPresentation.resultText(for: record) == "Could not calculate that expression.")
        #expect(TaskDetailPresentation.showsResultSection(record))
    }

    /// Provenance changes nothing about rendering. A model wrote it or a template did; the user is
    /// shown the same block either way, and the declaration exists for readers that feed a planner,
    /// not for this one.
    @Test
    func modelAuthoredAndCodeAuthoredResultsRenderIdentically() {
        let model = makeRecord(result: .modelAuthored("The reading list is open."))
        let code = makeRecord(result: .codeAuthored("The reading list is open."))

        #expect(TaskDetailPresentation.resultText(for: model) == TaskDetailPresentation.resultText(for: code))
        #expect(
            TaskDetailPresentation.sheetHeight(for: model, screenRecord: .none)
                == TaskDetailPresentation.sheetHeight(for: code, screenRecord: .none)
        )
    }

    // MARK: - Which sections render, and in what order

    @Test
    func theResultBlockSitsAboveTheScreenRecordSection() {
        let record = makeRecord(result: .modelAuthored("The reading list is open."), visionSessionID: "session-1")

        #expect(
            TaskDetailPresentation.sections(for: record, screenRecord: .present(session()))
                == [.result, .screenRecord]
        )
    }

    @Test
    func anUnreadableJournalStillCountsAsASectionBesideAResult() {
        let record = makeRecord(result: .codeAuthored("Done."), visionSessionID: "session-1")

        #expect(
            TaskDetailPresentation.sections(for: record, screenRecord: .unreadable("could not be decrypted"))
                == [.result, .screenRecord]
        )
    }

    // MARK: - Height, in all four combinations

    /// **The four cases the old two-way ternary could not express.** Each is a different height, and
    /// the neither-section case is byte-for-byte the number this dialog has always used — a task
    /// with no result and no screen record looks exactly as it did before row E.
    @Test
    func theSheetIsSizedForEveryCombinationOfTheTwoOptionalSections() {
        let bare = makeRecord(result: nil)
        let withResult = makeRecord(result: .codeAuthored("Zipped 3 files."))
        let bareWithSession = makeRecord(result: nil, visionSessionID: "session-1")
        let both = makeRecord(result: .codeAuthored("Zipped 3 files."), visionSessionID: "session-1")
        let present = TaskScreenRecordState.present(session())

        let neither = TaskDetailPresentation.sheetHeight(for: bare, screenRecord: .none)
        let resultOnly = TaskDetailPresentation.sheetHeight(for: withResult, screenRecord: .none)
        let sessionOnly = TaskDetailPresentation.sheetHeight(for: bareWithSession, screenRecord: present)
        let bothSections = TaskDetailPresentation.sheetHeight(for: both, screenRecord: present)

        #expect(neither == 320, "the no-sections height this dialog has always used")
        #expect(sessionOnly == 560, "the screen-record height this dialog has always used")
        #expect(resultOnly > neither)
        #expect(bothSections == resultOnly + TaskDetailPresentation.screenRecordSectionHeight)
        // All four are distinct, which is the property the two-way branch could not have.
        #expect(Set([neither, resultOnly, sessionOnly, bothSections]).count == 4)
    }

    /// A longer result makes a taller sheet, up to the point where the block starts scrolling
    /// instead. Both halves matter: without the first the sheet gaps under long text, without the
    /// second one runaway summary makes a nine-hundred-point sheet.
    @Test
    func theSheetGrowsWithTheResultUntilTheBlockStartsScrollingInstead() {
        let short = makeRecord(result: .codeAuthored("Done."))
        let medium = makeRecord(result: .codeAuthored(String(repeating: "a", count: 200)))
        let atTheCap = makeRecord(result: .codeAuthored(String(repeating: "a", count: 1_000)))
        let alsoAtTheCap = makeRecord(result: .codeAuthored(String(repeating: "b", count: 900)))

        let shortHeight = TaskDetailPresentation.sheetHeight(for: short, screenRecord: .none)
        let mediumHeight = TaskDetailPresentation.sheetHeight(for: medium, screenRecord: .none)
        let cappedHeight = TaskDetailPresentation.sheetHeight(for: atTheCap, screenRecord: .none)

        #expect(shortHeight < mediumHeight)
        #expect(mediumHeight < cappedHeight)
        #expect(
            cappedHeight == TaskDetailPresentation.sheetHeight(for: alsoAtTheCap, screenRecord: .none),
            "past the line cap the sheet stops growing and the block scrolls"
        )
        // And the cap really is the ceiling: the tallest possible sheet, both sections present.
        let ceiling = TaskDetailPresentation.baseHeight
            + TaskDetailPresentation.resultSectionChrome
            + CGFloat(TaskDetailPresentation.resultMaximumLines) * TaskDetailPresentation.resultLineHeight
            + TaskDetailPresentation.screenRecordSectionHeight
        let tallest = makeRecord(
            result: .codeAuthored(String(repeating: "a", count: StoredTaskResult.maxTextLength)),
            visionSessionID: "session-1"
        )
        #expect(TaskDetailPresentation.sheetHeight(for: tallest, screenRecord: .present(session())) == ceiling)
    }

    /// Line counting: a paragraph wraps by length, an explicit break starts a new line, and neither
    /// an empty string nor a string of newlines can produce zero lines or more than the cap.
    @Test
    func theLineEstimateCountsWrappingAndExplicitBreaksAndStaysInsideItsBounds() {
        let perLine = TaskDetailPresentation.resultCharactersPerLine

        #expect(TaskDetailPresentation.resultLineCount(for: "Done.") == 1)
        #expect(TaskDetailPresentation.resultLineCount(for: String(repeating: "a", count: perLine)) == 1)
        #expect(TaskDetailPresentation.resultLineCount(for: String(repeating: "a", count: perLine + 1)) == 2)
        #expect(TaskDetailPresentation.resultLineCount(for: "one\ntwo\nthree") == 3)
        // An explicit break costs a line even when the paragraph before it is empty.
        #expect(TaskDetailPresentation.resultLineCount(for: "one\n\ntwo") == 3)
        #expect(TaskDetailPresentation.resultLineCount(for: "") == 1)
        #expect(
            TaskDetailPresentation.resultLineCount(for: String(repeating: "a\n", count: 40))
                == TaskDetailPresentation.resultMaximumLines
        )
        #expect(
            TaskDetailPresentation.resultLineCount(
                for: String(repeating: "a", count: StoredTaskResult.maxTextLength)
            ) == TaskDetailPresentation.resultMaximumLines
        )
    }

    /// The block's text area is what the estimate is *for* — the sheet reserves exactly the space the
    /// view then gives its scrolling content, so an under-estimate scrolls rather than clips.
    @Test
    func theReservedTextHeightIsTheHeightTheBlockGivesItsContent() {
        let text = String(repeating: "a", count: 200)
        let lines = TaskDetailPresentation.resultLineCount(for: text)

        #expect(TaskDetailPresentation.resultTextHeight(for: text) == CGFloat(lines) * TaskDetailPresentation.resultLineHeight)
        #expect(
            TaskDetailPresentation.height(of: .result, resultText: text)
                == TaskDetailPresentation.resultSectionChrome + TaskDetailPresentation.resultTextHeight(for: text)
        )
        #expect(
            TaskDetailPresentation.height(of: .screenRecord, resultText: text)
                == TaskDetailPresentation.screenRecordSectionHeight,
            "the screen-record section's height does not depend on the result"
        )
    }

    // MARK: - Fixtures

    private func makeRecord(
        result: StoredTaskResult?,
        visionSessionID: String? = nil
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: "zip my downloads",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_030),
            outcomeStatus: .completed,
            visionSessionID: visionSessionID,
            result: result
        )
    }

    private func session() -> VisionSessionRecord {
        VisionSessionRecord(
            id: "session-1",
            goal: "open my reading list",
            appDisplayName: "Safari",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
