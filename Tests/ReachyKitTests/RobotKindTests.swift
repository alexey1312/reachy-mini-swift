import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

/// The family central files a robot under. Every row here is a case
/// `robot_kinds.py` documents in `pollen-robotics/reachy_mini_central_signalling`,
/// because a client that sorts the listing differently from central lists a robot
/// the server counts as something else.
@Suite("Robot kind")
struct RobotKindTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let kind: String?
        let robotType: String?
        let expected: RobotKind

        init(_ kind: String?, alias robotType: String? = nil, _ expected: RobotKind) {
            self.kind = kind
            self.robotType = robotType
            self.expected = expected
        }

        var testDescription: String {
            "kind \(kind.debugDescription), robot_type \(robotType.debugDescription)"
        }
    }

    @Test("kind is read the way central reads it", arguments: [
        // A Reachy Mini daemon sends no kind at all.
        Row(nil, .reachyMini),
        Row("microduck", .microDuck),
        // Case and every character outside a-z0-9 are ignored.
        Row("Micro-Duck", .microDuck),
        Row("micro duck", .microDuck),
        Row("reachy_mini", .reachyMini),
        Row("Reachy Mini", .reachyMini),
        Row("reachy-mini", .reachyMini),
        Row("reachymini", .reachyMini),
        // A blank kind is no kind, so the `robot_type` alias decides.
        Row("", alias: "microduck", .microDuck),
        Row("   ", alias: "Micro Duck", .microDuck),
        Row(nil, alias: "microduck", .microDuck),
        Row("", alias: "", .reachyMini),
        // A usable kind wins over the alias.
        Row("reachy_mini", alias: "microduck", .reachyMini),
        Row("toaster", .other),
    ])
    func classifies(_ row: Row) {
        #expect(RobotKind(kind: row.kind, robotType: row.robotType) == row.expected)
    }

    /// Central refuses to normalise a value longer than 64 characters, so a kind
    /// padded until it compacts to a known one is still `other`.
    @Test("a kind longer than central reads is another family")
    func refusesLongValues() {
        let padded = "micro" + String(repeating: "-", count: 55) + "duck"
        #expect(padded.count == 64)
        #expect(RobotKind(kind: padded, robotType: nil) == .microDuck)
        #expect(RobotKind(kind: padded + "!", robotType: nil) == .other)
    }

    /// Central passes `meta` on without checking it, so `kind` can be any JSON at
    /// all. One entry with a number there must not cost the whole listing.
    @Test("a kind that is not a string falls through to the alias")
    func toleratesAnyJSONInKind() throws {
        let json = Data(#"""
        [
          {"peerId": "peer-1", "meta": {"kind": 7, "robot_type": "microduck"}},
          {"peerId": "peer-2", "meta": {"kind": {"family": "duck"}}},
          {"peerId": "peer-3"}
        ]
        """#.utf8)

        let robots = try JSONCodec.web.decode([CentralRobot].self, from: json)

        #expect(robots.map(\.kind) == [.microDuck, .reachyMini, .reachyMini])
    }
}
