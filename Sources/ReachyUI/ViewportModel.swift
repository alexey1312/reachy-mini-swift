import Observation
import ReachyDesign
import ReachyKit
import ReachyMedia
import ReachyScene

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
        /// never stop it. There is no HTTP API here, so there is no scene.
        case remote(CameraSession)
    }

    private(set) var content: Content = .scene
    private(set) var sceneModel: RobotSceneModel?
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
    private(set) var hearing: DirectionOfArrivalModel?
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

    var address: RobotAddress? {
        if case let .lan(address) = source {
            address
        } else {
            nil
        }
    }

    /// Only the LAN path has a 3D model at all, so the switcher is not what
    /// decides whether to offer one — the source is.
    var offersScene: Bool {
        if case .lan = source {
            true
        } else {
            false
        }
    }

    /// Why there is no 3D model, where there is a reason rather than a wait.
    var sceneUnavailableReason: String? {
        guard case .remote = source else { return nil }
        return String(
            localized: .reachy(
                "The robot's 3D description is served over its own network, which a relay session cannot reach."
            )
        )
    }

    /// Re-attaching to the same source is a no-op, so a SwiftUI redraw cannot
    /// restart the download. A different one tears everything down first — one
    /// robot can appear at several addresses, but the geometry is per robot.
    func attach(to source: Source) {
        guard self.source != source else { return }
        detach()
        self.source = source
        // Nothing to switch to over the relay, and landing on an empty 3D tab
        // would be a worse first frame than the video that is already arriving.
        if case .remote = source {
            content = .camera
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
        if case let .lan(address) = source {
            startHearing(at: address)
        }
        switch (content, source) {
        case let (.scene, .lan(address)):
            stopCamera()
            startScene(at: address)
        case (.scene, .remote):
            // Nothing to start. `sceneUnavailableReason` is what the view renders,
            // rather than a spinner that would never resolve.
            break
        case let (.camera, .lan(address)):
            // Paused rather than stopped: the meshes stay in memory, so coming
            // back to 3D does not re-download the robot's description.
            sceneModel?.pauseStream()
            startCamera(at: address)
        case let (.camera, .remote(session)):
            // Already running — `RemoteRobotLink` started it, and it is the same
            // connection the commands are on. Adopted, never started or stopped.
            cameraSession = session
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
            hearing = DirectionOfArrivalModel(address: address)
        }
        hearing?.start()
    }

    private func stopHearing() {
        hearing?.stop()
    }

    private func startScene(at address: RobotAddress) {
        if sceneModel == nil {
            guard let connection = try? RobotConnection(address: address) else {
                setupError = String(localized: .reachy("Could not reach \(address.host)"))
                return
            }
            sceneModel = RobotSceneModel(address: address, client: connection)
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
        case let (.remote(lhs), .remote(rhs)): lhs === rhs
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
            // preview that wants the badge injects a settled model, which has no
            // address and therefore no socket to open.
            hearing: DirectionOfArrivalModel? = nil
        ) -> ViewportModel {
            let model = ViewportModel()
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
