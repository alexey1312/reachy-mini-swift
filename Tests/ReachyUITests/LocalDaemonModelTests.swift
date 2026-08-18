import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The one question the local-daemon row asks: is anything serving here.
///
/// The section itself is mounted under `#if os(macOS)` and no reference image can
/// cover that mount point — the snapshot suite runs on an iOS simulator — so this
/// suite is where the behaviour behind the row is held.
@MainActor
@Suite("Local daemon", .timeLimit(.minutes(1)))
struct LocalDaemonModelTests {
    @Test("a daemon that answers shows as reachable")
    func reachable() async {
        let model = LocalDaemonModel(interval: .milliseconds(20)) { _ in true }

        model.start()
        await waitUntil("the daemon is reachable") { model.status == .reachable }
        model.stop()
    }

    @Test("nothing answering shows as not responding")
    func unreachable() async {
        let model = LocalDaemonModel(interval: .milliseconds(20)) { _ in false }

        model.start()
        await waitUntil("the daemon is unreachable") { model.status == .unreachable }
        model.stop()
    }

    /// The row is mounted for the whole life of the gate, so an answer already on
    /// screen has to survive the screen going away and coming back — otherwise a
    /// reader who has been told there is nothing here gets a spinner instead, for
    /// the ten seconds until the next probe.
    @Test("stopping keeps the last answer rather than resetting to checking")
    func stopKeepsTheAnswer() async {
        let model = LocalDaemonModel(interval: .milliseconds(20)) { _ in false }

        model.start()
        await waitUntil("the daemon is unreachable") { model.status == .unreachable }
        model.stop()

        #expect(model.status == .unreachable)
    }

    /// Loopback, and the port the daemon serves on by default. Pinned because the
    /// row has no address field: this constant *is* what "on this computer" means,
    /// and a wrong one would look exactly like a daemon that is not running.
    @Test("the address probed is loopback on the daemon's own port")
    func probesLoopback() {
        #expect(LocalDaemonModel.loopback.host == "127.0.0.1")
        #expect(LocalDaemonModel.loopback.port == RobotAddress.defaultPort)
    }
}
