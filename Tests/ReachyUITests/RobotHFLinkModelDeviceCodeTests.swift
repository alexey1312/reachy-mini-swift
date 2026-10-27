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
        status: (@MainActor (RobotSession, RobotDeviceLogin) async throws -> RobotDeviceLoginStatus)? = nil,
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
                status: status ?? { _, _ in script.next() },
                cancel: { _, _ in cancelled?.cancel() },
                pause: pause
            )
        )
    }

    @Test("an approved code links the robot and reads its account back")
    func linksOnceApproved() async {
        let cancelled = Script([])
        let model = model(
            start: login,
            readings: [.pending, .pending, .authorized(username: "alexey1312")],
            cancelled: cancelled
        )
        var opened: [URL] = []

        await model.linkWithDeviceCode(session: .preview()) { opened.append($0) }

        // The pre-filled page, so the person confirms rather than types.
        #expect(opened == [login.verificationURIComplete])
        #expect(model.isLinked)
        #expect(model.relayCaption == String(localized: .reachy("Online")))
        #expect(model.linkError == nil)
        #expect(model.deviceLogin == nil)
        #expect(!model.isLinking)
        // Success is the one way out that leaves the robot's sign-in alone.
        #expect(cancelled.cancellations == 0)
    }

    @Test("the robot links through hf.co", arguments: [false, true])
    func linksThroughTheShortDomain(prefilled: Bool) async throws {
        let page = try #require(URL(string: "https://hf.co/oauth/device"))
        let complete = try #require(URL(string: "https://hf.co/oauth/device?user_code=WDJB-MJHT"))
        let login = RobotDeviceLogin(
            sessionID: "abc",
            userCode: "WDJB-MJHT",
            verificationURI: page,
            verificationURIComplete: prefilled ? complete : nil
        )
        let model = model(start: login, readings: [.authorized(username: "alexey1312")])
        var opened: [URL] = []

        await model.linkWithDeviceCode(session: .preview()) { opened.append($0) }

        #expect(opened == [prefilled ? complete : page])
        #expect(model.isLinked)
        #expect(model.linkError == nil)
    }

    /// Anything on the network can answer as a robot, and the page is opened under
    /// a button that reads "Open huggingface.co".
    @Test("a sign-in page that is not Hugging Face's is not opened, and the robot is stopped")
    func refusesAPageOffTheHub() async throws {
        let cancelled = Script([])
        let spoofed = try RobotDeviceLogin(
            sessionID: "abc",
            userCode: "WDJB-MJHT",
            verificationURI: #require(URL(string: "https://huggingface-login.example/device"))
        )
        let model = model(start: spoofed, readings: [.authorized(username: "alexey1312")], cancelled: cancelled)
        var opened: [URL] = []

        await model.linkWithDeviceCode(session: .preview()) { opened.append($0) }

        #expect(opened.isEmpty)
        #expect(model.linkError == RobotHFLinkModel.untrustedPageText)
        #expect(model.deviceLogin == nil)
        #expect(cancelled.cancellations == 1)
    }

    @Test("a code that ran out says so")
    func reportsAnExpiredCode() async {
        let cancelled = Script([])
        let model = model(start: login, readings: [.pending, .expired(message: nil)], cancelled: cancelled)

        await model.linkWithDeviceCode(session: .preview()) { _ in }

        #expect(model.linkError == String(localized: .reachy(
            "The code expired before it was approved. Link the robot again."
        )))
        #expect(!model.isLinked)
        #expect(cancelled.cancellations == 1)
    }

    /// Daemon 1.12 answers a failed sign-in with one of a few fixed sentences
    /// (pollen-robotics/reachy_mini#1363), and the card translates them.
    @Test("a refusal the daemon words is shown in this app's words")
    func reportsTheHubsRefusal() async {
        let model = model(start: login, readings: [.failed(message: "Authorization was denied.")])

        await model.linkWithDeviceCode(session: .preview()) { _ in }

        #expect(model.linkError == String(localized: .reachy("The sign-in was denied on huggingface.co.")))
    }

    /// A daemon before 1.12 could put the provider's own text here, and upstream
    /// stopped because that text could carry credentials.
    @Test("text the daemon did not word is replaced, not shown")
    func hidesUnknownText() async {
        let model = model(start: login, readings: [.failed(message: "access_denied: token hf_leak")])

        await model.linkWithDeviceCode(session: .preview()) { _ in }

        #expect(model.linkError == RobotHFFailureCaption.general)
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

    /// A Cancel lands far more often in the reading than in the pause: on a robot the
    /// reading is a network round trip, and in a test the pause is no wait at all.
    /// The robot must still hear it, and from a task that is not cancelled — a
    /// request made from a cancelled task never leaves.
    @Test("a cancel during a reading still tells the robot to stop")
    func cancelsOnTheRobotMidReading() async {
        let cancelled = Script([])
        let model = model(
            start: login,
            status: { _, _ in
                cancelled.noteReading()
                try await Task.sleep(for: .seconds(60))
                return .pending
            },
            cancelled: cancelled
        )

        model.beginDeviceLogin(session: .preview()) { _ in }
        await waitUntil("the robot is being read") { cancelled.readsStarted > 0 }
        model.cancelDeviceLogin()
        await waitUntil("the card stops waiting") { model.deviceLogin == nil }

        #expect(cancelled.cancellations == 1)
        #expect(!cancelled.cancelledFromACancelledTask)
        #expect(model.linkError == nil)
        #expect(!model.isLinking)
    }

    /// A robot that stopped answering may still be polling the Hub, and a code that
    /// nobody waits for could link it later.
    @Test("a failed reading reports it and tells the robot to stop")
    func cancelsOnTheRobotAfterAFailedReading() async {
        let cancelled = Script([])
        let model = model(
            start: login,
            status: { _, _ in throw URLError(.timedOut) },
            cancelled: cancelled
        )

        await model.linkWithDeviceCode(session: .preview()) { _ in }

        #expect(model.linkError != nil)
        #expect(cancelled.cancellations == 1)
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
        private var cancelledInCancelledTask = false
        private var started = 0

        init(_ readings: [RobotDeviceLoginStatus]) {
            self.readings = readings
        }

        func next() -> RobotDeviceLoginStatus {
            lock.withLock { readings.count > 1 ? readings.removeFirst() : readings.first ?? .pending }
        }

        func noteReading() {
            lock.withLock { started += 1 }
        }

        /// Notes whether the robot-side cancel ran in a cancelled task, where a real
        /// request would be cancelled before it left.
        func cancel() {
            let isCancelled = Task.isCancelled
            lock.withLock {
                cancelled += 1
                cancelledInCancelledTask = cancelledInCancelledTask || isCancelled
            }
        }

        var cancellations: Int {
            lock.withLock { cancelled }
        }

        var cancelledFromACancelledTask: Bool {
            lock.withLock { cancelledInCancelledTask }
        }

        var readsStarted: Int {
            lock.withLock { started }
        }
    }
}
