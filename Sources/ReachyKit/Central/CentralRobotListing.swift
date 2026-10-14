import Foundation

/// The one thing a screen needs from central: which of this account's Reachy Minis
/// are reachable right now.
///
/// A protocol rather than the client itself so listing can be stood up without
/// HTTP — the same reason `RobotAPIClient` exists next to `RobotConnection`.
public protocol CentralRobotListing: Sendable {
    /// Presence in the answer *is* the online signal: central sweeps a peer whose
    /// lease lapsed, so a robot that is off simply is not in the list.
    func robots() async throws -> [CentralRobot]
}

extension CentralRelayClient: CentralRobotListing {}
