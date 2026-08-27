import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Shared shapes for the four model-route suites (SONNY-130).
///
/// **The seam these suites drive is the same one they always drove, one layer out.** Before this
/// ticket each of the four clients took `session: URLSession = .shared` and each test file carried
/// its own private `URLProtocol` with a single shared static handler — which is why three of them
/// had to be `@Suite(.serialized)`, as `TavilySearchProviderTests`' own doc comment explained. The
/// injectable session is still there; it is now a parameter of `SonnyBackendClient`, which the four
/// clients take instead. `BackendStubURLProtocol` keys its handlers by host rather than by one
/// static, so these suites need no serialization and can run beside each other.
enum ModelRouteFixtures {
    /// §4.2's response to `/v1/plan` and `/v1/research/synthesize`.
    static func textRouteJSON(
        outputText: String,
        usage: [String: Any]? = nil,
        requestID: String = "req_plan_1"
    ) -> Data {
        var object: [String: Any] = ["request_id": requestID, "output_text": outputText]
        if let usage { object["usage"] = usage }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// §4.4's response to `/v1/transcriptions`.
    static func transcriptionJSON(
        text: String,
        usage: [String: Any]? = nil,
        requestID: String = "req_voice_1"
    ) -> Data {
        var object: [String: Any] = ["request_id": requestID, "text": text]
        if let usage { object["usage"] = usage }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// §4.3's response to `/v1/search`, which carries no `usage` block at all.
    static func searchJSON(results: [[String: Any]], requestID: String = "req_search_1") -> Data {
        try! JSONSerialization.data(withJSONObject: ["request_id": requestID, "results": results])
    }

    /// The usage block as the server sends it when the provider reported real numbers.
    static func reportedTokenUsage(input: Int, output: Int, total: Int) -> [String: Any] {
        [
            "input_tokens": input,
            "output_tokens": output,
            "total_tokens": total,
            "audio_duration_seconds": NSNull(),
            "source": "reported",
        ]
    }

    static func reportedDurationUsage(seconds: Double) -> [String: Any] {
        [
            "input_tokens": NSNull(),
            "output_tokens": NSNull(),
            "total_tokens": NSNull(),
            "audio_duration_seconds": seconds,
            "source": "reported",
        ]
    }

    static func estimatedTokenUsage(input: Int, output: Int, total: Int) -> [String: Any] {
        [
            "input_tokens": input,
            "output_tokens": output,
            "total_tokens": total,
            "audio_duration_seconds": NSNull(),
            "source": "estimated",
        ]
    }

    /// The task context these suites send unless a test is about the other retention value.
    static let standardContext = BackendTaskContext(taskID: "task-fixture-1", retention: .standard)

    static func reply(_ body: Data) -> BackendStubURLProtocol.Outcome {
        .reply(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    /// §7.1's error envelope, which is the only failure shape these routes can now produce.
    static func failure(
        status: Int,
        code: String,
        message: String = "Server-authored sentence the client must never display.",
        retryable: Bool = false
    ) -> BackendStubURLProtocol.Outcome {
        let body = try! JSONSerialization.data(withJSONObject: [
            "error": [
                "code": code,
                "message": message,
                "retryable": retryable,
                "retry_after_seconds": NSNull(),
                "request_id": "req_err_1",
            ],
        ])
        return .reply(statusCode: status, headers: ["Content-Type": "application/json"], body: body)
    }
}
