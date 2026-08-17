import Foundation
@testable import ReachyKit
import Testing

/// Integration tests against a live (simulated) daemon.
/// Skipped unless `REACHY_SIM_HOST` is set — run via `./bin/mise run test:sim`
/// with `./bin/mise run sim-daemon` active in another terminal.
@Suite(
    "Live simulator integration",
    .enabled(if: ProcessInfo.processInfo.environment["REACHY_SIM_HOST"] != nil)
)
struct SimulatorIntegrationTests {
    private var address: RobotAddress {
        RobotAddress(host: ProcessInfo.processInfo.environment["REACHY_SIM_HOST"] ?? "127.0.0.1")
    }

    @Test("handshake returns identity and daemon version")
    func handshake() async throws {
        let connection = try RobotConnection(address: address)
        let handshake = try await connection.handshake()
        #expect(handshake.identity.daemonVersion?.isEmpty == false)
        #expect(handshake.status.simulationEnabled == true)
    }

    /// The readiness gate against a real daemon: `/api/state/full` is guarded by
    /// `get_backend`, so a 200 here is what `state == running` alone can't promise.
    @Test("readiness probe passes on a live backend")
    func readinessProbe() async throws {
        let connection = try RobotConnection(address: address)
        let status = try await connection.daemonStatus()
        try #require(status.state == .running, "sim daemon must be running for this test")
        try await connection.probeBackendReady()
    }

    @Test("set_target moves the head (visible in the state stream)", .timeLimit(.minutes(1)))
    func teleop() async throws {
        let client = try SetTargetClient(address: address, tickInterval: .milliseconds(10))
        await client.connect()

        // Stream a yaw target for a while, then check the observed head pose moved.
        let targetYaw = 0.4
        let sender = Task {
            for _ in 0 ..< 40 {
                await client.send(.init(yaw: targetYaw))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer {
            sender.cancel()
            Task { await client.disconnect() }
        }

        let stream = try StateStreamClient(address: address)
        var bestYaw = 0.0
        for await state in stream.states() {
            if let yaw = state.headPose?.value1?.yaw {
                bestYaw = max(bestYaw, abs(yaw))
                if bestYaw > 0.2 {
                    break
                }
            }
        }
        #expect(bestYaw > 0.2, "head yaw should approach the streamed target")
    }

    @Test("webrtc signaling negotiates up to the robot's SDP offer", .timeLimit(.minutes(1)))
    func webrtcSignaling() async throws {
        // The sim registers its producer only after media acquire.
        let connection = try RobotConnection(address: address)
        try? await connection.acquireMedia()

        let client = try CameraSignalingClient(address: address)
        for await event in await client.events() {
            if case let .offer(_, sdp) = event {
                #expect(sdp.hasPrefix("v=0"))
                break
            }
        }
        await client.disconnect()
    }

    /// The daemon's own default is 10 Hz. This used to assert only `< 10 s` for 40
    /// frames — under 4 Hz — which is why the project believed 20 Hz for so long.
    @Test("the default stream runs at the daemon's 10 Hz", .timeLimit(.minutes(1)))
    func stateStream() async throws {
        let rate = try await measuredRate(options: StateStreamOptions())
        #expect(rate > 6 && rate < 14, "measured \(rate) Hz")
    }

    /// The viewer asks for 20 Hz explicitly; if the parameter were ignored this
    /// would come back at the default rate.
    @Test("asking for 20 Hz doubles the frame rate", .timeLimit(.minutes(1)))
    func fastStateStream() async throws {
        let rate = try await measuredRate(options: .visualization)
        #expect(rate > 14, "measured \(rate) Hz")
    }

    /// The viewer profile must actually deliver what it asks for: motor angles and
    /// a matrix pose. A silent stream here means someone added a `with_target_*`.
    @Test("the visualization profile delivers joints and a matrix pose", .timeLimit(.minutes(1)))
    func visualizationPayload() async throws {
        var configuration = StateStreamClient.Configuration()
        configuration.options = .visualization
        let client = try StateStreamClient(address: address, configuration: configuration)
        for await update in client.updates() {
            guard let frame = update.frame else { continue }
            #expect(frame.headJoints?.count == 7)
            if case let .matrix(values) = frame.headPose {
                #expect(values.count == 16)
            } else {
                Issue.record("expected a matrix head pose, got \(String(describing: frame.headPose))")
            }
            return
        }
    }

    /// The sound library, end to end: send, list, play, stop, delete.
    ///
    /// **The only test that exercises the hand-written multipart body against something
    /// that parses it.** `RobotConnectionSoundsTests` asserts the bytes; only a daemon can
    /// say whether `python-multipart` accepts them. The same body was posted at a Wireless
    /// unit on 2026-08-17 and answered `{"status":"ok","path":"/tmp/reachy_mini_sounds/…"}`.
    ///
    /// The name is unique per run and deleted at the end, so a failure leaves one file in
    /// the daemon's `/tmp` and nothing else. **On `sim-daemon` the play comes out of the
    /// host Mac's own speaker** — the same warning `/api/volume/*` carries.
    @Test("a sound round-trips through the daemon", .timeLimit(.minutes(1)))
    func soundRoundTrip() async throws {
        let connection = try RobotConnection(address: address)
        let name = "reachy-kit-probe-\(UUID().uuidString.prefix(8)).wav"

        try await connection.uploadSound(named: name, data: Self.probeWAV())
        // A mapped array rather than `contains { … }` inside the macro: swiftformat's
        // `preferKeyPath` rewrites such a closure and `#expect` cannot expand the result.
        #expect(try await connection.sounds().map(\.filename).contains(name))

        try await connection.playSound(named: name)
        try await connection.stopSound()

        try await connection.deleteSound(named: name)
        #expect(try await connection.sounds().map(\.filename).contains(name) == false)

        // Measured rather than assumed: `delete_sound` is the one route on this surface
        // that reports whether a file exists, and it does so as a 404.
        let error = await #expect(throws: ReachyKitError.self) {
            try await connection.deleteSound(named: name)
        }
        #expect(error?.statusCode == 404)
    }

    /// A real WAV, because the daemon probes the *content* with GStreamer and refuses
    /// anything it cannot open — a header with silence behind it is not enough to assume.
    /// Measured: a text file named `.wav` comes back `400 Unsupported or invalid audio
    /// file`, which is a second refusal after the extension allow-list.
    private static func probeWAV(frames: Int = 4410, rate: Int = 22050) -> Data {
        func u32(_ value: Int) -> Data {
            withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
        }
        func u16(_ value: Int) -> Data {
            withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) }
        }

        var samples = Data()
        for index in 0 ..< frames {
            let value = Int16(12000 * sin(2 * Double.pi * 440 * Double(index) / Double(rate)))
            samples.append(UInt8(truncatingIfNeeded: value))
            samples.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        // PCM, mono, 16-bit.
        var format = Data()
        format += u16(1) + u16(1)
        format += u32(rate) + u32(rate * 2)
        format += u16(2) + u16(16)

        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + u32(format.count) + format
        body += Data("data".utf8) + u32(samples.count) + samples

        return Data("RIFF".utf8) + u32(body.count) + body
    }

    private func measuredRate(options: StateStreamOptions) async throws -> Double {
        var configuration = StateStreamClient.Configuration()
        configuration.options = options
        let client = try StateStreamClient(address: address, configuration: configuration)

        var count = 0
        var start: ContinuousClock.Instant?
        for await state in client.states() {
            #expect(state.controlMode != nil)
            // Time from the first frame, so connection setup is not counted.
            guard let start else {
                start = .now
                continue
            }
            count += 1
            if count == 40 {
                let elapsed = start.duration(to: .now).components
                // Whole seconds alone would round 2.4 s down to 2 and report 20 Hz
                // for a 16 Hz stream.
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                return seconds > 0 ? Double(count) / seconds : 0
            }
        }
        return 0
    }
}
