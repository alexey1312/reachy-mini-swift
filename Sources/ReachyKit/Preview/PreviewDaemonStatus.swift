#if DEBUG
    import Foundation
    import ReachyJSON

    /// What the daemon says about itself, as a fixture.
    ///
    /// Split out of `PreviewFixtures.swift` when that file crossed SwiftLint's 400-line
    /// ceiling — which `--strict` makes a build failure — and it is the right seam
    /// rather than an arbitrary one: everything here builds one JSON payload, while
    /// its neighbour builds client doubles and value fixtures.
    public extension Components.Schemas.DaemonStatus {
        /// Built by decoding JSON rather than through the generated memberwise initialiser: the
        /// `backend_status` payload is a `oneOf` whose Swift shape changes whenever the spec is
        /// refreshed, while the daemon's own wire format is the stable thing to pin a fixture to.
        static func preview(
            state: Components.Schemas.DaemonState = .running,
            motorMode: Components.Schemas.MotorControlMode = .enabled,
            error: String? = nil,
            wirelessVersion: Bool = true,
            simulationEnabled: Bool = false,
            mockupSimEnabled: Bool = false,
            // The camera the daemon detected, which is what `hasCamera` reads.
            // `nil` derives the name this robot would report; `""` is what the wire
            // carries when there is no media server — no camera, `--no-media`, or
            // one that failed to start.
            cameraSpecsName: String? = nil,
            controlLoop: ControlLoopStats? = nil,
            // Absent by default: the field was never in this fixture, and adding one
            // would move every reference that draws the installed version.
            version: String? = nil
        ) -> Components.Schemas.DaemonStatus {
            let camera = cameraSpecsName ?? Self.previewCameraName(
                wirelessVersion: wirelessVersion,
                simulationEnabled: simulationEnabled,
                mockupSimEnabled: mockupSimEnabled
            )
            let backend = state == .running
                ? """
                {"ready": true, "motor_control_mode": "\(motorMode.rawValue)",
                 "last_alive": null, "control_loop_stats": \(Self.previewLoopJSON(controlLoop))}
                """
                : "null"
            let errorField = error.map { "\"error\": \"\($0)\"," } ?? ""
            let versionField = version.map { "\"version\": \"\($0)\"," } ?? ""
            let json = """
            {"robot_name": "Reachy Mini", "state": "\(state.rawValue)",
             "wireless_version": \(wirelessVersion), "desktop_app_daemon": false,
             "simulation_enabled": \(simulationEnabled), "mockup_sim_enabled": \(mockupSimEnabled),
             "camera_specs_name": "\(camera)",
             \(errorField)\(versionField)
             "backend_status": \(backend)}
            """
            // swiftlint:disable:next force_try
            return try! JSONCodec.daemon.decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
        }

        /// The `CameraSpecs.name` each robot's daemon would report, from
        /// `reachy_mini/media/camera_constants.py`. A **Lite unit names one too** —
        /// `ReachyMiniLiteCamSpecs.name` is `"lite"` — which is the whole point of
        /// deriving this rather than leaving it empty off a wired robot.
        private static func previewCameraName(
            wirelessVersion: Bool,
            simulationEnabled: Bool,
            mockupSimEnabled: Bool
        ) -> String {
            if simulationEnabled || mockupSimEnabled {
                return "mujoco"
            }
            return wirelessVersion ? "wireless" : "lite"
        }

        /// Written back out as the daemon writes it — one key per measurement,
        /// absent rather than null when it has none — so a fixture cannot describe a
        /// payload the robot could not send.
        private static func previewLoopJSON(_ stats: ControlLoopStats?) -> String {
            guard let stats else { return "{}" }
            let fields: [String?] = [
                stats.frequencyHz.map { "\"mean_control_loop_frequency\": \($0)" },
                stats.maxIntervalSeconds.map { "\"max_control_loop_interval\": \($0)" },
                stats.errorCount.map { "\"nb_error\": \($0)" },
                stats.motorController.map { "\"motor_controller\": \"\($0)\"" },
            ]
            return "{\(fields.compactMap(\.self).joined(separator: ", "))}"
        }
    }
#endif
