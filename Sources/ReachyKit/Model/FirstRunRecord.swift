import Foundation

/// This device's own memory of a robot's first run, for when the robot cannot be
/// asked (#169).
///
/// The robot's `first_wake_up_completed` flag is the truth, and on the LAN it is
/// read over the robot's own data channel. That needs a WebRTC session, and a robot
/// with no media server — `--no-media`, a camera that failed, a network that blocks
/// it — never opens one. This record is the fallback the owner chose for that case:
/// a robot this device meets for the first time is offered the run, one it has
/// started and not finished is offered it again, and one it has seen through — or
/// seen marked by the robot itself — is never asked about again, so the WebRTC
/// check costs a robot one connect per device rather than every connect.
///
/// Keyed by `RobotIdentity.deduplicationKey`, like `KnownRobots`, never by address
/// (rule 4). The injectable defaults exist for the tests: `--parallel` runs suites
/// concurrently against one table.
public struct FirstRunRecordStore {
    public enum State: String, Sendable {
        /// The run was offered and has not ended — a disconnect halfway through.
        case pending
        /// Finished, skipped, or read as completed off the robot.
        case settled
    }

    static let key = "ReachyKit.firstRunRecords"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    public func state(for robot: String) -> State? {
        records[robot].flatMap(State.init(rawValue:))
    }

    public func record(_ state: State, for robot: String) {
        var records = records
        records[robot] = state.rawValue
        defaults.set(records, forKey: Self.key)
    }

    private var records: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
