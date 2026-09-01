import Foundation
import Observation
import ReachyDesign
import ReachyKit
import ReachyMedia
import ReachyScene
import ReachySimulator

/// Owns the two live views of the robot — the 3D model and the camera — and
/// guarantees that only one of them is running.
///
/// The guarantee is the whole point: a viewport that is always on screen would
/// otherwise hold a WebRTC peer connection and a state-stream socket open for as
/// long as the app is in the foreground.
@MainActor
@Observable
final class ViewportModel {
    enum Content: String, CaseIterable, Identifiable {
        case scene
        case camera

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .scene: String(localized: .reachy("3D model"))
            case .camera: String(localized: .reachy("Camera"))
            }
        }

        var systemImage: String {
            switch self {
            case .scene: "cube.transparent"
            case .camera: "video"
            }
        }
    }

    /// Where the live views come from — and, for the camera, who owns them.
    enum Source {
        /// The daemon on this network: a 3D scene built from its URDF, and a
        /// camera session of our own.
        case lan(RobotAddress)
        /// A relay session. The camera is the peer connection that is *already up*
        /// and carrying the robot's commands, so this model borrows it and must
        /// never stop it. The connection rides along because the scene is reachable
        /// here too now — out of the app's own bundle, with the pose polled off the
        /// data channel rather than read from a socket that does not exist.
        case remote(CameraSession, connection: RemoteRobotConnection)
        /// A simulator in this very process. It is its own geometry server and its
        /// own state stream, so the scene needs nothing but the object; there is no
        /// camera, because there is nothing to point one at.
        ///
        /// Concrete rather than a pair of existentials: there is exactly one
        /// simulator type, and a class compares by identity the way `.remote` does.
        case simulated(SimulatedRobotClient)
    }

    private(set) var content: Content = .scene
    /// `internal(set)` rather than `private(set)`: the relay's half lives in a
    /// sibling file, and a `private` setter is scoped to this one — the same reason
    /// `RobotSession` gives for its own.
    internal(set) var sceneModel: RobotSceneModel?
    /// Shared between the scene and the hearing indicator; see `remotePoseStream`.
    var poseStream: RemotePoseStream?
    private(set) var cameraSession: CameraSession?
    /// Where the robot last heard a voice.
    ///
    /// **Owned here rather than by either engine, because it outlives the switch
    /// between them.** It is the one reading that is worth the same in both views —
    /// over the camera it names somebody the picture cannot show, and over the 3D
    /// model it explains why the head is about to turn. Hanging it off
    /// `RobotSceneModel`, which already receives the frames, would have made it a
    /// property of the 3D tab.
    ///
    /// Nil over the relay: no HTTP API means no state stream, the same reason there
    /// is no scene there.
    internal(set) var hearing: DirectionOfArrivalModel?
    /// Set when a transport could not even be constructed — a bad address, not a
    /// failure to reach the robot.
    private(set) var setupError: String?

    private(set) var source: Source?
    /// Whether `cameraSession` is ours to stop. A borrowed one is the same peer
    /// connection the remote control channel rides on: ending it here would take
    /// the robot's commands down with the video, and the viewport scrolling off
    /// screen is not a reason to end a session.
    private var ownsCamera = false
    private var isActive = false

    /// How loud this device's voice comes out of the robot, where 1 is unchanged.
    ///
    /// **The one control over the loudness a person actually complains about.** The
    /// daemon applies no software gain and its mixer is already at 100, so the robot
    /// cannot play a sound louder to match a call — the call has to come down to meet
    /// the sounds. Stored on the device rather than on the robot, because it scales
    /// *this* microphone.
    var callMicVolume: Double = UserDefaults.standard.object(forKey: ViewportModel.micVolumeKey) as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(callMicVolume, forKey: ViewportModel.micVolumeKey)
            cameraSession?.micVolume = callMicVolume
        }
    }

    static let micVolumeKey = "callMicVolume"
    /// Below 0.1 a voice is gone rather than quiet, and above 2 the encoder clips
    /// before the robot gets louder. libwebrtc itself accepts 0…10.
    static let micVolumeRange: ClosedRange<Double> = 0.1 ... 2

    var address: RobotAddress? {
        if case let .lan(address) = source {
            address
        } else {
            nil
        }
    }

    /// Which sources have a 3D model at all: the switcher is not what decides
    /// whether to offer one — the source is. Only the relay has none.
    var offersScene: Bool {
        switch source {
        case .lan, .simulated, .remote: true
        case nil: false
        }
    }

    /// Whether the joystick belongs over the 3D model as well as over the camera.
    ///
    /// Only the simulator, and the reason is what the model *is* there: the
    /// simulator is its own robot, so the scene is the thing being driven rather
    /// than a picture of it. A LAN robot's scene mirrors the state stream, and a
    /// pad over it would move a model while the camera — the view a person checks
    /// the robot against — sits behind another segment. That one keeps its
    /// joystick over the video, where the two agree.
    var offersSceneTeleop: Bool {
        switch source {
        case .simulated: true
        case .lan, .remote, nil: false
        }
    }

    /// Re-attaching to the same source is a no-op, so a SwiftUI redraw cannot
    /// restart the download. A different one tears everything down first — one
    /// robot can appear at several addresses, but the geometry is per robot.
    func attach(to source: Source) {
        guard self.source != source else { return }
        detach()
        self.source = source
        // Each source has one content it can actually show first: the relay has
        // only video, and a simulator has only the model. Landing on the other
        // would be an empty pane in both directions.
        switch source {
        case .remote: content = .camera
        case .simulated: content = .scene
        case .lan: break
        }
        activate()
    }

    func detach() {
        sceneModel?.stop()
        sceneModel = nil
        stopCamera()
        // Dropped rather than merely stopped: `detach` is a different robot, and a
        // held reading would be the previous one's.
        stopHearing()
        hearing = nil
        poseStream = nil
        source = nil
        setupError = nil
    }

    func setContent(_ next: Content) {
        guard content != next else { return }
        guard next != .scene || offersScene else { return }
        content = next
        activate()
    }

    /// The single lever for "is the viewport on screen": the Live tab's appearance
    /// on compact, the scene phase everywhere.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            activate()
        } else {
            suspend()
        }
    }

    /// Starts whichever engine `content` names and shuts the other one down.
    private func activate() {
        guard isActive, let source else { return }
        setupError = nil
        // Outside the switch on purpose: it is wanted under both contents, and the
        // one thing that decides it is whether this connection has a state stream
        // at all.
        switch source {
        case let .lan(address):
            startHearing(at: address)
        case let .remote(camera, connection):
            startRemoteHearing(connection, camera: camera)
        case .simulated:
            // The simulator publishes its own state and has no microphones to
            // report a direction from.
            break
        }
        switch (content, source) {
        case let (.scene, .lan(address)):
            stopCamera()
            startScene(at: address)
        case let (.scene, .remote(camera, connection)):
            stopCamera()
            startRemoteScene(connection, camera: camera)
        case let (.camera, .lan(address)):
            // Paused rather than stopped: the meshes stay in memory, so coming
            // back to 3D does not re-download the robot's description.
            sceneModel?.pauseStream()
            startCamera(at: address)
        case let (.scene, .simulated(client)):
            stopCamera()
            startSimulatedScene(client)
        case (.camera, .simulated):
            // Unreachable in practice and stated rather than assumed: a simulator
            // reports no `camera_specs_name`, so `session.hasCamera` is false and
            // `ViewportOptions.offered` never puts `.camera` in the switcher. The
            // arm exists because a source change must not be able to land here
            // silently.
            break
        case let (.camera, .remote(session, _)):
            // Already running — `RemoteRobotLink` started it, and it is the same
            // connection the commands are on. Adopted, never started or stopped.
            cameraSession = session
            // Adopted, so nothing here built the track — the gain still has to reach it.
            session.micVolume = callMicVolume
            ownsCamera = false
        }
    }

    private func suspend() {
        sceneModel?.pauseStream()
        stopCamera()
        stopHearing()
    }

    /// Idempotent, and it keeps the model across a suspend so a reading still inside
    /// its window survives a glance at another tab. Only `detach()` throws it away,
    /// because that is a different robot.
    private func startHearing(at address: RobotAddress) {
        if hearing == nil {
            // An address no socket can be built from leaves an inert model rather
            // than an error: this indicator has never had a failure state, and one
            // reading fewer is not worth a banner over the viewport.
            hearing = DirectionOfArrivalModel(stream: try? RobotStateStream(address: address))
        }
        hearing?.start()
    }

    private func stopHearing() {
        hearing?.stop()
    }

    private func startSimulatedScene(_ client: SimulatedRobotClient) {
        if sceneModel == nil {
            // One object for both roles: it serves the geometry out of the app's
            // bundle and publishes the state stream itself, which is the whole
            // reason the `RobotStateStreaming` seam exists.
            sceneModel = RobotSceneModel(stream: client, client: client)
        }
        sceneModel?.start()
        sceneModel?.resumeStream()
    }

    private func startScene(at address: RobotAddress) {
        if sceneModel == nil {
            guard let connection = try? RobotConnection(address: address),
                  let stream = try? RobotStateStream(address: address)
            else {
                setupError = String(localized: .reachy("Could not reach \(address.host)"))
                return
            }
            sceneModel = RobotSceneModel(stream: stream, client: connection)
        }
        // Both are idempotent; whichever applies at this point is the one that runs.
        sceneModel?.start()
        sceneModel?.resumeStream()
    }

    private func startCamera(at address: RobotAddress) {
        guard cameraSession == nil else { return }
        guard let session = try? CameraSession(address: address) else {
            setupError = String(localized: .reachy("Could not reach \(address.host)"))
            return
        }
        cameraSession = session
        ownsCamera = true
        session.micVolume = callMicVolume
        session.start()
    }

    /// WebRTC has no cheap pause — a session we built is dropped and renegotiated
    /// from scratch next time. A borrowed one is only let go of: over the relay it
    /// is the connection the robot is being controlled through, so stopping it to
    /// save battery would disconnect the robot.
    private func stopCamera() {
        if ownsCamera {
            cameraSession?.stop()
        }
        cameraSession = nil
        ownsCamera = false
    }
}

extension ViewportModel.Source: Equatable {
    /// Two borrowed cameras are the same source only when they are the same
    /// object — `CameraSession` is a reference type with no value identity, and
    /// `.task(id:)` in the root view compares these to decide whether to re-attach.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.lan(lhs), .lan(rhs)): lhs == rhs
        // The camera decides identity: the connection is the same peer's, so two
        // sources naming one camera are one source.
        case let (.remote(lhs, _), .remote(rhs, _)): lhs === rhs
        case let (.simulated(lhs), .simulated(rhs)): lhs === rhs
        default: false
        }
    }
}

#if DEBUG
    extension ViewportModel {
        /// Assembled rather than attached: `attach(to:)` would build a real `RobotConnection` and
        /// a real `CameraSession`. Lives here because every field below is `private(set)`.
        static func preview(
            content: Content = .scene,
            sceneModel: RobotSceneModel? = nil,
            cameraSession: CameraSession? = nil,
            setupError: String? = nil,
            address: RobotAddress? = RobotAddress(host: "192.168.1.42"),
            // Overrides `address` where the transport is the point. Defaulted from
            // it so every preview written before the relay existed is unchanged.
            source: Source? = nil,
            // Nil by default, so the direction-of-arrival badge is absent from every
            // reference that predates it and none of them moved when it landed. A
            // preview that wants the badge injects a settled model, which is built
            // with no stream and therefore has no socket to open.
            hearing: DirectionOfArrivalModel? = nil,
            // Always assigned, never left to the stored default: the real one reads
            // `UserDefaults`, so a preview that took whatever a previous one wrote
            // would render a different slider on each run.
            callMicVolume: Double = 1
        ) -> ViewportModel {
            let model = ViewportModel()
            model.callMicVolume = callMicVolume
            model.content = content
            model.sceneModel = sceneModel
            model.cameraSession = cameraSession
            model.setupError = setupError
            model.source = source ?? address.map(Source.lan)
            model.hearing = hearing
            return model
        }
    }
#endif
