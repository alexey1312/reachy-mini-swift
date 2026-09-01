import Foundation
import ReachyKit
import ReachySimulator

/// The robot's shape, served out of this app to a session that cannot ask for it.
///
/// `RobotGeometryProvider` reads exactly two things off its client — the URDF and
/// the meshes that description names — and ``RobotGeometryClient`` is that pair, so
/// this conforms to it rather than posing as a connection.
/// It is not a robot and never pretends to be one: the pose comes from the `pose`
/// channel (``RemotePoseStream``, or ``RemoteStateStream`` behind it on an older
/// daemon), and every command goes to the real connection.
///
/// The assets are already in the app. `ReachySimulator` carries them because a
/// simulated robot has no daemon to ask, and a relayed one has no route to ask
/// over — the same absence, answered the same way, rather than a second copy.
struct BundledGeometryClient: RobotGeometryClient {
    private let geometry = BundledRobotGeometry()

    func urdf() async throws -> String {
        try geometry.urdf()
    }

    func stlAsset(named filename: String) async throws -> Data {
        try geometry.stlAsset(named: filename)
    }
}
