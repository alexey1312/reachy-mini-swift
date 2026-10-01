import Foundation
@testable import ReachyKit
import Testing

/// What the first run asks of the relay beyond the flag (#169): the test sound, and
/// the motor-by-motor pose the sleep-position check reads.
@Suite("The first run over the relay", .timeLimit(.minutes(1)))
struct RemoteRobotFirstRunTests {
    /// The LAN route is `backend.play_sound("impatient1.wav")` and nothing else; the
    /// data channel's `play_sound {file}` reaches the same method on every daemon
    /// this app supports.
    @Test("the test sound plays the file the LAN route plays")
    func playsTheTestSound() async throws {
        let channel = FakeDataChannel(replies: [
            "play_sound": #"{"status":"ok","command":"play_sound"}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        try await connection.playTestSound()

        let sent = try JSONSerialization.jsonObject(with: Data(#require(channel.sent.first).utf8)) as? [String: Any]
        #expect(sent?["type"] as? String == "play_sound")
        #expect(sent?["file"] as? String == "impatient1.wav")
    }

    @Test("a relayed session offers the test sound")
    @MainActor
    func offersTheTestSound() async {
        let channel = FakeDataChannel(replies: [
            "get_version": #"{"version":"1.9.0"}"#,
            "get_hardware_id": #"{"hardware_id":"hw-relay"}"#,
            "get_state": #"{"state":{"motor_mode":"disabled","is_move_running":false}}"#,
        ])
        let session = RobotSession { _ in throw ReachyKitError.wirelessFeaturesUnavailable }
        await session.connect(using: RemoteRobotConnection(channel: channel, timeout: .seconds(5)))

        #expect(session.canPlayTestSound)
    }

    /// Daemon 1.10.0 put the seven head motors on the snapshot so a peer can check
    /// the pose motor by motor; it is the socket's `head_joints` under another name.
    @Test("the snapshot's head motors reach the frame")
    func readsTheHeadMotors() async throws {
        let channel = FakeDataChannel(replies: [
            "get_state": #"""
            {"state":{"head_pose":[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],"antennas":[-3.05,3.05],
            "head_joint_positions":[0,-0.17,0.84,-0.12,0.09,-0.81,0.18],"body_yaw":0,
            "motor_mode":"disabled","is_recording":false,"is_move_running":false}}
            """#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        let frame = try #require(try await connection.stateFrame())

        #expect(frame.headJoints == [0, -0.17, 0.84, -0.12, 0.09, -0.81, 0.18])
        #expect(frame.antennas == [-3.05, 3.05])
    }

    @Test("an older snapshot without them leaves the frame's head motors empty")
    func toleratesTheirAbsence() async throws {
        let channel = FakeDataChannel(replies: [
            "get_state": #"{"state":{"antennas":[0.1,-0.1],"body_yaw":0,"motor_mode":"enabled"}}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        let frame = try #require(try await connection.stateFrame())

        #expect(frame.headJoints == nil)
    }
}
