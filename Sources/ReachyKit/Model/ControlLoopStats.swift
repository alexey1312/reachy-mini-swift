import Foundation

/// The robot's control loop as its daemon last measured it.
///
/// This is the only live health telemetry the daemon publishes over HTTP, and it
/// is the one that matters for a robot: not how busy the processor is, but whether
/// the loop driving the motors is holding its period. A Raspberry Pi at 20% CPU
/// with a loop that has fallen to 30 Hz is a robot in trouble; the CPU figure alone
/// would say everything is fine.
///
/// Every field is optional independently. The daemon fills the dictionary one key
/// at a time, and only after it has collected more than one interval to average —
/// so the first second after a backend starts reports a controller name and
/// nothing else.
public struct ControlLoopStats: Sendable, Equatable {
    /// Mean loop rate over the last second.
    ///
    /// The daemon targets **50 Hz** (`backend.py`, `self.control_loop_frequency`),
    /// and a real Reachy Mini Wireless answers 49.59. Nothing exposes the target, so
    /// a reader judging this number has to carry it — `HealthMetric` does.
    public let frequencyHz: Double?
    /// The longest single gap in that second. The mean hides a stall; this does not.
    public let maxIntervalSeconds: Double?
    /// Errors **in the last second**, not since the backend started: the daemon
    /// zeroes its own counter immediately after copying it here. The window matters
    /// for reading the number — 47 per second is a robot in trouble and 47 in an
    /// afternoon is nothing.
    public let errorCount: Int?
    /// Whatever `str(self.c.get_stats())` produced, despite the field being named
    /// `motor_controller`. On daemon 1.9.0 that is a timing breakdown rather than a
    /// name: `ControlLoopStats(period=~20.02ms, read_dt=~1.95 ms, write_dt=~0.44 ms)`,
    /// read off a real robot. Treat it as free-form daemon text, never as an
    /// identifier to match on.
    public let motorController: String?

    public init(
        frequencyHz: Double? = nil,
        maxIntervalSeconds: Double? = nil,
        errorCount: Int? = nil,
        motorController: String? = nil
    ) {
        self.frequencyHz = frequencyHz
        self.maxIntervalSeconds = maxIntervalSeconds
        self.errorCount = errorCount
        self.motorController = motorController
    }
}

public extension Components.Schemas.DaemonStatus {
    /// Nil whenever no real robot is driving.
    ///
    /// Three cases reach that, and none of them is an error to report: the MuJoCo
    /// and mockup backends publish no loop at all, and a relayed session's status is
    /// synthesised from the motor mode alone (`RemoteRobotConnection`), which leaves
    /// the dictionary empty. An empty dictionary answers nil rather than a struct of
    /// four nils, so a screen can ask one question instead of four.
    var controlLoop: ControlLoopStats? {
        guard let stats = backendStatus?.value1?.controlLoopStats.additionalProperties.value,
              !stats.isEmpty
        else { return nil }
        return ControlLoopStats(
            frequencyHz: Self.number(stats["mean_control_loop_frequency"]),
            maxIntervalSeconds: Self.number(stats["max_control_loop_interval"]),
            errorCount: Self.number(stats["nb_error"]).map { Int($0) },
            motorController: (stats["motor_controller"] ?? nil) as? String
        )
    }

    /// JSON numbers arrive as whichever Swift type `OpenAPIValueContainer` managed
    /// to decode them into, and that depends on the value rather than on the field:
    /// it tries `Int` before `Double`, so a loop running at exactly 100 Hz decodes
    /// as `Int` while 99.7 decodes as `Double`. Asking for one of them is a field
    /// that reads correctly all day and then blanks.
    private static func number(_ value: (any Sendable)??) -> Double? {
        switch value ?? nil {
        case let value as Double: value
        case let value as Int: Double(value)
        default: nil
        }
    }
}

// Deliberately not exposed: `RobotBackendStatus.last_alive` and `.ready`.
//
// Both are in the schema, both look like exactly what a health panel wants, and
// **daemon 1.9.0 never writes either one.** `RobotBackendStatus` is built once at
// backend start-up with `last_alive=None, ready=False`; the control loop then
// updates `self.last_alive` — the backend's own attribute, not the status object's
// field — and `get_status()` refreshes only `error` and `motor_control_mode` before
// handing the same instance back. So the wire carries `"last_alive": null,
// "ready": false` for the entire life of a perfectly healthy robot.
//
// A "last seen 3s ago" row built on that would read as a robot that has never
// answered. Check the daemon source before reviving either field.
