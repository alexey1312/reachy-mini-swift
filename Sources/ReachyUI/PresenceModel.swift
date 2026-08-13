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
