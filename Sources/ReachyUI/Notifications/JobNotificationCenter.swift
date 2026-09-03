import Foundation
import Observation
import ReachyKit

/// How a long job tells the app it began and how it ended.
///
/// A closure rather than a protocol, and it carries the whole `Event` rather than a
/// `Notice`, so that neither `SystemUpdateModel` nor `AppInstallModel` gains an
/// import, a dependency, or any knowledge that notifications exist at all.
typealias JobNotify = @MainActor (JobNotificationPlan.Event) -> Void

/// Performs the plan's effects, and owns the two things a pure reducer cannot know:
/// whether the reader is looking at the app, and what the system said about
/// authorization.
///
/// **Why a singleton, when `RunningAppActivityController` is `@State` on
/// `RootLifecycle`.** ActivityKit refuses a request from anywhere but the foreground,
/// so a foreground-only SwiftUI drive costs the Live Activity nothing. A job
/// notification's entire purpose is the moment the app is *not* the thing on screen;
/// putting a SwiftUI update pass in its delivery path would make delivery contingent
/// on a redraw a backgrounded scene is free to coalesce or defer. So it is reached
/// the way `QuickActionInbox`, `CallRequestInbox` and `AppStoreRequestInbox` are
/// reached — the thing that must hear about a finished job has no initialiser to be
/// injected through, and it must not be a view.
///
/// Every system call arrives as an injected `@Sendable` closure whose default is
/// `JobNotificationSystem`. That is what lets the whole thing be exercised by
/// `mise run test`, where the real ones would trap rather than fail.
@MainActor
@Observable
final class JobNotificationCenter {
    static let shared = JobNotificationCenter()

    typealias IsEnabled = @Sendable () -> Bool
    typealias Authorization = @Sendable () async -> PermissionState
    typealias Post = @Sendable (JobNotificationPlan.Request) async -> Void

    private var plan = JobNotificationPlan()
    private var isForeground = false
    private var authorization: PermissionState = .undetermined

    private let isEnabled: IsEnabled
    private let readAuthorization: Authorization
    private let post: Post

    init(
        isEnabled: @escaping IsEnabled = JobNotificationSystem.isEnabled,
        authorization: @escaping Authorization = JobNotificationSystem.authorization,
        post: @escaping Post = JobNotificationSystem.post
    ) {
        self.isEnabled = isEnabled
        readAuthorization = authorization
        self.post = post
    }

    /// The scene phase changed, and this is the one fact SwiftUI is the only source
    /// for. `RootLifecycle` calls it; nothing else should.
    ///
    /// Authorization is re-read here rather than at each delivery, and the reason is
    /// a race rather than a saving. `receive(_:)` has to mutate the plan
    /// *synchronously* — a `Task` around it lets a settle overtake the start it
    /// belongs to, and a settle whose start was not yet recorded is silently dropped
    /// by the plan's primary guard. So the async read is moved to the one moment it
    /// can actually change: the reader went to Settings and came back, which is a
    /// scene-phase transition by definition.
    func sceneBecame(active: Bool) async {
        isForeground = active
        authorization = await readAuthorization()
    }

    /// Both halves of a job's life, from either model.
    ///
    /// Synchronous up to and including the plan's decision; only delivery is
    /// deferred, and deliveries are order-independent because every request names its
    /// own identifier.
    func receive(_ event: JobNotificationPlan.Event) {
        plan.isPermitted = !isForeground && isEnabled() && authorization == .granted
        let effects = plan.handle(event)
        guard !effects.isEmpty else { return }
        Task { [post] in
            for case let .post(request) in effects {
                await post(request)
            }
        }
    }
}
