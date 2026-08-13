import Foundation

// SONNY-80 experiment. Minimal MCP JSON-RPC 2.0 plumbing for talking to cua-driver's stdio proxy:
// a Sendable JSON value (Swift 6 strict concurrency rules out [String: Any] across actors), the
// line-framed request/response codec, and the tools/call result unwrapping. Pure functions —
// everything here is unit-tested without spawning any process.

public indirect enum CUAJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CUAJSONValue])
    case object([String: CUAJSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [CUAJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> CUAJSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    static func fromFoundation(_ value: Any) -> CUAJSONValue {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // NSNumber bridges bools and numbers; CFBooleanRef is the reliable discriminator.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(fromFoundation))
        case let object as [String: Any]:
            return .object(object.mapValues(fromFoundation))
        default:
            return .null
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            // Emit integral numbers as integers so tool params like pid/window_id round-trip the
            // way cua-driver's schemas declare them.
            if value.rounded() == value, value.magnitude < 9_007_199_254_740_992 { return Int(value) }
            return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let members): return members.mapValues(\.foundationValue)
        }
    }
}

struct CUAJSONRPCMessage: Sendable {
    let id: Int?
    let result: CUAJSONValue?
    let error: CUAJSONValue?
    let method: String?
}

/// A tool-level failure (`isError: true` on a tools/call result) — the tool ran and refused,
/// distinct from a transport failure (dead pipe, timeout). Click-class callers map these to
/// skip-and-recapture outcomes; everything else surfaces them as run errors.
struct CUAToolError: Error, Sendable {
    let message: String
}

enum CUAJSONRPCCodec {
    /// One line-framed JSON-RPC request. `id: nil` encodes a notification.
    static func encode(id: Int?, method: String, params: CUAJSONValue?) throws -> Data {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { envelope["id"] = id }
        if let params { envelope["params"] = params.foundationValue }
        var data = try JSONSerialization.data(withJSONObject: envelope)
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) throws -> CUAJSONRPCMessage {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw VisionActionLoopError.driverFailure("cua-driver sent a non-object JSON-RPC frame")
        }
        return CUAJSONRPCMessage(
            id: (object["id"] as? NSNumber)?.intValue,
            result: object["result"].map(CUAJSONValue.fromFoundation),
            error: object["error"].map(CUAJSONValue.fromFoundation),
            method: object["method"] as? String
        )
    }

    /// Unwraps an MCP tools/call result: throws on protocol errors and `isError` tool results
    /// (carrying the tool's own message), returns the structured content and any image bytes.
    static func unwrapToolResult(_ result: CUAJSONValue, toolName: String) throws -> (structured: CUAJSONValue, imagePNG: Data?) {
        if result["isError"]?.boolValue == true {
            throw CUAToolError(message: "\(toolName): \(errorText(from: result))")
        }
        let structured = result["structuredContent"] ?? .object([:])
        var imagePNG: Data?
        if let content = result["content"]?.arrayValue {
            for part in content where part["type"]?.stringValue == "image" {
                if let base64 = part["data"]?.stringValue, let data = Data(base64Encoded: base64) {
                    imagePNG = data
                    break
                }
            }
        }
        return (structured, imagePNG)
    }

    static func errorText(from result: CUAJSONValue) -> String {
        if let content = result["content"]?.arrayValue {
            let texts = content.compactMap { part -> String? in
                guard part["type"]?.stringValue == "text" else { return nil }
                return part["text"]?.stringValue
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        if let refusal = result["structuredContent"]?["refusal"],
           let message = refusal["message"]?.stringValue {
            return message
        }
        if let code = result["structuredContent"]?["code"]?.stringValue {
            return code
        }
        return "unspecified tool error"
    }
}
