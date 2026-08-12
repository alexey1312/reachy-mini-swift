import Foundation
@testable import ReachyJSON
import Testing

@Suite("JSON codec")
struct JSONCodecTests {
    private struct Stamped: Codable, Equatable {
        let takenAt: Date
    }

    /// FastAPI emits fractional seconds; the same field arrives without them from
    /// other daemon routes. Both have to read.
    @Test("the daemon profile reads ISO 8601 with and without fractional seconds")
    func daemonDates() throws {
        let fractional = try JSONCodec.daemon.decode(
            Stamped.self,
            from: Data(#"{"takenAt":"2026-08-12T10:14:03.472Z"}"#.utf8)
        )
        let whole = try JSONCodec.daemon.decode(
            Stamped.self,
            from: Data(#"{"takenAt":"2026-08-12T10:14:03Z"}"#.utf8)
        )

        #expect(whole.takenAt.timeIntervalSince1970 == 1_786_529_643)
        #expect(abs(fractional.takenAt.timeIntervalSince1970 - 1_786_529_643.472) < 0.001)
    }

    @Test("the daemon profile refuses a date it cannot read, rather than inventing one")
    func daemonRejectsNonsense() {
        #expect(throws: DecodingError.self) {
            try JSONCodec.daemon.decode(Stamped.self, from: Data(#"{"takenAt":"yesterday"}"#.utf8))
        }
    }

    /// The freeze, at the level it matters: bytes. Records written by shipped
    /// builds carry `Date` as a `timeIntervalSinceReferenceDate` number, and a
    /// strategy change here does not reformat them — it makes them unreadable,
    /// which every store reports as an empty cache. See ADR 0004.
    @Test("a stored date is a number, and stays one")
    func storedDatesAreNumbers() throws {
        let data = try JSONCodec.stored.encode(Stamped(takenAt: Date(timeIntervalSinceReferenceDate: 1000)))

        #expect(try #require(String(bytes: data, encoding: .utf8)) == #"{"takenAt":1000}"#)
    }

    @Test("a stored value round-trips")
    func storedRoundTrip() throws {
        let value = Stamped(takenAt: Date(timeIntervalSinceReferenceDate: 12345.75))
        let data = try JSONCodec.stored.encode(value)

        #expect(try JSONCodec.stored.decode(Stamped.self, from: data) == value)
    }

    /// This pins today's coincidence, not the contract: `.web` and `.stored` produce
    /// the same bytes only because both carry Foundation's defaults right now, not
    /// because they are the same profile. The day `.web` gets a date rule of its own
    /// (ADR 0004 permits it — Hugging Face may start sending one), this assertion is
    /// what changes; `.stored`'s own tests do not, because `.stored` may not move.
    @Test("the web profile carries Foundation's defaults today")
    func webCarriesFoundationDefaultsToday() throws {
        let value = Stamped(takenAt: Date(timeIntervalSinceReferenceDate: 1000))

        #expect(try JSONCodec.web.encode(value) == JSONCodec.stored.encode(value))
    }
}
