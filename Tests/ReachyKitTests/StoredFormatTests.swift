import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

/// A record in the shape shipped builds wrote. `.stored` may not move without a
/// schema bump — see ADR 0004. What this pins is the `Date`: Foundation's default
/// encoding is a `timeIntervalSinceReferenceDate` number, and any strategy that
/// makes it a string leaves every catalogue on every device undecodable, which
/// `RobotCatalogueCache.record` reports as an empty cache rather than as an error.
@Suite("Stored format")
struct StoredFormatTests {
    @Test("a catalogue record written before JSONCodec still decodes")
    func decodesAShippedRecord() throws {
        let shipped = #"{"schema":1,"robotID":"hw-1","apps":[],"takenAt":776000000}"#

        let record = try JSONCodec.stored.decode(RobotAppCatalogueRecord.self, from: Data(shipped.utf8))

        #expect(record.robotID == "hw-1")
        #expect(record.schema == RobotCatalogueCache.schema)
        #expect(record.takenAt == Date(timeIntervalSinceReferenceDate: 776_000_000))
    }

    @Test("and one written now is still that shape")
    func writesTheSameShape() throws {
        let record = RobotAppCatalogueRecord(
            robotID: "hw-1",
            apps: [],
            takenAt: Date(timeIntervalSinceReferenceDate: 776_000_000)
        )

        let json = try #require(String(bytes: JSONCodec.stored.encode(record), encoding: .utf8))

        #expect(json.contains(#""takenAt":776000000"#))
        #expect(!json.contains("1994-08"))
    }
}
