import Foundation
import Testing
import MacAgentCore
@testable import MacAgent

/// SONNY-450. `RunPillPresentation` is what the run pill says for each widget state, read off the
/// widget's own precedence; every kind, its glyph, words, tint and accessibility label are held
/// here without a window.
@Suite
struct RunPillPresentationTests {
    @Test
    func aRunInFlightShowsASpinnerAndTheRequestThatIsRunning() throws {
        let pill = try #require(RunPillPresentation.make(state: .working, command: "zip the largest files on my Desktop"))

        #expect(pill.kind == .running)
        #expect(pill.glyph == nil)
        #expect(pill.words == "zip the largest files on my Desktop")
        #expect(pill.tint == .action)
        #expect(pill.accessibilityLabel == "Sonny is working on: zip the largest files on my Desktop. Click to expand.")
    }

    @Test
    func aRunWithNoRequestTextSaysSonnyIsWorking() throws {
        let pill = try #require(RunPillPresentation.make(state: .working, command: "   "))

        #expect(pill.words == RunPillPresentation.runningFallback)
    }

    @Test
    func aParkedClarificationSaysSonnyNeedsYou() throws {
        let pill = try #require(RunPillPresentation.make(state: .clarification("Which file did you mean?"), command: "open it"))

        #expect(pill.kind == .needsYou)
        #expect(pill.glyph == "exclamationmark.bubble.fill")
        #expect(pill.words == RunPillPresentation.needsYouWords)
        #expect(pill.tint == .attention)
        #expect(pill.accessibilityLabel == "Sonny needs you. Click to answer.")
    }

    @Test
    func aResultIsDoneWithItsFirstLine() throws {
        let pill = try #require(RunPillPresentation.make(state: .result("Zipped 3 files.\nThe archive is on the Desktop.", nil), command: "zip"))

        #expect(pill.kind == .done)
        #expect(pill.glyph == "checkmark.circle.fill")
        #expect(pill.words == "Zipped 3 files.")
        #expect(pill.tint == .allow)
        #expect(pill.accessibilityLabel == "Done: Zipped 3 files. Click to expand.")
    }

    @Test
    func aFailureIsFailedWithItsSentence() throws {
        let pill = try #require(RunPillPresentation.make(state: .failure("No file named report.pdf is on the Desktop."), command: "open"))

        #expect(pill.kind == .failed)
        #expect(pill.glyph == "xmark.octagon.fill")
        #expect(pill.words == "No file named report.pdf is on the Desktop.")
        #expect(pill.tint == .error)
        #expect(pill.accessibilityLabel.hasPrefix("Failed: No file named report.pdf"))
    }

    @Test
    func anIdleWidgetShowsNoPill() {
        #expect(RunPillPresentation.make(state: .idle, command: "") == nil)
    }

    @Test
    func longWordsAreCutAtTheLimitWithAnEllipsis() throws {
        let command = String(repeating: "summarise the quarterly report ", count: 4)
        let pill = try #require(RunPillPresentation.make(state: .working, command: command))

        #expect(pill.words.count <= RunPillPresentation.wordLimit)
        #expect(pill.words.hasSuffix("…"))
        #expect(!pill.words.hasSuffix(" …"))
    }

    /// The pill is System B, like the widget it stands in for: `WidgetTheme` and `WidgetType`,
    /// never a `SonnyTheme`, `SonnyType` or `SonnySpacing` token (the two-system rule in
    /// `.claude/rules/macagent-ui-conventions.md`).
    @Test
    @MainActor
    func thePillViewUsesOnlySystemBTokens() throws {
        let source = try MacAgentSource.read("RunPillView.swift")

        #expect(source.contains("WidgetTheme."))
        #expect(source.contains("WidgetType."))
        #expect(!source.contains("SonnyTheme"))
        #expect(!source.contains("SonnyType"))
        #expect(!source.contains("SonnySpacing"))
        #expect(!source.contains("SonnyRadius"))
    }
}

/// The pill's window sits flush with the visible frame's top-right corner, on whichever screen
/// the cursor is on; the view's own padding is the visible gap.
@Suite
struct RunPillPlacementTests {
    @Test
    func thePillSitsFlushWithTheTopRightOfTheVisibleFrame() {
        let frame = RunPillPlacement.frame(
            contentSize: CGSize(width: 200, height: 68),
            in: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )

        #expect(frame == CGRect(x: 1240, y: 807, width: 200, height: 68))
    }

    @Test
    func aSecondScreensFrameIsHonouredInItsOwnCoordinates() {
        let frame = RunPillPlacement.frame(
            contentSize: CGSize(width: 260, height: 68),
            in: CGRect(x: 1440, y: 100, width: 2560, height: 1400)
        )

        #expect(frame.maxX == 4000)
        #expect(frame.maxY == 1500)
        #expect(frame.size == CGSize(width: 260, height: 68))
    }
}
