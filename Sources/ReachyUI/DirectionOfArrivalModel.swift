import Foundation
import Observation
import ReachyKit

/// Where the robot last heard a voice from.
///
/// **A socket of its own, and not `RobotSceneModel`'s.** That one already receives
/// every field of every frame and could publish this for a line — but it streams
/// only while the 3D model is the thing on screen, so the indicator would go dead
/// the moment somebody switched to the camera. That is exactly the view where
/// "somebody spoke, and they are off to your left" is worth knowing, because the
/// robot's own picture cannot show them. `StateStreamOptions.hearing` is what keeps
/// the second socket cheap: two fields at 5 Hz, with every geometry flag named
/// `false` because the daemon defaults three of them to `true`.
///
/// **LAN only, structurally.** `ViewportModel.Source.remote` has no HTTP API and so
/// no state stream — the same reason it has no 3D scene. The indicator is absent
/// over the relay rather than present and permanently silent.
@MainActor
@Observable
final class DirectionOfArrivalModel {
    /// Which way the sound came from, in **the robot's** frame.
    ///
    /// Left and right rather than leading and trailing, and this is the same
    /// exception `JoystickPad` takes: these are the robot's own directions, not the
    /// reader's, so a right-to-left language must not mirror them. Mirroring would
    /// silently reverse a fact about the world.
    enum Side: Equatable, Sendable {
        case left
        case right
        /// **Directly in front or directly behind — and the array cannot tell
        /// which.** The daemon reports one angle along the left–right axis
        /// (`.claude/rules/daemon-api.md`: 0 = left, π/2 = front/back, π = right),
        /// so π/2 is a genuine degeneracy rather than a reading to be refined. This
        /// is the case that rules out drawing a compass: a 360° dial would have to
        /// invent a front or a back, and it would be wrong half the time with no way
        /// for anyone to notice.
        case frontOrBehind
    }

    struct Heard: Equatable, Sendable {
        let side: Side
        /// Radians, as the daemon sent them. Kept so the view can lean the glyph
        /// rather than only pick a side.
        let angle: Double
        let at: Date
    }

    /// How wide the degenerate band around π/2 is, on each side.
    ///
    /// A feel constant, like `JoystickMapping.rotationThreshold`, and it can only be
    /// settled on hardware: too narrow and a voice directly in front alternates
    /// between "left" and "right" frame by frame, too wide and the indicator says
    /// "somewhere ahead" for most of the room. 22.5° is a starting point, not a
    /// measurement.
    static let frontBackBand: Double = .pi / 8

    /// How long a reading stays on screen once the robot stops hearing speech.
    ///
    /// Retired by the stream rather than by a `Timer`, the way
    /// `RunningAppModel.expireActionFailure` is retired by its poll: frames arrive
    /// at 5 Hz whether or not anybody is talking, so the stream is a clock this
    /// model already owns. A timer would be a second one.
    static let holdWindow: TimeInterval = 3

    /// The last voice still worth showing, or `nil` for a quiet robot.
    private(set) var lastHeard: Heard?

    /// **Whether this robot answers the question at all.**
    ///
    /// `doa` is nullable and `sim-daemon` sends `null` forever, so an indicator that
    /// mounted on hope would sit blank on every simulator run and on any unit with
    /// no microphone array. It goes true on the first reading that is not null and
    /// stays true: a robot that has answered once is a robot with an array, and a
    /// quiet room is not a retraction.
    private(set) var isSupported = false

    private let stream: (any RobotStateStreaming)?
    private let now: @Sendable () -> Date
    private var streamTask: Task<Void, Never>?

    /// `nil` for an inert model, which is what a preview injects and what a relay
    /// session gets.
    init(stream: (any RobotStateStreaming)?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.stream = stream
        self.now = now
    }

    /// Idempotent, so a SwiftUI redraw cannot open a second socket.
    func start() {
        guard streamTask == nil, let stream else { return }
        let updates = stream.updates(.hearing)
        streamTask = Task { [weak self] in
            for await update in updates {
                guard let self else { break }
                consume(update)
            }
        }
    }

    /// Cancelling the task closes the socket — `StateStreamClient` wraps `receive()`
    /// in a cancellation handler precisely so it does.
    ///
    /// `lastHeard` is deliberately kept: coming back to the viewport a second later
    /// should not blank a reading that is still inside its window, and the first
    /// frame will retire it if it is not.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// The mapping, pure and static so it can be asserted without a socket.
    ///
    /// Angles outside `[0, π]` are clamped rather than wrapped: the daemon's own
    /// range is that half-circle, so anything beyond it is noise, and wrapping would
    /// turn a slightly negative reading into a confident "right".
    /// The type is named in full in the default argument because `Self` is not in
    /// scope there.
    static func side(for angle: Double, band: Double = DirectionOfArrivalModel.frontBackBand) -> Side {
        let clamped = min(max(angle, 0), .pi)
        if abs(clamped - .pi / 2) <= band {
            return .frontOrBehind
        }
        return clamped < .pi / 2 ? .left : .right
    }

    private func consume(_ update: StateStreamUpdate) {
        // A frame that failed to decode, or a daemon that carries no array, says
        // nothing about the room — it must neither light the indicator nor retire a
        // reading somebody is still looking at.
        guard let doa = update.hearing else { return }
        isSupported = true
        let date = now()
        if doa.speechDetected {
            lastHeard = Heard(side: Self.side(for: doa.angle), angle: doa.angle, at: date)
        } else if let last = lastHeard, date.timeIntervalSince(last.at) > Self.holdWindow {
            lastHeard = nil
        }
    }
}

#if DEBUG
    extension DirectionOfArrivalModel {
        /// A model parked in one state, with no socket. `lastHeard` and `isSupported`
        /// are `private(set)`, so this has to live in the same file.
        ///
        /// Constructing the model is inert on its own — `start()` is what reaches the
        /// robot, and a model with no stream cannot even do that.
        static func preview(_ heard: Heard?, isSupported: Bool = true) -> DirectionOfArrivalModel {
            let model = DirectionOfArrivalModel(stream: nil)
            model.isSupported = isSupported
            model.lastHeard = heard
            return model
        }

        static func preview(_ side: Side) -> DirectionOfArrivalModel {
            let angle: Double = switch side {
            case .left: 0.2
            case .frontOrBehind: .pi / 2
            case .right: .pi - 0.2
            }
            return preview(Heard(side: side, angle: angle, at: Date(timeIntervalSince1970: 1_800_000_000)))
        }
    }
#endif
