#if os(iOS)
    import ActivityKit
    import Foundation
    import OSLog

    /// The ActivityKit conformance, and — with the functions below — the only place in
    /// this repository that imports the framework.
    ///
    /// It is iOS-only, and the macOS SDK ships ActivityKit for Mac Catalyst alone
    /// (`arm64e-apple-ios-macabi`), which this app is not. So the Mac keeps naming the
    /// running app in its menu bar and gets no card, and **only `mise run build:app:ios`
    /// compiles any of this** — a macOS build reports success over code it never saw.
    public struct RunningAppActivityAttributes: ActivityAttributes {
        public typealias ContentState = RunningAppActivityContent

        public let app: RunningAppActivityApp

        public init(app: RunningAppActivityApp) {
            self.app = app
        }
    }

    /// The thin adapter the planner's effects are performed through.
    ///
    /// Every function is `nonisolated` and takes only `Sendable` values, because
    /// `Activity` is a plain class with no `Sendable` conformance: holding one across
    /// an actor hop is a region-isolation violation, so the handle is looked up out of
    /// `Activity.activities` **inside** each call and never stored. That is also the
    /// honest model — the process that renders the card is not the process that
    /// started it, so a stored handle would be a belief rather than a fact.
    public enum RunningAppActivityKit {
        private static let log = Logger(
            subsystem: "com.alexey1312.ReachyMini",
            category: "RunningAppActivity"
        )

        /// Read at every attempt rather than once: a reader can switch Live Activities
        /// off for this app in Settings without this process being told.
        public nonisolated static var isEnabled: Bool {
            ActivityAuthorizationInfo().areActivitiesEnabled
        }

        /// What the system currently holds for this app — the source of truth for
        /// "is there one", which no stored handle can be.
        public nonisolated static func live() -> [RunningAppActivityApp] {
            Activity<RunningAppActivityAttributes>.activities.map(\.attributes.app)
        }

        /// Requesting can fail for reasons with no screen to report them on: the
        /// reader switched activities off, the device is at its limit, or the app was
        /// not foreground. None of them is worth a message — the dock is already on
        /// screen saying the same thing, and the next busy edge or foreground pass
        /// tries again for free. `attributesTooLarge` is the exception: that is a bug
        /// in what this app packed, so it is logged as a fault.
        public nonisolated static func start(
            app: RunningAppActivityApp,
            content: RunningAppActivityContent,
            staleDate: Date
        ) {
            do {
                _ = try Activity.request(
                    attributes: RunningAppActivityAttributes(app: app),
                    content: ActivityContent(state: content, staleDate: staleDate),
                    pushType: nil
                )
            } catch ActivityAuthorizationError.attributesTooLarge {
                log.fault("Live Activity attributes exceeded the 4 KB ceiling for \(app.appName, privacy: .public)")
            } catch {
                log.debug("Live Activity not started: \(error.localizedDescription, privacy: .public)")
            }
        }

        public nonisolated static func update(
            runKey: String,
            content: RunningAppActivityContent,
            staleDate: Date,
            alert: (title: String, body: String)?
        ) async {
            guard let activity = activity(for: runKey) else { return }
            await activity.update(
                ActivityContent(state: content, staleDate: staleDate),
                // Resolved strings arriving as a resource: the title interpolates an
                // app and a robot name, so it cannot be a catalogue key. A key that
                // matches nothing renders as itself, which is exactly what is wanted.
                alertConfiguration: alert.map {
                    AlertConfiguration(
                        title: LocalizedStringResource(stringLiteral: $0.title),
                        body: LocalizedStringResource(stringLiteral: $0.body),
                        sound: .default
                    )
                }
            )
        }

        public nonisolated static func end(
            runKey: String,
            content: RunningAppActivityContent?,
            after date: Date?
        ) async {
            guard let activity = activity(for: runKey) else { return }
            await activity.end(
                content.map { ActivityContent(state: $0, staleDate: nil) },
                dismissalPolicy: date.map { .after($0) } ?? .immediate
            )
        }

        private nonisolated static func activity(
            for runKey: String
        ) -> Activity<RunningAppActivityAttributes>? {
            Activity<RunningAppActivityAttributes>.activities.first { $0.attributes.app.runKey == runKey }
        }
    }
#endif
