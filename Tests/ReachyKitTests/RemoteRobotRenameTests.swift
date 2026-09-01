import Foundation
@testable import ReachyKit
import Testing

/// Renaming over the relay: daemon 1.10.0 carries `set_robot_name` on the data
/// channel, where the HTTP route the LAN path uses cannot be reached.
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

    /// The handshake alone says no — no HTTP route answers over the relay — so the
    /// transport conformance is the only thing that opens the field. Asserted
    /// through the session, because a bare `is` check is a fact the compiler
    /// already proved and would survive the flag being dropped.
    @MainActor
    @Test("the session offers renaming over the relay")
    func sessionOffersRenaming() async {
        let session = RobotSession()
        let connection = RemoteRobotConnection(
            channel: FakeDataChannel(replies: [
                "get_version": #"{"version":"1.10.0"}"#,
                "get_hardware_id": #"{"hardware_id":"hw-relay"}"#,
                "get_state": #"{"state":{"motor_mode":"enabled"}}"#,
            ]),
            timeout: .seconds(5)
        )

        await session.connect(using: connection)

        #expect(session.supportsRename)
    }
}
