import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Voice transcription, **against Sonny's own backend** (SONNY-130).
///
/// **Every test in the environment-key version of this file has a successor here**, one of them
/// renamed because what it asserted no longer exists:
///
/// | before | after |
/// |---|---|
/// | `transcribesFixtureResponse` | same name |
/// | `transcribesFixtureResponseWithDurationUsage` | same name |
/// | `transcriberSurfacesBadHTTPStatusWithBody` | `transcriberSurfacesABackendFailureWithTheAppsOwnWords` |
/// | `transcriberRejectsEmptyAndWhitespaceOnlyTranscripts` | same name |
/// | `transcriberReportsUnreadableAudioFile` | same name |
///
/// The rename is the same one the planner's failure test took, for the same reason: a transcription
/// error carries no HTTP status and no response body any more, because §7.1 forbids showing the
/// server's own sentence and the shared client turns both into a typed `code`.
struct OpenAITranscriberTests {
    // MARK: - The wire

    @Test
    @MainActor
    func transcribesFixtureResponse() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(
                text: "Open Safari",
                usage: ModelRouteFixtures.reportedTokenUsage(input: 12, output: 4, total: 16)
            ))
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let recorder = TaskUsageRecorder()
        let result = try await Self.transcriber(fixture, usageRecorder: recorder)
            .transcribe(audioFileURL: audioURL, recordedDuration: 4)

        #expect(result.text == "Open Safari")
        #expect(result.usage?.tokenSource == .reported)
        #expect(result.usage?.tokenCounts.totalTokens == 16)
        #expect(result.usage?.model == "transcriptions")
        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedInputTokens == 12)
        #expect(summary.reportedOutputTokens == 4)
        #expect(summary.reportedTotalTokens == 16)

        let sent = try recorded.only
        #expect(sent.method == "POST")
        #expect(sent.path == "/v1/transcriptions")
        #expect(sent.authorization == "Bearer test-access-token")
        #expect(sent.idempotencyKey?.isEmpty == false)
        // §4.4: multipart, and the boundary the body actually uses.
        let contentType = try #require(sent.contentType)
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        #expect(sent.text.contains("--\(boundary)"))
    }

    @Test
    @MainActor
    func theMultipartBodyCarriesMetaAsJSONAndTheAudioBytesVerbatim() async throws {
        // §4.4's two parts. The audio goes as bytes rather than base64 because base64 would inflate
        // it by a third for no gain — the contract's own reasoning, and this is what holds it.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(text: "Open Safari"))
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("SENTINEL-AUDIO-BYTES")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = OpenAITranscriber(
            client: fixture.client,
            taskContext: BackendTaskContext(taskID: "task-voice-9", retention: .notStored)
        )
        _ = try await transcriber.transcribe(audioFileURL: audioURL, recordedDuration: 3)

        let body = try recorded.only.text
        #expect(body.contains("name=\"meta\""))
        #expect(body.contains("Content-Type: application/json"))
        #expect(body.contains("\"task_id\":\"task-voice-9\"") || body.contains("\"task_id\": \"task-voice-9\""))
        // A voice command in a run started with "Don't save this task" carries the same answer as
        // every other request that run makes — and voice is the content type most likely to be
        // overlooked, which is the founder's own note of 2026-08-16.
        #expect(body.contains("\"retention\":\"none\"") || body.contains("\"retention\": \"none\""))
        #expect(body.contains("name=\"audio\""))
        #expect(body.contains("Content-Type: audio/mp4"))
        #expect(body.contains("SENTINEL-AUDIO-BYTES"))
        #expect(body.contains(audioURL.lastPathComponent))
    }

    @Test
    @MainActor
    func theRequestNamesNoProviderNoModelAndNoVendorEndpoint() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(text: "Open Safari"))
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        _ = try await Self.transcriber(fixture).transcribe(audioFileURL: audioURL, recordedDuration: 2)

        let sent = try recorded.only
        let wire = sent.text.lowercased()
        for forbidden in ["openai", "api.openai.com", "gpt-4o", "transcribe-model", "whisper"] {
            #expect(!wire.contains(forbidden), "request body names \(forbidden)")
        }
        #expect(!sent.text.contains("response_format"))
    }

    // MARK: - Usage

    @Test
    @MainActor
    func transcribesFixtureResponseWithDurationUsage() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(
                text: "Open Notes",
                usage: ModelRouteFixtures.reportedDurationUsage(seconds: 2.5)
            ))
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let recorder = TaskUsageRecorder()
        let result = try await Self.transcriber(fixture, usageRecorder: recorder)
            .transcribe(audioFileURL: audioURL, recordedDuration: 2.5)

        #expect(result.text == "Open Notes")
        #expect(result.usage?.audioDurationSeconds == 2.5)
        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedTotalTokens == 0)
        #expect(summary.audioDurationSeconds == 2.5)
    }

    // MARK: - The audio limit

    @Test
    @MainActor
    func aRecordingPastTheLimitIsRefusedBeforeAnythingIsSent() async throws {
        // **SONNY-130's audio limit, client half.** Asserted on the concrete sentence, which the
        // ticket's acceptance criteria ask for by name, and on the request count — the whole point
        // is that an over-long recording costs nothing, so a refusal that still uploaded would be
        // the feature not working.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(text: "should not reach here"))
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await Self.transcriber(fixture).transcribe(
                audioFileURL: audioURL,
                recordedDuration: VoiceRecordingLimit.maximumDurationSeconds + 0.5
            )
            Issue.record("Expected a recording past the limit to be refused.")
        } catch let error as TranscriptionError {
            #expect(error == .recordingTooLong(maximumSeconds: 180))
            #expect(
                error.errorDescription
                    == "That recording is too long. Sonny listens for up to 3 minutes at a time."
            )
        }
        #expect(recorded.all.isEmpty)
    }

    @Test
    @MainActor
    func aRecordingExactlyAtTheLimitIsStillTranscribed() async throws {
        // The boundary, both sides. `AudioCommandRecorder` bounds the *file* a few seconds above the
        // cap precisely so a recording never lands on this edge in practice; the rule is still worth
        // pinning, because "too long" and "long enough" differing by a millisecond is the kind of
        // thing a later edit flips without noticing.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(text: "Just in time"))
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await Self.transcriber(fixture).transcribe(
            audioFileURL: audioURL,
            recordedDuration: VoiceRecordingLimit.maximumDurationSeconds
        )
        #expect(result.text == "Just in time")
        #expect(!VoiceRecordingLimit.isTooLong(VoiceRecordingLimit.maximumDurationSeconds))
        #expect(VoiceRecordingLimit.isTooLong(VoiceRecordingLimit.maximumDurationSeconds + 0.001))
    }

    @Test
    @MainActor
    func aCallerThatKnowsNoDurationIsNotRefused() async throws {
        // `nil` is a legitimate answer, and it means "the server's byte ceiling is what remains".
        // The alternative — refusing what cannot be measured — would break voice entirely the first
        // time a measurement failed.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(text: "Unmeasured"))
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await Self.transcriber(fixture)
            .transcribe(audioFileURL: audioURL, recordedDuration: nil)
        #expect(result.text == "Unmeasured")
    }

    @Test
    func theLimitAndItsSentenceAreTheOnesTheServerAndTheFounderWereToldAbout() {
        // The number is quoted in `server/src/model/limits.ts`, in the manual-test checklist and in
        // the ticket's closing comment. Written as a literal here so that changing it is a change
        // somebody made on purpose, and so the sentence is not silently reworded either.
        #expect(VoiceRecordingLimit.maximumDurationSeconds == 180)
        #expect(
            VoiceRecordingLimit.refusalSentence()
                == "That recording is too long. Sonny listens for up to 3 minutes at a time."
        )
        // The unit switches when the cap is not a whole number of minutes, so a later 90-second cap
        // does not render "1 minutes".
        #expect(
            VoiceRecordingLimit.refusalSentence(maximumSeconds: 90)
                == "That recording is too long. Sonny listens for up to 90 seconds at a time."
        )
        #expect(
            VoiceRecordingLimit.refusalSentence(maximumSeconds: 60)
                == "That recording is too long. Sonny listens for up to 1 minute at a time."
        )
    }

    // MARK: - Failure

    @Test
    @MainActor
    func transcriberSurfacesABackendFailureWithTheAppsOwnWords() async throws {
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            ModelRouteFixtures.failure(
                status: 429,
                code: "limit.rate",
                message: "Rate limited: 12 requests in 60s from account acct_7f3c",
                retryable: true
            )
        }
        defer { fixture.unregister() }

        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await Self.transcriber(fixture)
                .transcribe(audioFileURL: audioURL, recordedDuration: 2)
            Issue.record("Expected the backend failure to surface as TranscriptionError.backend.")
        } catch let error as TranscriptionError {
            guard case .backend(.api(let api)) = error else {
                Issue.record("Expected .backend(.api), got \(error).")
                return
            }
            #expect(api.code == .limitRate)
            #expect(api.statusCode == 429)
            let shown = try #require(error.errorDescription)
            #expect(shown == "Too many requests just now. Try again shortly.")
            #expect(!shown.contains("acct_7f3c"))
            #expect(!shown.contains("429"))
        }
    }

    @Test
    @MainActor
    func transcriberRejectsEmptyAndWhitespaceOnlyTranscripts() async throws {
        let fixture = SignedInBackendFixture()
        let audioURL = try Self.writeAudio("fake-audio")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        defer { fixture.unregister() }

        for text in ["", "   \n  "] {
            fixture.register { _ in
                ModelRouteFixtures.reply(ModelRouteFixtures.transcriptionJSON(text: text))
            }
            await #expect(throws: TranscriptionError.missingText, "text \(text.debugDescription)") {
                _ = try await Self.transcriber(fixture)
                    .transcribe(audioFileURL: audioURL, recordedDuration: 2)
            }
        }

        // A body with no `text` field at all is a different failure now: `text` is required by
        // §4.4's response, so a body without it does not decode. The environment-key version
        // collapsed the two into `missingText`; the contract's shape separates them.
        fixture.register { _ in ModelRouteFixtures.reply(Data("{}".utf8)) }
        do {
            _ = try await Self.transcriber(fixture)
                .transcribe(audioFileURL: audioURL, recordedDuration: 2)
            Issue.record("Expected a response with no text field to fail to decode.")
        } catch let error as TranscriptionError {
            guard case .backend(.undecodableResponse) = error else {
                Issue.record("Expected .backend(.undecodableResponse), got \(error).")
                return
            }
        }
    }

    @Test
    @MainActor
    func transcriberReportsUnreadableAudioFile() async throws {
        let fixture = SignedInBackendFixture()
        defer { fixture.unregister() }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macagent-missing-\(UUID().uuidString).m4a")

        await #expect(throws: TranscriptionError.unreadableAudioFile(missingURL.path)) {
            _ = try await Self.transcriber(fixture)
                .transcribe(audioFileURL: missingURL, recordedDuration: 2)
        }
    }

    // MARK: - Fixtures

    @MainActor
    private static func transcriber(
        _ fixture: SignedInBackendFixture,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared
    ) -> OpenAITranscriber {
        OpenAITranscriber(
            client: fixture.client,
            taskContext: ModelRouteFixtures.standardContext,
            usageRecorder: usageRecorder
        )
    }

    private static func writeAudio(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macagent-transcriber-test-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
        return url
    }
}
