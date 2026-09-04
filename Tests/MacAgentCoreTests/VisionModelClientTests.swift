import CoreGraphics
import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

// MARK: - Fakes

private struct SilentRecognizer: ImageTextRecognizing {
    func recognizeText(inPNGData pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
        []
    }
}

private func fixtureCapture(png: Data, width: Int, height: Int) -> CapturedWindowImage {
    CapturedWindowImage(
        pngData: png,
        pixelWidth: width,
        pixelHeight: height,
        bundleIdentifier: "com.example.notes",
        windowTitle: "Fixture",
        windowID: 1,
        windowFrame: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    )
}

/// §4.5's reply.
///
/// **Outside the suite deliberately.** `BackendStubURLProtocol`'s handler runs on whatever thread
/// `URLSession` calls it on, so a `@MainActor` helper cannot be called from inside one — the same
/// shape `ModelRouteFixtures` takes for SONNY-130's four suites, and for the same reason.
///
/// `output_text` is a required field of the contract's response, so a body without it fails to decode
/// rather than decoding into nothing.
private func visionReply(
    _ outputText: String = #"{"action":"done","rationale":"ok"}"#,
    usage: [String: Any]? = nil
) -> BackendStubURLProtocol.Outcome {
    var object: [String: Any] = ["request_id": "req_vision_1", "output_text": outputText]
    if let usage { object["usage"] = usage }
    return .reply(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)
    )
}

/// The vision client, **against Sonny's own backend** (SONNY-131), and the ceiling that refuses an
/// oversize capture (SONNY-114).
///
/// **Every test in the environment-key version of this file has a successor here or a recorded
/// retirement**, following the accounting SONNY-130's four migrated suites use:
///
/// | before | after |
/// |---|---|
/// | `theDataURLDeclaresThePayloadsOwnMediaTypeOnBothBranches` | `theImageOnTheWireDeclaresThePayloadsOwnMediaTypeOnBothBranches` |
/// | `aPayloadOverTheCeilingIsRefusedWithNothingSent` | same name |
/// | `theShippingPolicyKeepsEvenItsWorstCaseUnderTheCeiling` | same name |
/// | `aRequestAtTheCeilingStaysInsideTheHostBodyBudget` | same name |
/// | `aCompressedBodyIsARealGzipStreamAndNotRawDeflate` | same name |
/// | `theChecksumMatchesThePublishedCRC32Vector` | same name |
/// | `theDefaultEndpointSendsAnUncompressedBodyWithNoContentEncoding` | `theRequestCarriesNoContentEncodingSetByThisClient` |
/// | `aCompressedRequestInflatesToTheSameJSONTheUncompressedPathSends` | **retired** — see below |
/// | `compressionShrinksTheWireBodyWithoutMovingTheCeiling` | **retired**; its ceiling half is `theCeilingIsTheSameNumberOnBothSidesOfTheNetwork` |
///
/// **The two retirements are the same fact and it is worth stating plainly.** The client no longer
/// has a `compressesRequestBody` switch: `SonnyBackendClient` builds every request now, and it does
/// not compress. Those two tests drove that switch, so there is nothing left for them to drive. The
/// *encoder* they exercised through it — `HTTPBodyCompression` — is untouched and its own two tests
/// are still here; it has no production caller today and is kept for **SONNY-317**, which implements
/// §6.4's gzip on both sides at once. It is a utility with a named owner rather than an unreachable
/// guard, which is the distinction PR #139's F11 turns on.
///
/// **The suite is no longer `.serialized`.** It used to be, because its fixture transport keyed its
/// handler off one `static`. `BackendStubURLProtocol` keys by host, so these run beside each other
/// and beside SONNY-130's four — the same removal `ModelRouteFixtures` records for those.
@MainActor
struct VisionModelClientTests {
    // MARK: - Fixtures

    private static func client(
        _ fixture: SignedInBackendFixture,
        context: BackendTaskContext = BackendTaskContext(taskID: "task-fixture-1", retention: .standard),
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared
    ) -> SonnyVisionModelClient {
        SonnyVisionModelClient(client: fixture.client, taskContext: context, usageRecorder: usageRecorder)
    }

    private static let session = VisionSessionRequestContext(sessionID: "session-fixture-1", iteration: 5)

    private static func smallPayload() async throws -> RedactedPayload {
        let png = ImageFixtures.whiteOverBlackPNG(width: 64, height: 48)
        return try await LocalRedactionService(textRecognizer: SilentRecognizer())
            .redactCapture(fixtureCapture(png: png, width: 64, height: 48))
    }

    // MARK: - What goes on the wire

    @Test
    func theRequestCarriesSection45sFieldsToTheScreenRouteUnderTheUsersOwnSession() async throws {
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        let payload = try await Self.smallPayload()
        _ = try await Self.client(fixture).decide(prompt: "look at this", payload: payload, session: Self.session)

        let sent = try recorded.only
        #expect(sent.method == "POST")
        #expect(sent.path == "/v1/screen/analyze")
        #expect(sent.contentType == "application/json")
        // The user's own Sonny session, not a provider credential — the whole point of the move.
        #expect(sent.authorization == "Bearer test-access-token")
        // §9.1: every POST carries a key, and it is what makes a retry unable to double-bill.
        #expect(sent.idempotencyKey?.isEmpty == false)

        let body = sent.json
        // §2.4: required on every content-bearing request, and never defaulted.
        #expect(body["task_id"] as? String == "task-fixture-1")
        #expect(body["retention"] as? String == "standard")
        // §4.5's two session fields. There is no server-side session — these exist so metering can
        // price a session rather than a request, and so a support lookup can put one request back
        // into the sequence it came from.
        #expect(body["session_id"] as? String == "session-fixture-1")
        #expect(body["session_iteration"] as? Int == 5)
        // §1.3: the client composes the prompt and the server never rebuilds it, because
        // `VisionSessionPromptBuilder` is a prompt-injection boundary and a second copy of one is
        // the shape where one gets hardened and the other does not.
        #expect(body["prompt"] as? String == "look at this")

        let image = try #require(body["image"] as? [String: Any])
        #expect(image["encoding"] as? String == "base64")
        #expect(image["media_type"] as? String == payload.imageMediaType?.rawValue)
        #expect(image["pixel_width"] as? Int == payload.imagePixelWidth)
        #expect(image["pixel_height"] as? Int == payload.imagePixelHeight)
        let data = try #require(image["data"] as? String)
        // The bytes really are the redacted ones, byte-for-byte — not a re-encode and not a
        // placeholder. This is the whole security claim of the route stated on the wire.
        #expect(Data(base64Encoded: data) == payload.redactedImageData)
    }

    @Test
    func theRequestNamesNoProviderNoModelAndNoVendorEndpoint() async throws {
        // SONNY-131's second requirement, asserted on the bytes rather than argued. This is the
        // property that turns SONNY-110's move to a paid zero-retention route into a redeploy: if
        // the client named the model or the vendor, changing either would need an app release — and
        // SONNY-110's requirement widened on 2026-08-16 to no retention *and* no training rights, so
        // it is a change that has to be makeable.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        let payload = try await Self.smallPayload()
        _ = try await Self.client(fixture)
            .decide(prompt: "look at this", payload: payload, session: Self.session)

        let sent = try recorded.only
        // The image is excluded before the scan: base64 of arbitrary pixels can contain any
        // substring, so a scan over it would flag a match no human put there. Everything the client
        // *chose* is what is under test.
        var body = sent.json
        var image = try #require(body["image"] as? [String: Any])
        image["data"] = ""
        body["image"] = image
        let text = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""

        for forbidden in [
            "opencode", "openai", "anthropic", "cerebras", "luna", "gpt-",
            "api.openai.com", "opencode.ai", "zen", "model",
        ] {
            #expect(
                !text.lowercased().contains(forbidden),
                "the request body names \(forbidden)"
            )
        }
        // And the transcript line the run records names the route rather than a model, which is the
        // one other place the old client's vendor name reached a human.
        #expect(Self.client(fixture).transcriptDescription == "screen.analyze")
    }

    @Test
    func aRunStartedWithDontSaveThisTaskSendsRetentionNone() async throws {
        // §10.1: `"none"` is what the app sends for a run started with "Don't save this task", and it
        // is the one thing that produces it. Asserted on the wire because the field is the whole of
        // the user's privacy answer once the request leaves the Mac.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        _ = try await Self.client(
            fixture,
            context: BackendTaskContext(taskID: "task-private", retention: .notStored)
        ).decide(prompt: "p", payload: try await Self.smallPayload(), session: Self.session)

        #expect(try recorded.only.json["retention"] as? String == "none")
        #expect(try recorded.only.json["task_id"] as? String == "task-private")
    }

    @Test
    func theRequestCarriesNoContentEncodingSetByThisClient() async throws {
        // **The client still does not compress, and that is now a two-sided fact** (SONNY-131,
        // correcting §6.4). The contract used to say this client's switch and its endpoint "flip in
        // one edit" when it was repointed at Sonny's gateway. They do not: the gateway implements no
        // request decompression, and Fastify hands a gzip-encoded body to the JSON parser as bytes,
        // which fails as a malformed body — a `400` on every screen-control request, from a change
        // that reads like a one-line optimisation. SONNY-317 does both sides together.
        //
        // `Accept-Encoding` is deliberately not set by hand either, and **this test cannot see
        // that and does not claim to**: URLSession adds it below `URLProtocol` and decompresses
        // transparently, so its absence from `headers` here is a fact about this layer rather than
        // about the wire. Setting it by hand would only *narrow* the advertisement, which is why
        // nothing does — recorded here rather than asserted, because an assertion would pass whether
        // or not the property held.
        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        _ = try await Self.client(fixture)
            .decide(prompt: "go", payload: try await Self.smallPayload(), session: Self.session)

        let sent = try recorded.only
        #expect(sent.headers["Content-Encoding"] == nil)
        #expect((try? JSONSerialization.jsonObject(with: sent.body)) != nil, "the body is readable JSON")
    }

    /// **The image on the wire declares what the bytes are, not what they used to be.**
    ///
    /// This was a hardcoded `"data:image/png;base64,…"` literal in the client. Now that the encoder
    /// picks per capture — and picks PNG on some real captures and JPEG on others — a literal would
    /// mislabel roughly half of them. Both branches are exercised here, from real encoder output
    /// rather than a hand-built payload, because the payload's initializer is deliberately
    /// unreachable from a test.
    @Test
    func theImageOnTheWireDeclaresThePayloadsOwnMediaTypeOnBothBranches() async throws {
        let service = LocalRedactionService(textRecognizer: SilentRecognizer())
        let cases: [(Data, VisionCaptureMediaType, String)] = [
            (ImageFixtures.whiteOverBlackPNG(width: 400, height: 300), .png, "image/png"),
            (ImageFixtures.uniformNoisePNG(width: 400, height: 300), .jpeg, "image/jpeg")
        ]

        for (png, expectedType, expectedWire) in cases {
            let payload = try await service.redactCapture(fixtureCapture(png: png, width: 400, height: 300))
            #expect(payload.imageMediaType == expectedType)

            let fixture = SignedInBackendFixture()
            let recorded = RecordedBackendRequests()
            fixture.register { request in
                recorded.append(request)
                return visionReply()
            }
            defer { fixture.unregister() }

            _ = try await Self.client(fixture).decide(prompt: "p", payload: payload, session: Self.session)

            let image = try #require(try recorded.only.json["image"] as? [String: Any])
            #expect(image["media_type"] as? String == expectedWire, "declared type for \(expectedType)")
        }
    }

    @Test
    func theDimensionsSentAreTheEncodedOnesRatherThanTheCaptures() async throws {
        // §4.5 rule 3, and the reason it is a rule: since SONNY-114 the egress ladder may resample to
        // fit the byte budget, so the picture the model is shown can be smaller than the capture.
        // The dimensions on the wire are the ones the model's coordinates live in — `SentImageSize`
        // — and metering prices the image from them. Sending the capture's instead would be a number
        // that is true of nothing that was sent.
        let png = ImageFixtures.uniformNoisePNG(width: 1_200, height: 900)
        let resampling = VisionCaptureEgressPolicy(
            maximumImageBytes: 60_000,
            ladder: VisionCaptureEgressPolicy.default.ladder
        )
        let payload = try await LocalRedactionService(textRecognizer: SilentRecognizer(), egressPolicy: resampling)
            .redactCapture(fixtureCapture(png: png, width: 1_200, height: 900))
        // The fixture must actually have been resampled or this test asserts nothing.
        #expect(payload.imagePixelWidth != 1_200, "the fixture must reach a resampling rung")

        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        _ = try await Self.client(fixture).decide(prompt: "p", payload: payload, session: Self.session)

        let image = try #require(try recorded.only.json["image"] as? [String: Any])
        #expect(image["pixel_width"] as? Int == payload.imagePixelWidth)
        #expect(image["pixel_height"] as? Int == payload.imagePixelHeight)
    }

    // MARK: - Usage

    @Test
    func aVisionCallRecordsTheUsageTheBackendReported() async throws {
        // **Vision usage had no record of any kind before this ticket.** `AIUsageCallKind` had three
        // cases and none was vision, and all five vision-path files contained zero usage-recording
        // calls — so the most expensive call the product makes was the one thing its own per-task
        // summary said nothing about, on the line SONNY-17 makes the only paid one.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            visionReply(usage: [
                "input_tokens": 1_900,
                "output_tokens": 40,
                "total_tokens": 1_940,
                "audio_duration_seconds": NSNull(),
                "source": "reported",
            ])
        }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        _ = try await Self.client(fixture, usageRecorder: recorder)
            .decide(prompt: "p", payload: try await Self.smallPayload(), session: Self.session)

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.records.first?.kind == .screenControl)
        // §4.2: `model` holds the route's name rather than a model identifier the client is no
        // longer allowed to know.
        #expect(summary.records.first?.model == "screen.analyze")
        #expect(summary.records.first?.tokenSource == .reported)
        #expect(summary.reportedTotalTokens == 1_940)
        #expect(summary.estimatedTotalTokens == 0)
    }

    @Test
    func aVisionCallWithNoUsageBlockIsStillCounted() async throws {
        // §4.5's own response shape rather than an omission: `server/src/model/vision.ts` sends no
        // `usage` at all when the provider reported none, because the only estimate this gateway
        // could make is from the text — and on this route the text is the small part of a request
        // whose dominant term is an image. So the *count* of screen-control calls is always right,
        // and a token figure appears only where a provider measured one.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in visionReply() }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        _ = try await Self.client(fixture, usageRecorder: recorder)
            .decide(prompt: "p", payload: try await Self.smallPayload(), session: Self.session)

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.records.first?.kind == .screenControl)
        #expect(summary.records.first?.tokenSource == nil)
        #expect(summary.reportedTotalTokens == 0)
        #expect(summary.estimatedTotalTokens == 0)
        // The distinction that makes this worth asserting: a call with no numbers is not the same as
        // no call, and the summary must not claim tokens nobody measured.
        #expect(summary.hasEstimatedTokens == false)
    }

    @Test
    func aFailedIterationIsStillCountedBecauseItStillCostWhatItCost() async throws {
        // The ordering the four text clients use, for the reason `OpenAIPlanner` records: a reply the
        // parser then rejects still cost what it cost, and a summary that silently omitted exactly
        // the failed iterations would understate the sessions a user is most likely to ask about.
        // Here the reply is well-formed at the transport layer and nonsense to `VisionDecisionParser`
        // — which runs in the runner, one layer out, so this client returns it and records the call.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in visionReply("not a decision at all") }
        defer { fixture.unregister() }

        let recorder = TaskUsageRecorder()
        let reply = try await Self.client(fixture, usageRecorder: recorder)
            .decide(prompt: "p", payload: try await Self.smallPayload(), session: Self.session)

        #expect(reply == "not a decision at all")
        #expect(recorder.snapshot().requestCount == 1)
    }

    // MARK: - Failures

    @Test
    func aBackendFailureSurfacesTheAppsOwnSentenceAndNoneOfTheServers() async throws {
        // §7.1: the client never displays the server's `message`; it maps `code` to its own copy.
        // That is not style — a sentence authored on the server and rendered in the app is a hole
        // through Sonny's standing "the product does not explain itself" rule, editable by whoever
        // edits the server with no review by anyone who knows it.
        let fixture = SignedInBackendFixture()
        fixture.register { _ in
            .reply(
                statusCode: 502,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: [
                    "error": [
                        "code": "provider.rejected",
                        "message": "Server-authored sentence the client must never display.",
                        "retryable": false,
                        "retry_after_seconds": NSNull(),
                        "request_id": "req_err_1",
                    ],
                ])
            )
        }
        defer { fixture.unregister() }

        let payload = try await Self.smallPayload()
        var thrown: (any Error)?
        do {
            _ = try await Self.client(fixture).decide(prompt: "p", payload: payload, session: Self.session)
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? VisionModelClientError)
        guard case .backend(let backend) = error else {
            Issue.record("expected a backend failure, got \(error)")
            return
        }
        guard case .api(let api) = backend else {
            Issue.record("expected the server's own envelope, got \(backend)")
            return
        }
        #expect(api.code == .providerRejected)
        // §9.3: not retryable, so the sentence must not invite one.
        #expect(api.isRetryable == false)
        let sentence = try #require(error.errorDescription)
        #expect(sentence == "Sonny couldn't do this one.")
        #expect(!sentence.contains("Server-authored"))
        #expect(!sentence.contains("502"))
        #expect(!sentence.lowercased().contains("provider"))
    }

    @Test
    func aSessionWithNoSignInFailsAtTheRequestRatherThanAtConstruction() async throws {
        // The consequence of the credential moving, stated as behaviour. There is no key to be
        // missing now, so the client always constructs — and a user with no session gets a sentence
        // they can act on at the moment they act, rather than a capability that silently is not
        // there. The same collapse SONNY-130 made for search, on the route where "silently not
        // there" would have been a screen-control feature that never appeared.
        let client = SonnyVisionModelClient(
            client: makeHermeticBackendClient(),
            taskContext: BackendTaskContext(taskID: "t", retention: .standard)
        )

        var thrown: (any Error)?
        do {
            _ = try await client.decide(
                prompt: "p",
                payload: try await Self.smallPayload(),
                session: Self.session
            )
        } catch {
            thrown = error
        }

        let error = try #require(thrown as? VisionModelClientError)
        // `makeHermeticBackendClient` has no environment, so the request fails before a URL is built
        // — which is the "this build has no Sonny account service" shape rather than "not signed in".
        // Either way it is a typed backend failure carrying the app's own sentence, which is the
        // property under test.
        guard case .backend = error else {
            Issue.record("expected a backend failure, got \(error)")
            return
        }
        #expect(error.errorDescription?.isEmpty == false)
    }

    // MARK: - The ceiling

    /// **A payload over the ceiling is refused before anything leaves.**
    ///
    /// The refusal is deliberate and predates SONNY-114: a clear failure beats a truncated upload
    /// with an obscure error. This pins both halves — the error carries the re-derived limit, and no
    /// request was made.
    ///
    /// The over-size payload is built by handing the redaction service a *permissive* egress policy,
    /// which is the only honest way to make one: under the shipping policy the encoder's whole job is
    /// to make sure this cannot happen.
    @Test
    func aPayloadOverTheCeilingIsRefusedWithNothingSent() async throws {
        let png = ImageFixtures.uniformNoisePNG(width: 1_600, height: 1_600)
        let permissive = VisionCaptureEgressPolicy(
            maximumImageBytes: .max,
            ladder: [VisionCaptureEgressPolicy.Rung(scale: 1.0, jpegQuality: 1.0)]
        )
        let payload = try await LocalRedactionService(textRecognizer: SilentRecognizer(), egressPolicy: permissive)
            .redactCapture(fixtureCapture(png: png, width: 1_600, height: 1_600))
        let bytes = try #require(payload.redactedImageData).count
        #expect(
            bytes > SonnyVisionModelClient.maximumImageBytes,
            "the fixture must exceed the ceiling or this test asserts nothing (got \(bytes))"
        )

        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        await #expect(throws: VisionModelClientError.payloadTooLarge(
            bytes: bytes,
            limit: SonnyVisionModelClient.maximumImageBytes
        )) {
            _ = try await Self.client(fixture).decide(prompt: "p", payload: payload, session: Self.session)
        }
        #expect(recorded.all.isEmpty)
    }

    @Test
    func theRefusalNamesTheRealProblemInTheAppsOwnWords() async throws {
        // The acceptance criterion in one assertion: "an oversize payload is refused with a human
        // message naming the real problem". Not a status, not a byte count with no subject, and not
        // an invitation to retry something that will fail identically.
        let error = VisionModelClientError.payloadTooLarge(
            bytes: 5_000_000,
            limit: SonnyVisionModelClient.maximumImageBytes
        )
        let sentence = try #require(error.errorDescription)
        #expect(sentence == "The window screenshot is 5000000 bytes, over the 3000000-byte limit for one request.")
        #expect(sentence.contains("screenshot"), "the sentence must name what was too big")
    }

    /// **The encoder's guarantee meets the client's ceiling**, which is the property that makes the
    /// refusal above unreachable in practice rather than a failure mode users meet.
    ///
    /// The fixture is uniform noise at 2560x1440 — the encoder's own worst case at a 27-inch 5K
    /// display's point resolution, and content no real screen produces. Measured at `9cfa090`, the
    /// same input through the PNG-only path is 12,110,641 bytes, which is over the *old* ceiling
    /// of 9,000,000: the iteration would have failed outright.
    @Test
    func theShippingPolicyKeepsEvenItsWorstCaseUnderTheCeiling() async throws {
        let png = ImageFixtures.uniformNoisePNG(width: 2_560, height: 1_440)
        #expect(png.count > 9_000_000, "the fixture must be one the old ceiling refused")

        let payload = try await LocalRedactionService(textRecognizer: SilentRecognizer())
            .redactCapture(fixtureCapture(png: png, width: 2_560, height: 1_440))
        let bytes = try #require(payload.redactedImageData).count
        // Printed rather than asserted at a literal, following `redactionLatencyIsBoundedOnA
        // RepresentativeCapture`'s precedent: the ceiling is the contract, the exact figure is a
        // measurement that belongs in the record with the SHA it was taken at. The doc comment on
        // `maximumImageBytes` quotes this line.
        print("EGRESS-WORST-CASE-BYTES: \(bytes) at \(payload.imagePixelWidth ?? 0)x\(payload.imagePixelHeight ?? 0), "
            + "\(payload.imageMediaType?.rawValue ?? "?") (seeded uniform noise, 2560x1440 source)")
        #expect(bytes <= SonnyVisionModelClient.maximumImageBytes)

        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        _ = try await Self.client(fixture).decide(prompt: "p", payload: payload, session: Self.session)
        #expect(recorded.all.count == 1)
    }

    /// **The request body a payload at the ceiling produces, which is the number row 12's host choice
    /// is sized against.**
    ///
    /// The ceiling is on the image alone; base64 inflates it by 4/3 and the JSON envelope and prompt
    /// sit on top. Rather than allocating a payload at the ceiling to weigh it, this measures the
    /// fixed overhead from a real request and extrapolates — the image half of the body is exactly
    /// `ceil(n / 3) * 4` characters, so the extrapolation is arithmetic rather than an estimate.
    ///
    /// 4,200,000 is not a magic number: it is the smallest round ceiling that leaves the whole
    /// request under the tightest serverless body limit on row 12's shortlist. Before SONNY-114 the
    /// same calculation gave about 12 MB, which cleared none of them. **It is also now the server's
    /// own limit, derived from this same ceiling** — see the test below.
    @Test
    func aRequestAtTheCeilingStaysInsideTheHostBodyBudget() async throws {
        let png = ImageFixtures.whiteOverBlackPNG(width: 640, height: 480)
        let payload = try await LocalRedactionService(textRecognizer: SilentRecognizer())
            .redactCapture(fixtureCapture(png: png, width: 640, height: 480))
        let imageBytes = try #require(payload.redactedImageData).count

        let fixture = SignedInBackendFixture()
        let recorded = RecordedBackendRequests()
        fixture.register { request in
            recorded.append(request)
            return visionReply()
        }
        defer { fixture.unregister() }

        let prompt = VisionSessionPromptBuilder.decisionPrompt(
            goal: "Reply to the newest message and send it",
            appDisplayName: "Mail",
            redactedObserved: LocalRedactionService(textRecognizer: SilentRecognizer()).redactText(
                VisionSessionPromptBuilder.observedBlock(
                    windowTitle: "Inbox",
                    history: (1...6).map { "iteration \($0): clicked \u{201C}Compose\u{201D}" }
                )
            ),
            imageWidth: payload.imagePixelWidth ?? 0,
            imageHeight: payload.imagePixelHeight ?? 0,
            delimiters: fixedTagBoundary
        )
        _ = try await Self.client(fixture).decide(prompt: prompt, payload: payload, session: Self.session)

        func base64Length(_ count: Int) -> Int { ((count + 2) / 3) * 4 }
        let body = try recorded.only.body
        let overhead = body.count - base64Length(imageBytes)
        let worstCase = base64Length(SonnyVisionModelClient.maximumImageBytes) + overhead

        #expect(overhead > 0, "the body must carry more than the image")
        #expect(worstCase <= 4_200_000, "a request at the ceiling would be \(worstCase) bytes")
    }

    @Test
    func theCeilingIsTheSameNumberOnBothSidesOfTheNetwork() {
        // §6.1: "This number and SONNY-114's are one number. If `maximumImageBytes` ever moves, this
        // limit is re-derived in the same change." The server holds `MAXIMUM_IMAGE_BYTES = 3_000_000`
        // in `server/src/model/limits.ts` and *derives* §6.1's 4,200,000 body limit from it;
        // `test/screen.test.ts` asserts that derivation. This is the Swift half of the same pin —
        // written as a literal for the reason `ModelRouteNumbersTests` gives for §12's table: neither
        // side can see the other's code, so each writes the number down and asserts its own half.
        #expect(SonnyVisionModelClient.maximumImageBytes == 3_000_000)
        #expect(VisionCaptureEgressPolicy.default.maximumImageBytes == 3_000_000)
        // Derived here the same way the server derives it, so the relation is what is pinned rather
        // than two constants that happen to agree today.
        let base64AtTheCeiling = ((SonnyVisionModelClient.maximumImageBytes + 2) / 3) * 4
        #expect(base64AtTheCeiling == 4_000_000)
        #expect(base64AtTheCeiling + 200_000 == 4_200_000)
    }

    // MARK: - SONNY-146's encoder, kept for SONNY-317

    /// **`NSData.compressed(using: .zlib)` is raw DEFLATE, not gzip**, and a body labelled `gzip`
    /// that is raw DEFLATE fails to inflate at the far end — which is a request that dies for a
    /// reason nothing in the error mentions. This pins the container.
    ///
    /// Three separate things, because a stream can be wrong in three separate ways: the header bytes
    /// identify it as gzip/DEFLATE, the payload really does inflate back to the original, and the
    /// trailer carries the CRC and length an inflater checks *after* decompressing — a stream that
    /// inflates to the right bytes and then fails its own integrity check is the quiet version of
    /// this bug.
    @Test
    func aCompressedBodyIsARealGzipStreamAndNotRawDeflate() throws {
        let original = Data(String(repeating: "Sonny vision payload ", count: 4_000).utf8)

        let gzipped = try HTTPBodyCompression.gzipped(original)

        #expect(Array(gzipped.prefix(3)) == [0x1f, 0x8b, 0x08], "gzip magic and DEFLATE method")
        let deflated = gzipped.dropFirst(10).dropLast(8)
        let inflated = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        #expect(inflated == original)
        let trailer = Array(gzipped.suffix(8))
        let checksum = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        #expect(checksum == HTTPBodyCompression.crc32(original))
        #expect(size == UInt32(original.count))
    }

    /// The CRC-32 table and polynomial, against the published vector. A transcription slip here
    /// produces a stream that decompresses correctly and is then rejected by the receiver, so it
    /// cannot be caught by a round-trip alone.
    @Test
    func theChecksumMatchesThePublishedCRC32Vector() {
        #expect(HTTPBodyCompression.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }
}
