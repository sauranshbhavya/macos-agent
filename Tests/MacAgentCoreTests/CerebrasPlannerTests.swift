import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-86, fixture-backed — no test here touches the network or needs a key. Covered: the
/// Chat Completions codec end-to-end into a valid `AgentPlan`, `decodeStrict` rejection
/// surfacing as a normal planner error (with usage still recorded — tokens were spent either
/// way), both output modes' request shapes, the three provider obligations (shared usage
/// recording, cancellation passing through as cancellation, own `LocalizedError` copy), and
/// the live-verified reason schema-in-prompt is the default mode.
@Suite(.serialized)
@MainActor
struct CerebrasPlannerTests {
    // MARK: - Decoding end-to-end

    @Test
    func validChatCompletionsResponseDecodesEndToEndAndRecordsReportedUsage() async throws {
        CerebrasFixtureURLProtocol.handler = { _ in
            try Self.chatResponse(
                content: Self.openAppPlanJSON,
                usage: ["prompt_tokens": 42, "completion_tokens": 18, "total_tokens": 60]
            )
        }
        let recorder = TaskUsageRecorder()
        let planner = try Self.makePlanner(usageRecorder: recorder)

        let plan = try await planner.plan(command: "Open Safari")

        #expect(plan.summary == "Open Safari.")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.operation == .openApp)
        #expect(plan.steps.first?.appName == "Safari")

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedInputTokens == 42)
        #expect(summary.reportedOutputTokens == 18)
        #expect(summary.reportedTotalTokens == 60)
        #expect(summary.records.first?.kind == .planner)
        #expect(summary.records.first?.model == "gpt-oss-120b")
        #expect(summary.records.first?.tokenSource == .reported)
    }

    @Test
    func absentUsageFallsBackToEstimatedCounts() async throws {
        CerebrasFixtureURLProtocol.handler = { _ in
            try Self.chatResponse(content: Self.openAppPlanJSON, usage: nil)
        }
        let recorder = TaskUsageRecorder()
        let planner = try Self.makePlanner(usageRecorder: recorder)

        _ = try await planner.plan(command: "Open Safari")

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedTotalTokens == 0)
        #expect(summary.estimatedInputTokens > 0)
        #expect(summary.estimatedOutputTokens > 0)
        #expect(summary.records.first?.tokenSource == .estimated)
    }

    @Test
    func fencedContentIsNormalizedBeforeDecoding() async throws {
        CerebrasFixtureURLProtocol.handler = { _ in
            try Self.chatResponse(content: "```json\n\(Self.openAppPlanJSON)\n```")
        }
        let planner = try Self.makePlanner()

        let plan = try await planner.plan(command: "Open Safari")

        #expect(plan.steps.first?.operation == .openApp)
    }

    // MARK: - decodeStrict rejection is a normal planner error (C10: nothing new around it)

    @Test
    func inventedOperationRejectsThroughDecodeStrictAndStillRecordsUsage() async throws {
        CerebrasFixtureURLProtocol.handler = { _ in
            try Self.chatResponse(
                content: #"{"summary":"Nope.","requiresConfirmation":false,"steps":[{"id":"x","operation":"launch_missiles","description":"Invented."}]}"#,
                usage: ["prompt_tokens": 42, "completion_tokens": 18, "total_tokens": 60]
            )
        }
        let recorder = TaskUsageRecorder()
        let planner = try Self.makePlanner(usageRecorder: recorder)

        await #expect(throws: AgentPlanDecodingError.self) {
            _ = try await planner.plan(command: "Open Safari")
        }
        // The response failed *after* the tokens were spent; the recorder still says so.
        #expect(recorder.snapshot().requestCount == 1)
        #expect(recorder.snapshot().reportedTotalTokens == 60)
    }

    @Test
    func unexpectedStepKeyRejectsWithTheExactDecodeStrictError() async throws {
        CerebrasFixtureURLProtocol.handler = { _ in
            try Self.chatResponse(
                content: #"{"summary":"Sneaky.","requiresConfirmation":false,"steps":[{"id":"x","operation":"open_app","description":"Open.","appName":"Safari","shellCommand":"rm -rf /"}]}"#
            )
        }
        let planner = try Self.makePlanner()

        await #expect(throws: AgentPlanDecodingError.unexpectedStepKey("shellCommand")) {
            _ = try await planner.plan(command: "Open Safari")
        }
    }

    // MARK: - Transport failures carry this planner's own LocalizedError

    @Test
    func missingChoicesSurfacesAsMissingMessageContent() async throws {
        CerebrasFixtureURLProtocol.handler = { _ in
            try Self.response(status: 200, bodyObject: ["id": "chatcmpl-1"])
        }
        let planner = try Self.makePlanner()

        await #expect(throws: CerebrasPlannerError.missingMessageContent) {
            _ = try await planner.plan(command: "Open Safari")
        }
        #expect(CerebrasPlannerError.missingMessageContent.errorDescription
            == "Cerebras response did not include message content.")
    }

    @Test
    func non2xxSurfacesAsBadResponseWithStatusAndBody() async throws {
        CerebrasFixtureURLProtocol.handler = { _ in
            try Self.response(status: 503, bodyObject: ["error": "over capacity"])
        }
        let planner = try Self.makePlanner()

        do {
            _ = try await planner.plan(command: "Open Safari")
            Issue.record("Expected badResponse to be thrown.")
        } catch let error as CerebrasPlannerError {
            guard case .badResponse(let status, let body) = error else {
                Issue.record("Expected badResponse, got \(error).")
                return
            }
            #expect(status == 503)
            #expect(body.contains("over capacity"))
            #expect(error.errorDescription?.contains("HTTP 503") == true)
        }
    }

    @Test
    func missingKeyThrowsAtConstructionWithItsOwnCopy() {
        #expect(throws: CerebrasPlannerError.missingAPIKey) {
            _ = try CerebrasPlanner(apiKey: "   ", usageRecorder: NoopTaskUsageRecorder.shared)
        }
        #expect(CerebrasPlannerError.missingAPIKey.errorDescription
            == "CEREBRAS_API_KEY is not set. Add it to the environment before launching the app.")
    }

    // MARK: - Cancellation obligation

    /// Provider obligation 2, pinned: cancelling the task mid-request must surface as
    /// `CancellationError`/`URLError(.cancelled)` — the same predicate the app's cancel UX
    /// applies — never as this planner's own error type, which would render a deliberate
    /// cancel as a red failure.
    @Test
    func cancellationSurfacesAsCancellationNotAsAPlannerFailure() async throws {
        let planner = try Self.makePlanner(session: Self.hangingSession())

        let task = Task { try await planner.plan(command: "Open Safari") }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled request to throw.")
        } catch {
            let isCancellation = error is CancellationError
                || (error as? URLError)?.code == .cancelled
            #expect(isCancellation, "Cancellation must not surface as \(error).")
            #expect(!(error is CerebrasPlannerError))
        }
    }

    // MARK: - Request shapes, both modes

    @Test
    func schemaInPromptModeExtendsTheSharedPromptAndSendsNoResponseFormat() async throws {
        CerebrasFixtureURLProtocol.handler = { request in
            CerebrasFixtureURLProtocol.capturedBody = try request.bodyData()
            return try Self.chatResponse(content: Self.openAppPlanJSON)
        }
        let planner = try Self.makePlanner()

        _ = try await planner.plan(command: "Open Safari")

        let body = try #require(CerebrasFixtureURLProtocol.capturedBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "gpt-oss-120b")
        #expect(object["reasoning_effort"] as? String == "medium")
        #expect(object["response_format"] == nil)

        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        let system = try #require(messages.first?["content"] as? String)
        #expect(system.hasPrefix(OpenAIPlanner.systemPrompt(toolRegistry: .default)))
        #expect(system.contains(CerebrasPlanner.schemaJSONText()))
        #expect(messages.last?["content"] as? String == "Open Safari")
    }

    @Test
    func nativeStructuredOptInSendsResponseFormatAndTheUnmodifiedSharedPrompt() async throws {
        CerebrasFixtureURLProtocol.handler = { request in
            CerebrasFixtureURLProtocol.capturedBody = try request.bodyData()
            return try Self.chatResponse(content: Self.openAppPlanJSON)
        }
        let planner = try Self.makePlanner(useNativeStructuredOutput: true)

        _ = try await planner.plan(command: "Open Safari")

        let body = try #require(CerebrasFixtureURLProtocol.capturedBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == OpenAIPlanner.systemPrompt(toolRegistry: .default))

        let format = try #require(object["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let jsonSchema = try #require(format["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "agent_plan")
        #expect(jsonSchema["strict"] as? Bool == true)
        #expect((jsonSchema["schema"] as? [String: Any])?.isEmpty == false)
    }

    @Test
    func priorTaskContextRidesAsItsOwnMessageBetweenSystemAndCommand() async throws {
        CerebrasFixtureURLProtocol.handler = { request in
            CerebrasFixtureURLProtocol.capturedBody = try request.bodyData()
            return try Self.chatResponse(content: Self.openAppPlanJSON)
        }
        let planner = try Self.makePlanner()
        let context = PriorTaskContext(
            command: "Find the 3 largest files in ~/Desktop/MacAgentDemo and zip them.",
            plan: AgentPlan(
                summary: "Zip largest files.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "scan",
                        operation: .scanSelectLargestFiles,
                        description: "Scan files.",
                        inputPath: "~/Desktop/MacAgentDemo",
                        count: 3
                    )
                ]
            ),
            outcome: PriorTaskOutcome(status: .completed, summary: "Created largest.zip."),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        _ = try await planner.plan(command: "use ~/Documents instead", priorTaskContext: context)

        let body = try #require(CerebrasFixtureURLProtocol.capturedBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect((messages[1]["content"] as? String)?.contains("TRUSTED_PRIOR_TASK_CONTEXT_BEGIN") == true)
        #expect(messages[2]["content"] as? String == "use ~/Documents instead")
    }

    // MARK: - Why schema-in-prompt is the default

    /// Re-verified live 2026-08-13 (inference-docs.cerebras.ai/capabilities/structured-outputs):
    /// Cerebras caps native structured-output schemas at 5,000 characters and strictly
    /// enforces its limits since 2026-07-21, so the shared plan schema is a validation error
    /// in native mode. This pin ties the default-mode decision to that measured fact — if the
    /// schema ever shrinks below the cap, this fails and the native default deserves
    /// re-evaluation rather than silent inheritance.
    @Test
    func sharedPlanSchemaStillExceedsTheNativeStructuredOutputCap() {
        #expect(CerebrasPlanner.schemaJSONText().count > 5_000)
    }

    // MARK: - Fixtures

    private static func makePlanner(
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared,
        session: URLSession? = nil,
        useNativeStructuredOutput: Bool = false
    ) throws -> CerebrasPlanner {
        try CerebrasPlanner(
            apiKey: "test-key",
            session: session ?? fixtureSession(),
            usageRecorder: usageRecorder,
            useNativeStructuredOutput: useNativeStructuredOutput
        )
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CerebrasFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A session whose requests never complete on their own, so the only way out is the
    /// cancellation under test; the short timeout turns a broken cancellation path into a
    /// fast, wrong-error failure instead of a hung suite.
    private static func hangingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    private static func chatResponse(
        content: String,
        usage: [String: Any]? = nil
    ) throws -> (HTTPURLResponse, Data) {
        var body: [String: Any] = [
            "id": "chatcmpl-1",
            "choices": [
                ["message": ["role": "assistant", "content": content]]
            ]
        ]
        if let usage {
            body["usage"] = usage
        }
        return try response(status: 200, bodyObject: body)
    }

    private static func response(status: Int, bodyObject: [String: Any]) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, try JSONSerialization.data(withJSONObject: bodyObject))
    }

    private static let openAppPlanJSON =
        #"{"summary":"Open Safari.","requiresConfirmation":false,"steps":[{"id":"open","operation":"open_app","description":"Open Safari.","appName":"Safari"}]}"#
}

private final class CerebrasFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: CerebrasPlannerError.missingMessageContent)
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

/// Accepts every request and never answers it — see `hangingSession()`.
private final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody {
            return httpBody
        }

        guard let stream = httpBodyStream else {
            Issue.record("Expected JSON body data.")
            throw CerebrasPlannerError.missingMessageContent
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? CerebrasPlannerError.missingMessageContent
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
