import Foundation
import Testing
@testable import MacAgentCore

@Suite(.serialized)
struct VisionModelClientTests {
    @Test
    func usesOpenCodeLunaResponsesAPIByDefault() async throws {
        VisionFixtureURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://opencode.ai/zen/go/v1/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try request.bodyData()
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["model"] as? String == "gpt-5.6-luna")
            let input = try #require(object["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            #expect(content.first?["type"] as? String == "input_text")
            #expect(content.first?["text"] as? String == "choose the next action")
            #expect(content.last?["type"] as? String == "input_image")
            #expect(content.last?["image_url"] as? String == "data:image/png;base64,AQID")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"output_text":"{\"action\":\"done\",\"rationale\":\"complete\"}"}"#.utf8))
        }
        defer { VisionFixtureURLProtocol.handler = nil }

        let client = try VisionModelClient(
            environment: ["OPENCODE_API_KEY": "test-key"],
            session: Self.fixtureSession()
        )

        let result = try await client.decide(prompt: "choose the next action", pngData: Data([1, 2, 3]))

        #expect(client.transcriptDescription == "opencode/gpt-5.6-luna")
        #expect(result.reply.contains(#""action":"done""#))
    }

    @Test
    func requiresOpenCodeAPIKey() {
        #expect(throws: VisionActionLoopError.self) {
            _ = try VisionModelClient(environment: [:])
        }
    }

    private static func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VisionFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class VisionFixtureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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
            throw URLError(.cannotDecodeContentData)
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
