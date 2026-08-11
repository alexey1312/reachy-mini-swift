import Foundation
@testable import ReachyKit
import Testing

/// `control_loop_stats` is a free-form object in the spec, so nothing about its
/// shape is checked at decode time — every guarantee this feature relies on has to
/// be asserted here against payloads the daemon actually emits.
@Suite("Control loop stats")
struct ControlLoopStatsTests {
    private func status(backend: String) throws -> Components.Schemas.DaemonStatus {
        let json = """
        {"type": "daemon_status", "robot_name": "reachy_mini", "state": "running",
         "wireless_version": true, "desktop_app_daemon": false,
         "simulation_enabled": false, "mockup_sim_enabled": false,
         "version": "1.9.0", "backend_status": \(backend)}
        """
        return try JSONDecoder.reachyDaemon.decode(
            Components.Schemas.DaemonStatus.self,
            from: Data(json.utf8)
        )
    }

    @Test("reads a full reading off a running robot backend")
    func readsFullReading() throws {
        let status = try status(backend: """
        {"ready": true, "motor_control_mode": "enabled", "last_alive": null,
         "control_loop_stats": {"mean_control_loop_frequency": 99.71,
                                "max_control_loop_interval": 0.0184,
                                "nb_error": 3, "motor_controller": "FeetechController"}}
        """)

        let loop = try #require(status.controlLoop)
        #expect(loop.frequencyHz == 99.71)
        #expect(loop.maxIntervalSeconds == 0.0184)
        #expect(loop.errorCount == 3)
        #expect(loop.motorController == "FeetechController")
    }

    /// `OpenAPIValueContainer` tries `Int` before `Double`, so the Swift type a
    /// field arrives as depends on the *value*: a loop running at exactly 100 Hz
    /// decodes as `Int` and the same field at 99.7 decodes as `Double`. Reading
    /// only one of the two is a row that works all day and then blanks.
    @Test("reads a whole-number frequency, which JSON carries without a decimal point")
    func readsIntegralFrequency() throws {
        let status = try status(backend: """
        {"ready": true, "motor_control_mode": "enabled", "last_alive": null,
         "control_loop_stats": {"mean_control_loop_frequency": 100, "nb_error": 0}}
        """)

        #expect(status.controlLoop?.frequencyHz == 100)
        #expect(status.controlLoop?.errorCount == 0)
    }

    /// The daemon fills the dictionary key by key and only once it has averaged
    /// more than one interval, so this is the first second of every backend.
    @Test("reads a partial reading, leaving the keys the daemon has not written yet nil")
    func readsPartialReading() throws {
        let status = try status(backend: """
        {"ready": true, "motor_control_mode": "enabled", "last_alive": null,
         "control_loop_stats": {"motor_controller": "FeetechController"}}
        """)

        let loop = try #require(status.controlLoop)
        #expect(loop.motorController == "FeetechController")
        #expect(loop.frequencyHz == nil)
        #expect(loop.maxIntervalSeconds == nil)
        #expect(loop.errorCount == nil)
    }

    /// Three separate situations collapse to this one: a MuJoCo backend, a mockup
    /// sim backend, and a relayed session whose status `RemoteRobotConnection`
    /// synthesises from the motor mode alone. None of them is a fault to report.
    @Test("answers nil for an empty dictionary rather than a struct of four nils")
    func emptyDictionaryIsNil() throws {
        let status = try status(backend: """
        {"ready": true, "motor_control_mode": "enabled", "last_alive": null,
         "control_loop_stats": {}}
        """)

        #expect(status.controlLoop == nil)
    }

    @Test("answers nil for a simulated backend, which carries no loop field at all")
    func simulatedBackendIsNil() throws {
        let status = try status(backend: """
        {"motor_control_mode": "enabled", "error": null}
        """)

        #expect(status.controlLoop == nil)
    }

    @Test("answers nil for a torn-down backend")
    func stoppedBackendIsNil() throws {
        #expect(try status(backend: "null").controlLoop == nil)
    }

    /// Project rule 3: an unknown field must not break decoding, and a *changed*
    /// one must not crash the reader either. A future daemon spelling the count as
    /// a string leaves that row empty and the others intact.
    @Test("ignores a value of an unexpected type instead of trapping")
    func unexpectedTypeIsIgnored() throws {
        let status = try status(backend: """
        {"ready": true, "motor_control_mode": "enabled", "last_alive": null,
         "control_loop_stats": {"nb_error": "none", "mean_control_loop_frequency": 99.5,
                                "loop_jitter_p99": 0.004}}
        """)

        let loop = try #require(status.controlLoop)
        #expect(loop.errorCount == nil)
        #expect(loop.frequencyHz == 99.5)
    }

    /// The fixture every preview and snapshot reference is built from has to
    /// produce a payload the reader can actually read, or the previews would prove
    /// nothing about the screen.
    @Test("the preview fixture round-trips through the wire format")
    func previewFixtureRoundTrips() {
        let status = Components.Schemas.DaemonStatus.preview(
            controlLoop: ControlLoopStats(
                frequencyHz: 99.4,
                maxIntervalSeconds: 0.021,
                errorCount: 2,
                motorController: "FeetechController"
            )
        )

        #expect(status.controlLoop?.frequencyHz == 99.4)
        #expect(status.controlLoop?.errorCount == 2)
        #expect(Components.Schemas.DaemonStatus.preview().controlLoop == nil)
    }
}
