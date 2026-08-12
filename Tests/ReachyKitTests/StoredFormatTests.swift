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
        // The literal `1`, not `RobotCatalogueCache.schema`: this fixture is a
        // shipped record, frozen at the schema it was actually written with. The
        // sanctioned way to change `.stored` is a schema bump (ADR 0004), and
        // comparing against the live constant would fail this decode test — for a
        // reason that has nothing to do with decoding — the day that bump lands.
        #expect(record.schema == 1)
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
        // The number, not a string: a strategy change that turned this into an ISO
        // 8601 date would still contain the substring "takenAt", so check for the
        // quote a string encoding would add around the value instead.
        #expect(!json.contains(#""takenAt":""#))
    }

    /// `RobotSnapshot` is the App Group record the widget reads, carries the most
    /// `Date` fields of anything `.stored` writes, and has the least able consumer
    /// to report a decode failure — a widget process that missed its readiness
    /// window renders nothing rather than an error. `failedApp` is populated and
    /// `runningApp`/`runningAppName` left nil, which is also the shape a real crash
    /// leaves behind (the two are mutually exclusive — see the type's doc comment).
    @Test("a snapshot record written before JSONCodec still decodes")
    func decodesAShippedSnapshot() throws {
        let shipped = """
        {"robotID":"hw-1","robotName":"Reachy Mini","isAwake":true,\
        "failedApp":{"name":"reachy-mini-dance","title":"Dance Party",\
        "error":"Process exited with code 1"},"runningAppTakenAt":775999000,"takenAt":776000000}
        """

        let snapshot = try JSONCodec.stored.decode(RobotSnapshot.self, from: Data(shipped.utf8))

        #expect(snapshot.robotID == "hw-1")
        #expect(snapshot.robotName == "Reachy Mini")
        #expect(snapshot.isAwake)
        #expect(snapshot.runningApp == nil)
        #expect(snapshot.failedApp?.name == "reachy-mini-dance")
        #expect(snapshot.failedApp?.title == "Dance Party")
        #expect(snapshot.runningAppTakenAt == Date(timeIntervalSinceReferenceDate: 775_999_000))
        #expect(snapshot.takenAt == Date(timeIntervalSinceReferenceDate: 776_000_000))
    }

    @Test("and a snapshot written now is still that shape")
    func writesTheSameSnapshotShape() throws {
        let snapshot = RobotSnapshot(
            robotID: "hw-1",
            robotName: "Reachy Mini",
            isAwake: true,
            runningApp: nil,
            failedApp: RobotSnapshot.FailedApp(
                name: "reachy-mini-dance",
                title: "Dance Party",
                error: "Process exited with code 1"
            ),
            runningAppTakenAt: Date(timeIntervalSinceReferenceDate: 775_999_000),
            takenAt: Date(timeIntervalSinceReferenceDate: 776_000_000)
        )

        // Foundation's `JSONEncoder` does not promise key order — measured to
        // reorder between runs on this many fields — so this checks each pair
        // rather than the whole string, the same reason the catalogue record's
        // fixture above never asserts full equality either.
        let json = try #require(String(bytes: JSONCodec.stored.encode(snapshot), encoding: .utf8))

        #expect(json.contains(#""robotID":"hw-1""#))
        #expect(json.contains(#""robotName":"Reachy Mini""#))
        #expect(json.contains(#""isAwake":true"#))
        #expect(json.contains(#""runningAppTakenAt":775999000"#))
        #expect(json.contains(#""takenAt":776000000"#))
        #expect(json.contains(#""name":"reachy-mini-dance""#))
        #expect(json.contains(#""title":"Dance Party""#))
        #expect(json.contains(#""error":"Process exited with code 1""#))
        // Nil optionals are omitted rather than written as `null`.
        #expect(!json.contains(#""runningApp":"#))
        #expect(!json.contains(#""runningAppName":"#))
    }
}
