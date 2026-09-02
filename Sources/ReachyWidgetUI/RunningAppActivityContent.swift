import Foundation
import ReachyDesign
import ReachyKit

/// What the Lock Screen says about the app holding the robot, split the way
/// ActivityKit splits it.
///
/// Two values rather than one, and the split is not ours to choose: attributes are
/// fixed when the activity is requested and never change again, while the content
/// state is what every update replaces. So identity goes in ``RunningAppActivityApp``
/// and everything a reading can move goes in ``RunningAppActivityContent``.
///
/// **Neither of them may be built by the process that draws them.** A Live Activity
/// runs in its own sandbox with no network access at all — unlike a widget, it cannot
/// even read a timeline. Everything on screen is whatever the app last handed over,
/// and attributes plus state together may not exceed 4 KB. That ceiling is the reason
/// the caption is clamped in `init` rather than at the call site: the only field that
/// can approach it is a crash, and `RobotAppStatus.error` is a summary line followed
/// by a verbatim stderr tail.
///
/// No ActivityKit import here on purpose. The conformances live in
/// `RunningAppActivityAttributes.swift` behind `#if os(iOS)`; these two stay plain
/// values so `mise run test` — SwiftPM on macOS — can hold every rule about them.
public struct RunningAppActivityApp: Codable, Hashable, Sendable {
    /// Which robot, so a Stop knows what to address and a reading about a different
    /// robot can be told apart from this one.
    public let robotID: String?
    public let robotName: String?
    /// The Python entry point — the only name `stop-current-app` is keyed by.
    public let appName: String
    /// The name a reader may see, already joined against the installed list.
    ///
    /// **Never the daemon's own word.** `AppManager.start_app` files a running app
    /// with an empty `extra`, so `RobotApp.title` off a status reply *is* the entry
    /// point, and a Lock Screen saying `dance_party` is the same bug as Siri saying
    /// it. In the app the join has already happened — `describedFromInstalled`
    /// swaps in the installed twin before `recordRunning` ever sees the status — and
    /// in an intent it is `RobotAppTitles`.
    public let appTitle: String
    public let emoji: String?
    /// `RobotApp.Gradient` flattened to its two palette names. It is `Codable` but
    /// not `Hashable`, and this type is both.
    public let gradientFrom: String?
    public let gradientTo: String?
    /// `RobotApp.id`, so an app with no palette derives the same colours here as in
    /// every other surface that draws it.
    public let artworkKey: String

    public init(
        robotID: String?,
        robotName: String?,
        appName: String,
        appTitle: String,
        emoji: String?,
        gradientFrom: String?,
        gradientTo: String?,
        artworkKey: String
    ) {
        self.robotID = robotID
        self.robotName = robotName
        self.appName = appName
        self.appTitle = appTitle
        self.emoji = emoji
        self.gradientFrom = gradientFrom
        self.gradientTo = gradientTo
        self.artworkKey = artworkKey
    }

    /// What to call the robot in a sentence or on a card.
    ///
    /// Daemon 1.9.0 mounts no rename route and reports an empty name, so a robot
    /// without one is ordinary rather than exceptional — the same fallback
    /// `RobotWidgetContent` makes, and it lives on the type rather than beside
    /// either surface so both spell it once.
    public var displayName: String {
        robotName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: .reachy("Reachy Mini"))
    }

    /// The identity of one run. Two readings share a run when they name the same app
    /// on the same robot — no start time, because the daemon reports none and a
    /// timestamp this device invented would change across relaunches.
    public var runKey: String {
        "\(robotID ?? "-")/\(appName)"
    }
}

public struct RunningAppActivityContent: Codable, Hashable, Sendable {
    /// One line, and a bounded one.
    ///
    /// The Lock Screen presentation is truncated above 160 pt and there is no
    /// `ScrollView` inside a Live Activity, so a multi-line error has nowhere to go
    /// even if the payload could carry it. The full text stays where it already is:
    /// `RobotAppStatus.error` for the sheet, `RobotSnapshot.FailedApp.error` for the
    /// widget's own window.
    public static let captionLimit = 120

    public let caption: String
    public let symbolName: String
    /// Whether the caption is a failure — a crash, a wedge, or a refused command.
    /// The tone is the caller's mapping, as everywhere else in this target.
    public let isFailed: Bool
    /// Whether a Stop can be honoured at all.
    ///
    /// False for a robot this device knows only over the relay: an intent reaches a
    /// robot through `RobotIntentTarget.connection`, which dials a LAN address,
    /// deliberately — a relay robot needs a WebRTC session negotiated over
    /// signalling, and that does not fit an intent's budget. A button that silently
    /// does nothing is worse than no button, so the surface draws none and falls
    /// through to its deep link.
    public let canStop: Bool
    /// When the reading behind this content arrived. Rendered as its own age, and
    /// the one thing on the card that stays true with no process running.
    public let readAt: Date

    public init(caption: String, symbolName: String, isFailed: Bool, canStop: Bool, readAt: Date) {
        self.caption = Self.clamped(caption)
        self.symbolName = symbolName
        self.isFailed = isFailed
        self.canStop = canStop
        self.readAt = readAt
    }

    /// Whether two readings differ in anything a reader can see.
    ///
    /// `readAt` is excluded, and excluding it is the whole point: it moves with
    /// every poll tick by construction, so a plain `==` would call every tick a
    /// change and there would be no such thing as an unchanged reading. What it
    /// costs is that the age on screen can trail the true one by up to the
    /// controller's refresh floor — which is honest in the direction that matters,
    /// since it only ever claims the reading is *older* than it is.
    public func rendersSameAs(_ other: Self) -> Bool {
        caption == other.caption
            && symbolName == other.symbolName
            && isFailed == other.isFailed
            && canStop == other.canStop
    }

    /// The first non-empty line, trimmed and capped.
    ///
    /// In `init` rather than at the call site because a caller cannot get it wrong
    /// there, and because the input is not always ours: a crash carries the daemon's
    /// summary line plus a raw stderr tail, and a conversation turn carries whatever
    /// the app on the robot said. `RunningAppCaption` records what happens to a
    /// one-line slot fed the whole thing — a state row reading
    /// `Process exited with code 1 / INFO: connection rejected (403 For…`.
    ///
    /// Capped by characters and asserted in bytes: a robot's name is free text
    /// somebody typed, and 120 emoji are 480 bytes.
    static func clamped(_ text: String) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.count > captionLimit else { return line }
        return line.prefix(captionLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
