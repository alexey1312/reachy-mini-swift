import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// Capturing what this phone drove, and driving it again.
@MainActor
@Suite("Move recorder", .timeLimit(.minutes(1)))
struct MoveRecorderModelTests {
    private func store() throws -> MoveRecordingStore {
        let defaults = try #require(UserDefaults(suiteName: "MoveRecorderModelTests.\(UUID().uuidString)"))
        return MoveRecordingStore(defaults: defaults)
    }

    /// Collects what playback sent, in order.
    final class Channel: TeleopChannel, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sent: [TeleopTarget] = []
        private(set) var connects = 0

        func connect() async {
            lock.withLock { connects += 1 }
        }

        func send(_ target: TeleopTarget) async {
            lock.withLock { sent.append(target) }
        }

        func disconnect() async {}
    }

    private let start = Date(timeIntervalSince1970: 1000)

    @Test("a take keeps every captured pose, timed from its start")
    func records() throws {
        let model = try MoveRecorderModel(store: store())

        model.beginRecording(at: start)
        model.capture(TeleopTarget(yaw: 1), at: start.addingTimeInterval(0.1))
        model.capture(TeleopTarget(yaw: 2), at: start.addingTimeInterval(0.25))
        let take = model.endRecording(named: "Wave", at: start.addingTimeInterval(0.3))

        let recording = try #require(take)
        // Compared with a tolerance rather than exactly: `Date` is a `Double` of
        // seconds since 2001, so a difference taken near the epoch carries ~2e-8 s of
        // representation noise. It is not the sampler's, and it is far below anything
        // playback can express.
        #expect(zip(recording.frames.map(\.offset), [0.1, 0.25]).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(recording.frames.map(\.target.yaw) == [1, 2])
        #expect(model.recordings.map(\.name) == ["Wave"])
    }

    /// A tap that starts and stops a recording before the sampler ever ran leaves
    /// nothing worth keeping, and a row named after it would be a row that plays
    /// nothing.
    @Test("a take with no frames is not saved")
    func discardsEmptyTakes() throws {
        let model = try MoveRecorderModel(store: store())

        model.beginRecording(at: start)

        #expect(model.endRecording(named: "Nothing", at: start.addingTimeInterval(1)) == nil)
        #expect(model.recordings.isEmpty)
    }

    @Test("capturing outside a take is ignored")
    func ignoresStrayCaptures() throws {
        let model = try MoveRecorderModel(store: store())

        model.capture(TeleopTarget(yaw: 1), at: start)

        #expect(!model.isRecording)
        #expect(model.endRecording(named: "Stray", at: start) == nil)
    }

    @Test("playback sends every frame, in order")
    func playsBack() async throws {
        let model = try MoveRecorderModel(store: store())
        let channel = Channel()
        let recording = MoveRecording(
            name: "Wave",
            recordedAt: start,
            frames: [
                .init(offset: 0, target: TeleopTarget(yaw: 1)),
                .init(offset: 0.1, target: TeleopTarget(yaw: 2)),
            ]
        )

        await model.play(recording, channel: channel, wait: { _ in })

        #expect(channel.connects == 1)
        #expect(channel.sent.map(\.yaw) == [1, 2])
        #expect(!model.isPlaying)
    }

    /// The gaps come from the recording, not from an assumed rate: a phone that
    /// dropped ticks while recording must replay the timing it actually captured.
    @Test("playback waits the gaps the recording carries")
    func honoursTiming() async throws {
        let model = try MoveRecorderModel(store: store())
        let waits = Waits()
        let recording = MoveRecording(
            name: "Uneven",
            recordedAt: start,
            frames: [
                .init(offset: 0.2, target: TeleopTarget()),
                .init(offset: 0.5, target: TeleopTarget()),
                .init(offset: 1.5, target: TeleopTarget()),
            ]
        )

        await model.play(recording, channel: Channel(), wait: { waits.record($0) })

        #expect(waits.all.count == 3)
        #expect(zip(waits.all, [0.2, 0.3, 1.0]).allSatisfy { abs($0 - $1) < 0.001 })
    }

    /// Milliseconds rather than `Duration`s: the assertion is arithmetic on gaps, and
    /// comparing `Duration`s to literals needs a conversion in the test that the
    /// production code would then not share.
    final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var all: [Double] = []

        func record(_ duration: Duration) {
            let parts = duration.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
            lock.withLock { all.append(seconds) }
        }
    }
}
