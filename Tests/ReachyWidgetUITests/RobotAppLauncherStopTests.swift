import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// From daemon 1.14.0 a stop ends with the robot awake in the zero pose, the daemon's
/// own work (pollen-robotics/reachy_mini#1488). A promise of sleep would be false, and
/// a `goto` would add nothing.
@Suite("Robot app launcher on daemon 1.14", .timeLimit(.minutes(1)))
struct RobotAppLauncherStopTests {
    @Test("a stop promises no sleep and sends nothing after it", arguments: [false, true])
    func aStopIsTheWholeOfIt(noMedia: Bool) async throws {
        let client = StubAppsClient()
        client.daemonVersion = "1.14.0"
        client.noMedia = noMedia ? true : nil
        client.running = StubAppsClient.status(name: "dance_party")
        let launcher = try await RobotAppLauncher(client: client, assumeAwake: nil, handshake: client.handshake())

        let outcome = try await launcher.stop()

        #expect(outcome == .stopped(name: "dance_party", robotSleeps: false))
        #expect(client.calls == [.currentAppStatus, .stopCurrentApp])
    }
}
