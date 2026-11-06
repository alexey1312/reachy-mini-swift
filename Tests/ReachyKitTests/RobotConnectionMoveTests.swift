import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// `POST /api/move/goto`, which is the only "return to base" this app has.
@Suite("Moves over HTTP", .timeLimit(.minutes(1)))
struct RobotConnectionMoveTests {
    private func makeConnection(_ session: URLSession) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)
    }

    /// The daemon's own zero, and the reason it is not `[0, 0]`:
    /// `reachy_mini.INIT_ANTENNAS_JOINT_POSITIONS` is `[-0.1745, 0.1745]`, carrying
    /// the comment "to reduce shaking at vertical", and it is what the daemon sends
    /// when it parks the robot itself. Two definitions of base would put a stopped
    /// dance and a stopped app in visibly different poses.
    @Test("the neutral pose is the daemon's own zero")
    func neutralAntennasMatchTheDaemon() {
        #expect(RobotConnection.zeroAntennas == [-0.1745, 0.1745])
    }

    /// From 1.14.0 a play over another move still answers 200 with a task id, and the
    /// task fails at once. The route registers it before answering, so a task already
    /// off the list never played. `moveRoutesWaitOutADownload` below shows that a list
    /// that cannot be read leaves the play standing.
    @Test("a play that is gone from the list at once was refused")
    func aPlayGoneFromTheListWasRefused() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/move/play/recorded-move-dataset/library/happy": .init(statusCode: 200, json: #"{"uuid": "move-1"}"#),
            "/api/move/running": .init(statusCode: 200, json: #"[]"#),
        ])

        await #expect(throws: ReachyKitError.moveBusy) {
            _ = try await makeConnection(session).playMove(dataset: "library", move: "happy")
        }
    }

    @Test("a play on the list is the move that started")
    func aPlayOnTheListStarted() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/move/play/recorded-move-dataset/library/happy": .init(statusCode: 200, json: #"{"uuid": "move-1"}"#),
            "/api/move/running": .init(statusCode: 200, json: #"[{"uuid": "move-1"}]"#),
        ])

        #expect(try await makeConnection(session).playMove(dataset: "library", move: "happy") == "move-1")
    }

    /// The order `RobotPower.sleep()` depends on: a refused sleep has to throw before
    /// the motors are cut, or the head drops in the middle of the other move.
    @Test("a sleep that is gone from the list at once was refused")
    func aSleepGoneFromTheListWasRefused() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/move/play/goto_sleep": .init(statusCode: 200, json: #"{"uuid": "move-1"}"#),
            "/api/move/running": .init(statusCode: 200, json: #"[]"#),
        ])

        await #expect(throws: ReachyKitError.moveBusy) {
            _ = try await makeConnection(session).gotoSleep()
        }
    }

    /// `wake_up` stands down at once on a robot already awake at the zero pose, so an
    /// empty list there says nothing. Nothing is read back.
    @Test("a wake-up is not read back")
    func aWakeUpIsNotReadBack() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/move/play/wake_up": .init(statusCode: 200, json: #"{"uuid": "move-1"}"#),
            "/api/move/running": .init(statusCode: 200, json: #"[]"#),
        ])

        #expect(try await makeConnection(session).wakeUp() == "move-1")
    }

    /// The constant and the call are asserted separately on purpose: changing one
    /// without the other is the mistake, and only the wire form catches it.
    ///
    /// Every axis is named explicitly because an omitted `GotoModelRequest` field
    /// means "leave that one where it is", which for a return to base is the one
    /// thing it must not mean.
    @Test("goto sends every axis, with the daemon's antenna pair")
    func gotoNeutralSendsTheWholeZeroPose() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/move/goto": .init(statusCode: 200, json: #"{"uuid": "move-1"}"#),
        ])

        let uuid = try await makeConnection(session).gotoNeutral(duration: 1)

        #expect(uuid == "move-1")
        let body = try #require(StubURLProtocol.bodies(for: session).first)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["antennas"] as? [Double] == [-0.1745, 0.1745])
        #expect(sent["body_yaw"] as? Double == 0)
        let head = try #require(sent["head_pose"] as? [String: Any])
        #expect(head.count == 6)
        #expect(["x", "y", "z", "roll", "pitch", "yaw"].allSatisfy { head[$0] as? Double == 0 })
    }

    /// Both routes build `RecordedMoves(dataset)` before they answer, which
    /// downloads a dataset the daemon has not cached; a cold load of the Music
    /// library took about 15 s. The server answers after four seconds — past the
    /// 3.5 s health-poll budget and well inside the 35 s Hub one — so a route left
    /// on the short client times out here, as it did while the robot went on to
    /// play the move. No injected session: that would replace the very budget
    /// under test.
    @Test("the move index and the play wait out a dataset download")
    func moveRoutesWaitOutADownload() async throws {
        let server = try SlowHTTPServer(delay: .seconds(4)) { path in
            path.hasPrefix("/api/move/play/") ? #"{"uuid": "move-1"}"# : #"["happy"]"#
        }
        defer { server.stop() }
        let port = try await server.readyPort()
        let connection = try RobotConnection(address: RobotAddress(host: "127.0.0.1", port: Int(port)))

        async let moves = connection.listMoves(dataset: "Anne-Charlotte/music")
        async let uuid = connection.playMove(dataset: "Anne-Charlotte/music", move: "happy")

        #expect(try await moves == ["happy"])
        #expect(try await uuid == "move-1")
    }
}
