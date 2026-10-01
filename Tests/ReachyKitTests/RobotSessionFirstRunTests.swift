import Foundation
@testable import ReachyKit
import Testing

/// When the session offers the first run and when it tells the robot it is over
/// (#169): read during a relay connect, written where the run ends, and nowhere else.
///
/// Driven through a real `RemoteRobotConnection` over a scripted channel rather
/// than a hand-rolled `FirstWakeUpClient`, so the version gate is the session's
/// own reading of `get_version` — the same path a relayed robot takes.
@MainActor
@Suite("First run", .timeLimit(.minutes(1)))
struct RobotSessionFirstRunTests {
    private static func replies(
        version: String = "1.11.0",
        motorMode: String = "disabled",
        completed: Bool? = false
    ) -> [String: String] {
        var replies = [
            "get_version": #"{"version":"\#(version)"}"#,
            "get_hardware_id": #"{"hardware_id":"hw-relay"}"#,
            "get_state": #"{"state":{"motor_mode":"\#(motorMode)","is_move_running":false}}"#,
            "set_motor_mode": #"{"motor_mode":"enabled","status":"ok"}"#,
            "wake_up": #"{"status":"ok","command":"wake_up","completed":true}"#,
            "set_first_wake_up": #"{"command":"set_first_wake_up","status":"ok","is_completed":true}"#,
        ]
        if let completed {
            replies["get_first_wake_up"] = #"{"command":"get_first_wake_up","is_completed":\#(completed)}"#
        }
        return replies
    }

    private func session() -> RobotSession {
        var configuration = RobotSession.Configuration()
        configuration.motorSettleDelay = .milliseconds(1)
        return RobotSession(configuration: configuration) { _ in
            Issue.record("a relayed session must not dial an address")
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
    }

    private func connectedSession(over channel: FakeDataChannel) async -> RobotSession {
        let session = session()
        await session.connect(using: RemoteRobotConnection(channel: channel, timeout: .seconds(5)))
        #expect(session.client != nil)
        return session
    }

    /// Parsed rather than matched as text, so neither key order nor the encoder's
    /// spacing can make an assertion pass or fail.
    private func sent(_ command: String, on channel: FakeDataChannel) -> [[String: Any]] {
        channel.sent
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { $0["type"] as? String == command }
    }

    // MARK: - The offer

    @Test("a robot nobody has woken is offered the first run")
    func offersAFreshRobot() async {
        let channel = FakeDataChannel(replies: Self.replies(completed: false))
        let session = await connectedSession(over: channel)

        #expect(session.offersFirstRun)
        #expect(sent("get_first_wake_up", on: channel).count == 1)
        guard case .connected = session.phase else {
            Issue.record("the first run stands in for the shell; the connection still completes")
            return
        }
    }

    @Test("a robot already through its first wake-up goes straight to the shell")
    func skipsAMarkedRobot() async {
        let channel = FakeDataChannel(replies: Self.replies(completed: true))
        let session = await connectedSession(over: channel)

        #expect(!session.offersFirstRun)
        #expect(sent("set_first_wake_up", on: channel).isEmpty)
    }

    /// 1.9.x is supported and reachable over the relay, and answers an unknown
    /// command with an `error` naming no command — a waiter nothing ever matches,
    /// which here would hold the connect gate for the whole reply budget.
    @Test("a daemon before 1.10.0 is never asked")
    func skipsAnOlderDaemon() async {
        let channel = FakeDataChannel(replies: Self.replies(version: "1.9.0", completed: false))
        let session = await connectedSession(over: channel)

        #expect(!session.offersFirstRun)
        #expect(sent("get_first_wake_up", on: channel).isEmpty)
    }

    /// Nothing on screen asked for the flag, so nothing on screen hears about it —
    /// and a robot that cannot answer is not shown a setup it may long since have had.
    @Test("a robot that cannot answer about the flag connects without an offer or an error")
    func swallowsAFailedRead() async {
        var replies = Self.replies(completed: nil)
        replies["get_first_wake_up"] = #"{"command":"get_first_wake_up","error":"storage unavailable"}"#
        let channel = FakeDataChannel(replies: replies)
        let session = await connectedSession(over: channel)

        #expect(!session.offersFirstRun)
        #expect(session.robotError == nil)
        guard case .connected = session.phase else {
            Issue.record("a failed read must not fail the connection")
            return
        }
    }

    /// The fork under the root picks the first run or the shell on `.connected`, so a
    /// flag read after that would draw the shell for a moment and then take it away.
    @Test("the flag is read before the connection completes")
    func readsBeforeConnecting() async throws {
        var replies = Self.replies()
        replies["get_first_wake_up"] = nil
        let channel = FakeDataChannel(replies: replies)
        let session = session()

        let connecting = Task {
            await session.connect(using: RemoteRobotConnection(channel: channel, timeout: .seconds(5)))
        }
        try await waitUntil("the flag is asked about") {
            !sent("get_first_wake_up", on: channel).isEmpty
        }
        guard case .connecting = session.phase else {
            Issue.record("the gate came down before the flag was known: \(session.phase)")
            return
        }
        channel.emit(#"{"command":"get_first_wake_up","is_completed":false}"#)
        await connecting.value

        #expect(session.offersFirstRun)
    }

    // MARK: - The wake no longer marks the robot

    /// #157 marked the robot here; the first run now wakes it partway through, and a
    /// mark at that moment would end the run's claim before its last step.
    @Test("waking the robot does not touch the flag")
    func wakingIsNotTheEnd() async {
        let channel = FakeDataChannel(replies: Self.replies(completed: false))
        let session = await connectedSession(over: channel)

        await session.wake()

        #expect(sent("get_first_wake_up", on: channel).count == 1, "the connect's read and no other")
        #expect(sent("set_first_wake_up", on: channel).isEmpty)
        #expect(session.offersFirstRun)
    }

    // MARK: - The end

    @Test("finishing marks the robot once and hands over to the shell")
    func finishingMarksTheRobot() async throws {
        let channel = FakeDataChannel(replies: Self.replies(completed: false))
        let session = await connectedSession(over: channel)

        await session.finishFirstRun()
        await session.finishFirstRun()

        #expect(!session.offersFirstRun)
        let writes = sent("set_first_wake_up", on: channel)
        #expect(writes.count == 1)
        let write = try #require(writes.first)
        #expect(write["is_completed"] as? Bool == true)
    }

    /// Bookkeeping the owner never sees must not hold them on the last screen — not
    /// for a round trip, and not for a whole reply budget on a relay gone quiet.
    @Test("the shell takes over before the robot has answered the write")
    func withdrawsBeforeWriting() async throws {
        var replies = Self.replies(completed: false)
        replies["set_first_wake_up"] = nil
        let channel = FakeDataChannel(replies: replies)
        let session = await connectedSession(over: channel)

        let finishing = Task { await session.finishFirstRun() }
        try await waitUntil("the write is on its way") {
            !sent("set_first_wake_up", on: channel).isEmpty
        }

        #expect(!session.offersFirstRun)
        channel.emit(#"{"command":"set_first_wake_up","status":"ok","is_completed":true}"#)
        await finishing.value
    }

    /// A failed write answers `"status": "error"` with the value still on disk. The
    /// robot stays new and the next connect offers the run again; this one is over.
    @Test("a write the robot could not store still ends this run, without an error")
    func survivesARefusedWrite() async {
        var replies = Self.replies(completed: false)
        replies["set_first_wake_up"] = #"{"command":"set_first_wake_up","status":"error","is_completed":false}"#
        let channel = FakeDataChannel(replies: replies)
        let session = await connectedSession(over: channel)

        await session.finishFirstRun()

        #expect(!session.offersFirstRun)
        #expect(session.robotError == nil)
        #expect(sent("set_first_wake_up", on: channel).count == 1)
    }

    @Test("a robot that was never offered the run is never written to")
    func leavesAnUnofferedRobotAlone() async {
        let channel = FakeDataChannel(replies: Self.replies(completed: true))
        let session = await connectedSession(over: channel)

        await session.finishFirstRun()

        #expect(sent("set_first_wake_up", on: channel).isEmpty)
    }

    /// A disconnect halfway through is not a finish: the robot stays new, and the
    /// next connect — possibly to another robot — decides afresh.
    @Test("disconnecting withdraws the offer and writes nothing")
    func disconnectingIsNotFinishing() async {
        let channel = FakeDataChannel(replies: Self.replies(completed: false))
        let session = await connectedSession(over: channel)

        session.disconnect()

        #expect(!session.offersFirstRun)
        #expect(sent("set_first_wake_up", on: channel).isEmpty)
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
    }
}
