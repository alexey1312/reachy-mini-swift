import Foundation
@testable import ReachyIntrospection
import ReachyJSON
import Testing

@Suite("JSON value")
struct JSONValueTests {
    @Test("every kind of value survives a round trip")
    func roundTrip() throws {
        let value = JSONValue.object([
            "name": .string("Reachy"),
            "awake": .bool(true),
            "volume": .number(0.5),
            "count": .number(3),
            "error": .null,
            "tabs": .array([.string("robot"), .string("live")]),
        ])

        let data = try JSONCodec.web.encode(value)

        #expect(try JSONCodec.web.decode(JSONValue.self, from: data) == value)
    }

    /// A Boolean read as a number would turn `true` into 1 in every state an agent reads.
    @Test("a Boolean stays a Boolean and a number stays a number")
    func boolIsNotNumber() throws {
        let value = try JSONCodec.web.decode(JSONValue.self, from: Data(#"{"on":true,"level":1}"#.utf8))

        #expect(value["on"] == .bool(true))
        #expect(value["level"] == .number(1))
    }

    @Test("an Encodable value becomes its JSON form, and an input decodes back")
    func bridgesCodable() throws {
        struct Input: Codable, Equatable {
            let text: String
        }

        let value = try JSONValue(encoding: Input(text: "127.0.0.1"))

        #expect(value == .object(["text": .string("127.0.0.1")]))
        #expect(try value.decode(Input.self) == Input(text: "127.0.0.1"))
    }
}
