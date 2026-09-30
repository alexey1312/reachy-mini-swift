import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The robot signing itself in with a device code (daemon 1.10.0,
/// pollen-robotics/reachy_mini#1223): it asks the Hub for a code, a person
/// approves it in a browser, and the card reads the robot's progress until it
/// holds a token. The approval is the browser's, so these script the robot's side.
@MainActor
@Suite("Robot Hugging Face link — device code", .timeLimit(.minutes(1)))
struct RobotHFLinkModelDeviceCodeTests {
    private let login = RobotDeviceLogin(
        sessionID: "abc",
        userCode: "WDJB-MJHT",
        verificationURI: URL(string: "https://huggingface.co/device")!,
        verificationURIComplete: URL(string: "https://huggingface.co/device?user_code=WDJB-MJHT")!,
        interval: .seconds(5),
        expiresIn: .seconds(900)
    )

    private func model(
        start: RobotDeviceLogin? = nil,
        readings: [RobotDeviceLoginStatus] = [],
        pause: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        cancelled: Script? = nil
    ) -> RobotHFLinkModel {
        let script = Script(readings)
        return RobotHFLinkModel(
            account: { _, _ in HFAuthStatus(isLoggedIn: true, username: "alexey1312") },
            relay: { _ in RelayStatus(state: .connected, isConnected: true) },
            deviceCode: .init(
                start: { _ in
                    guard let start else { throw ReachyKitError.daemonRejected(statusCode: 404) }
                    return start
                },
                status: { _, _ in script.next() },
                cancel: { _, _ in cancelled?.cancel() },
                pause: pause
            )
        )
    }

    @Test("an approved code links the robot and reads its account back")
    func linksOnceApproved() async {
        let model = model(start: login, readings: [.pending, .pending, .authorized(username: "alexey1312")])
        var opened: [URL] = []

        await model.linkWithDeviceCode(session: .preview()) { opened.append($0) }

        // The pre-filled page, so the person confirms rather than types.
        #expect(opened == [login.verificationURIComplete])
        #expect(model.isLinked)
        #expect(model.relayCaption == String(localized: .reachy("Online")))
        #expect(model.linkError == nil)
        #expect(model.deviceLogin == nil)
        #expect(!model.isLinking)
    }

    @Test("a code that ran out says so")
    func reportsAnExpiredCode() async {
        let model = model(start: login, readings: [.pending, .expired(message: nil)])

        await model.linkWithDeviceCode(session: .preview()) { _ in }

        #expect(model.linkError == String(localized: .reachy(
            "The code expired before it was approved. Link the robot again."
        )))
        #expect(!model.isLinked)
    }

    /// The Hub's own words, by way of the robot — runtime text, so the slot stays a
    /// `String` (rule 9).
    @Test("a refusal from the Hub is shown in its own words")
    func reportsTheHubsRefusal() async {
        let model = model(start: login, readings: [.failed(message: "access_denied")])

        await model.linkWithDeviceCode(session: .preview()) { _ in }

        #expect(model.linkError == "access_denied")
    }

    /// Stopping must reach the robot, or it goes on polling the Hub for a code
    /// nobody will ever enter.
    @Test("cancelling tells the robot to stop, and reports nothing")
    func cancelsOnTheRobot() async {
        let cancelled = Script([])
        let model = model(start: login, pause: { _ in throw CancellationError() }, cancelled: cancelled)

        await model.linkWithDeviceCode(session: .preview()) { _ in }

        #expect(cancelled.cancellations == 1)
        #expect(model.linkError == nil)
        #expect(model.deviceLogin == nil)
    }

    /// A daemon before 1.10.0 does not mount the route. Nothing is opened: a browser
    /// page for a code that does not exist is worse than the error.
    @Test("a robot that cannot start one opens nothing")
    func opensNothingWhenTheRobotRefuses() async {
        let model = model(start: nil)
        var opened: [URL] = []

        await model.linkWithDeviceCode(session: .preview()) { opened.append($0) }

        #expect(opened.isEmpty)
        #expect(model.linkError != nil)
        #expect(!model.isLinking)
    }

    /// The robot's side of the sign-in, one reading at a time. Keeps answering the
    /// last reading once the script runs out, the way a robot left pending would.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [RobotDeviceLoginStatus]
        private var cancelled = 0

        init(_ readings: [RobotDeviceLoginStatus]) {
            self.readings = readings
        }

        func next() -> RobotDeviceLoginStatus {
            lock.withLock { readings.count > 1 ? readings.removeFirst() : readings.first ?? .pending }
        }

        func cancel() {
            lock.withLock { cancelled += 1 }
        }

        var cancellations: Int {
            lock.withLock { cancelled }
        }
    }
}
