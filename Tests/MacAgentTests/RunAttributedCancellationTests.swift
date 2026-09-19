import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgent
@testable import MacAgentCore

// MARK: - SONNY-456: stopping a run resumes the question that run parked, and no other

/// A screen-control question's cancellation hop reads the run that parked it, whoever cancelled and
/// whatever the widget is showing (PR #279's review, the first item on the next lane's list).
///
/// **Two runs, a question parked on each, the widget left on the first, and the second cancelled
/// from outside any run** — which is where a Stop on a pill, the hotkey and `start()`'s own
/// `currentTask?.cancel()` all cancel from. Before the hop was bound, that read the first run's
/// continuation: the run on screen was declined, and the cancelled run was never resumed, so it
/// never ended and would have held its slot against the cap of three for good.
@Suite(.serialized)
@MainActor
struct RunAttributedCancellationTests {
    @Test
    func cancellingABackgroundRunsPausedSessionResumesThatRunAndNotTheOneOnScreen() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let onScreen = viewModel.focusedRunID
        let background = viewModel.addRunSlotForTests()
        let pauseOnScreen = VisionSessionPause(appDisplayName: "Safari", reason: .screenLocked, iteration: 1)
        let pauseInBackground = VisionSessionPause(appDisplayName: "Notes", reason: .userIdle, iteration: 2)

        let onScreenTask = Task {
            try await RunScope.$current.withValue(onScreen) {
                try await viewModel.awaitVisionResume(pauseOnScreen)
            }
        }
        let backgroundTask = Task {
            try await RunScope.$current.withValue(background) {
                try await viewModel.awaitVisionResume(pauseInBackground)
            }
        }
        try await HangBackstop.waitOrAbandon(for: "both runs to park their pause") {
            slot(onScreen, in: viewModel)?.visionResumeContinuation != nil
                && slot(background, in: viewModel)?.visionResumeContinuation != nil
        }
        try #require(viewModel.focusedRunID == onScreen, "precondition: the widget is on the other run")

        backgroundTask.cancel()
        // Ends on either run's question moving, so a hop that reached the wrong run fails at an
        // assertion below rather than as a wait that gave up.
        try await HangBackstop.waitOrAbandon(for: "the cancellation to resume one of the two questions") {
            slot(background, in: viewModel)?.visionResumeContinuation == nil
                || slot(onScreen, in: viewModel)?.visionResumeContinuation == nil
        }

        #expect(slot(onScreen, in: viewModel)?.visionSessionPause == pauseOnScreen, "the run on screen was declined instead")
        #expect(slot(onScreen, in: viewModel)?.visionResumeContinuation != nil)
        let resumedItsOwn = slot(background, in: viewModel)?.visionResumeContinuation == nil
        #expect(resumedItsOwn, "the cancelled run was never resumed, so it would never end")
        #expect(slot(background, in: viewModel)?.visionSessionPause == nil)

        // Whichever question is still parked is answered in its own run, so neither task outlives
        // the test. Awaiting the cancelled run is only safe once it has been resumed.
        if resumedItsOwn {
            let ended = await backgroundTask.result
            #expect(throws: CancellationError.self) { try ended.get() }
        } else {
            RunScope.$current.withValue(background) { viewModel.resolveVisionPause(resuming: false) }
        }
        RunScope.$current.withValue(onScreen) { viewModel.resolveVisionPause(resuming: false) }
        _ = await onScreenTask.result
    }

    /// The same for Safe mode's capture review, where the run on screen has nothing parked: the
    /// unbound hop found nothing there and returned, which is the quieter of the two failures.
    @Test
    func cancellingABackgroundRunsCaptureReviewResumesItWhenTheRunOnScreenHasNothingParked() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let onScreen = viewModel.focusedRunID
        let background = viewModel.addRunSlotForTests()
        let preview = VisionCapturePreview(
            appDisplayName: "Notes",
            windowTitle: nil,
            redactedImageData: nil,
            pixelWidth: 10,
            pixelHeight: 10,
            redactionReport: [],
            iteration: 1,
            maximumIterations: 8
        )

        let backgroundTask = Task {
            try await RunScope.$current.withValue(background) {
                try await viewModel.confirmVisionCaptureBeforeSending(preview)
            }
        }
        try await HangBackstop.waitOrAbandon(for: "the background run to park its capture review") {
            slot(background, in: viewModel)?.visionCaptureContinuation != nil
        }
        try #require(viewModel.focusedRunID == onScreen, "precondition: the widget is on the other run")

        backgroundTask.cancel()
        // The hop is one main-actor turn away. The unbound hop finds nothing on the run on screen
        // and returns, so this wait is the assertion: it ends only when the right run is resumed.
        let resumedItsOwn = try await HangBackstop.waitRecordingAStuckWait(
            for: "the cancelled run's capture review to be resumed",
            stuck: "the cancelled run's question was never resumed: its cancellation read the run on screen"
        ) {
            slot(background, in: viewModel)?.visionCaptureContinuation == nil
        }
        guard resumedItsOwn else {
            RunScope.$current.withValue(background) { viewModel.resolveVisionCapturePreview(allowing: false) }
            _ = await backgroundTask.result
            return
        }
        #expect(slot(background, in: viewModel)?.visionCapturePreview == nil)
        let ended = await backgroundTask.result
        #expect(throws: CancellationError.self) { try ended.get() }
    }

    /// All four questions hop through the one bound helper, and none starts a bare `Task` of its
    /// own — the approval and the delegation cannot be parked from a test without a live session,
    /// so their hops are held here as the same spelling the two above are driven through.
    @Test
    func everyParkedQuestionsCancellationHopsThroughTheBoundHelper() throws {
        let source = try MacAgentSource.read("AgentViewModel+VisionSession.swift")
        #expect(MacAgentSource.count(of: "withTaskCancellationHandler", inText: source) == 4)
        #expect(MacAgentSource.count(of: "let parkedOn = runIDInScope", inText: source) == 4)
        #expect(MacAgentSource.count(of: "} onCancel: {\n            self.afterCancellation(ofAQuestionParkedOn: parkedOn) {", inText: source) == 4)
        #expect(MacAgentSource.count(of: "Task { @MainActor in", inText: source) == 1, "a hop started a task outside the bound helper")
        let helper = try MacAgentSource.braceBlock(of: source, openedBy: "_ resume: @escaping @MainActor @Sendable () -> Void\n    ) {")
        #expect(MacAgentSource.count(of: "RunScope.$current.withValue(runID) {", inText: helper) == 1)
    }
}
