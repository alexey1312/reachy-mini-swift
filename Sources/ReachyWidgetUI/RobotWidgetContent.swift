import Foundation
import ReachyDesign
import ReachyKit

/// What the widget puts on screen, worked out from a snapshot before any view is
/// involved — so the one rule that matters here is testable without rendering
/// anything.
///
/// That rule: a reading past its window is reported as *when it was taken*, never
/// as what the robot is doing. Nothing tells this app that a robot was switched
/// off, carried out of range or unplugged, and a widget still reading "Awake" an
/// hour later is worse than one admitting it does not know.
public struct RobotWidgetContent: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let symbolName: String
    /// Lets the view render a memory differently from a live reading, without
    /// having to work out which it is.
    public let isStale: Bool

    public init(title: String, detail: String, symbolName: String, isStale: Bool) {
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.isStale = isStale
    }

    public init(state: RobotSnapshotState, at date: Date = Date()) {
        switch state {
        case .unknown:
            self.init(
                title: String(localized: .reachy("No robot")),
                detail: String(localized: .reachy("Open the app to connect")),
                symbolName: "questionmark.circle",
                isStale: false
            )
        case let .fresh(snapshot):
            self.init(
                title: Self.name(of: snapshot),
                detail: Self.activity(of: snapshot, at: date),
                symbolName: Self.symbol(for: snapshot, at: date),
                isStale: false
            )
        case let .stale(snapshot):
            self.init(
                title: Self.name(of: snapshot),
                detail: String(localized: .reachy("Last seen \(Self.age(of: snapshot, at: date))")),
                symbolName: "clock.arrow.circlepath",
                isStale: true
            )
        }
    }

    /// Daemon 1.9.0 mounts no rename route and reports an empty name, so a robot
    /// without one is ordinary rather than exceptional — it still needs calling
    /// something.
    private static func name(of snapshot: RobotSnapshot) -> String {
        snapshot.robotName ?? String(localized: .reachy("Reachy Mini"))
    }

    /// A running app is the most useful thing there is to say, so it displaces
    /// the plain awake reading rather than crowding in beside it — and an app that
    /// just died displaces it for the same reason. Falling silently back to "Awake"
    /// would be this widget's version of pretending nothing happened.
    private static func activity(of snapshot: RobotSnapshot, at date: Date) -> String {
        if let runningApp = snapshot.runningAppTitle(at: date) {
            return runningApp
        }
        if let failed = snapshot.failedApp(at: date) {
            return String(localized: .reachy("\(failed.title ?? failed.name) stopped"))
        }
        return snapshot.isAwake
            ? String(localized: .reachy("Awake"))
            : String(localized: .reachy("Asleep"))
    }

    private static func symbol(for snapshot: RobotSnapshot, at date: Date) -> String {
        if snapshot.runningAppTitle(at: date) != nil {
            return "square.grid.2x2.fill"
        }
        if snapshot.failedApp(at: date) != nil {
            return "exclamationmark.triangle.fill"
        }
        return snapshot.isAwake ? "figure.wave" : "moon.zzz.fill"
    }

    private static func age(of snapshot: RobotSnapshot, at date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: snapshot.takenAt, relativeTo: date)
    }
}
