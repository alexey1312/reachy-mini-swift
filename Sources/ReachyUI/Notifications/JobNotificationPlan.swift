import Foundation
import ReachyDesign

/// Every decision a job notification makes, as a pure reducer.
///
/// The same shape as `RunningAppActivityPlan`, and deliberately **not** for the same
/// reason — copying that file's rationale here would be wrong. ActivityKit is iOS
/// only; `UserNotifications` ships on both platforms this app targets, so nothing
/// here needs an `#if os` fence. The split earns its place on a harder fact:
///
/// > `UNUserNotificationCenter.current()` traps in a process that is not an app
/// > bundle. `mise run test` is SwiftPM on macOS, where the test host has no bundle
/// > identifier, so a rule that calls it is a rule that *crashes* the suite rather
/// > than one that fails it.
///
/// So every rule lives here, over Foundation and `ReachyDesign` alone, and the one
/// thing this cannot know — whether the reader is looking at the app right now —
/// arrives as a fact the controller sets.
///
/// **The rule the whole thing hangs off**, inherited from the Live Activity and
/// sharpened for an event that cannot be taken back once delivered:
///
/// > Announce only a transition this app *observed*, that the reader did not just
/// > watch happen, and that a job register actually answered. Never on silence, and
/// > never a verdict inferred from a timer.
struct JobNotificationPlan: Equatable, Sendable {
    /// Which long job this is. The daemon runs both families through one
    /// `bg_job_register.run_command`, but they end differently enough that the copy
    /// and the policy split four ways rather than two.
    enum Kind: String, Equatable, Sendable, CaseIterable {
        case systemUpdate
        case appInstall
        case appUpdate
        case appRemove
    }

    /// Identity, and nothing a reader sees.
    ///
    /// The split is the one `RunningAppActivityApp` already makes between `runKey`
    /// and `appTitle`: `subject` is the daemon's `RobotApp.name`, never its title,
    /// so renaming an app mid-job cannot change the key of the job in flight.
    /// `robotID` is `RobotIdentity.deduplicationKey` — rule 4, identity and never an
    /// address.
    struct Key: Hashable, Sendable {
        var kind: Kind
        var robotID: String?
        /// `nil` for a system update: there is one per robot and it has no subject.
        var subject: String?

        init(kind: Kind, robotID: String?, subject: String? = nil) {
            self.kind = kind
            self.robotID = robotID
            self.subject = subject
        }

        /// Stable across the life of one job, which is what lets a settle find the
        /// start it belongs to after a reconnect.
        var identifier: String {
            "\(kind.rawValue)/\(robotID ?? "-")/\(subject ?? "-")"
        }

        /// One robot's job notifications group together in Notification Centre.
        var threadIdentifier: String {
            "reachy.job/\(robotID ?? "-")"
        }
    }

    /// A key plus the words for it, captured when the job *starts*.
    ///
    /// Display text rides along rather than being looked up at the end, because at
    /// the end there may be nothing to look it up from: a system update takes the
    /// daemon down, so `session.connectedIdentity` is `nil` exactly when
    /// `confirmRestart` finally answers.
    struct Notice: Equatable, Sendable {
        var key: Key
        var robotName: String?
        /// The app's title. `nil` for a system update.
        var subjectTitle: String?

        init(key: Key, robotName: String? = nil, subjectTitle: String? = nil) {
            self.key = key
            self.robotName = robotName
            self.subjectTitle = subjectTitle
        }
    }

    /// How a job ended, as the *monitor* saw it — never as a screen restated it.
    ///
    /// `AppInstallModel` collapses `.timedOut` into `.failed` for the screen, which
    /// is right there and wrong here: a timeout is the register failing to answer,
    /// not the job failing. Keeping them apart is the whole reason the announcement
    /// rides `AppJobMonitor.Outcome` and not `AppInstallModel.State`.
    enum Result: Equatable, Sendable {
        /// `detail` is the new version for a system update, and nothing otherwise.
        case succeeded(detail: String?)
        /// The daemon's own words, already resolved.
        case failed(String)
        /// The daemon restarted and took its in-memory job register with it. Neither
        /// success nor failure, and the copy must say exactly that.
        case inconclusive
        /// The budget ran out with the register never answering. Silent — see
        /// `announcement(for:_:)`.
        case unanswered
    }

    /// Resolved strings rather than resources: every one interpolates a robot or an
    /// app name, the same trade `RunningAppActivityPlan.Alert` makes.
    struct Request: Equatable, Sendable {
        var identifier: String
        var threadIdentifier: String
        var title: String
        var body: String
    }

    enum Event: Equatable, Sendable {
        /// A job the app watched begin. The only thing that makes a later settle
        /// announceable.
        case started(Notice, at: Date)
        case settled(Notice, Result, at: Date)
    }

    enum Effect: Equatable, Sendable {
        case post(Request)
    }

    /// Whether a notification may be posted at all: the reader is not looking at the
    /// app, the setting is on, and the system granted authorization. Read at every
    /// attempt rather than once — all three flip without this process being told.
    var isPermitted = false

    /// Jobs this app watched start and has not yet seen end.
    ///
    /// The primary guard, and it kills a whole class of bugs rather than one: a
    /// settle whose start was never observed belongs to a relaunched process, a
    /// stale model, or a `check` that failed before any job existed. None of those
    /// may notify, and none of them has to be enumerated to be refused.
    private(set) var running: Set<Key> = []

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .started(notice, _):
            begin(notice)
        case let .settled(notice, result, at: date):
            settle(notice, result, at: date)
        }
    }

    /// A start is recorded **whether or not posting is currently permitted**.
    ///
    /// Deliberate asymmetry: a reader who grants permission halfway through a
    /// ten-minute robot update should still be told it finished. Permission is a
    /// property of the moment of delivery, not of the moment the job began.
    private mutating func begin(_ notice: Notice) -> [Effect] {
        running.insert(notice.key)
        return []
    }

    private mutating func settle(_ notice: Notice, _ result: Result, at date: Date) -> [Effect] {
        // Always consumed, even when nothing is posted: a job settles once, and a
        // second settle for the same key is a repeat this must not announce.
        guard running.remove(notice.key) != nil else { return [] }
        guard isPermitted else { return [] }
        guard let copy = Self.announcement(for: notice, result) else { return [] }
        return [.post(Request(
            // Two genuinely separate runs of the same job stack in Notification
            // Centre rather than replacing one another.
            identifier: "\(notice.key.identifier)#\(Int(date.timeIntervalSince1970))",
            threadIdentifier: notice.key.threadIdentifier,
            title: copy.title,
            body: copy.body
        ))]
    }

    /// The policy table. `nil` is silence, and every `nil` below is a decision.
    private static func announcement(for notice: Notice, _ result: Result) -> (title: String, body: String)? {
        // The register never answered inside its budget. Calling that "failed" would
        // be a verdict inferred from a timer — the exact mistake `settleJob` was
        // written to stop making. The screen still says "check the app list"; a
        // notification the reader cannot question does not get to guess.
        guard result != .unanswered else { return nil }

        switch notice.key.kind {
        case .systemUpdate:
            return systemUpdateCopy(notice, result)
        case .appInstall, .appUpdate, .appRemove:
            return appJobCopy(notice, result)
        }
    }

    private static func systemUpdateCopy(_ notice: Notice, _ result: Result) -> (title: String, body: String)? {
        let robot = displayName(notice)
        switch result {
        case let .succeeded(detail):
            let body = detail.map { String(localized: .reachy("\(robot) is running \($0).")) }
                ?? String(localized: .reachy("\(robot) finished updating."))
            return (String(localized: .reachy("Update finished")), body)
        case let .failed(reason):
            return (String(localized: .reachy("Update failed")), reason)
        case .inconclusive:
            // `SystemUpdateModel` cannot reach this: its restart path settles against
            // the register and then re-reads the version. Total switch, not a live
            // branch.
            return nil
        case .unanswered:
            // Unreachable — `announcement(for:_:)` already returned. Kept because the
            // switch must be total, and repeated rather than folded away so that
            // deleting the guard above changes no behaviour. Measured: a mutation
            // that removes only the guard leaves every test green.
            return nil
        }
    }

    private static func appJobCopy(_ notice: Notice, _ result: Result) -> (title: String, body: String)? {
        let robot = displayName(notice)
        let app = notice.subjectTitle ?? notice.key.subject ?? robot
        switch result {
        case .succeeded:
            // A successful removal is the absence of a thing, and the app list
            // already shows it. Nobody backgrounds the app waiting for one.
            switch notice.key.kind {
            case .appInstall:
                return (
                    String(localized: .reachy("\(app) is installed")),
                    String(localized: .reachy("Installed on \(robot)."))
                )
            case .appUpdate:
                return (
                    String(localized: .reachy("\(app) is updated")),
                    String(localized: .reachy("Updated on \(robot)."))
                )
            case .appRemove, .systemUpdate:
                return nil
            }
        case let .failed(reason):
            // A failed removal *is* announced: the app is still there, which is a
            // fact about the robot rather than the absence of one.
            return (failureTitle(notice.key.kind, app: app), reason)
        case .inconclusive:
            return (
                String(localized: .reachy("The robot restarted")),
                String(localized: .reachy("\(robot) restarted while the job was running. Check the app list."))
            )
        case .unanswered:
            // Unreachable for the same reason as above, and the one of the two that
            // any test actually pins.
            return nil
        }
    }

    private static func failureTitle(_ kind: Kind, app: String) -> String {
        switch kind {
        case .appInstall: String(localized: .reachy("Installing \(app) failed"))
        case .appUpdate: String(localized: .reachy("Updating \(app) failed"))
        case .appRemove: String(localized: .reachy("Removing \(app) failed"))
        case .systemUpdate: String(localized: .reachy("Update failed"))
        }
    }

    /// The same fallback the widget's content already uses for an unnamed robot.
    private static func displayName(_ notice: Notice) -> String {
        notice.robotName ?? String(localized: .reachy("Reachy Mini"))
    }
}
