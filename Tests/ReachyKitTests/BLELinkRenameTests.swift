import Foundation
@testable import ReachyKit
import Testing

/// Naming the robot over Bluetooth. `SET_NAME` arrived in daemon 1.10.0 (#1298); a
/// 1.9.x robot echoes it back, and that echo is the only way to tell the two apart
/// before the robot is on a network. Replies are the strings `_set_robot_name` in the
/// 1.11.0 venv answers with.
@MainActor
@Suite("BLE link — naming the robot", .timeLimit(.minutes(1)))
struct BLELinkRenameTests {
    @Test("a 1.10 robot names itself and reports the name it stored")
    func namesTheRobot() async throws {
        let transport = FakeBLETransport()
        transport.script("SET_NAME kitchen reachy", read: "OK: working", notify: "OK: Named kitchen reachy")

        let outcome = try await BLELink(transport: transport).rename(to: "kitchen reachy")

        #expect(outcome == .named("kitchen reachy"))
    }

    @Test("a 1.9 robot echoes the command, which reads as unsupported rather than as a failure")
    func olderRobotCannotBeNamed() async throws {
        let transport = FakeBLETransport()
        transport.script("SET_NAME kitchen", read: "ECHO: SET_NAME kitchen")

        let outcome = try await BLELink(transport: transport).rename(to: "kitchen")

        #expect(outcome == .unsupported)
    }

    @Test("a name the daemon refuses is reported as such")
    func refusedName() async {
        let transport = FakeBLETransport()
        transport.script("SET_NAME x", read: "OK: working", notify: "ERROR: Invalid name")

        await #expect(throws: BLECommandError.invalidName) {
            _ = try await BLELink(transport: transport).rename(to: "x")
        }
    }

    @Test("naming needs the PIN session, like every command proxied to the daemon")
    func needsTheSession() {
        #expect(BLECommand.setName("x").needsSession)
        #expect(BLECommand.setName("kitchen reachy").wireFormat == "SET_NAME kitchen reachy")
    }
}
