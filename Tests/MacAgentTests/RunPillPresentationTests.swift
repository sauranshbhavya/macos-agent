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

    // MARK: - A live screen-control session (founder decision 2026-09-12, PR #237's F1)

    private static let session = VisionSessionProgress(
        appDisplayName: "Notes",
        iteration: 2,
        maximumIterations: 12,
        currentAction: "Clicking the New Note button"
    )

    /// **Its own kind, and told apart from an ordinary run by what it says rather than by a flag.**
    /// The arm that folds the two together is `mutation/plans/…`'s P7, and it is what shipped until
    /// this round: a session behind "Sonny is working on: …" in the same action blue as a file zip.
    @Test
    func aLiveSessionIsItsOwnKindAndNotAnOrdinaryRun() throws {
        let pill = try #require(RunPillPresentation.make(state: .controlling(Self.session), command: "open Notes"))
        let ordinary = try #require(RunPillPresentation.make(state: .working, command: "open Notes"))

        #expect(pill.kind == .controlling)
        #expect(pill.kind != ordinary.kind)
        #expect(pill.words == "Sonny is controlling Notes")
        #expect(pill.words != ordinary.words)
        #expect(pill.tint == .controlling)
        #expect(pill.tint != ordinary.tint, "a session must not read in the same colour as a file zip")
        #expect(pill.glyph == "cursorarrow.rays")
        #expect(ordinary.controlling == nil)
    }

    /// Every clause of `WidgetControllingPanel`'s stated requirement, carried to the corner: that
    /// Sonny is controlling something, which app, what it is doing now, how far in, Pause, Stop.
    @Test
    func theControllingPillCarriesWhatTheHudCarries() throws {
        let pill = try #require(RunPillPresentation.make(state: .controlling(Self.session), command: ""))
        let controlling = try #require(pill.controlling)

        #expect(controlling.appDisplayName == "Notes")
        #expect(controlling.currentAction == "Clicking the New Note button")
        #expect(controlling.stepLine == "Step 2 of 12")
        #expect(controlling.pauseLabel == ScreenControlSessionPresentation.pauseLabel)
        #expect(controlling.stopLabel == ScreenControlSessionPresentation.stopLabel)
        #expect(controlling.pauseAccessibilityLabel == "Pause Sonny controlling Notes")
        #expect(controlling.stopAccessibilityLabel == "Stop Sonny controlling Notes")
    }

    /// **The way out, in the pill's own words and in the spoken label** — the panel's closing line
    /// is on the pill for the reason the panel gives it: during a session the pointer is not the
    /// user's to aim, so a control nobody knows about is not a control. `mutation/plans/…`'s P8
    /// empties it.
    @Test
    func theControllingPillCarriesTheWayOut() throws {
        let pill = try #require(RunPillPresentation.make(state: .controlling(Self.session), command: ""))
        let controlling = try #require(pill.controlling)

        #expect(controlling.hotkeyLine == "\(EmergencyStopHotKey.displayName) stops it from anywhere.")
        #expect(!controlling.hotkeyLine.isEmpty)
        #expect(pill.accessibilityLabel.contains(EmergencyStopHotKey.displayName))
        #expect(pill.accessibilityLabel.contains(ScreenControlSessionPresentation.stopLabel))
        #expect(pill.accessibilityLabel.contains("Sonny is controlling Notes"))
        #expect(pill.accessibilityLabel.contains("Clicking the New Note button"))
    }

    /// A session whose action line is missing still says something rather than nothing.
    @Test
    func aSessionWithNoActionLineFallsBackRatherThanShowingAnEmptyRow() throws {
        let quiet = VisionSessionProgress(
            appDisplayName: "Notes",
            iteration: 1,
            maximumIterations: 12,
            currentAction: "   "
        )
        let pill = try #require(RunPillPresentation.make(state: .controlling(quiet), command: ""))

        #expect(try #require(pill.controlling).currentAction == RunPillPresentation.controllingActionFallback)
    }

    /// **The tooltip drops the instruction and the label keeps it** (PR #237's F7). The tooltip is
    /// the surface the founders' no-explanatory-copy rule governs; the accessibility label is where
    /// a screen reader needs the action.
    @Test
    func theTooltipCarriesNoInstructionAndTheLabelStillDoes() throws {
        let states: [WidgetState] = [
            .working,
            .result("Zipped 3 files.", nil),
            .failure("Could not reach the folder."),
            .clarification("Which file did you mean?"),
            .controlling(Self.session)
        ]
        for state in states {
            let pill = try #require(RunPillPresentation.make(state: state, command: "zip my Desktop"))
            #expect(!pill.tooltip.contains("Click to"), "tooltip instructs: \(pill.tooltip)")
            #expect(!pill.tooltip.isEmpty)
        }
        // The control: the label, which is the channel that should still say it.
        let working = try #require(RunPillPresentation.make(state: .working, command: "zip my Desktop"))
        #expect(working.accessibilityLabel.contains("Click to expand."))
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
