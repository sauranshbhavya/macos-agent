import Foundation

/// The vision model, as a seam.
///
/// **The parameter type is the security property.** `payload` is a ``RedactedPayload``, whose
/// initializer is `fileprivate` to `LocalRedactionService.swift` — so the only way any conformer of
/// this protocol can be handed something to send is for `LocalRedactionService` to have produced it,
/// and there is no overload taking raw bytes to reach for instead. An unredacted screenshot leaving
/// this device does not fail a review; it fails to compile. (SONNY-89's structural non-bypass,
/// consumed exactly as it was designed to be.)
public protocol VisionModelDeciding: Sendable {
    /// A short description of the model and route, for the run transcript.
    var transcriptDescription: String { get }

    func decide(prompt: String, payload: RedactedPayload) async throws -> String
}

public enum VisionModelClientError: Error, Equatable, LocalizedError {
    case missingAPIKey(String)
    case payloadCarriedNoImage
    case payloadTooLarge(bytes: Int, limit: Int)
    case badResponse(status: Int, body: String)
    case unreadableReply(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name):
            return "Sonny needs \(name) set to use screen control."
        case .payloadCarriedNoImage:
            return "The redacted capture carried no image to send."
        case .payloadTooLarge(let bytes, let limit):
            return "The window screenshot is \(bytes) bytes, over the \(limit)-byte limit for one request."
        case .badResponse(let status, _):
            return "The vision model returned HTTP \(status)."
        case .unreadableReply:
            return "Sonny could not read the vision model's reply."
        }
    }
}

/// The production vision model: gpt-5.6-luna, reached through OpenCode's Zen route.
///
/// **Founder decisions of 2026-08-14, recorded here because this file is where they bite.** The
/// model is the founders' call with no benchmark gate — the three-arm comparison that would have
/// chosen it was cancelled rather than deferred, and row I's own attended runs double as the working
/// check. The route terminates at OpenAI and carries **30-day retention**, which the founders accept
/// *for development*. Before v1 release the product moves to a paid zero-retention route; that is a
/// named release-checklist item in the changelog's roadmap notes, not a footnote, and production
/// routing is deliberately out of this branch's scope. Nothing here should be read as the shipping
/// configuration.
///
/// The wire shape is inherited from the experiment branch (`experiment/cua-drivers` at `cd27a7c`)
/// because it is the shape that was actually exercised against the live route; the surrounding
/// design — redaction, containment, the engine gate — is built fresh, which is what E13 asked for.
public struct OpenCodeVisionModelClient: VisionModelDeciding {
    /// The request-size ceiling, on the image alone.
    ///
    /// **Re-derived by SONNY-114, not inherited.** The old 9,000,000 came from the experiment branch
    /// as the observed practical limit for one request on this route, and it was a number sized for
    /// an uncompressed full-resolution PNG: base64 turns an image at that ceiling into a request body
    /// of about 12 MB, which was ruling out every serverless host with a body limit before anyone had
    /// asked whether the payload needed to be that big. It did not.
    ///
    /// This is now the same budget the egress ladder encodes down to
    /// (``VisionCaptureEgressPolicy/default``), so the two cannot drift: the encoder aims at exactly
    /// the number this refuses above. A payload at the ceiling produces a request body of
    /// `ceil(3_000_000 / 3) * 4` = 4,000,000 bytes of base64 plus the prompt (4,673 characters on a
    /// six-entry history) and about 120 bytes of JSON envelope — call it 4.01 MB, measured.
    ///
    /// The refusal itself is unchanged and still deliberate: a capture that exceeds this fails the
    /// whole iteration with a clear message rather than becoming a truncated upload with an obscure
    /// one. What changed is what has to happen first. The ladder returns the **first** rung whose
    /// encoding fits, so most captures never leave the top one; reaching this refusal means every
    /// rung was tried and every one came back over budget, and the encoder then hands back the
    /// smallest it managed rather than throwing, precisely so the message a user sees is this one.
    ///
    /// **How much headroom that leaves, measured rather than estimated.** The seeded uniform-noise
    /// fixture at a 27-inch 5K display's point resolution — the encoder's worst case among the
    /// reproducible ones, since noise is the content no encoder can compress — encodes to
    /// **2,781,667 bytes at its full 2560x1440, without the ladder resampling at all**, at
    /// `6201e45`. `theShippingPolicyKeepsEvenItsWorstCaseUnderTheCeiling` prints that figure on
    /// every run, so it is regenerable rather than a number frozen into a comment.
    ///
    /// Larger point resolutions than 5K do reach the resampling rungs on noise, and no figure is
    /// quoted for them here: the ones SONNY-114 measured came from a one-off random image nobody can
    /// reproduce, and an unreproducible number in a comment is worth less than the absence of one.
    /// What holds regardless is the shape — this is a backstop rather than a path users meet, since
    /// no real screen produces incompressible content and every real capture measured for SONNY-114
    /// fitted the top rung with room to spare.
    public static let maximumImageBytes = VisionCaptureEgressPolicy.default.maximumImageBytes

    public static let defaultEndpoint = URL(string: "https://opencode.ai/zen/go/v1/responses")!
    public static let defaultModel = "gpt-5.6-luna"
    public static let apiKeyEnvironmentVariable = "OPENCODE_API_KEY"

    private let model: String
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public var transcriptDescription: String { "opencode/\(model)" }

    /// Whether the request body is gzip-encoded on the wire (SONNY-146).
    ///
    /// **A property of the far end, not a preference**, which is why it travels with `endpoint`
    /// rather than being a standalone switch. A body sent under `Content-Encoding: gzip` to a route
    /// that does not accept it fails the whole request, so this may only be turned on for an endpoint
    /// known to inflate it.
    ///
    /// **Off for the default endpoint, and that is not caution for its own sake.** Whether OpenCode's
    /// Zen route accepts a gzip-encoded request body is unverified: confirming it needs a live call
    /// with a real key, which this ticket had no way to make, and it is exactly what SONNY-146's
    /// first requirement asked for. Turning it on unverified would risk every screen-control session
    /// for a saving measured at 30%.
    ///
    /// **SONNY-131 is the consumer that turns it on.** That ticket repoints this client at Sonny's
    /// own gateway, and `docs/sonny-backend-api-contract.md` §6.4 already obliges that server to
    /// accept `Content-Encoding: gzip` and to apply its size limits to the *decoded* body. So the
    /// change there is this flag and the endpoint together, in one edit, at the one construction
    /// site.
    public let compressesRequestBody: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        endpoint: URL = OpenCodeVisionModelClient.defaultEndpoint,
        compressesRequestBody: Bool = false,
        session: URLSession = .shared
    ) throws {
        self.model = environment["SONNY_VISION_MODEL"] ?? Self.defaultModel
        self.endpoint = endpoint
        self.compressesRequestBody = compressesRequestBody
        self.session = session
        guard let key = environment[Self.apiKeyEnvironmentVariable],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisionModelClientError.missingAPIKey(Self.apiKeyEnvironmentVariable)
        }
        self.apiKey = key
    }

    public func decide(prompt: String, payload: RedactedPayload) async throws -> String {
        guard let imageData = payload.redactedImageData, let mediaType = payload.imageMediaType else {
            throw VisionModelClientError.payloadCarriedNoImage
        }
        guard imageData.count <= Self.maximumImageBytes else {
            throw VisionModelClientError.payloadTooLarge(bytes: imageData.count, limit: Self.maximumImageBytes)
        }

        let body: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": prompt],
                        [
                            "type": "input_image",
                            // The media type comes off the payload rather than being a literal: since
                            // SONNY-114 the encoder picks PNG or JPEG per capture, and a hardcoded
                            // "image/png" would label roughly half of real captures as a format they
                            // are not.
                            "image_url": "data:\(mediaType.rawValue);base64,\(imageData.base64EncodedString())"
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `Accept-Encoding` is deliberately not set. URLSession already advertises `gzip, deflate` on
        // every request and handles the response transparently — measured against a local server,
        // which saw exactly that header when nothing here set one. Setting it by hand only *narrows*
        // the advertisement (the same probe saw `gzip` alone, and `identity`, when each was set), so
        // the instruction to "set Accept-Encoding while there" would have made the response half
        // worse rather than better. Recorded because it reads like an omission.
        let json = try JSONSerialization.data(withJSONObject: body)
        if compressesRequestBody {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = try HTTPBodyCompression.gzipped(json)
        } else {
            request.httpBody = json
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VisionModelClientError.badResponse(status: -1, body: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VisionModelClientError.badResponse(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<unreadable body>"
            )
        }

        do {
            // The same parser the text planner uses. Shared rather than re-implemented: both routes
            // return OpenAI's Responses shape, and two parsers for one wire format is two places for
            // a format change to be half-handled.
            return try OpenAIResponseParser.outputText(from: data)
        } catch {
            throw VisionModelClientError.unreadableReply(
                String(data: data, encoding: .utf8) ?? "<unreadable body>"
            )
        }
    }
}
