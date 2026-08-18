import Foundation
@testable import ReachyKit
import ReachySimulator
import Testing

/// The robot's own description, for the suites a toy fixture cannot serve.
///
/// **These suites ran nowhere until `ReachySimulator` landed.** Both the URDF
/// parser's real-description tests and the whole Stewart geometry derivation were
/// gated on `REACHY_URDF_FIXTURE` pointing at a file someone had pulled off a
/// daemon by hand, because this client shipped no robot geometry. The simulator
/// carries upstream's description so a session with no robot can draw one, and the
/// same file answers here.
///
/// The environment variable still wins where it is set: pointed at a live daemon's
/// `GET /api/kinematics/urdf`, it is what would catch upstream changing the shape
/// the viewer assumes before the bundled copy is refreshed.
enum RobotDescriptionFixture {
    static func document() throws -> URDFDocument {
        if let path = ProcessInfo.processInfo.environment["REACHY_URDF_FIXTURE"] {
            return try URDFParser.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        }
        return try URDFParser.parse(BundledRobotGeometry().urdf())
    }

    static func geometry() throws -> StewartGeometry {
        try #require(StewartGeometry(urdf: document()))
    }
}
