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
    /// The request-size ceiling. Inherited from the experiment, where it was the observed practical
    /// limit for one request on this route; kept because a capture that exceeds it fails the whole
    /// iteration with a clear message rather than a truncated upload with an obscure one.
    public static let maximumImageBytes = 9_000_000

    public static let defaultEndpoint = URL(string: "https://opencode.ai/zen/go/v1/responses")!
    public static let defaultModel = "gpt-5.6-luna"
    public static let apiKeyEnvironmentVariable = "OPENCODE_API_KEY"

    private let model: String
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public var transcriptDescription: String { "opencode/\(model)" }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        endpoint: URL = OpenCodeVisionModelClient.defaultEndpoint,
        session: URLSession = .shared
    ) throws {
        self.model = environment["SONNY_VISION_MODEL"] ?? Self.defaultModel
        self.endpoint = endpoint
        self.session = session
        guard let key = environment[Self.apiKeyEnvironmentVariable],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisionModelClientError.missingAPIKey(Self.apiKeyEnvironmentVariable)
        }
        self.apiKey = key
    }

    public func decide(prompt: String, payload: RedactedPayload) async throws -> String {
        guard let png = payload.redactedImagePNGData else {
            throw VisionModelClientError.payloadCarriedNoImage
        }
        guard png.count <= Self.maximumImageBytes else {
            throw VisionModelClientError.payloadTooLarge(bytes: png.count, limit: Self.maximumImageBytes)
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
                            "image_url": "data:image/png;base64,\(png.base64EncodedString())"
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
