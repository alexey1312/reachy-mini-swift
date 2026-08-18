import Foundation

/// The robot's description and meshes, carried in the app rather than fetched.
///
/// A simulated session has no daemon to ask. Every other client answers
/// `/api/kinematics/urdf` and `/api/kinematics/stl/{filename}` over HTTP, and
/// `RobotGeometryProvider` builds the whole 3D scene from those two calls alone —
/// so serving them from a bundle is all it takes for the same scene to appear over
/// no network at all.
///
/// **The files are upstream's, unmodified**: `reachy_mini`'s
/// `descriptions/reachy_mini/urdf`, Apache-2.0, whose text ships beside them. Not a
/// port and not a re-export — project rule 1 forbids copying their *code*, and
/// these are the robot's shape, which is the one thing a client cannot derive.
public struct BundledRobotGeometry: Sendable {
    public enum Failure: Error, Equatable {
        /// A mesh the description names is not in the bundle. Always a packaging
        /// mistake rather than a runtime condition — `BundledRobotGeometryTests`
        /// asserts the two sets match exactly, so this cannot reach a shipped app
        /// without the suite going red first.
        case missingAsset(String)
        case unreadableDescription
    }

    /// The 41 meshes the description draws, by the bare filename the URDF names
    /// them with once `URDFParser` has stripped the `package://` prefix.
    public static let meshFilenames: Set<String> = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "stl", subdirectory: nil) ?? []
        return Set(urls.map(\.lastPathComponent))
    }()

    public init() {}

    /// The description verbatim, as `/api/kinematics/urdf` would answer it.
    ///
    /// `robot.urdf` rather than upstream's `robot_no_collision.urdf`: which one a
    /// real daemon serves is up to its backend, and it makes no difference to what
    /// is drawn here — `URDFParser` skips the whole `<collision>` subtree, and the
    /// two files name the same 41 meshes from their `<visual>` elements. Shipping
    /// the unabridged one keeps the asset identical to the source it came from.
    public func urdf() throws -> String {
        guard let url = Bundle.module.url(forResource: "robot", withExtension: "urdf"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw Failure.unreadableDescription
        }
        return text
    }

    /// One mesh, by the name the description gives it — `antenna.stl`, not
    /// `package://assets/antenna.stl`. `URDFParser.strippedPackagePrefix` is what
    /// makes those the same call a LAN client makes.
    public func stlAsset(named filename: String) throws -> Data {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: name, withExtension: ext.isEmpty ? "stl" : ext),
              let data = try? Data(contentsOf: url)
        else {
            throw Failure.missingAsset(filename)
        }
        return data
    }
}
