import CoreGraphics
import Foundation
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

/// SONNY-114: what actually goes on the wire, and the ceiling that refuses it.
///
/// **This file exists because none of it had a test.** `maximumImageBytes` and `payloadTooLarge`
/// were production code with zero coverage before this ticket re-derived the number they carry, and
/// the media type in the `data:` URL was a hardcoded `image/png` literal that no assertion looked at.
@Suite(.serialized)
struct VisionModelClientTests {
    private static func client(session: URLSession, compressesRequestBody: Bool = false) throws -> OpenCodeVisionModelClient {
        try OpenCodeVisionModelClient(
            environment: ["OPENCODE_API_KEY": "test-key"],
            endpoint: URL(string: "https://example.invalid/v1/responses")!,
            compressesRequestBody: compressesRequestBody,
            session: session
        )
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VisionFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let replyJSON = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"action\":\"done\",\"rationale\":\"ok\"}"}]}]}"#

    private static func respondAndCapture() {
        VisionFixtureURLProtocol.requestCount = 0
        VisionFixtureURLProtocol.capturedBody = nil
        VisionFixtureURLProtocol.capturedHeaders = nil
        VisionFixtureURLProtocol.handler = { request in
            VisionFixtureURLProtocol.requestCount += 1
            VisionFixtureURLProtocol.capturedBody = try request.bodyData()
            VisionFixtureURLProtocol.capturedHeaders = request.allHTTPHeaderFields
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(replyJSON.utf8))
        }
    }

    /// **The `data:` URL declares what the bytes are, not what they used to be.**
    ///
    /// This was `"data:image/png;base64,…"` as a literal. Now that the encoder picks per capture —
    /// and picks PNG on some real captures and JPEG on others — a literal would mislabel roughly half
    /// of them. Both branches are exercised here, from real encoder output rather than a hand-built
    /// payload, because the payload's initializer is deliberately unreachable from a test.
    @Test
    func theDataURLDeclaresThePayloadsOwnMediaTypeOnBothBranches() async throws {
        let service = LocalRedactionService(textRecognizer: SilentRecognizer())
        let cases: [(Data, VisionCaptureMediaType, String)] = [
            (ImageFixtures.whiteOverBlackPNG(width: 400, height: 300), .png, "data:image/png;base64,"),
            (ImageFixtures.uniformNoisePNG(width: 400, height: 300), .jpeg, "data:image/jpeg;base64,")
        ]

        for (png, expectedType, expectedPrefix) in cases {
            let payload = try await service.redactCapture(fixtureCapture(png: png, width: 400, height: 300))
            #expect(payload.imageMediaType == expectedType)

            Self.respondAndCapture()
            _ = try await Self.client(session: Self.fixtureSession()).decide(prompt: "p", payload: payload)

            let body = try #require(VisionFixtureURLProtocol.capturedBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let input = try #require(json["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            let imageURL = try #require(content.last?["image_url"] as? String)
            #expect(imageURL.hasPrefix(expectedPrefix), "declared type for \(expectedType)")
        }
    }

    /// **A payload over the ceiling is refused before anything leaves.**
    ///
    /// The refusal is deliberate and predates this ticket: a clear failure beats a truncated upload
    /// with an obscure error. What changed is the number, so this pins both halves — the error
    /// carries the re-derived limit, and no request was made.
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
            bytes > OpenCodeVisionModelClient.maximumImageBytes,
            "the fixture must exceed the ceiling or this test asserts nothing (got \(bytes))"
        )

        Self.respondAndCapture()
        await #expect(throws: VisionModelClientError.payloadTooLarge(
            bytes: bytes,
            limit: OpenCodeVisionModelClient.maximumImageBytes
        )) {
            _ = try await Self.client(session: Self.fixtureSession()).decide(prompt: "p", payload: payload)
        }
        #expect(VisionFixtureURLProtocol.requestCount == 0)
    }

    /// **The encoder's guarantee meets the client's ceiling**, which is the property that makes the
    /// refusal above unreachable in practice rather than a failure mode users meet.
    ///
    /// The fixture is uniform noise at 2560x1440 — the encoder's own worst case at a 27-inch 5K
    /// display's point resolution, and content no real screen produces. Measured at `9a84e3b`, the
    /// same input through today's PNG-only path is 12,110,641 bytes, which is over the *old* ceiling
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
        #expect(bytes <= OpenCodeVisionModelClient.maximumImageBytes)

        Self.respondAndCapture()
        _ = try await Self.client(session: Self.fixtureSession()).decide(prompt: "p", payload: payload)
        #expect(VisionFixtureURLProtocol.requestCount == 1)
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
    /// request under the tightest serverless body limit on row 12's shortlist. Before this ticket the
    /// same calculation gave about 12 MB, which cleared none of them.
    @Test
    func aRequestAtTheCeilingStaysInsideTheHostBodyBudget() async throws {
        let png = ImageFixtures.whiteOverBlackPNG(width: 640, height: 480)
        let payload = try await LocalRedactionService(textRecognizer: SilentRecognizer())
            .redactCapture(fixtureCapture(png: png, width: 640, height: 480))
        let imageBytes = try #require(payload.redactedImageData).count

        Self.respondAndCapture()
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
            imageHeight: payload.imagePixelHeight ?? 0
        )
        _ = try await Self.client(session: Self.fixtureSession()).decide(prompt: prompt, payload: payload)

        func base64Length(_ count: Int) -> Int { ((count + 2) / 3) * 4 }
        let body = try #require(VisionFixtureURLProtocol.capturedBody)
        let overhead = body.count - base64Length(imageBytes)
        let worstCase = base64Length(OpenCodeVisionModelClient.maximumImageBytes) + overhead

        #expect(overhead > 0, "the body must carry more than the image")
        #expect(worstCase <= 4_200_000, "a request at the ceiling would be \(worstCase) bytes")
    }

    // MARK: - SONNY-146: the request body on the wire

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

    /// **The default endpoint sends an uncompressed body and no `Content-Encoding`.** OpenCode's
    /// Zen route does **not** inflate a gzip body: it answers HTTP 500, where the same body sent
    /// uncompressed answers 200. Measured 2026-08-17 at `34ebd59`, where `VisionModelClient.swift`
    /// and `HTTPBodyCompression.swift` were byte-identical to `main` at `6af4044`; full evidence is
    /// in SONNY-146's comment of that date. So `false` is the measured-correct value for this
    /// endpoint rather than caution against an unknown, and what this test pins is a value the route
    /// requires. SONNY-131 turns it on in the same edit that repoints this client at Sonny's own
    /// gateway, which the API contract already obliges to accept gzip.
    ///
    /// (SONNY-164 corrected this paragraph on 2026-08-20; it read "unverified" until then. The claim
    /// lived in **three** places and that ticket named two — the `compressesRequestBody` doc comment
    /// and SONNY-146's closing comment — so this one survived the first pass and was caught by
    /// PR #77's review. A stale claim has a population; fixing the instances a ticket lists is not
    /// the same as fixing the claim.)
    @Test
    func theDefaultEndpointSendsAnUncompressedBodyWithNoContentEncoding() async throws {
        Self.respondAndCapture()

        // Constructed without naming `compressesRequestBody`, so what is pinned is the *production*
        // default and not this suite's helper default. The first version of this test went through
        // the helper, which passes the flag explicitly — flipping the real default to `true` left it
        // green, which a mutation caught.
        let client = try OpenCodeVisionModelClient(
            environment: ["OPENCODE_API_KEY": "test-key"],
            endpoint: URL(string: "https://example.invalid/v1/responses")!,
            session: Self.fixtureSession()
        )
        _ = try await client.decide(prompt: "go", payload: try await Self.smallPayload())

        #expect(client.compressesRequestBody == false)
        let headers = try #require(VisionFixtureURLProtocol.capturedHeaders)
        #expect(headers["Content-Encoding"] == nil)
        let body = try #require(VisionFixtureURLProtocol.capturedBody)
        #expect((try? JSONSerialization.jsonObject(with: body)) != nil, "an uncompressed body is still readable JSON")
    }

    /// And with it on, the wire body is a gzip stream that inflates back to the same JSON the
    /// uncompressed path sends — so compression changes the encoding and nothing else.
    ///
    /// Compared as parsed objects rather than as bytes, deliberately. `JSONSerialization` gives no
    /// ordering guarantee for a `[String: Any]`, so two serialisations of the same dictionary can
    /// differ byte-for-byte at identical length — which is exactly what the first version of this
    /// test hit, and it would have been a flaky assertion rather than a wrong one.
    @Test
    func aCompressedRequestInflatesToTheSameJSONTheUncompressedPathSends() async throws {
        let payload = try await Self.smallPayload()

        Self.respondAndCapture()
        _ = try await Self.client(session: Self.fixtureSession()).decide(prompt: "go", payload: payload)
        let plain = try #require(VisionFixtureURLProtocol.capturedBody)

        Self.respondAndCapture()
        _ = try await Self.client(session: Self.fixtureSession(), compressesRequestBody: true)
            .decide(prompt: "go", payload: payload)
        let compressed = try #require(VisionFixtureURLProtocol.capturedBody)
        let headers = try #require(VisionFixtureURLProtocol.capturedHeaders)

        #expect(headers["Content-Encoding"] == "gzip")
        #expect(Array(compressed.prefix(3)) == [0x1f, 0x8b, 0x08])
        let inflated = try (Data(compressed.dropFirst(10).dropLast(8)) as NSData).decompressed(using: .zlib) as Data
        let inflatedJSON = try #require(try JSONSerialization.jsonObject(with: inflated) as? [String: Any])
        let plainJSON = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(NSDictionary(dictionary: inflatedJSON).isEqual(to: plainJSON))
    }

    /// **The ceiling is about the decoded body, so compression does not move it** — the question
    /// SONNY-146 had to answer without quietly changing an answer that other work depends on.
    ///
    /// `maximumImageBytes` bounds the *image*, before the body is built and before any compression,
    /// and it exists for legibility and for a clear refusal rather than for wire size. The contract's
    /// 4,200,000-byte server limit is measured on the *decoded* body by deliberate choice, so a
    /// client that compresses cannot smuggle a larger payload past it. Neither number moves.
    ///
    /// What compression does change is the figure SONNY-125 will measure against Supabase, which
    /// publishes no request-body ceiling at all. This prints the ratio on every run rather than
    /// freezing it into prose, following `theShippingPolicyKeepsEvenItsWorstCaseUnderTheCeiling`'s
    /// precedent — the encoder's output moves when its ladder or budget moves, and a number in a
    /// comment would not.
    @Test
    func compressionShrinksTheWireBodyWithoutMovingTheCeiling() async throws {
        let png = ImageFixtures.uniformNoisePNG(width: 1_728, height: 1_117)
        let payload = try await LocalRedactionService(textRecognizer: SilentRecognizer())
            .redactCapture(fixtureCapture(png: png, width: 1_728, height: 1_117))

        Self.respondAndCapture()
        _ = try await Self.client(session: Self.fixtureSession()).decide(prompt: "go", payload: payload)
        let plain = try #require(VisionFixtureURLProtocol.capturedBody)

        Self.respondAndCapture()
        _ = try await Self.client(session: Self.fixtureSession(), compressesRequestBody: true)
            .decide(prompt: "go", payload: payload)
        let wire = try #require(VisionFixtureURLProtocol.capturedBody)

        let ratio = Double(wire.count) / Double(plain.count)
        print("EGRESS-COMPRESSION-RATIO: \(wire.count)/\(plain.count) = \(String(format: "%.3f", ratio)) on a \(payload.imagePixelWidth ?? 0)x\(payload.imagePixelHeight ?? 0) \(payload.imageMediaType?.rawValue ?? "?") capture")

        #expect(wire.count < plain.count, "compression must shrink the wire body")
        // The image ceiling is unchanged and is checked before the body exists, so it cannot be a
        // function of what compression achieves.
        #expect(OpenCodeVisionModelClient.maximumImageBytes == 3_000_000)
    }

    private static func smallPayload() async throws -> RedactedPayload {
        let png = ImageFixtures.whiteOverBlackPNG(width: 64, height: 48)
        return try await LocalRedactionService(textRecognizer: SilentRecognizer())
            .redactCapture(fixtureCapture(png: png, width: 64, height: 48))
    }
}

// MARK: - Fixture transport

private final class VisionFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedHeaders: [String: String]?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: VisionModelClientError.payloadCarriedNoImage)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else {
            Issue.record("Expected a JSON body.")
            throw VisionModelClientError.payloadCarriedNoImage
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}
