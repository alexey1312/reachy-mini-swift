import Foundation
import ReachyJSON

/// A move this phone captured, as the poses it sent rather than as anything the
/// robot recorded.
///
/// **Nothing is installed on the robot for this.** Pollen's own answer is an app
/// ("The Marionette") and Reachy's Brain runs a server of its own; both put the
/// recording where the robot can lose it. Here the frames are the very targets
/// `TeleopDriver` already emits, so playback is the same wire path as driving —
/// which is also why it works on a robot with nothing installed at all.
public struct MoveRecording: Codable, Sendable, Identifiable, Equatable {
    /// One sampled pose and when it happened, measured from the start of the take.
    ///
    /// An offset rather than a rate: the sampler is a `Task` on the main actor and a
    /// loaded phone drops ticks, so a recording played back at an assumed 10 Hz
    /// would drift against the take it came from.
    public struct Frame: Codable, Sendable, Equatable {
        public let offset: TimeInterval
        public let target: TeleopTarget

        public init(offset: TimeInterval, target: TeleopTarget) {
            self.offset = offset
            self.target = target
        }
    }

    public let id: UUID
    public var name: String
    public let recordedAt: Date
    public let frames: [Frame]

    /// Zero for an empty take rather than a crash on `frames.last` — a recording
    /// stopped before the first tick is a real thing to have on disk.
    public var duration: TimeInterval {
        frames.last?.offset ?? 0
    }

    public init(id: UUID = UUID(), name: String, recordedAt: Date, frames: [Frame]) {
        self.id = id
        self.name = name
        self.recordedAt = recordedAt
        self.frames = frames
    }
}

/// Where recordings live between launches.
///
/// **Not keyed by robot**, unlike `PinnedAppStore` and `MovePlaybackStore`: a
/// recording is a pose sequence, and every Reachy Mini has the same joints. Playing
/// one back on a second robot is a feature rather than a mix-up.
public struct MoveRecordingStore {
    static let key = "ReachyKit.moveRecordings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    /// Newest first: a take is usually played back straight after it is made.
    public var all: [MoveRecording] {
        stored().sorted { $0.recordedAt > $1.recordedAt }
    }

    public func save(_ recording: MoveRecording) {
        var recordings = stored().filter { $0.id != recording.id }
        recordings.append(recording)
        write(recordings)
    }

    public func delete(_ id: UUID) {
        write(stored().filter { $0.id != id })
    }

    public func rename(_ id: UUID, to name: String) {
        write(stored().map {
            guard $0.id == id else { return $0 }
            return MoveRecording(id: $0.id, name: name, recordedAt: $0.recordedAt, frames: $0.frames)
        })
    }

    private func stored() -> [MoveRecording] {
        guard let data = defaults.data(forKey: Self.key),
              let recordings = try? JSONCodec.stored.decode([MoveRecording].self, from: data)
        else { return [] }
        return recordings
    }

    private func write(_ recordings: [MoveRecording]) {
        guard let data = try? JSONCodec.stored.encode(recordings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
