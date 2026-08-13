import Foundation
import Observation
import ReachyKit

/// Records what this phone drove the robot to do, and drives it again.
///
/// **Both halves ride the teleop channel, not the daemon's move slot.** A recorded
/// take is a list of `TeleopTarget`s — the very values `TeleopDriver` pushes — so
/// playback is the same wire path as a thumb on the joystick, and it needs nothing
/// installed on the robot. The cost is that it is not a *daemon* move: it does not
/// appear in `GET /api/move/running`, and a dance started elsewhere would fight it
/// for the robot, which is why every caller frees the floor first.
@MainActor
@Observable
final class MoveRecorderModel {
    /// A take in progress: when it started, and what has been captured since.
    private struct Take {
        let startedAt: Date
        var frames: [MoveRecording.Frame] = []
    }

    private(set) var recordings: [MoveRecording]
    private(set) var isPlaying = false
    private(set) var lastError: String?

    var isRecording: Bool {
        take != nil
    }

    /// How long the take in progress has been running, for a screen to count up.
    private(set) var elapsed: TimeInterval = 0

    private var take: Take?
    private let store: MoveRecordingStore

    init(store: MoveRecordingStore = MoveRecordingStore()) {
        self.store = store
        recordings = store.all
    }

    func beginRecording(at date: Date = Date()) {
        take = Take(startedAt: date)
        elapsed = 0
    }

    /// Called by whatever is sampling the driver. Outside a take it does nothing —
    /// the sampler is a `.task` that outlives the button by a tick or two.
    func capture(_ target: TeleopTarget, at date: Date = Date()) {
        guard var take else { return }
        let offset = date.timeIntervalSince(take.startedAt)
        take.frames.append(MoveRecording.Frame(offset: offset, target: target))
        self.take = take
        elapsed = offset
    }

    /// - Returns: the saved take, or nil when nothing was captured — a start and a
    ///   stop inside one sampling interval is a row that would play nothing.
    @discardableResult
    func endRecording(named name: String, at _: Date = Date()) -> MoveRecording? {
        guard let take else { return nil }
        self.take = nil
        elapsed = 0
        guard !take.frames.isEmpty else { return nil }
        let recording = MoveRecording(name: name, recordedAt: take.startedAt, frames: take.frames)
        store.save(recording)
        recordings = store.all
        return recording
    }

    func delete(_ id: UUID) {
        store.delete(id)
        recordings = store.all
    }

    func rename(_ id: UUID, to name: String) {
        store.rename(id, to: name)
        recordings = store.all
    }

    /// Plays a take back over the channel, honouring the gaps it carries.
    ///
    /// The waits come from the recording's own offsets rather than from an assumed
    /// rate: the sampler is a main-actor `Task` and a loaded phone drops ticks, so a
    /// take replayed at a nominal 10 Hz would not be the take that was made.
    ///
    /// `wait` is injectable because the timing *is* the behaviour here — a test that
    /// slept through it would be asserting on a loaded runner's scheduler.
    func play(
        _ recording: MoveRecording,
        channel: any TeleopChannel,
        wait: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async {
        guard !isPlaying else { return }
        isPlaying = true
        defer { isPlaying = false }

        await channel.connect()
        var previous: TimeInterval = 0
        for frame in recording.frames {
            guard !Task.isCancelled else { break }
            await wait(.seconds(frame.offset - previous))
            previous = frame.offset
            await channel.send(frame.target)
        }
        await channel.disconnect()
    }
}

#if DEBUG
    extension MoveRecorderModel {
        static func preview(
            recordings: [MoveRecording] = [],
            isRecording: Bool = false,
            elapsed: TimeInterval = 0
        ) -> MoveRecorderModel {
            // Its own defaults suite, emptied first: a preview renders the state it
            // was handed and must not write into — or read back out of — the reader's
            // own recordings.
            let name = "MoveRecorderModel.preview"
            let suite = UserDefaults(suiteName: name) ?? .standard
            suite.removePersistentDomain(forName: name)
            let store = MoveRecordingStore(defaults: suite)
            for recording in recordings {
                store.save(recording)
            }
            let model = MoveRecorderModel(store: store)
            if isRecording {
                model.beginRecording()
            }
            model.elapsed = elapsed
            return model
        }
    }

    extension MoveRecording {
        static func preview(
            name: String = "Hello wave",
            seconds: TimeInterval = 4.2,
            at recordedAt: Date = Date(timeIntervalSince1970: 1_770_000_000)
        ) -> MoveRecording {
            let count = max(Int(seconds * 10), 1)
            return MoveRecording(
                name: name,
                recordedAt: recordedAt,
                frames: (0 ..< count).map {
                    .init(offset: Double($0) / 10, target: TeleopTarget(yaw: sin(Double($0) / 8) / 2))
                }
            )
        }
    }
#endif
