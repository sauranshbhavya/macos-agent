import Foundation
import Testing
@testable import MacAgentCore

@Suite(.serialized)
@MainActor
struct OpenAIPlannerTests {
    @Test
    func plannerRecordsReportedResponsesUsage() async throws {
        PlannerFixtureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(Self.openAppResponseWithUsageJSON.utf8))
        }

        let recorder = TaskUsageRecorder()
        let planner = try OpenAIPlanner(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            session: Self.fixtureSession(),
            usageRecorder: recorder
        )

        _ = try await planner.plan(command: "Open Safari")

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedInputTokens == 42)
        #expect(summary.reportedOutputTokens == 18)
        #expect(summary.reportedTotalTokens == 60)
        #expect(summary.estimatedTotalTokens == 0)
        #expect(summary.records.first?.kind == .planner)
        #expect(summary.records.first?.tokenSource == .reported)
    }

    @Test
    func plannerEstimatesResponsesUsageWhenUsageIsNull() async throws {
        PlannerFixtureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(Self.openAppResponseWithNullUsageJSON.utf8))
        }

        let recorder = TaskUsageRecorder()
        let planner = try OpenAIPlanner(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            session: Self.fixtureSession(),
            usageRecorder: recorder
        )

        _ = try await planner.plan(command: "Open Safari")

        let summary = recorder.snapshot()
        #expect(summary.requestCount == 1)
        #expect(summary.reportedTotalTokens == 0)
        #expect(summary.estimatedInputTokens > 0)
        #expect(summary.estimatedOutputTokens > 0)
        #expect(summary.estimatedTotalTokens == summary.estimatedInputTokens + summary.estimatedOutputTokens)
        #expect(summary.hasEstimatedTokens)
        #expect(summary.records.first?.tokenSource == .estimated)
    }

    @Test
    func priorTaskContextIsSentAsSeparatePlannerMessage() async throws {
        PlannerFixtureURLProtocol.handler = { request in
            PlannerFixtureURLProtocol.capturedBody = try request.bodyData()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(Self.openAppResponseJSON.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let planner = try OpenAIPlanner(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            session: session
        )
        let context = PriorTaskContext(
            command: "Find the 3 largest files in ~/Desktop/MacAgentDemo and zip them.",
            plan: Self.largestPlan(),
            outcome: PriorTaskOutcome(status: .completed, summary: "Created largest.zip."),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        _ = try await planner.plan(
            command: "use ~/Documents/MacAgentDocs instead",
            priorTaskContext: context
        )

        let body = try #require(PlannerFixtureURLProtocol.capturedBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input.count == 3)
        #expect(Self.messageText(input[1])?.contains("TRUSTED_PRIOR_TASK_CONTEXT_BEGIN") == true)
        #expect(Self.messageText(input[1])?.contains("MacAgentDemo") == true)
        #expect(Self.messageText(input[2]) == "use ~/Documents/MacAgentDocs instead")
    }

    @Test
    func prepareFailurePriorTaskContextIsSentAsSeparatePlannerMessage() async throws {
        PlannerFixtureURLProtocol.handler = { request in
            PlannerFixtureURLProtocol.capturedBody = try request.bodyData()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(Self.openAppResponseJSON.utf8))
        }

        let planner = try OpenAIPlanner(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            session: Self.fixtureSession()
        )
        let context = PriorTaskContext(
            command: "find the 3 largest files in ~/Desktop/SomeFolder",
            outcome: PriorTaskOutcome(status: .failed, summary: "The folder ~/Desktop/SomeFolder could not be scanned."),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        _ = try await planner.plan(
            command: "use ~/Documents instead",
            priorTaskContext: context
        )

        let body = try #require(PlannerFixtureURLProtocol.capturedBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        #expect(input.count == 3)
        let contextText = try #require(Self.messageText(input[1]))
        #expect(contextText.contains("Previous command: find the 3 largest files in ~/Desktop/SomeFolder"))
        #expect(contextText.contains("Previous plan summary: - unavailable; prior task failed before preparation completed"))
        #expect(contextText.contains("Previous outcome: failed - The folder ~/Desktop/SomeFolder could not be scanned."))
        #expect(Self.messageText(input[2]) == "use ~/Documents instead")
    }

    @Test
    func plannerSurfacesBadHTTPStatusWithResponseBody() async throws {
        PlannerFixtureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"error":{"message":"upstream exploded"}}"#.utf8))
        }

        let planner = try OpenAIPlanner(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            session: Self.fixtureSession()
        )

        do {
            _ = try await planner.plan(command: "Open Safari")
            Issue.record("Expected an HTTP 500 to surface as PlannerError.badResponse.")
        } catch let error as PlannerError {
            guard case .badResponse(let status, let body) = error else {
                Issue.record("Expected .badResponse, got \(error).")
                return
            }
            #expect(status == 500)
            #expect(body.contains("upstream exploded"))
        }
    }

    @Test
    func plannerSurfacesMalformedOutputTextAsItsOwnDecodingError() async throws {
        PlannerFixtureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"output_text":"{not valid json"}"#.utf8))
        }

        let planner = try OpenAIPlanner(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            session: Self.fixtureSession()
        )

        await #expect(throws: AgentPlanDecodingError.invalidJSON) {
            _ = try await planner.plan(command: "Open Safari")
        }
    }

    @Test
    func plannerSurfacesUnreadableResponseBodyAsMissingOutputText() async throws {
        PlannerFixtureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("<html>not json at all</html>".utf8))
        }

        let planner = try OpenAIPlanner(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.openai.com/v1/responses")!,
            session: Self.fixtureSession()
        )

        await #expect(throws: PlannerError.missingOutputText) {
            _ = try await planner.plan(command: "Open Safari")
        }
    }

    private static func messageText(_ message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]],
              let first = content.first else {
            return nil
        }
        return first["text"] as? String
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func largestPlan() -> AgentPlan {
        AgentPlan(
            summary: "Zip largest files.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files.",
                    inputPath: "~/Desktop/MacAgentDemo",
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Create zip.",
                    inputPath: "~/Desktop/MacAgentDemo",
                    outputPath: "~/Desktop/largest.zip",
                    count: 3
                )
            ]
        )
    }

    private static let openAppResponseJSON = #"""
    {
      "id": "resp_123",
      "output_text": "{\"summary\":\"Open Safari.\",\"requiresConfirmation\":false,\"steps\":[{\"id\":\"open\",\"operation\":\"open_app\",\"description\":\"Open Safari.\",\"inputPath\":null,\"outputPath\":null,\"count\":null,\"targetURL\":null,\"appName\":\"Safari\",\"question\":null,\"mediaProvider\":null,\"mediaTitle\":null,\"mediaArtist\":null,\"contextSource\":null,\"routineName\":null,\"routineSteps\":null,\"workspaceName\":null,\"workspaceApps\":null,\"workspaceURLs\":null,\"sourceURLs\":null,\"searchQuery\":null,\"draftTitle\":null,\"draftContent\":null,\"shortcutName\":null,\"shortcutInput\":null}]}"
    }
    """#

    private static let openAppResponseWithUsageJSON = #"""
    {
      "id": "resp_123",
      "output_text": "{\"summary\":\"Open Safari.\",\"requiresConfirmation\":false,\"steps\":[{\"id\":\"open\",\"operation\":\"open_app\",\"description\":\"Open Safari.\",\"inputPath\":null,\"outputPath\":null,\"count\":null,\"targetURL\":null,\"appName\":\"Safari\",\"question\":null,\"mediaProvider\":null,\"mediaTitle\":null,\"mediaArtist\":null,\"contextSource\":null,\"routineName\":null,\"routineSteps\":null,\"workspaceName\":null,\"workspaceApps\":null,\"workspaceURLs\":null,\"sourceURLs\":null,\"searchQuery\":null,\"draftTitle\":null,\"draftContent\":null,\"shortcutName\":null,\"shortcutInput\":null}]}",
      "usage": {
        "input_tokens": 42,
        "output_tokens": 18,
        "total_tokens": 60
      }
    }
    """#

    private static let openAppResponseWithNullUsageJSON = #"""
    {
      "id": "resp_123",
      "output_text": "{\"summary\":\"Open Safari.\",\"requiresConfirmation\":false,\"steps\":[{\"id\":\"open\",\"operation\":\"open_app\",\"description\":\"Open Safari.\",\"inputPath\":null,\"outputPath\":null,\"count\":null,\"targetURL\":null,\"appName\":\"Safari\",\"question\":null,\"mediaProvider\":null,\"mediaTitle\":null,\"mediaArtist\":null,\"contextSource\":null,\"routineName\":null,\"routineSteps\":null,\"workspaceName\":null,\"workspaceApps\":null,\"workspaceURLs\":null,\"sourceURLs\":null,\"searchQuery\":null,\"draftTitle\":null,\"draftContent\":null,\"shortcutName\":null,\"shortcutInput\":null}]}",
      "usage": null
    }
    """#
}

private final class PlannerFixtureURLProtocol: URLProtocol {
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
            client?.urlProtocol(self, didFailWithError: PlannerError.missingOutputText)
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
            Issue.record("Expected JSON body data.")
            throw PlannerError.missingOutputText
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? PlannerError.missingOutputText
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
