import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// Handing the robot a copy of the account's token, and taking it away again.
///
/// Neither one is a single call: the robot is told, then asked what it now holds,
/// and the relay is worth reading back only when a reconnect actually started.
@MainActor
@Suite("Robot Hugging Face link", .timeLimit(.minutes(1)))
struct RobotHFLinkModelTests {
    private let online = RelayStatus(state: .connected, isConnected: true)
    private let off = RelayStatus(state: .stopped, isConnected: false)
    private let started = RelayRefresh(status: "requested", tokenAvailable: true)
    private let skipped = RelayRefresh(status: "skipped", tokenAvailable: true)

    /// The one path that reaches the robot with no token to give it.
    @Test("no token means no call")
    func refusesToLinkWithoutAToken() async {
        let attempts = Attempts()
        let model = RobotHFLinkModel(link: { _, _ in
            attempts.next()
            return started
        })
        await model.link(session: .preview(), token: nil)
        #expect(attempts.calls == 0)
        #expect(model.linkError != nil)
        #expect(!model.isLinking)
    }

    @Test("linking asks the robot what it now holds")
    func readsTheAccountBackAfterLinking() async {
        let sent = Recorded()
        let model = RobotHFLinkModel(
            account: { _, _ in HFAuthStatus(isLoggedIn: true, username: "alexey1312") },
            relay: { _ in online },
            link: { _, token in
                sent.record(token)
                return started
            }
        )
        await model.link(session: .preview(), token: "hf_token")
        #expect(sent.calls == ["hf_token"])
        #expect(model.isLinked)
        #expect(model.accountText == String(localized: .reachy("Linked to alexey1312")))
        #expect(model.relayCaption == String(localized: .reachy("Online")))
        #expect(model.linkError == nil)
    }

    /// `skipped` means no reconnect was started, so reading the relay back would
    /// report the state it had before the link — the daemon's own docstring calls
    /// that trap out by name.
    @Test("a skipped reconnect leaves the relay reading alone")
    func doesNotRereadASkippedRelay() async {
        let reads = Attempts()
        let model = RobotHFLinkModel(
            account: { _, _ in HFAuthStatus(isLoggedIn: true) },
            relay: { _ in
                reads.next()
                return off
            },
            link: { _, _ in skipped }
        )
        let session = RobotSession.preview()
        await model.load(session: session)
        #expect(reads.calls == 1)

        await model.link(session: session, token: "hf_token")
        #expect(reads.calls == 1)
        #expect(model.relay == off)
    }

    @Test("a started reconnect is read back")
    func rereadsAStartedRelay() async {
        let reads = Attempts()
        let model = RobotHFLinkModel(
            account: { _, _ in HFAuthStatus(isLoggedIn: true) },
            relay: { _ in
                reads.next() == 1 ? off : online
            },
            link: { _, _ in started }
        )
        let session = RobotSession.preview()
        await model.load(session: session)
        await model.link(session: session, token: "hf_token")
        #expect(reads.calls == 2)
        #expect(model.relay == online)
    }

    /// The `defer` is the point: a refused link must not leave the button disabled
    /// for the rest of the session.
    @Test("a refused link reports and frees the button")
    func reportsARefusedLink() async {
        let model = RobotHFLinkModel(link: { _, _ in throw URLError(.badServerResponse) })
        await model.link(session: .preview(), token: "hf_token")
        #expect(model.linkError != nil)
        #expect(!model.isLinking)
    }

    @Test("unlinking asks the robot what it now holds")
    func readsTheAccountBackAfterUnlinking() async {
        let unlinked = Attempts()
        let model = RobotHFLinkModel(
            account: { _, refresh in
                // The reading after an unlink must not come out of the daemon's cache,
                // which is the whole reason this call carries a flag.
                #expect(refresh)
                return HFAuthStatus(isLoggedIn: false)
            },
            relay: { _ in off },
            unlink: { _ in unlinked.next() }
        )
        await model.unlink(session: .preview())
        #expect(unlinked.calls == 1)
        #expect(!model.isLinked)
        #expect(model.accountText == String(localized: .reachy("Not linked")))
        #expect(model.linkError == nil)
    }

    /// A robot that has just dropped its token is a robot on its way off the relay,
    /// so the readings afterwards are allowed to fail. **The unlink itself
    /// succeeded**, and saying otherwise would invite the user to try again.
    @Test("readings that fail after an unlink are not reported as a failure")
    func swallowsTheReadingsAfterAnUnlink() async {
        let model = RobotHFLinkModel(
            account: { _, _ in throw URLError(.cannotConnectToHost) },
            relay: { _ in throw URLError(.cannotConnectToHost) },
            unlink: { _ in }
        )
        await model.unlink(session: .preview())
        #expect(model.linkError == nil)
        #expect(model.robotAccount == nil)
        #expect(model.relay == nil)
        #expect(model.accountText == "…")
    }

    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded = 0

        @discardableResult
        func next() -> Int {
            lock.withLock {
                recorded += 1
                return recorded
            }
        }

        var calls: Int {
            lock.withLock { recorded }
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
