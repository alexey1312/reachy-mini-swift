import Foundation

/// What the robot can actually do right now, split along the two axes the
/// daemon really gates on.
///
/// Most `/api` routes depend on `get_backend`, which answers 503 whenever the
/// backend is torn down — that is one axis. Motion additionally needs the
/// motors under power: a robot parked in `disabled` accepts every move command,
/// plays the sound, and does not move. Camera and daemon logs sit outside both.
public extension RobotSession {
    var isBackendRunning: Bool {
        lastStatus?.isBackendRunning ?? false
    }

    /// Reported by all three backend flavours (robot, MuJoCo, mockup sim).
    var motorMode: Components.Schemas.MotorControlMode? {
        lastStatus?.motorControlMode
    }

    /// Gate for anything that moves the robot.
    var isAwake: Bool {
        lastStatus?.isAwake ?? false
    }

    /// The daemon's own fault text, e.g. "Power supply not connected".
    ///
    /// `Daemon.status()` copies a backend error up to the top level and forces
    /// `state` to `error`, so the top-level field is the one that usually carries
    /// it; the per-flavour fields are the fallback.
    var backendFault: String? {
        let candidates = [
            lastStatus?.error,
            lastStatus?.backendStatus?.value1?.error,
            lastStatus?.backendStatus?.value2?.error,
            lastStatus?.backendStatus?.value3?.error,
        ]
        return candidates
            .compactMap(\.self)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Whether the daemon has a camera to stream, taken from the one field that
    /// says so rather than inferred from which robot it is.
    ///
    /// **This used to read `wirelessVersion`, on the belief that "a wired unit has
    /// no camera at all". The daemon's own source says otherwise**, in four places:
    /// `media/camera_constants.py` defines `ReachyMiniLiteCamSpecs` with
    /// `name = "lite"` and its own resolutions and calibration; `device_detection.py`
    /// matches the camera by display name (`Reachy`, `Arducam_12MP`, `imx708`) and
    /// carries a `Darwin` branch returning an `avfvideosrc` index, which exists for
    /// no reason but a daemon running on somebody's Mac; `daemon.py` builds the
    /// media server under `if not no_media:` and branches media on nothing else —
    /// `wireless_version` reaches it but changes only whether `wlan_ip` is
    /// published; and `/api/camera/specs` depends on `get_daemon` with no guard at
    /// all. Pollen's own hardware datasheet lists a Raspberry Pi Camera v3 on the
    /// Lite controller board. So a Lite owner was shown no video for a camera they
    /// have.
    ///
    /// `camera_specs_name` is the honest signal and was already arriving undecoded:
    /// `Daemon` assigns it exactly once, `self._status.camera_specs_name =
    /// self._media_server.camera_specs.name`, and only if the media server was
    /// built. No camera, `--no-media`, or a media server that failed to come up all
    /// leave it at the schema's empty default. It also covers the simulator for
    /// free — MuJoCo reports `"mujoco"` — which is what `simulationEnabled` was
    /// doing here.
    ///
    /// Over the relay the question is settled before any of that: the peer
    /// connection carrying the commands is the one carrying the video, so there is
    /// a camera by construction, and `RemoteRobotConnection` synthesises a status
    /// that reports no camera name at all.
    ///
    /// Not consulted: `media_released`. A released media server still names its
    /// camera, and offering video while an app holds it would fail — but that is a
    /// transient the UI does not model anywhere yet, and reading it here alone
    /// would be half an answer.
    var hasCamera: Bool {
        isRemote || lastStatus?.cameraSpecsName?.isEmpty == false
    }

    /// The 3D model needs a description, meshes and a pose. Two of those come out
    /// of the app on every link that cannot fetch them — the simulator has served
    /// them from its bundle all along, and the relay now does the same — and the
    /// pose is polled off the data channel where there is no socket to open.
    ///
    /// So this is now every link but none: ADR 0003 gave the scene up over the
    /// relay because the routes are HTTP, and the shape of a Reachy Mini turned out
    /// not to be something a client has to be told.
    var canRenderScene: Bool {
        switch link {
        case .lan, .simulated, .remote: true
        case .none: false
        }
    }

    /// Whether this robot has dances to offer and a way to play them.
    ///
    /// Asked of the transport rather than of the address, which stood in for it and
    /// was wrong in both directions: a relayed session has no address and plays
    /// perfectly well, while the simulator has an address of sorts and no library
    /// at all. `MovePlaybackClient.offersMoveLibrary` is the question itself.
    var canPlayMoves: Bool {
        movesClient?.offersMoveLibrary == true
    }

    /// The robot's inertial reading, or nil where there is none to read.
    ///
    /// Not cached and not polled here: it changes when somebody moves the robot,
    /// which is not on any schedule this session keeps.
    func imuReading() async throws -> RobotIMUReading? {
        guard let client else { throw ReachyKitError.notConnected }
        return try await client.imuReading()
    }

    /// Whether the beta channel is closed to this robot.
    ///
    /// Daemons before 1.10.0 rank the PyPI pre-release list as strings, so `1.9.0rc1`
    /// outranks `1.10.0rc5`: `/update/available` answers "up to date" and
    /// `/update/start` refuses with 400. The daemon-side fix ships in the very
    /// version those robots cannot reach, so the toggle is inert until a stable
    /// update carries them past it.
    var refusesPreReleaseUpdates: Bool {
        DaemonCompatibilityPolicy.isKnownOlder(than: "1.10.0", reported: lastStatus?.version)
    }

    /// `/wifi/*` and `/update/*` are mounted only under `--wireless-version`, so a
    /// Lite robot answers 404 to all of them. Hide those controls rather than let
    /// the user press a button that cannot work.
    var supportsWirelessFeatures: Bool {
        lastStatus?.wirelessVersion == true
    }
}
