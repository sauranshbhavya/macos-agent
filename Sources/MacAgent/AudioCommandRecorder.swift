import AVFoundation
import Foundation
import MacAgentCore

/// One finished recording: the file, and how long the user actually held the key for.
///
/// **The duration travels with the file because the file's own length is not the same number**
/// (SONNY-130). `AVAudioRecorder` stops itself at `record(forDuration:)`, so a user who holds the
/// hotkey for ten minutes produces a file just over the ceiling and a *held* duration of ten
/// minutes. The refusal is about the second one — it is what the founder's manual item does — and a
/// check that read the file's length would quietly transcribe every over-long recording as though it
/// had been a normal one.
struct FinishedRecording {
    let url: URL
    let heldFor: TimeInterval
}

@MainActor
final class AudioCommandRecorder {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var startedAt: Date?
    private let now: () -> Date

    /// `now` is a seam so the duration logic can be tested without a microphone.
    ///
    /// No agent session can record audio or drive the live app, so a test that had to make a real
    /// recording could not exist; this is what makes "a recording past the cap is refused" a thing
    /// the suite can hold rather than a thing only the founder can check. It is not a wall-clock
    /// *assertion* — nothing here races a clock — it is a measurement of how long a user held a key,
    /// which is exactly what a clock is for.
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// The hard ceiling on the *file*, as distinct from the cap on the recording.
    ///
    /// A few seconds above `VoiceRecordingLimit.maximumDurationSeconds` on purpose. The cap is what
    /// refuses, and it needs the measured duration to have genuinely passed it; a ceiling set to the
    /// cap exactly would leave a recording sitting on the boundary, where a few milliseconds of
    /// scheduling decide whether the user is refused or charged for. The gap makes the answer
    /// unambiguous while still bounding the file at roughly two megabytes, which is the whole point
    /// of having a ceiling: without one, a hotkey that sticks records until the disk fills.
    static let fileCeilingSeconds = VoiceRecordingLimit.maximumDurationSeconds + 5

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macagent-voice-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        // **Bounded at the source** (SONNY-130). `record()` with no duration is what made a stuck
        // hotkey an unbounded file, which became an unbounded upload at the founders' expense the
        // moment voice started going through Sonny's own backend.
        recorder.record(forDuration: Self.fileCeilingSeconds)

        self.recorder = recorder
        recordingURL = url
        startedAt = now()
    }

    func stop() throws -> FinishedRecording {
        // Read before stopping: `AVAudioRecorder` reports no `currentTime` once it is not recording,
        // and it may already have stopped itself at the ceiling above — in which case the elapsed
        // time is still the honest answer to "how long did the user hold this".
        let heldFor = startedAt.map { now().timeIntervalSince($0) } ?? 0
        recorder?.stop()
        recorder = nil
        startedAt = nil

        guard let recordingURL else {
            throw VoiceRecordingError.noActiveRecording
        }

        self.recordingURL = nil
        return FinishedRecording(url: recordingURL, heldFor: heldFor)
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        startedAt = nil

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }
}

enum VoiceRecordingError: Error, LocalizedError {
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No active voice recording was found."
        }
    }
}
