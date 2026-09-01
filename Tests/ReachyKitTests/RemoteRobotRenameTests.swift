import Foundation
@testable import ReachyKit
import Testing

/// Renaming used to be LAN-only, because the only way to do it was an HTTP route.
/// Daemon 1.10.0 put it on the data channel.
@Suite("Renaming over the relay", .timeLimit(.minutes(1)))
struct RemoteRobotRenameTests {
    @Test("the new name goes out as a channel command")
    func sendsTheRename() async throws {
        let channel = FakeDataChannel(replies: [
            "set_robot_name": #"{"robot_name":"attic"}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        let stored = try await connection.setRobotName("attic")

        #expect(stored == "attic")
        let sent = try #require(channel.sent.first)
        #expect(sent.contains("set_robot_name"))
        #expect(sent.contains("attic"))
    }

    /// The name the robot settled on, not the one that was asked for: the daemon
    /// is free to normalise it, and reporting the request back would show a name
    /// the robot does not have.
    @Test("the robot's answer is what is reported")
    func reportsWhatTheRobotSettledOn() async throws {
        let channel = FakeDataChannel(replies: [
            "set_robot_name": #"{"robot_name":"attic-2"}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        #expect(try await connection.setRobotName("Attic 2") == "attic-2")
    }

    /// What the session reads to decide whether to offer the control at all — the
    /// relay's own handshake says no, because no HTTP route answers there.
    @Test("the transport says it can rename")
    func declaresTheCapability() {
        let connection = RemoteRobotConnection(channel: FakeDataChannel(), timeout: .seconds(5))
        #expect(connection is any RobotRenameClient)
    }
}
