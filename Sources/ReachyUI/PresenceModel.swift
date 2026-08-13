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
    typealias SetFaceTracking = @MainActor (RobotSession, Bool) async throws -> Bool

    private(set) var isWobbling = false
    private(set) var isTracking = false
    private(set) var busy = false
    private(set) var lastError: String?

    private var standingDown = false
    private let setWobblingCall: SetWobbling
    private let setFaceTrackingCall: SetFaceTracking

    init(
        setWobbling: @escaping SetWobbling = { try await $0.setWobbling($1) },
        setFaceTracking: @escaping SetFaceTracking = { try await $0.setFaceTracking($1) }
    ) {
        setWobblingCall = setWobbling
        setFaceTrackingCall = setFaceTracking
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
            let took = try await setFaceTrackingCall(session, enabled)
            isTracking = took
            if enabled, !took {
                lastError = String(
                    localized: .reachy("This robot has no camera available for face tracking.")
                )
            }
        }
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
            error: String? = nil
        ) -> PresenceModel {
            let model = PresenceModel()
            model.isWobbling = wobbling
            model.isTracking = tracking
            model.lastError = error
            return model
        }
    }
#endif
