import Foundation
import Observation
import ReachyKit

/// Drives the robot's two daemon-side presence behaviours from the viewport.
///
/// **This model is the only record of what is on, and it is a record of requests
/// rather than of the robot.** No route reports either state (see ``PresenceClient``),
/// so a switch here means "this is what this app last asked for". An app running on
/// the robot can change both underneath — `enable_wobbling` is an SDK call apps make
/// for themselves — and nothing can detect that. The screen says so in words rather
/// than implying a reading it does not have.
@MainActor
@Observable
final class PresenceModel {
    typealias SetWobbling = @MainActor (RobotSession, Bool) async throws -> Void
    typealias SetFaceTracking = @MainActor (RobotSession, Bool, Double) async throws -> Bool
    typealias TrackedFace = @MainActor (RobotSession) async throws -> RobotFaceTarget?

    /// How much of the tracked aim reaches the head. **The floor is not zero, and that
    /// is the one decision in this file that the daemon does not make for us.**
    /// `enable_head_tracking(weight: 0)` is a real state — it pauses the worker and
    /// clears the aim without stopping the detector — but it is indistinguishable on
    /// screen from the switch above being off, and a switch that says "on" over a robot
    /// that visibly follows nothing is the kind of thing that gets reported as broken.
    /// So stopping is what the switch is for, and this only decides how far.
    ///
    /// The floor's value is a feel constant, like every number in the teleop path: it is
    /// low enough to read as "barely follows" and high enough to be visible on a robot.
    /// Only the robot settles it.
    static let weightRange: ClosedRange<Double> = 0.2 ... 1

    private(set) var isWobbling = false
    private(set) var isTracking = false
    /// Whether the robot can see somebody, or nil for "no answer yet".
    ///
    /// The one thing on this model that is a reading rather than a request, and it
    /// stays nil while tracking is off — the route reports the tracker's last aim, so
    /// asking a stopped tracker would report whoever it saw before it stopped.
    /// A failed poll returns it to nil rather than to false: unknown is not "nobody".
    private(set) var seesFace: Bool?
    private(set) var busy = false
    private(set) var lastError: String?

    /// Bound to the slider, so it moves under the thumb; **not** `private(set)` for that
    /// reason, and not what the robot has been told either — ``commitTrackingWeight(session:)``
    /// is. The split is `AudioSettingsModel`'s: a value the robot only hears about once
    /// the gesture ends.
    var trackingWeight: Double = 1

    /// The weight the robot was last sent, so a gesture that ends where it started sends
    /// nothing. Tracking's route is idempotent, unlike `volume/set` with its test beep,
    /// so this is thrift rather than a rule.
    private var appliedWeight: Double = 1

    private var standingDown = false
    private var faceWatch: Task<Void, Never>?
    private let setWobblingCall: SetWobbling
    private let setFaceTrackingCall: SetFaceTracking
    private let trackedFaceCall: TrackedFace
    /// A status line, not an animation: once a second is enough to tell somebody the
    /// robot found them, and it costs the daemon a cached variable per poll.
    private let facePollInterval: Duration

    init(
        setWobbling: @escaping SetWobbling = { try await $0.setWobbling($1) },
        setFaceTracking: @escaping SetFaceTracking = { try await $0.setFaceTracking($1, weight: $2) },
        trackedFace: @escaping TrackedFace = { try await $0.trackedFace() },
        facePollInterval: Duration = .seconds(1)
    ) {
        setWobblingCall = setWobbling
        setFaceTrackingCall = setFaceTracking
        trackedFaceCall = trackedFace
        self.facePollInterval = facePollInterval
    }

    /// The flag follows the call rather than the tap: a switch showing a state the
    /// robot refused is worse than one that visibly sprang back.
    func setWobbling(_ enabled: Bool, session: RobotSession) async {
        await perform {
            try await setWobblingCall(session, enabled)
            isWobbling = enabled
        }
    }

    /// Unlike wobbling, the robot's answer here is real — a camera-less robot says
    /// `enabled: false` under a 200, and that is a refusal to report rather than a
    /// success to record.
    func setFaceTracking(_ enabled: Bool, session: RobotSession) async {
        await perform {
            let weight = trackingWeight
            let took = try await setFaceTrackingCall(session, enabled, weight)
            isTracking = took
            if took {
                appliedWeight = weight
            }
            if enabled, !took {
                lastError = String(
                    localized: .reachy("This robot has no camera available for face tracking.")
                )
            }
        }
        watchFace(session: session)
    }

    /// Follows the tracker for as long as it is running, and only that long.
    private func watchFace(session: RobotSession) {
        // A weight commit is `setFaceTracking(true)` with a different number, so it
        // lands here too. Restarting on it would blank the line for a poll every time
        // the slider settles, which reads as the robot losing the face.
        if isTracking, faceWatch != nil {
            return
        }
        faceWatch?.cancel()
        faceWatch = nil
        seesFace = nil
        guard isTracking else { return }
        faceWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, isTracking else { return }
                let seen: Bool?
                do {
                    seen = try await trackedFaceCall(session) != nil
                } catch {
                    // Logged, not surfaced: one failed poll is not worth a banner
                    // over a live view and the next is a second away. Without this
                    // the log held nothing at all for a camera pipeline that died,
                    // which reads exactly like a robot that sees nobody.
                    _ = RobotSession.message(for: error)
                    seen = nil
                }
                // Checked before the assignment, not after: `setFaceTracking(false)`
                // has already set this to nil, and a poll suspended across it would
                // otherwise write over that and leave the indicator up.
                guard !Task.isCancelled, isTracking else { return }
                seesFace = seen
                try? await Task.sleep(for: facePollInterval)
            }
        }
    }

    /// Sends the weight the thumb settled on, and only then.
    ///
    /// Re-enabling is how a weight is changed — `enable_head_tracking` takes it as a
    /// parameter and there is no route that sets it alone — so this is
    /// `setFaceTracking(true)` with a different number, and it is skipped entirely while
    /// tracking is off: the slider is a preference then, not a command.
    func commitTrackingWeight(session: RobotSession) async {
        guard isTracking, trackingWeight != appliedWeight else { return }
        await setFaceTracking(true, session: session)
    }

    /// Hands the head back to whoever is driving it by hand. Both behaviours here aim
    /// the head themselves, so neither may stay on under a joystick.
    ///
    /// **Face tracking does not share the head, it takes it.** The daemon composes the
    /// two as `linear_pose_interpolation(pose, aim, weight)` and this app asks for
    /// `weight: 1`, so a tracked aim replaces the teleop target outright — and
    /// `set_target_head_pose` does not even flag an IK pass while it is on. Body yaw
    /// still goes through, which is what makes the symptom look like a broken pad: the
    /// torso turns under a head that will not follow, and the daemon's
    /// `|head − body| ≤ 65°` clamp — inert only because ``TeleopDriver`` composes the
    /// body's yaw into the head's — comes back to life and stops the turn well short of
    /// what the slider reads. Losing a face for 2 s then walks the head to neutral under
    /// the thumb.
    ///
    /// Wobbling only adds an offset, so it is a jitter rather than a fight. It goes with
    /// it because a hand on the stick asks for a robot that moves where it is pushed and
    /// nowhere else.
    ///
    /// A refused call leaves its flag set, so the next deflection tries again rather than
    /// recording a hand-off that never happened.
    func standDown(session: RobotSession) async {
        guard !standingDown, isWobbling || isTracking else { return }
        standingDown = true
        defer { standingDown = false }
        if isWobbling {
            await setWobbling(false, session: session)
        }
        if isTracking {
            await setFaceTracking(false, session: session)
        }
    }

    /// The same hand-off, shaped for the pad's gesture handler.
    ///
    /// The flags are read synchronously and nothing is spawned once both are off — a
    /// drag delivers this at screen rate for as long as a finger is down. `standDown`'s
    /// own latch is what covers the window where the calls are still in flight and the
    /// flags therefore still true.
    func teleopStandDown(session: RobotSession) -> TeleopStandDown {
        { [self] in
            guard isWobbling || isTracking else { return }
            Task { await standDown(session: session) }
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        lastError = nil
        do {
            try await work()
        } catch {
            lastError.recordDaemonFailure(error)
        }
    }
}

#if DEBUG
    extension PresenceModel {
        /// Parked in one state. Here rather than in `Previews/` because everything it
        /// writes is `private(set)`, which `@testable` does not reach from another
        /// module.
        static func preview(
            wobbling: Bool = false,
            tracking: Bool = false,
            weight: Double = 1,
            error: String? = nil,
            seesFace: Bool? = nil
        ) -> PresenceModel {
            let model = PresenceModel()
            model.isWobbling = wobbling
            model.isTracking = tracking
            model.trackingWeight = weight
            model.appliedWeight = weight
            model.lastError = error
            model.seesFace = seesFace
            return model
        }
    }
#endif
