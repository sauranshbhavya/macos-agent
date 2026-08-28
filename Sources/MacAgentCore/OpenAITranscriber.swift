import Foundation

public enum TranscriptionError: Error, LocalizedError, Equatable, CarriesBackendError {
    /// **`missingAPIKey` and `badResponse(Int, String)` are gone** (SONNY-136). SONNY-130 kept both
    /// unreachable — no transcriber reads a provider key and none reads an HTTP status — because the
    /// sentence naming the variable was this ticket's to remove. Removing the sentence and keeping
    /// the case would have left an enum case nothing can construct and nothing can throw, so both
    /// went together.
    case unreadableAudioFile(String)
    case missingText
    /// The recording is longer than Sonny will transcribe. **This is the client half of SONNY-130's
    /// audio limit**, and the sentence below is what the user actually sees.
    case recordingTooLong(maximumSeconds: Int)
    /// A call to Sonny's backend failed. The user sees `SonnyBackendCopy`'s sentence, never the
    /// server's own `message` (§7.1).
    case backend(SonnyBackendError)

    /// ``CarriesBackendError``: so a cancellation raised inside the shared client is still
    /// recognisable after this type wraps it (SONNY-320), the same one line the other two text
    /// wrappers carry.
    ///
    /// **What this route does not yet have is anything that presses stop**, stated here rather than
    /// left for a reader to assume from the conformance. `AgentViewModel.stopVoiceRecordingAndTranscribe`
    /// runs the transcription in an unstructured `Task { }` that nothing stores, so
    /// `cancelCurrentRun`'s `currentTask?.cancel()` cannot reach it — the product question of
    /// whether it should, and what surface would offer the press, is SONNY-332's.
    ///
    /// **The caller now asks, which is the half that is done** (SONNY-327). This used to say the
    /// route's own `catch` called `setError(error.localizedDescription)` without consulting
    /// ``SonnyBackendError/isCancellation(_:)`` at all, and it did; the non-success exit is now the
    /// single seam `AgentViewModel.deliverTranscriptionError(_:)`, which consults it. So a
    /// cancellation that becomes raisable renders as a stop rather than as the `.cancelled`
    /// sentence below. The conformance is still right and still belongs here: the population
    /// SONNY-320 fixed is the error type, and a type that answers the question wrongly is a trap for
    /// the caller that eventually asks it.
    public var backendError: SonnyBackendError? {
        guard case .backend(let error) = self else { return nil }
        return error
    }

    public var errorDescription: String? {
        switch self {
        case .unreadableAudioFile(let path):
            return "Could not read recorded audio at \(path)."
        case .missingText:
            return "Sonny couldn't read anything back from that recording."
        case .recordingTooLong(let maximumSeconds):
            return VoiceRecordingLimit.refusalSentence(maximumSeconds: maximumSeconds)
        case .backend(let error):
            return SonnyBackendCopy.sentence(for: error)
        }
    }
}

/// How long a spoken command may be, and what the user is told when one runs past it (SONNY-130).
///
/// **The cap exists because the recorder never had one.** `AudioCommandRecorder` records AAC mono
/// 44.1 kHz with no maximum duration, which was survivable while the audio went to the user's own
/// provider key: a stuck hotkey cost the user their own money and nothing else. Behind Sonny's
/// backend it is an unbounded upload at the founders' expense, and `docs/sonny-backend-api-contract.md`
/// §4.4 records the byte limit on the server as a "backstop for an unbounded recording, until
/// SONNY-130's duration cap". This is that cap.
///
/// **180 seconds, and the number is derived rather than picked.** Ordinary speech runs two to three
/// words a second, so three minutes is 350–500 words — longer than any command Sonny can act on,
/// and longer than anything a user would dictate into a `create_local_draft` step. Past it, the
/// thing recording is not a command; it is a recorder nobody stopped.
///
/// **The server enforces bytes and this side enforces duration, and that split is deliberate.** The
/// Mac is the side holding the recorder, so it is the only side that knows a duration honestly — a
/// client-supplied one would be a client-trust decision on the field that decides the bill, which
/// §2.4.1 forbids in general. The server's own ceiling is §6.1's 10 MiB, which at this recorder's
/// bitrate is around fifteen minutes: so the cap here binds first by an order of magnitude, which is
/// the ordering §6.2 requires, and the byte limit is the backstop for a client that is not ours.
public enum VoiceRecordingLimit {
    public static let maximumDurationSeconds: TimeInterval = 180

    /// Whether a recording of `duration` is past the cap.
    ///
    /// A separate function rather than a comparison written at each call site, because there are two
    /// call sites — the recorder and the transcriber — and a limit spelled twice is a limit that
    /// eventually disagrees with itself.
    public static func isTooLong(_ duration: TimeInterval) -> Bool {
        duration > maximumDurationSeconds
    }

    /// What the user is told. Functional, not explanatory (founder, 2026-08-14): what happened and
    /// what to do next, with nothing about uploads, costs, backends or limits-in-general.
    ///
    /// The duration is spelled in whichever unit reads as a round number, because the alternative —
    /// dividing by sixty and writing "minutes" — renders "1 minutes" for a ninety-second cap and
    /// "2 minutes" for a hundred-and-fifty-second one. The cap is a constant somebody will change.
    public static func refusalSentence(maximumSeconds: Int = Int(maximumDurationSeconds)) -> String {
        let spelled: String
        if maximumSeconds % 60 == 0 {
            let minutes = maximumSeconds / 60
            spelled = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        } else {
            spelled = maximumSeconds == 1 ? "1 second" : "\(maximumSeconds) seconds"
        }
        return "That recording is too long. Sonny listens for up to \(spelled) at a time."
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public var text: String
    public var usage: AIUsageRecord?

    public init(text: String, usage: AIUsageRecord? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// Voice transcription, **through Sonny's backend** (SONNY-130).
///
/// Raw voice audio is the most personally sensitive of the four content types this branch moved, and
/// the founder's decision of 2026-08-16 is that it goes through the backend and is retained under
/// the standard content clock — it is content, not telemetry. A run started with "Don't save this
/// task" sends `retention: "none"` like every other request, which is `taskContext`'s job and not
/// this type's.
public struct OpenAITranscriber: Sendable {
    private let client: SonnyBackendClient
    private let taskContext: BackendTaskContext
    private let usageRecorder: any TaskUsageRecording

    public init(
        client: SonnyBackendClient,
        taskContext: BackendTaskContext,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared
    ) {
        self.client = client
        self.taskContext = taskContext
        self.usageRecorder = usageRecorder
    }

    /// Transcribe a recording, refusing one that ran past `VoiceRecordingLimit`.
    ///
    /// **`recordedDuration` is a parameter rather than something measured here, and it has no
    /// default.** Reading an `.m4a`'s duration means `AVFoundation`, which `MacAgentCore` does not
    /// import; the side that knows how long the recording ran is `AudioCommandRecorder`, which held
    /// the hotkey down. Undefaulted because a defaulted `nil` would let a call site skip the cap by
    /// saying nothing, which is the one way this limit stops existing — and `nil` really is a
    /// legitimate answer, for a caller that genuinely does not know, where the server's byte ceiling
    /// is what remains.
    public func transcribe(
        audioFileURL: URL,
        recordedDuration: TimeInterval?
    ) async throws -> TranscriptionResult {
        // **Refused before a byte is sent**, which is the shape §6.2 asks for and the shape
        // `VisionModelClient` already uses for its own oversize payloads: a refusal the user can act
        // on, rather than a 413 they cannot explain and cannot fix by retrying. Checked before the
        // file is even read, so an over-length recording costs nothing at all.
        if let recordedDuration, VoiceRecordingLimit.isTooLong(recordedDuration) {
            throw TranscriptionError.recordingTooLong(
                maximumSeconds: Int(VoiceRecordingLimit.maximumDurationSeconds)
            )
        }

        guard let audioData = try? Data(contentsOf: audioFileURL) else {
            throw TranscriptionError.unreadableAudioFile(audioFileURL.path)
        }

        let boundary = "SonnyAudioBoundary-\(UUID().uuidString)"
        let decoded: SonnyTranscriptionRouteResponse
        do {
            decoded = try await client.modelRouteResponse(
                SonnyTranscriptionRouteResponse.self,
                route: .transcription,
                body: Self.multipartBody(
                    boundary: boundary,
                    context: taskContext,
                    filename: audioFileURL.lastPathComponent,
                    audioData: audioData
                ),
                contentType: "multipart/form-data; boundary=\(boundary)"
            )
        } catch let error as SonnyBackendError {
            throw TranscriptionError.backend(error)
        }

        // An empty transcript and a missing one are the same outcome for the user — no words — and
        // this collapsed them long before the gateway existed. The server collapses them too, so
        // this is the second of two guards rather than the only one.
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.missingText
        }
        let usage = decoded.usage?.record(kind: .transcription, route: .transcription)
            ?? AIUsageRecord(
                kind: .transcription,
                model: SonnyModelRoute.transcription.usageModelName
            )
        usageRecorder.record(usage)
        return TranscriptionResult(text: text, usage: usage)
    }

    /// §4.4's two parts: `meta` as JSON, `audio` as the bytes verbatim.
    ///
    /// Multipart rather than base64-in-JSON because base64 inflates the audio by a third for no
    /// gain, which is the contract's own reasoning, and because this client already built one.
    static func multipartBody(
        boundary: String,
        context: BackendTaskContext,
        filename: String,
        audioData: Data
    ) -> Data {
        var body = Data()
        let meta = (try? JSONSerialization.data(withJSONObject: context.wireFields)) ?? Data("{}".utf8)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"meta\"\r\n")
        body.appendString("Content-Type: application/json\r\n\r\n")
        body.append(meta)
        body.appendString("\r\n")
        body.appendFileField(
            name: "audio",
            filename: filename,
            contentType: "audio/mp4",
            data: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func appendFileField(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(contentType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }

    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
