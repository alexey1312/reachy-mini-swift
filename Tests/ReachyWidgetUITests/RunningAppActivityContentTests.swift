import Foundation
import ReachyJSON
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// A Live Activity cannot fetch anything and cannot scroll. Everything on the Lock
/// Screen is whatever the app last handed over, inside a 4 KB ceiling and a 160 pt
/// box — so what this value refuses to carry matters more than what it carries.
@Suite("Running app activity content")
struct RunningAppActivityContentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The recorded shape of a crash: the daemon's summary line, then the app's
    /// stderr tail verbatim. `RunningAppCaption` records what a one-line slot fed
    /// the whole thing renders — a state row showing half a traceback.
    private let crash = """
    Process exited with code 1
    Traceback (most recent call last):
      File "/home/pollen/app/main.py", line 42, in <module>
        raise RuntimeError("no camera")
    RuntimeError: no camera
    """

    private func content(caption: String, canStop: Bool = true) -> RunningAppActivityContent {
        RunningAppActivityContent(
            caption: caption,
            symbolName: "play.circle",
            isFailed: false,
            canStop: canStop,
            readAt: now
        )
    }

    @Test("a crash is carried as its summary line and nothing else")
    func clampsACrashToItsSummaryLine() {
        let caption = content(caption: crash).caption
        #expect(caption == "Process exited with code 1")
        #expect(caption.contains(where: \.isNewline) == false)
    }

    @Test("a line longer than the budget is capped rather than truncated by the renderer")
    func capsALongLine() {
        let caption = content(caption: String(repeating: "a", count: 400)).caption
        #expect(caption.count == RunningAppActivityContent.captionLimit)
        #expect(caption.hasSuffix("…"))
    }

    @Test("a leading blank line does not become an empty caption")
    func skipsLeadingBlankLines() {
        #expect(content(caption: "\n  \nRunning").caption == "Running")
    }

    @Test("an ordinary caption passes through untouched")
    func leavesAnOrdinaryCaptionAlone() {
        #expect(content(caption: "Starting…").caption == "Starting…")
    }

    /// The only automated check on ActivityKit's ceiling. Everything else about the
    /// activity needs a device; this does not, and a regression here is silent —
    /// `Activity.request` throws `.attributesTooLarge` and the card simply never
    /// appears.
    @Test("the worst realistic payload fits the 4 KB ceiling with room to spare")
    func fitsTheActivityBudget() throws {
        let app = RunningAppActivityApp(
            robotID: String(repeating: "🤖", count: 64),
            robotName: String(repeating: "🤖", count: 64),
            appName: String(repeating: "e", count: 200),
            appTitle: String(repeating: "🎉", count: 120),
            emoji: "🎉",
            gradientFrom: "fuchsia",
            gradientTo: "emerald",
            artworkKey: String(repeating: "k", count: 200)
        )
        let state = content(caption: String(repeating: "🙃", count: 400))
        let size = try JSONCodec.stored.encode(app).count + JSONCodec.stored.encode(state).count
        // Measured at 2098 bytes for a payload no real robot produces — every free
        // text field at its cap and every one of them emoji. The bound is three
        // quarters of the ceiling rather than the ceiling itself, so that putting
        // the stderr tail back fails here instead of on somebody's Lock Screen.
        #expect(size < 3072, "encoded \(size) bytes of the 4096 ActivityKit allows")
    }

    @Test("content survives a round trip")
    func roundTrips() throws {
        let state = content(caption: "Running")
        let decoded = try JSONCodec.stored.decode(
            RunningAppActivityContent.self,
            from: JSONCodec.stored.encode(state)
        )
        #expect(decoded == state)
    }

    /// The controller decides whether to push an update by comparing two of these,
    /// so a field the comparison cannot see is a field the Lock Screen never
    /// updates.
    @Test("two contents differing only in whether Stop is offered are not equal")
    func distinguishesTheStopAffordance() {
        #expect(content(caption: "Running", canStop: true) != content(caption: "Running", canStop: false))
    }

    @Test("a run is keyed by the robot and the entry point, so two robots never share one")
    func runKeyNamesBothHalves() {
        let first = app(robotID: "kitchen", appName: "dance_party")
        let second = app(robotID: "study", appName: "dance_party")
        #expect(first.runKey != second.runKey)
        #expect(first.runKey == app(robotID: "kitchen", appName: "dance_party").runKey)
    }

    private func app(robotID: String?, appName: String) -> RunningAppActivityApp {
        RunningAppActivityApp(
            robotID: robotID,
            robotName: "Reachy",
            appName: appName,
            appTitle: "Dance Party",
            emoji: "💃",
            gradientFrom: nil,
            gradientTo: nil,
            artworkKey: appName
        )
    }
}
