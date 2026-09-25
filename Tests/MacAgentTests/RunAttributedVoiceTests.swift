import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgent
@testable import MacAgentCore

// MARK: - SONNY-456: a voice recording writes to the run it started on

/// A voice recording's stop, and everything after it, lands on the run the recording started on —
/// not on whichever run the widget is showing when the stop arrives.
///
/// Every caller of the stop is outside any run: the mic's own Stop, the hotkey's release and the
/// auto-stop. Before the recording carried its run, each wrote to the run on screen at that moment,
/// which is a different run as soon as the user can look at another one while they speak.
@Suite(.serialized)
@MainActor
struct RunAttributedVoiceTests {
    /// The recorder's own failure is the one write a test process can reach: nothing is recording,
    /// so `AudioCommandRecorder.stop()` throws before any transcription is attempted.
    @Test
    func aStopThatFailsSaysSoOnTheRunTheRecordingStartedOn() throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let onScreen = viewModel.focusedRunID
        let recordedOn = viewModel.addRunSlotForTests()

        viewModel.voiceRecordingRunID = recordedOn
        viewModel.isRecordingVoice = true
        try #require(viewModel.focusedRunID == onScreen, "precondition: the widget is on the other run")
        viewModel.toggleVoiceRecording(origin: .widget)

        #expect(!viewModel.isRecordingVoice)
        #expect(slot(recordedOn, in: viewModel)?.errorMessage != nil, "the recording's run was told nothing")
        #expect(slot(onScreen, in: viewModel)?.errorMessage == nil, "the failure landed on the run on screen")
    }

    /// With no recording's run on record the stop falls back to the run in scope, which is what it
    /// read before — the state every existing voice test drives, and the reason none of them moved.
    @Test
    func aStopWithNoRecordedRunStillWritesToTheRunOnScreen() throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let onScreen = viewModel.focusedRunID
        _ = viewModel.addRunSlotForTests()

        viewModel.isRecordingVoice = true
        viewModel.toggleVoiceRecording(origin: .widget)

        #expect(slot(onScreen, in: viewModel)?.errorMessage != nil)
    }

    /// The rest of the pipeline cannot run in a test process — it asks for the microphone and calls
    /// a transcriber — so the binding of its two tasks is read rather than run.
    @Test
    func bothVoiceTasksRunInsideTheRecordingsRun() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let start = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func startVoiceRecording(trigger: VoiceRecordingTrigger, origin: TaskOrigin) {"
        )
        #expect(MacAgentSource.count(of: "let recordingRun = runIDInScope\n        voiceRecordingRunID = recordingRun", inText: start) == 1)
        let startTask = try MacAgentSource.braceBlock(of: start, openedBy: "Task {")
        #expect(MacAgentSource.count(of: "await RunScope.$current.withValue(recordingRun) {", inText: startTask) == 1)
        #expect(MacAgentSource.count(of: "await beginRecordingOncePermitted(trigger: trigger)", inText: startTask) == 1)
        #expect(MacAgentSource.count(of: "voiceRecordingRunID = ", inText: source) == 1, "written once, where a recording starts")

        let stop = try MacAgentSource.braceBlock(of: source, openedBy: "private func stopVoiceRecordingAndTranscribe() {")
        #expect(MacAgentSource.count(of: "let recordingRun = voiceRecordingRunID ?? runIDInScope", inText: stop) == 1)
        let transcription = try MacAgentSource.braceBlock(of: stop, openedBy: "Task {")
        #expect(MacAgentSource.count(of: "await RunScope.$current.withValue(recordingRun) {", inText: transcription) == 1)
    }
}
