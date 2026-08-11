import Foundation

/// One catalogue, as a robot last answered it, in a form that survives the app
/// being unloaded.
///
/// The two conformers differ in payload and in how long their answer stays worth
/// showing, and in nothing else — which is why they share one store rather than
/// having one each.
public protocol RobotCatalogueRecord: Codable, Sendable, Equatable {
    static var slot: RobotCatalogueCache.Slot { get }
    /// How long this answer is still worth putting on screen. It bounds the case
    /// the revalidation cannot cover: a robot that is unreachable, or a Hugging
    /// Face that is down.
    static var freshness: TimeInterval { get }

    var schema: Int { get }
    /// The stable identity that produced this answer (`RobotIdentity.deduplicationKey`).
    /// The address is deliberately absent: it can change, and another robot can
    /// later receive it.
    var robotID: String { get }
    var takenAt: Date { get }
}

public extension RobotCatalogueRecord {
    func isStale(at date: Date = Date()) -> Bool {
        // A negative age is a clock that moved backwards, not a record from the
        // future gone old — the same reading `RobotAppsCache.isStale` takes.
        date.timeIntervalSince(takenAt) > Self.freshness
    }

    /// The one check a record passes before it reaches a screen.
    func isUsable(for robotID: String, at date: Date = Date()) -> Bool {
        schema == RobotCatalogueCache.schema && self.robotID == robotID && !isStale(at: date)
    }
}

/// The whole of `list-available` — installed apps and the Discover catalogue in
/// one answer, each entry a complete `AppInfo`.
///
/// Not `RobotAppSummary`, which is what the widget's `RobotAppsCache` holds: an
/// install hands the object back to the daemon unchanged, so a field lost here is
/// a field the robot would never receive.
public struct RobotAppCatalogueRecord: RobotCatalogueRecord {
    public static let slot = RobotCatalogueCache.Slot.apps
    /// The same day, and for the same reason, as `RobotAppsCache.freshness`: this
    /// is a *menu*, not a *reading*. Two different windows over one list — the
    /// widget's and the screen's — is a question whose right answer is that they
    /// are the same.
    public static let freshness: TimeInterval = 24 * 60 * 60

    public let schema: Int
    public let robotID: String
    public let apps: [RobotApp]
    public let takenAt: Date

    public init(
        schema: Int = RobotCatalogueCache.schema,
        robotID: String,
        apps: [RobotApp],
        takenAt: Date = Date()
    ) {
        self.schema = schema
        self.robotID = robotID
        self.apps = apps
        self.takenAt = takenAt
    }
}

/// The recorded-move index, every library the app has listed.
public struct RobotMoveIndexRecord: RobotCatalogueRecord {
    public static let slot = RobotCatalogueCache.Slot.moves
    /// A week, where the catalogue gets a day. A dataset index changes only when
    /// Pollen publishes a new dance, nothing in this app invalidates it, and the
    /// cost of one wrong row is a `play_move` the daemon refuses — which
    /// `MovesModel.lastError` already puts on screen.
    public static let freshness: TimeInterval = 7 * 24 * 60 * 60

    public let schema: Int
    public let robotID: String
    public let movesByDataset: [String: [String]]
    public let takenAt: Date

    public init(
        schema: Int = RobotCatalogueCache.schema,
        robotID: String,
        movesByDataset: [String: [String]],
        takenAt: Date = Date()
    ) {
        self.schema = schema
        self.robotID = robotID
        self.movesByDataset = movesByDataset
        self.takenAt = takenAt
    }
}
