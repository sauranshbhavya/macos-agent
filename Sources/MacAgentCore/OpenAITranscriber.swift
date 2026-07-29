import Foundation

public enum TranscriptionError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case unreadableAudioFile(String)
    case badResponse(Int, String)
    case missingText

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is not set. Add it to the environment before using voice input."
        case .unreadableAudioFile(let path):
            return "Could not read recorded audio at \(path)."
        case .badResponse(let status, let body):
            return "OpenAI transcription request failed with HTTP \(status): \(body)"
        case .missingText:
            return "OpenAI transcription response did not include text."
        }
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public var text: String
    public var usage: AIUsageRecord?

    public init(text: String, usage: AIUsageRecord? = nil) {
        self.text = text
        self.usage = usage
    }
}

public struct OpenAITranscriber: Sendable {
    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let session: URLSession
    private let usageRecorder: any TaskUsageRecording

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["OPENAI_TRANSCRIBE_MODEL"] ?? "gpt-4o-mini-transcribe",
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        session: URLSession = .shared,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared
    ) throws {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.missingAPIKey
        }
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.usageRecorder = usageRecorder
    }

    public func transcribe(audioFileURL: URL) async throws -> TranscriptionResult {
        guard let audioData = try? Data(contentsOf: audioFileURL) else {
            throw TranscriptionError.unreadableAudioFile(audioFileURL.path)
        }

        let boundary = "MacAgentBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            model: model,
            filename: audioFileURL.lastPathComponent,
            audioData: audioData
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.badResponse(-1, "No HTTP response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw TranscriptionError.badResponse(httpResponse.statusCode, body)
        }

        // A response missing `text` entirely is the same user-facing problem as an empty one:
        // no transcript. A raw DecodingError here would reach the user verbatim.
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.missingText
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.missingText
        }
        let usage = (try? AIUsagePayloadParser.transcriptionUsage(from: data)).map { parsedUsage in
            AIUsageRecord(
                kind: .transcription,
                model: model,
                tokenSource: parsedUsage.tokenSource,
                tokenCounts: parsedUsage.tokenCounts,
                audioDurationSeconds: parsedUsage.audioDurationSeconds
            )
        } ?? AIUsageRecord(kind: .transcription, model: model)
        usageRecorder.record(usage)
        return TranscriptionResult(text: text, usage: usage)
    }

    private static func multipartBody(
        boundary: String,
        model: String,
        filename: String,
        audioData: Data
    ) -> Data {
        var body = Data()
        body.appendFormField(name: "model", value: model, boundary: boundary)
        body.appendFormField(name: "response_format", value: "json", boundary: boundary)
        body.appendFileField(
            name: "file",
            filename: filename,
            contentType: "audio/mp4",
            data: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private struct Response: Decodable {
        var text: String
    }
}

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendFileField(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(contentType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }

    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
