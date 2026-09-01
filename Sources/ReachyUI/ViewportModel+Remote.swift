import ReachyKit
import ReachyMedia
import ReachyScene
import SwiftUI

/// What the viewport does over the relay: a scene built from the app's own copy of
/// the robot, and a pose read off the channel the robot pushes on.
///
/// A file of its own because `ViewportModel` is at SwiftLint's length limit — the
/// split `RobotConnection+Wireless` and `+Apps` make.
@MainActor
extension ViewportModel {
    /// The scene over the relay: the robot's shape out of this app, its pose off
    /// the data channel.
    ///
    /// Paused rather than stopped when the camera takes over, the same trade the
    /// LAN path makes — except that here what is kept is meshes read from the
    /// bundle, so the saving is decoding rather than download.
    func startRemoteScene(_ connection: RemoteRobotConnection, camera: CameraSession) {
        if sceneModel == nil {
            sceneModel = RobotSceneModel(
                stream: remotePose(connection: connection, camera: camera),
                client: BundledGeometryClient()
            )
        }
        sceneModel?.start()
        sceneModel?.resumeStream()
    }

    /// The indicator over the relay, on the frames the scene is already reading.
    ///
    /// Only where the robot pushes them: the polled fallback answers `get_state`,
    /// whose reply this app decodes for the pose alone, so an older daemon gets the
    /// scene and no badge. `isSupported` on the model is what says so on screen.
    func startRemoteHearing(_ connection: RemoteRobotConnection, camera: CameraSession) {
        guard hearing == nil, camera.poseChannel.isOpen else { return }
        hearing = DirectionOfArrivalModel(stream: remotePoseStream(connection, camera: camera))
        hearing?.start()
    }

    /// Pushed where the robot offers it, asked for where it does not.
    ///
    /// Daemon 1.10.0 opens a second data channel labelled `pose` during the same
    /// negotiation that brings up the control one, so by the time a scene is
    /// started the answer is already known. A daemon before that opens no such
    /// channel and never will, which is exactly what `isOpen` reports.
    ///
    /// The consequence of guessing wrong is a missed optimisation rather than a
    /// broken scene: polling works against both.
    func remotePose(
        connection: RemoteRobotConnection,
        camera: CameraSession
    ) -> any RobotStateStreaming {
        camera.poseChannel.isOpen
            ? remotePoseStream(connection, camera: camera)
            : RemoteStateStream(connection: connection)
    }

    /// One stream for the scene and the indicator both. The channel hands its
    /// messages to a single reader, so a second stream would take the first's
    /// frames — and `RemotePoseStream` fans out precisely so this can be shared.
    func remotePoseStream(
        _ connection: RemoteRobotConnection,
        camera: CameraSession
    ) -> RemotePoseStream {
        if let poseStream {
            return poseStream
        }
        let stream = RemotePoseStream(connection: connection, channel: camera.poseChannel)
        poseStream = stream
        return stream
    }
}
