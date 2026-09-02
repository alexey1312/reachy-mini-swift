import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The half of the network card that is not the join sheet: what the robot is on,
/// what it remembers, and taking a saved network away.
///
/// Every one of these calls has a second step — the status is read back — and that
/// second step is what no recorded image could ever show.
@MainActor
@Suite("Wi-Fi settings card", .timeLimit(.minutes(1)))
struct WiFiSettingsModelTests {
    private let onANetwork = WiFiStatus(mode: .wlan, connected: "Home", known: ["Home", "Office"])

    @Test("the card reads the robot's mode and its own last failure")
    func loadsTheStatus() async {
        let model = WiFiSettingsModel(
            status: { _ in onANetwork },
            lastError: { _ in "Wrong password" }
        )
        await model.load(session: .preview())
        #expect(model.status == onANetwork)
        #expect(model.joinError == "Wrong password")
        #expect(model.loadFailure == nil)
        #expect(model.modeText == String(localized: .reachy("On a network")))
    }

    /// The two transient words the card can show are catalogue keys like the three
    /// modes beside them — they used to be the only bare literals in this switch.
    @Test("a busy or unknown mode is reported in translated words")
    func modeTextCoversTheTransientModes() async {
        let busy = WiFiSettingsModel(status: { _ in WiFiStatus(mode: .busy, connected: nil) })
        await busy.load(session: .preview())
        #expect(busy.modeText == String(localized: .reachy("Working…")))

        let unknown = WiFiSettingsModel(status: { _ in WiFiStatus(mode: nil, connected: nil) })
        await unknown.load(session: .preview())
        #expect(unknown.modeText == String(localized: .reachy("Unknown")))
    }

    /// The rows on screen are better than no rows: a robot that answered once and
    /// then timed out has not forgotten those networks.
    @Test("a failed refresh is reported without emptying the card")
    func keepsTheStatusWhenALoadFails() async {
        let attempts = Attempts()
        let model = WiFiSettingsModel(
            status: { _ in
                guard attempts.next() == 1 else { throw URLError(.timedOut) }
                return onANetwork
            },
            lastError: { _ in nil }
        )
        let session = RobotSession.preview()
        await model.load(session: session)
        await model.load(session: session)
        #expect(model.status == onANetwork)
        #expect(model.loadFailure != nil)
    }

    /// Forgetting is only half done when the route answers: what the robot still
    /// remembers is a second call, and the rows come from it.
    @Test("forgetting one network reads the list back")
    func rereadsTheListAfterForgetting() async {
        let attempts = Attempts()
        let forgotten = Recorded()
        let model = WiFiSettingsModel(
            status: { _ in
                attempts.next() == 1
                    ? onANetwork
                    : WiFiStatus(mode: .wlan, connected: "Home", known: ["Home"])
            },
            lastError: { _ in nil },
            forget: { _, ssid in forgotten.record(ssid) }
        )
        let session = RobotSession.preview()
        await model.load(session: session)
        await model.forget("Office", session: session)
        #expect(forgotten.calls == ["Office"])
        #expect(model.status?.known == ["Home"])
        #expect(!model.busy)
    }

    /// The `defer` is the point: a robot that refuses one row must not leave every
    /// other button on the card disabled for the rest of the session.
    @Test("a refused forget reports and leaves the card usable")
    func staysUsableAfterARefusal() async {
        let model = WiFiSettingsModel(forget: { _, _ in throw URLError(.badServerResponse) })
        await model.forget("Home", session: .preview())
        #expect(model.loadFailure != nil)
        #expect(!model.busy)
    }

    /// `/wifi/forget_all` in one call rather than a loop over the rows: the
    /// per-network route answers 409 while another one runs, so a loop would race
    /// itself.
    @Test("forgetting everything uses the one route, not a row at a time")
    func forgetsEverythingInOneCall() async {
        let single = Recorded()
        let looped = Recorded()
        let model = WiFiSettingsModel(
            status: { _ in WiFiStatus(mode: .hotspot, connected: nil, known: []) },
            lastError: { _ in nil },
            forget: { _, ssid in looped.record(ssid) },
            forgetAll: { _ in single.record("all") }
        )
        await model.forgetAll(session: .preview())
        #expect(single.calls == ["all"])
        #expect(looped.calls.isEmpty)
        #expect(model.status?.known == [])
    }

    /// The error belongs to the robot, so it is gone only once the robot says so.
    @Test("the robot's last error clears only when the robot accepts it")
    func clearsTheStoredError() async {
        let model = WiFiSettingsModel(
            status: { _ in onANetwork },
            lastError: { _ in "Wrong password" },
            resetError: { _ in }
        )
        let session = RobotSession.preview()
        await model.load(session: session)
        await model.clearError(session: session)
        #expect(model.joinError == nil)

        let refusing = WiFiSettingsModel(
            status: { _ in onANetwork },
            lastError: { _ in "Wrong password" },
            resetError: { _ in throw URLError(.cannotConnectToHost) }
        )
        await refusing.load(session: session)
        await refusing.clearError(session: session)
        #expect(refusing.joinError == "Wrong password")
        #expect(refusing.loadFailure != nil)
    }

    /// One saved network already has a Forget button of its own, and the robot's own
    /// hotspot cannot be forgotten at all.
    @Test("Forget all appears only above one saved network")
    func offersForgetAllOnlyWhenItIsWorthIt() async {
        let model = WiFiSettingsModel(
            status: { _ in WiFiStatus(mode: .wlan, connected: "Home", known: ["Home"]) },
            lastError: { _ in nil }
        )
        let session = RobotSession.preview()
        await model.load(session: session)
        #expect(!model.offersForgetAll)

        let two = WiFiSettingsModel(status: { _ in onANetwork }, lastError: { _ in nil })
        await two.load(session: session)
        #expect(two.offersForgetAll)
    }

    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func record(_ value: String) {
            lock.withLock { recorded.append(value) }
        }

        var calls: [String] {
            lock.withLock { recorded }
        }
    }
}
