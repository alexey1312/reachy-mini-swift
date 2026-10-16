import Foundation
@testable import ReachyKit
import simd
import Testing

/// Records what went out. `set_full_target` is sent rather than performed, so
/// nothing needs scripting.
private final class TeleopChannelSpy: RemoteDataChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var open: Bool

    init(isOpen: Bool = true) {
        open = isOpen
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ text: String) async throws {
        record(text)
    }

    /// Synchronous on purpose: `NSLock` is `noasync`, because a lock held across
    /// a suspension is a deadlock waiting for the right scheduling.
    private func record(_ text: String) {
        lock.lock()
        recorded.append(text)
        lock.unlock()
    }

    func setOpen(_ open: Bool) {
        lock.lock()
        self.open = open
        lock.unlock()
    }

    func messages() -> AsyncStream<String> {
        AsyncStream { _ in }
    }
}

@Suite("Remote teleop channel", .timeLimit(.minutes(1)))
struct RemoteTeleopChannelTests {
    private static var immediateLimiter: TargetSlewLimiter {
        TargetSlewLimiter(
            tau: .nanoseconds(1),
            headAngularRate: .greatestFiniteMagnitude,
            bodyYawRate: .greatestFiniteMagnitude,
            antennaRate: .greatestFiniteMagnitude,
            translationRate: .greatestFiniteMagnitude
        )
    }

    private func teleop(
        tickInterval: Duration = .milliseconds(33),
        limiter: TargetSlewLimiter = Self.immediateLimiter,
        isOpen: Bool = true
    ) -> (RemoteTeleopChannel, TeleopChannelSpy) {
        let spy = TeleopChannelSpy(isOpen: isOpen)
        return (
            RemoteTeleopChannel(
                control: RemoteControlChannel(channel: spy),
                tickInterval: tickInterval,
                limiter: limiter
            ),
            spy
        )
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// A followed head swaps the limiter mid-stream (`TeleopDriver.useLimiter`), so the
    /// frame after the swap must already obey the new one.
    @Test("a new limiter paces the frames after it")
    func limiterChangesThePace() async throws {
        let (paced, spy) = teleop(limiter: TargetSlewLimiter())
        await paced.send(TeleopTarget(yaw: 1))

        await paced.tick()
        await paced.setLimiter(Self.immediateLimiter)
        await paced.tick()

        // What a channel that reaches the goal at once sends for the same target.
        let (reference, referenceSpy) = teleop()
        await reference.send(TeleopTarget(yaw: 1))
        await reference.tick()
        let goalText = try #require(referenceSpy.sent.first)
        let goal = try #require(object(goalText)["head"] as? [Double])

        #expect(spy.sent.count == 2)
        let firstText = try #require(spy.sent.first)
        let secondText = try #require(spy.sent.last)
        let first = try #require(object(firstText)["head"] as? [Double])
        let second = try #require(object(secondText)["head"] as? [Double])
        // The pad's 90°/s moves a 33 ms tick by about 3°, far short of one radian.
        #expect(zip(first, goal).contains { abs($0 - $1) > 0.1 })
        #expect(zip(second, goal).allSatisfy { abs($0 - $1) < 1e-12 })
    }

    /// One command where the LAN socket sends one frame: `set_target` alone would
    /// need `set_body_yaw` and `set_antennas` beside it and make every frame three.
    @Test("a target goes out as one set_full_target")
    func sendsOneCommand() async throws {
        let (teleop, spy) = teleop()

        await teleop.send(TeleopTarget(yaw: 0.2, bodyYaw: 0.3, antennaLeft: 0.4, antennaRight: -0.4))
        await teleop.tick()

        #expect(spy.sent.count == 1)
        let body = try object(#require(spy.sent.first))
        #expect(body["type"] as? String == "set_full_target")
        #expect((body["head"] as? [Double])?.count == 16)
        #expect(body["antennas"] as? [Double] == [-0.4, 0.4])
        #expect(body["body_yaw"] as? Double == 0.3)
    }

    /// The one test that matters here. Both transports carry the *same pose*, and
    /// the only thing that could silently differ is the euler convention: the LAN
    /// route sends XYZRPY and the daemon composes the matrix itself with
    /// `R.from_euler("xyz", …)`, while this side composes it and sends the result.
    /// Getting that wrong moves the robot somewhere else with no error anywhere.
    ///
    /// So the LAN payload is decoded back, run through the same composition the
    /// daemon performs, and compared element by element with what this channel put
    /// on the wire.
    @Test("the matrix on the wire is the pose the LAN route describes")
    func matchesTheLANPose() async throws {
        let target = TeleopTarget(
            x: 0.01, y: -0.02, z: 0.03,
            roll: 0.15, pitch: -0.25, yaw: 0.35,
            bodyYaw: 0.45, antennaLeft: 0.55, antennaRight: -0.65
        )
        let (teleop, spy) = teleop()

        await teleop.send(target)
        await teleop.tick()

        // What the LAN client would have sent, read back as the daemon reads it.
        let encoded = try #require(String(bytes: SetTargetClient.encode(target), encoding: .utf8))
        let lan = try object(encoded)
        let head = try #require(lan["target_head_pose"] as? [String: Double])
        let composed = try RigidTransform.transform(
            translation: SIMD3(#require(head["x"]), #require(head["y"]), #require(head["z"])),
            rpy: SIMD3(#require(head["roll"]), #require(head["pitch"]), #require(head["yaw"]))
        )
        let expected = RigidTransform.rowMajorValues(composed)

        let body = try object(#require(spy.sent.first))
        let actual = try #require(body["head"] as? [Double])
        #expect(actual.count == expected.count)
        for (sent, wanted) in zip(actual, expected) {
            #expect(abs(sent - wanted) < 1e-12)
        }
        // And the two halves the daemon does not transform at all, including
        // its explicit `[right, left]` antenna order.
        #expect(body["antennas"] as? [Double] == lan["target_antennas"] as? [Double])
        #expect(body["body_yaw"] as? Double == lan["target_body_yaw"] as? Double)
    }

    /// The bottom row of a rigid transform, which is what tells a row-major
    /// flatten from a column-major one when the rotation happens to be symmetric.
    @Test("the head matrix is flattened row by row")
    func flattensRowMajor() async throws {
        let (teleop, spy) = teleop()

        await teleop.send(TeleopTarget(x: 1, y: 2, z: 3))
        await teleop.tick()

        let body = try object(#require(spy.sent.first))
        let head = try #require(body["head"] as? [Double])
        // Translation lives in the last column of each of the first three rows.
        #expect(head[3] == 1)
        #expect(head[7] == 2)
        #expect(head[11] == 3)
        #expect(Array(head[12 ..< 16]) == [0, 0, 0, 1])
    }

    /// The UI emits at gesture rate; the next tick should carry only the newest
    /// goal, not one frame per write.
    @Test("a burst keeps only the latest goal")
    func burstKeepsLatestGoal() async throws {
        let (teleop, spy) = teleop()

        await teleop.send(TeleopTarget(yaw: 0.1))
        await teleop.send(TeleopTarget(yaw: 0.2))
        await teleop.send(TeleopTarget(yaw: 0.3))
        await teleop.tick()

        #expect(spy.sent.count == 1)
        let body = try object(#require(spy.sent.first))
        let head = try #require(body["head"] as? [Double])
        #expect(abs(head[0] - cos(0.3)) < 1e-12)
    }

    /// The relay uses the same slew limiter as LAN rather than putting a step on
    /// physical hardware.
    @Test("a step goal is slew limited")
    func slewLimitsAStep() async throws {
        let (teleop, spy) = teleop(
            tickInterval: .milliseconds(100),
            limiter: TargetSlewLimiter()
        )

        await teleop.send(TeleopTarget(bodyYaw: .pi))
        await teleop.tick()

        let body = try object(#require(spy.sent.first))
        let sent = try #require(body["body_yaw"] as? Double)
        #expect(abs(sent - 12 * .pi / 180) < 1e-12)
    }

    /// A peer gap drops intermediate frames. Once a peer returns, exactly the
    /// latest goal advances from the last pose that actually reached the robot.
    @Test("a peer gap does not queue stale targets")
    func peerGapKeepsLatestGoal() async throws {
        let (teleop, spy) = teleop(isOpen: false)

        await teleop.send(TeleopTarget(bodyYaw: 0.1))
        await teleop.tick()
        await teleop.send(TeleopTarget(bodyYaw: 0.3))
        #expect(spy.sent.isEmpty)

        spy.setOpen(true)
        await teleop.tick()

        #expect(spy.sent.count == 1)
        let body = try object(#require(spy.sent.first))
        #expect(body["body_yaw"] as? Double == 0.3)
    }

    /// This pacer rides a channel the peer connection opened long before a
    /// joystick existed. Disconnecting stops the pacer, not the shared channel.
    @Test("connecting and disconnecting leave the shared channel alone")
    func doesNotOwnTheChannel() async {
        let (teleop, spy) = teleop(tickInterval: .seconds(60))

        await teleop.send(TeleopTarget(bodyYaw: 0.3))
        await teleop.connect()
        await teleop.disconnect()

        #expect(spy.sent.isEmpty)
    }
}
