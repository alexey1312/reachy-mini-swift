import Foundation

/// The last recorded move this app asked a robot to play.
///
/// Persisted because a move outlives the process that started it: force-quit the
/// app mid-dance and the robot keeps going. `GET /api/move/running` is how the
/// next launch finds out — but it answers with UUIDs and nothing else, so
/// matching one against this record is the only way to say *which* dance is
/// playing rather than merely that one is.
public struct MovePlaybackRecord: Codable, Sendable, Equatable {
    /// `RobotIdentity.deduplicationKey`, so a record cannot be read back against
    /// a different robot. A UUID4 would not collide, but two robots on one
    /// network are two robots, and the wrong name is worse than no name.
    public let robotID: String
    public let uuid: String
    public let dataset: String
    public let move: String

    public init(robotID: String, uuid: String, dataset: String, move: String) {
        self.robotID = robotID
        self.uuid = uuid
        self.dataset = dataset
        self.move = move
    }
}

/// Where `MovePlaybackRecord` lives between launches.
///
/// Injectable for the reason `RobotSnapshotStore` and `RobotAppsCacheStore` are:
/// `swift test --parallel` runs suites concurrently against one `UserDefaults`
/// table, so a shared store makes one suite's writes another's reads.
public struct MovePlaybackStore {
    static let key = "ReachyKit.movePlayback"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    public var current: MovePlaybackRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(MovePlaybackRecord.self, from: data)
    }

    public func write(_ record: MovePlaybackRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
