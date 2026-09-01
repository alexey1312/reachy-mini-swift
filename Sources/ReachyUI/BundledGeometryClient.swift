import Foundation
import ReachyKit
import ReachySimulator

/// The robot's shape, served out of this app to a session that cannot ask for it.
///
/// `RobotGeometryProvider` reads exactly two things off its client — the URDF and
/// the meshes that description names — so this answers those and refuses the rest.
/// It is not a robot and never pretends to be one: the pose comes from
/// ``RemoteStateStream``, and every command goes to the real connection.
///
/// The assets are already in the app. `ReachySimulator` carries them because a
/// simulated robot has no daemon to ask, and a relayed one has no route to ask
/// over — the same absence, answered the same way, rather than a second copy.
struct BundledGeometryClient: RobotAPIClient {
    private let geometry = BundledRobotGeometry()

    func urdf() async throws -> String {
        try geometry.urdf()
    }

    func stlAsset(named filename: String) async throws -> Data {
        try geometry.stlAsset(named: filename)
    }

    /// Everything below is required by `RobotAPIClient` and never called: the scene
    /// asks this object for geometry and nothing else. Throwing rather than
    /// answering keeps it that way — a caller that starts using this as a robot
    /// finds out at once.
    func handshake() async throws -> RobotConnection.Handshake {
        throw ReachyKitError.notConnected
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        throw ReachyKitError.notConnected
    }

    func wakeUp() async throws -> String {
        throw ReachyKitError.notConnected
    }

    func gotoSleep() async throws -> String {
        throw ReachyKitError.notConnected
    }
}
