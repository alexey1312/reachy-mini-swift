import Foundation
import ReachyJSON

/// One installed app, cut down to what a widget can hold.
///
/// `RobotApp` encodes as the generated `AppInfo` verbatim — the entire Hugging
/// Face Space payload under `extra`, which exists so `POST /api/apps/install` gets
/// its object back unchanged. A widget installs nothing and decodes this blob on
/// every wake, so it carries the five fields a picker, a tile and `start-app`
/// actually need.
public struct RobotAppSummary: Codable, Sendable, Equatable, Identifiable {
    /// `RobotApp.id`. What the system stores in a widget's saved configuration,
    /// and the only key stable across the catalogue and the installed list.
    public let id: String
    /// `RobotApp.name` — the Python entry point. What `start-app/{app_name}` takes,
    /// and never an identity across lists (see `RobotApp.matches(installed:)`).
    public let name: String
    public let title: String
    public let emoji: String?
    public let gradient: RobotApp.Gradient?

    public init(id: String, name: String, title: String, emoji: String? = nil, gradient: RobotApp.Gradient? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.emoji = emoji
        self.gradient = gradient
    }

    public init(_ app: RobotApp) {
        self.init(id: app.id, name: app.name, title: app.title, emoji: app.emoji, gradient: app.gradient)
    }
}

/// The robot's installed apps, as the app last listed them.
public struct RobotAppsCache: Codable, Sendable, Equatable {
    /// A day, not `RobotSnapshotStore.freshness`'s half hour, and the consequence
    /// differs too: this is a *menu*, not a *reading*. A reading past its window
    /// must not be repeated as fact; a menu is merely old, and every launch is
    /// checked against the robot in real time regardless. So a stale list is still
    /// shown and still launchable — the widget only adds a footnote saying when it
    /// was taken.
    public static let freshness: TimeInterval = 24 * 60 * 60

    /// The stable identity established by the handshake that produced this list.
    /// The address is deliberately absent: it can change, and another robot can
    /// later receive it.
    public let robotID: String
    public let installed: [RobotAppSummary]
    public let takenAt: Date

    public init(robotID: String, installed: [RobotAppSummary], takenAt: Date) {
        self.robotID = robotID
        self.installed = installed
        self.takenAt = takenAt
    }

    public func summary(id: String) -> RobotAppSummary? {
        installed.first { $0.id == id }
    }

    public func isStale(at date: Date = Date()) -> Bool {
        // A negative age is a clock that moved backwards, not a list from the
        // future gone old.
        date.timeIntervalSince(takenAt) > Self.freshness
    }
}

/// The cache, in storage both processes can reach.
///
/// Only the most recently listed menu is stored, but it is bound to the hardware
/// identity that produced it. Connecting to another robot therefore reads no menu
/// until that robot has supplied one; it can never render or launch the previous
/// robot's entries by accident.
///
/// `@unchecked Sendable`, unlike `RobotSnapshotStore`, because an `EntityQuery`
/// requires it and this holds nothing but a `UserDefaults` — thread-safe by
/// documentation, unmarked by the compiler, exactly as `KnownRobots.defaults`
/// already records.
public struct RobotAppsCacheStore: @unchecked Sendable {
    static let key = "ReachyKit.installedApps"

    private let defaults: UserDefaults

    /// Defaults to the shared group, which is the only store the widget can read.
    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    private var stored: RobotAppsCache? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONCodec.stored.decode(RobotAppsCache.self, from: data)
    }

    public func current(for robotID: String) -> RobotAppsCache? {
        guard let stored, stored.robotID == robotID else { return nil }
        return stored
    }

    public func write(_ installed: [RobotAppSummary], robotID: String, at date: Date = Date()) {
        let cache = RobotAppsCache(robotID: robotID, installed: installed, takenAt: date)
        guard let data = try? JSONCodec.stored.encode(cache) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Deliberately **not** called on disconnect, unlike `RobotSnapshotStore.clear`.
    /// A configured widget would empty itself the moment someone let a robot go,
    /// and the identifiers its configuration is built from would stop resolving.
    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
