import Foundation

/// The two daemon-side behaviours that make a robot feel present rather than parked.
///
/// A file of its own because `RobotConnection.swift` is at SwiftLint's length limit,
/// the same split `RobotConnection+Wireless` and `+Apps` make.
public extension RobotConnection {
    /// Audio-reactive head wobbling: the daemon analyses the audio **it** is playing
    /// — sounds, and incoming WebRTC audio, which is what this app's telepresence
    /// sends — and turns it into head movement. A silent robot does not move.
    ///
    /// **The reply proves nothing.** `enable_wobbling` calls the media server inside
    /// `if backend._media_server is not None` and returns `{"status": "ok"}` from
    /// outside it, so a robot with no media server answers exactly like one that
    /// started wobbling. Nothing here can close that; do not add a check that
    /// pretends to.
    func setWobbling(_ enabled: Bool) async throws {
        if enabled {
            _ = try await client.enableWobblingApiMediaWobblingEnablePost().ok
        } else {
            _ = try await client.disableWobblingApiMediaWobblingDisablePost().ok
        }
    }

    /// Where the tracker is aimed right now, or nil when it sees nobody.
    ///
    /// Cheap enough to poll: the daemon answers from a cached target the tracking
    /// worker writes, so this reads a variable rather than a camera frame.
    func trackedFace() async throws -> RobotFaceTarget? {
        let payload = try await client
            .getTrackedFaceApiMediaTrackingFaceGet()
            .ok.body.json.additionalProperties.value
        return RobotFaceTarget.decoded(from: payload)
    }

    /// Daemon-side visual face tracking.
    ///
    /// - Returns: whether the robot is now tracking. Unlike wobbling this answer is
    ///   real: `enable_head_tracking` returns False when there is no camera, and the
    ///   route turns that into `status: "unavailable", enabled: false` — a refusal
    ///   wearing a 200.
    /// - Parameter weight: 0…1. Zero pauses the worker without stopping it, which is
    ///   why disabling is a separate route rather than `weight: 0`.
    @discardableResult
    func setFaceTracking(_ enabled: Bool, weight: Double = 1) async throws -> Bool {
        guard enabled else {
            // `disable_tracking` answers a constant `{"status":"ok","enabled":false}`
            // — the generator types it separately from the enable route's reply, and
            // decoding a constant to learn it is what it always was buys nothing.
            _ = try await client.disableTrackingApiMediaTrackingDisablePost().ok
            return false
        }
        let payload = try await client
            .enableTrackingApiMediaTrackingEnablePost(body: .json(.init(weight: weight)))
            .ok.body.json.additionalProperties
        // Absent rather than false would be a daemon that changed the shape of this
        // reply; treating that as "not tracking" is the safe way to be wrong.
        return payload["enabled"]?.value2 ?? false
    }
}
