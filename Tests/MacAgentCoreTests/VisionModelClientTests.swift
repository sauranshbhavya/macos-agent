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
    private static func client(session: URLSession) throws -> OpenCodeVisionModelClient {
        try OpenCodeVisionModelClient(
            environment: ["OPENCODE_API_KEY": "test-key"],
            endpoint: URL(string: "https://example.invalid/v1/responses")!,
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
        VisionFixtureURLProtocol.handler = { request in
            VisionFixtureURLProtocol.requestCount += 1
            VisionFixtureURLProtocol.capturedBody = try request.bodyData()
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
}

// MARK: - Fixture transport

private final class VisionFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedBody: Data?
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
