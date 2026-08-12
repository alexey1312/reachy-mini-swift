import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

/// A stopped daemon still answers `/api/daemon/status`, but nulls the fields
/// that only exist while the robot backend runs. Decoding must survive that —
/// it is the only path to a handshake with a sleeping robot.
@Suite("DaemonStatus decoding")
struct DaemonStatusDecodingTests {
    @Test("decodes a stopped daemon (backend torn down, backend_status null)")
    func decodesStoppedDaemon() throws {
        let json = """
        {"type": "daemon_status", "robot_name": "reachy_mini", "state": "stopped",
         "wireless_version": true, "desktop_app_daemon": false,
         "simulation_enabled": false, "mockup_sim_enabled": false,
         "no_media": false, "media_released": false, "camera_specs_name": "",
         "backend_status": null, "error": null, "wlan_ip": "192.168.1.42",
         "version": "1.9.0", "hardware_id": "abc123"}
        """
        let status = try JSONCodec.daemon.decode(
            Components.Schemas.DaemonStatus.self,
            from: Data(json.utf8)
        )

        #expect(status.state == .stopped)
        #expect(status.version == "1.9.0")
        #expect(status.backendStatus == nil)
    }

    @Test("decodes a never-started daemon (simulation flags null too)")
    func decodesNotInitializedDaemon() throws {
        let json = """
        {"type": "daemon_status", "robot_name": "reachy_mini", "state": "not_initialized",
         "wireless_version": true, "desktop_app_daemon": false,
         "simulation_enabled": null, "mockup_sim_enabled": null,
         "backend_status": null, "version": "1.9.0"}
        """
        let status = try JSONCodec.daemon.decode(
            Components.Schemas.DaemonStatus.self,
            from: Data(json.utf8)
        )

        #expect(status.state == .notInitialized)
        #expect(status.simulationEnabled == nil)
        #expect(status.mockupSimEnabled == nil)
    }

    @Test("decodes a running daemon whose backend has not reported last_alive yet")
    func decodesRunningDaemonWithoutLastAlive() throws {
        let json = """
        {"type": "daemon_status", "robot_name": "reachy_mini", "state": "running",
         "wireless_version": true, "desktop_app_daemon": false,
         "simulation_enabled": false, "mockup_sim_enabled": false,
         "backend_status": {"ready": true, "motor_control_mode": "disabled",
                            "last_alive": null, "control_loop_stats": {}},
         "version": "1.9.0"}
        """
        let status = try JSONCodec.daemon.decode(
            Components.Schemas.DaemonStatus.self,
            from: Data(json.utf8)
        )

        #expect(status.state == .running)
        #expect(status.backendStatus?.value1?.motorControlMode == .disabled)
    }
}
