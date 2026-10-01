import Foundation
@testable import ReachyKit
import Testing

/// When the session tells the robot it has met its owner (#157): after the first
/// wake-up this app performs, over the one transport that can store it.
///
/// Driven through a real `RemoteRobotConnection` over a scripted channel rather
/// than a hand-rolled `FirstWakeUpClient`, so the version gate is the session's
/// own reading of `get_version` — the same path a relayed robot takes.
@MainActor
@Suite("First wake-up", .timeLimit(.minutes(1)))
struct RobotSessionFirstWakeUpTests {
    private static func replies(
        version: String = "1.11.0",
        motorMode: String = "enabled",
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

    private func connectedSession(over channel: FakeDataChannel) async -> RobotSession {
        var configuration = RobotSession.Configuration()
        configuration.motorSettleDelay = .milliseconds(1)
        let session = RobotSession(configuration: configuration) { _ in
            Issue.record("a relayed session must not dial an address")
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
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

    @Test("a robot nobody has woken is marked once this app wakes it")
    func marksAFreshRobot() async throws {
        let channel = FakeDataChannel(replies: Self.replies(completed: false))
        let session = await connectedSession(over: channel)

        await session.wake()

        #expect(sent("get_first_wake_up", on: channel).count == 1)
        let write = try #require(sent("set_first_wake_up", on: channel).first)
        #expect(write["is_completed"] as? Bool == true)
    }

    /// Read before written: a robot already through its first wake-up — here or in
    /// Pollen's app — is a disk write on the robot that buys nothing.
    @Test("a robot already marked is read and left alone")
    func leavesAMarkedRobotAlone() async {
        let channel = FakeDataChannel(replies: Self.replies(completed: true))
        let session = await connectedSession(over: channel)

        await session.wake()

        #expect(sent("get_first_wake_up", on: channel).count == 1)
        #expect(sent("set_first_wake_up", on: channel).isEmpty)
    }

    /// Connecting proves the robot is online, not that anybody has met it.
    @Test("connecting alone does not touch the flag")
    func connectingIsNotAWakeUp() async {
        let channel = FakeDataChannel(replies: Self.replies(completed: false))
        _ = await connectedSession(over: channel)

        #expect(sent("get_first_wake_up", on: channel).isEmpty)
    }

    /// 1.9.x is supported and reachable over the relay, and answers an unknown
    /// command with an `error` naming no command — a waiter nothing ever matches.
    @Test("a daemon before 1.10.0 is never asked")
    func skipsAnOlderDaemon() async {
        let channel = FakeDataChannel(replies: Self.replies(version: "1.9.0", completed: false))
        let session = await connectedSession(over: channel)

        await session.wake()

        #expect(sent("wake_up", on: channel).count == 1)
        #expect(sent("get_first_wake_up", on: channel).isEmpty)
        #expect(sent("set_first_wake_up", on: channel).isEmpty)
    }

    @Test("a wake the robot refused records nothing")
    func skipsAFailedWake() async {
        var replies = Self.replies(completed: false)
        replies["wake_up"] = #"{"error":"Backend not running","command":"wake_up"}"#
        let channel = FakeDataChannel(replies: replies)
        let session = await connectedSession(over: channel)

        await session.wake()

        #expect(session.robotError != nil)
        #expect(sent("get_first_wake_up", on: channel).isEmpty)
    }

    /// The motors never came on, so whatever the animation did, nobody met a
    /// robot that stood up.
    @Test("a robot that still reads asleep after waking is not marked")
    func skipsARobotThatStayedAsleep() async {
        let channel = FakeDataChannel(replies: Self.replies(motorMode: "disabled", completed: false))
        let session = await connectedSession(over: channel)

        await session.wake()

        #expect(!session.isAwake)
        #expect(sent("get_first_wake_up", on: channel).isEmpty)
    }

    /// The flag is bookkeeping the owner never sees, so it must not hold "Waking
    /// up" over a robot that is already standing — not for a round trip, and not
    /// for the whole reply budget of a relay that stopped answering.
    @Test("the transition is over before the flag is asked about")
    func doesNotHoldTheTransition() async throws {
        let channel = FakeDataChannel(replies: Self.replies(completed: nil))
        let session = await connectedSession(over: channel)

        let waking = Task { await session.wake() }
        try await waitUntil("the flag is asked about") {
            !sent("get_first_wake_up", on: channel).isEmpty
        }

        #expect(session.powerTransition == nil)
        #expect(session.isAwake)
        channel.emit(#"{"command":"get_first_wake_up","is_completed":true}"#)
        await waking.value
    }

    /// Nothing on screen asked for the flag, so nothing on screen hears about it —
    /// `robotError` is the robot's connection and power.
    @Test("a robot that cannot answer about the flag is not an error")
    func swallowsAFailedRead() async {
        var replies = Self.replies(completed: nil)
        replies["get_first_wake_up"] = #"{"command":"get_first_wake_up","error":"storage unavailable"}"#
        let channel = FakeDataChannel(replies: replies)
        let session = await connectedSession(over: channel)

        await session.wake()

        #expect(session.robotError == nil)
        #expect(session.isAwake)
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
