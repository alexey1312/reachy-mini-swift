import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// Moving the robot to another network from settings. The awkward part is that
/// success is indistinguishable from a dropped connection, so the model reports what
/// the robot accepted and never what it did next.
@MainActor
@Suite("Wi-Fi join from settings", .timeLimit(.minutes(1)))
struct WiFiJoinModelTests {
    private func model(
        scan: @escaping WiFiJoinModel.Scan = { _ in [] },
        join: @escaping WiFiJoinModel.Join = { _, _, _, _ in }
    ) -> WiFiJoinModel {
        WiFiJoinModel(scan: scan, join: join)
    }

    @Test("nothing is sent without a network and a code")
    func refusesAnIncompleteForm() {
        let model = model()
        #expect(!model.canSend)
        model.manualSSID = "Home"
        #expect(!model.canSend)
        model.code = "AB12C"
        #expect(model.canSend)
    }

    /// A name typed with spaces around it is the same network.
    @Test("a manual name is trimmed")
    func trimsTheManualName() {
        let model = model()
        model.manualSSID = "  Home  "
        #expect(model.ssid == "Home")
    }

    /// A scan is one sweep of one radio, so a name can vanish between them. Leaving it
    /// selected would leave the picker showing a row it no longer lists.
    @Test("a network that drops out of the scan becomes a typed name")
    func keepsAVanishedSelection() async {
        let model = model(scan: { _ in ["Office"] })
        model.selected = "Home"
        await model.scan(session: .preview())
        #expect(model.selected == nil)
        #expect(model.manualSSID == "Home")
        #expect(model.ssid == "Home")
    }

    @Test("a selection the scan still lists is left alone")
    func keepsALivingSelection() async {
        let model = model(scan: { _ in ["Home", "Office"] })
        model.selected = "Home"
        await model.scan(session: .preview())
        #expect(model.selected == "Home")
        #expect(model.manualSSID.isEmpty)
    }

    @Test("what the robot accepted is what it is asked to join")
    func sendsTheForm() async {
        let sent = Sent()
        let model = model(join: { _, ssid, password, pin in sent.record(ssid, password, pin) })
        model.manualSSID = "Home"
        model.password = "hunter2"
        model.code = "AB12C"
        await model.send(session: .preview())
        #expect(sent.calls == [["Home", "hunter2", "AB12C"]])
        #expect(model.phase == .sent(ssid: "Home"))
        // Held no longer than the call that needed it.
        #expect(model.password.isEmpty)
    }

    @Test("a refusal keeps the form and names the reason")
    func reportsARefusal() async {
        let model = model(join: { _, _, _, _ in throw BLECommandError.badCredentials })
        model.manualSSID = "Home"
        model.password = "hunter2"
        model.code = "WRONG"
        await model.send(session: .preview())
        guard case let .refused(reason) = model.phase else {
            Issue.record("expected a refusal, got \(model.phase)")
            return
        }
        #expect(!reason.isEmpty)
        // Kept, unlike on the way to `.sent`: "Try again" under a footer blaming the
        // code should not also empty the password field.
        #expect(model.password == "hunter2")
        model.editAgain()
        #expect(model.phase == .editing)
    }

    /// Success here *is* the link going away, so a dropped connection is as likely to
    /// be a join that worked. Calling it a refusal sent people back to retype a
    /// password the robot had already accepted.
    @Test("a dropped link is neither a refusal nor a success")
    func separatesALostLinkFromARefusal() async {
        let model = model(join: { _, _, _, _ in throw URLError(.networkConnectionLost) })
        model.manualSSID = "Home"
        model.code = "AB12C"

        await model.send(session: .preview())

        #expect(model.phase == .uncertain(ssid: "Home"))
    }

    /// `RobotSession.message(for:)` answers nil for an abandoned call, and that means
    /// leave the screen alone. Overriding it with `??` put a red refusal panel over a
    /// form nobody had an answer about.
    @Test("an abandoned call leaves the form as it was")
    func reportsNothingForACancelledCall() async {
        let model = model(join: { _, _, _, _ in throw CancellationError() })
        model.manualSSID = "Home"
        model.code = "AB12C"

        await model.send(session: .preview())

        #expect(model.phase == .editing)
    }

    /// The list on screen is better than no list: a robot that answered once and then
    /// timed out has not stopped hearing those networks.
    @Test("a failed scan is reported without emptying the list")
    func keepsTheListWhenAScanFails() async {
        let attempts = Attempts()
        let model = model(scan: { _ in
            guard attempts.next() == 1 else { throw URLError(.timedOut) }
            return ["Home"]
        })
        let session = RobotSession.preview()
        await model.scan(session: session)
        #expect(model.networks == ["Home"])

        await model.scan(session: session)
        #expect(model.networks == ["Home"])
        #expect(model.scanFailure != nil)
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

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []

        func record(_ ssid: String, _ password: String, _ pin: String) {
            lock.withLock { recorded.append([ssid, password, pin]) }
        }

        var calls: [[String]] {
            lock.withLock { recorded }
        }
    }
}
