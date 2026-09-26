import Foundation

/// A UUID on the V2 wire, typed by what it names so a task id can't be passed where an action id
/// belongs. The contract spells every id as a lowercase canonical UUID, and decoding refuses any
/// other spelling so that a round trip reproduces the bytes it was given.
public struct WireID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string), uuid.uuidString.lowercased() == string else {
            return nil
        }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = WireID(string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a lowercase canonical UUID"
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum MessageTag {}
public enum TaskTag {}
public enum ActionTag {}
public enum DeviceTag {}
public enum SessionTag {}

public typealias MessageID = WireID<MessageTag>
public typealias TaskID = WireID<TaskTag>
public typealias ActionID = WireID<ActionTag>
public typealias DeviceID = WireID<DeviceTag>
public typealias SessionID = WireID<SessionTag>
