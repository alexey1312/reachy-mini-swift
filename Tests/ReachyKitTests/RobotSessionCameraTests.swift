import Foundation
@testable import ReachyKit
import Testing

/// Whether the app offers video, which is `camera_specs_name` and not which robot
/// answered.
///
/// This suite exists because the previous rule — `wireless_version` — was wrong in
/// exactly one direction and no reference image could show it: `Root — no camera`
/// and `Floating viewport — no camera` both rendered correctly for a robot that
/// genuinely had none, while a Lite owner with a camera got the same picture.
@MainActor
@Suite("Offering the camera")
struct RobotSessionCameraTests {
    @Test("a Lite robot has a camera, and used to be told it did not")
    func liteHasACamera() {
        let session = RobotSession.preview(status: .preview(wirelessVersion: false))

        #expect(session.hasCamera)
    }

    @Test("a Wireless robot has one too")
    func wirelessHasACamera() {
        let session = RobotSession.preview(status: .preview(wirelessVersion: true))

        #expect(session.hasCamera)
    }

    /// MuJoCo names its camera `"mujoco"`, which is what `simulationEnabled` was
    /// standing in for before the field was read directly.
    @Test("a simulator reports a camera of its own")
    func simulatorHasACamera() {
        let session = RobotSession.preview(
            status: .preview(wirelessVersion: false, simulationEnabled: true)
        )

        #expect(session.hasCamera)
    }

    /// The empty string is what the wire carries when no media server was built:
    /// `--no-media`, no camera found, or one that failed to start. `Daemon` assigns
    /// the field exactly once and only on success, so absence is the daemon's own
    /// way of saying there is nothing to stream.
    @Test("no media server means no camera, whichever robot it is", arguments: [true, false])
    func noMediaServerMeansNoCamera(wirelessVersion: Bool) {
        let session = RobotSession.preview(
            status: .preview(wirelessVersion: wirelessVersion, cameraSpecsName: "")
        )

        #expect(!session.hasCamera)
    }

    /// Settled by the link before the status is consulted: the peer connection
    /// carrying the commands is the one carrying the video, and
    /// `RemoteRobotConnection` synthesises a status that names no camera at all.
    /// So this passes only while `isRemote` is asked first.
    @Test("a relayed session has a camera by construction")
    func relayHasACameraWithoutNamingOne() {
        let session = RobotSession.preview(
            status: .preview(cameraSpecsName: ""),
            address: nil,
            link: .remote
        )

        #expect(session.hasCamera)
    }

    /// Nothing has answered yet, so nothing may be offered.
    @Test("no status is no camera")
    func noStatusIsNoCamera() {
        let session = RobotSession.preview(status: nil, address: nil)

        #expect(!session.hasCamera)
    }
}
