import Foundation

public enum CerebrasPlannerError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case badResponse(Int, String)
    case missingMessageContent

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "CEREBRAS_API_KEY is not set. Add it to the environment before launching the app."
        case .badResponse(let status, let body):
            return "Cerebras planner request failed with HTTP \(status): \(body)"
        case .missingMessageContent:
            return "Cerebras response did not include message content."
        }
    }
}

/// The open-weights planner (SONNY-86): `gpt-oss-120b` served by Cerebras, spoken to in the
/// OpenAI-compatible Chat Completions dialect, behind the same `Planning` seam and registered
/// with `PlannerProviderRegistry` as the selectable A/B alternate. OpenAI remains the default;
/// nothing here or anywhere else flips it.
///
/// **Output mode.** Schema-in-prompt is the default: the shared system prompt is extended
/// with the serialized plan schema and `AgentPlanDecoder.decodeStrict` enforces it
/// client-side, surfacing a rejection as a normal planner error. Cerebras's native
/// structured-output mode cannot carry the plan schema — re-verified live 2026-08-13 against
/// inference-docs.cerebras.ai/capabilities/structured-outputs: the schema cap is 5,000
/// characters (ours serializes well past it), and since 2026-07-21 the limits are strictly
/// enforced, so an oversized schema is a validation error rather than a silent degradation.
/// `useNativeStructuredOutput` opts into sending `response_format` anyway, existing precisely
/// so that rejection can be measured against the live API rather than re-argued from docs.
///
/// The provider obligations (`PlannerProvider`'s doc) are satisfied here: usage goes through
/// the injected `TaskUsageRecording` via the shared parser and record builder; cancellation
/// passes through untouched (a cancelled `URLSession` call throws `CancellationError` or
/// `URLError(.cancelled)`, and no catch below rewraps them); every error this file throws
/// itself is a `CerebrasPlannerError` or an `AgentPlanDecodingError`, both `LocalizedError`.
@MainActor
public final class CerebrasPlanner: Planning {
    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let session: URLSession
    private let toolRegistry: ToolRegistry
    private let usageRecorder: any TaskUsageRecording
    private let useNativeStructuredOutput: Bool

    public init(
        apiKey: String? = ProcessInfo.processInfo.environment["CEREBRAS_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["CEREBRAS_MODEL"] ?? "gpt-oss-120b",
        endpoint: URL = URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
        session: URLSession = .shared,
        toolRegistry: ToolRegistry = .default,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared,
        useNativeStructuredOutput: Bool = ProcessInfo.processInfo
            .environment["SONNY_CEREBRAS_STRUCTURED"] == "1"
    ) throws {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CerebrasPlannerError.missingAPIKey
        }
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.toolRegistry = toolRegistry
        self.usageRecorder = usageRecorder
        self.useNativeStructuredOutput = useNativeStructuredOutput
    }

    public func plan(command: String, priorTaskContext: PriorTaskContext? = nil) async throws -> AgentPlan {
        let requestBody = requestBody(command: command, priorTaskContext: priorTaskContext)
        let requestData = try JSONSerialization.data(withJSONObject: requestBody)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestData

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CerebrasPlannerError.badResponse(-1, "No HTTP response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw CerebrasPlannerError.badResponse(httpResponse.statusCode, body)
        }

        // Usage is recorded before the content is judged: a response that goes on to fail
        // decoding still cost tokens, and the recorder owns that truth either way.
        let reportedUsage = try AIUsagePayloadParser.responsesUsage(from: data)
        let contentResult = Result {
            try CerebrasChatResponseParser.messageContent(from: data)
        }
        usageRecorder.record(
            AIUsageRecord.responses(
                kind: .planner,
                model: model,
                reportedUsage: reportedUsage,
                estimatedInputText: String(data: requestData, encoding: .utf8) ?? command,
                estimatedOutputText: (try? contentResult.get()) ?? ""
            )
        )
        let content = try contentResult.get()
        return try AgentPlanDecoder.decodeStrict(from: Self.normalizedPlanText(content))
    }

    private func requestBody(command: String, priorTaskContext: PriorTaskContext?) -> [String: Any] {
        var systemPrompt = OpenAIPlanner.systemPrompt(toolRegistry: toolRegistry)
        if !useNativeStructuredOutput {
            systemPrompt += Self.schemaPromptSuffix()
        }

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        if let priorTaskContext {
            messages.append(["role": "user", "content": priorTaskContext.plannerContextText])
        }
        messages.append(["role": "user", "content": command])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "reasoning_effort": "medium"
        ]
        if useNativeStructuredOutput {
            body["response_format"] = Self.chatCompletionsResponseFormat()
        }
        return body
    }

    /// The shared plan schema as deterministic JSON text (sorted keys, stable across runs so
    /// prompts and tests agree byte for byte).
    nonisolated static func schemaJSONText() -> String {
        let schema = AgentPlanSchema.responseFormat()["schema"] ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Appended to the shared system prompt in schema-in-prompt mode. The shared prompt's own
    /// text is untouched — this planner extends its *copy* of the assembled string, so the
    /// OpenAI golden stays byte-identical.
    nonisolated static func schemaPromptSuffix() -> String {
        "\n\nYour reply must be exactly one JSON object conforming to this JSON Schema — "
            + "no markdown fences, no commentary, nothing before or after it:\n"
            + schemaJSONText()
    }

    /// The shared schema is authored in the Responses `text.format` shape (flat
    /// type/name/strict/schema); Chat Completions nests name/strict/schema one level down
    /// under a `json_schema` key. Re-wrapped here rather than authored twice.
    nonisolated static func chatCompletionsResponseFormat() -> [String: Any] {
        let flat = AgentPlanSchema.responseFormat()
        return [
            "type": "json_schema",
            "json_schema": [
                "name": flat["name"] ?? "agent_plan",
                "strict": flat["strict"] ?? true,
                "schema": flat["schema"] ?? [:]
            ]
        ]
    }

    /// Schema-in-prompt mode has no server-side output guarantee, and a model told "no
    /// markdown fences" can still emit them around an otherwise valid plan. Stripping a
    /// wrapping fence is input normalization ahead of `decodeStrict` — the schema itself is
    /// still enforced, and anything else malformed still rejects.
    nonisolated static func normalizedPlanText(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else {
            return trimmed
        }
        guard let firstNewline = trimmed.firstIndex(of: "\n") else {
            // A lone fence line carries no plan; hand it to the decoder unmodified to reject.
            return trimmed
        }
        trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension CerebrasPlanner {
    nonisolated public static let providerID = "cerebras"

    /// Registry descriptor for the open-weights A/B alternate (SONNY-86). Selected only by
    /// explicit `SONNY_PLANNER=cerebras`; construction throws `.missingAPIKey` without
    /// `CEREBRAS_API_KEY`, which the registry reports by falling back to the default with a
    /// visible notice.
    nonisolated public static let provider = PlannerProvider(
        id: providerID,
        displayName: "Cerebras"
    ) { usageRecorder in
        try CerebrasPlanner(usageRecorder: usageRecorder)
    }
}

public enum CerebrasChatResponseParser {
    public static func messageContent(from data: Data) throws -> String {
        // Same containment as OpenAIResponseParser: a truncated or non-JSON body must surface
        // as this parser's own error, not a raw Foundation error shown verbatim.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]] else {
            throw CerebrasPlannerError.missingMessageContent
        }

        for choice in choices {
            if let message = choice["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.isEmpty {
                return content
            }
        }

        throw CerebrasPlannerError.missingMessageContent
    }
}
