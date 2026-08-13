import Foundation

/// The two daemon-side behaviours that make a robot feel present rather than parked.
///
/// A protocol of its own rather than four more methods on ``RobotAPIClient``, for
/// the reason ``CacheMaintenanceClient`` is one: conforming *is* the capability, so
/// a session over the Hugging Face relay — whose control channel carries none of
/// this — reports it unavailable instead of failing a switch somebody just moved.
///
/// **Neither can be read back.** No route reports whether either is on:
/// `media/status` describes the media server, and a face target's `detected: false`
/// cannot tell "tracking off" from "nobody in front of the camera". Whatever calls
/// this owns the state it asked for, and owes the reader an honest account of that.
public protocol PresenceClient: Sendable {
    /// Audio-reactive head wobbling, driven by audio the **daemon** is playing.
    ///
    /// A 200 does not mean it took: the route's call sits inside a media-server nil
    /// check that its `{"status": "ok"}` is outside of.
    func setWobbling(_ enabled: Bool) async throws

    /// Daemon-side visual face tracking.
    ///
    /// - Returns: whether the robot is now tracking. This answer *is* real — a robot
    ///   with no camera answers `enabled: false` under a 200.
    @discardableResult
    func setFaceTracking(_ enabled: Bool, weight: Double) async throws -> Bool
}

extension RobotConnection: PresenceClient {}

public extension RobotSession {
    /// False over the relay, whose data channel carries no media routes.
    var canControlPresence: Bool {
        client is any PresenceClient
    }

    func setWobbling(_ enabled: Bool) async throws {
        try await withPresenceClient { try await $0.setWobbling(enabled) }
    }

    /// - Returns: whether the robot took it. False from a camera-less robot, which
    ///   the screen reports rather than leaving a switch on over a robot watching
    ///   nothing.
    @discardableResult
    func setFaceTracking(_ enabled: Bool) async throws -> Bool {
        try await withPresenceClient { try await $0.setFaceTracking(enabled, weight: 1) }
    }
}

extension RobotSession {
    func withPresenceClient<T>(_ call: (any PresenceClient) async throws -> T) async throws -> T {
        guard let client else { throw ReachyKitError.notConnected }
        guard let presence = client as? any PresenceClient else {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
        return try await call(presence)
    }
}
