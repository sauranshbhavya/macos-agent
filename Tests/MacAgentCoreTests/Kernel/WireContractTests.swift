import Foundation
import Testing
@testable import MacAgentCore

/// The Swift half of the V2 contract check. The server suite (`server/test/contracts.test.ts`)
/// decodes the same fixtures through its Zod mirror and the JSON Schema itself.
@Suite
struct WireContractTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Kernel
        .deletingLastPathComponent()   // MacAgentCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("contracts/v2/fixtures")

    static func names(_ directory: String) -> [String] {
        let url = fixtures.appendingPathComponent(directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    static func data(_ directory: String, _ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(directory).appendingPathComponent(name))
    }

    static func assertRoundTrip<P: WirePayload>(_ type: WireMessage<P>.Type, _ data: Data) throws {
        let message = try WireCoding.decode(type, from: data)
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let again = try JSONSerialization.jsonObject(with: WireCoding.encode(message)) as? NSDictionary
        #expect(original != nil)
        #expect(original == again)
    }

    @Test
    func everyDirectionHasFixtures() {
        for directory in ["client/valid", "client/invalid", "server/valid", "server/invalid"] {
            #expect(Self.names(directory).count > 5, "no fixtures in \(directory)")
        }
    }

    @Test(arguments: names("client/valid"))
    func clientMessageRoundTrips(_ name: String) throws {
        try Self.assertRoundTrip(ClientMessage.self, Self.data("client/valid", name))
    }

    @Test(arguments: names("server/valid"))
    func serverMessageRoundTrips(_ name: String) throws {
        try Self.assertRoundTrip(ServerMessage.self, Self.data("server/valid", name))
    }

    @Test(arguments: names("client/invalid"))
    func invalidClientMessageIsRefused(_ name: String) throws {
        let data = try Self.data("client/invalid", name)
        #expect(throws: (any Error).self) { try WireCoding.decode(ClientMessage.self, from: data) }
    }

    @Test(arguments: names("server/invalid"))
    func invalidServerMessageIsRefused(_ name: String) throws {
        let data = try Self.data("server/invalid", name)
        #expect(throws: (any Error).self) { try WireCoding.decode(ServerMessage.self, from: data) }
    }

    @Test
    func anUnknownFieldIsReportedAsOne() throws {
        let data = try Self.data("server/invalid", "finish-unknown-field.json")
        #expect(throws: WireError.unknownField) { try WireCoding.decode(ServerMessage.self, from: data) }
    }

    @Test
    func anUnknownTypeIsReportedAsOne() throws {
        let data = try Self.data("server/invalid", "unknown-type.json")
        #expect(throws: WireError.unknownType("thinking")) {
            try WireCoding.decode(ServerMessage.self, from: data)
        }
    }

    @Test
    func aMessageBuiltInSwiftEncodesToTheContractShape() throws {
        let task = try #require(TaskID("7d9f1c2e-4b3a-4e8f-9a21-0c5d6e7f8a90"))
        let message = ClientMessage(
            id: try #require(MessageID("00000000-0000-4000-8000-000000000013")),
            address: TaskAddress(task: task, seq: 8),
            payload: .taskCancel(TaskCancelBody(reason: .user))
        )
        let encoded = try JSONSerialization.jsonObject(with: WireCoding.encode(message)) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(
            with: Self.data("client/valid", "task-cancel.json")
        ) as? NSDictionary
        #expect(encoded == fixture)
    }

    @Test
    func effectsRaiseAndNeverLower() {
        #expect(Effect.navigate.raised(to: .external) == .external)
        #expect(Effect.external.raised(to: .navigate) == .external)
        #expect(Effect.unknown.raised(to: .destructive) == .destructive)
        #expect(Effect.credential.raised(to: .financial) == .credential)
        #expect(Effect.allCases.sorted() == Effect.allCases)
    }

    @Test
    func textIsCutToTheGatewaysLimitInUTF16UnitsAndNeverInsideACharacter() {
        // 499 letters and an emoji: 500 Characters and 500 scalars, but 501 UTF-16 units.
        #expect(overByOneUnit(500).clipped(toUTF16: 500) == lettersOf(500))
        #expect("ab😀".clipped(toUTF16: 4) == "ab😀")
        #expect("ab😀".clipped(toUTF16: 3) == "ab")
        // An accent written as its own scalar stays with its letter.
        #expect("cafe\u{301}".clipped(toUTF16: 4) == "caf")
        // A family is one Character of eight units, kept whole or left out whole.
        #expect("hi👨‍👩‍👧".clipped(toUTF16: 9) == "hi")
        #expect("hi👨‍👩‍👧".clipped(toUTF16: 10) == "hi👨‍👩‍👧")
        #expect("abc".clipped(toUTF16: 0) == "")
        #expect("".clipped(toUTF16: 0) == "")
    }
}
