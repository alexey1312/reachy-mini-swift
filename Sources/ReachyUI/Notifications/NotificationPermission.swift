import ReachyKit
import UserNotifications

/// Whether this app may post a notification — read without asking, and asked when
/// the reader says to.
///
/// It lives here rather than in `ReachyKit/Permissions/` beside `BluetoothPermission`
/// and `LocalNetworkProbe`, for the linking reason `MicrophonePermission` already
/// records: `ReachyKit` is linked by the widget extension, and a process woken for a
/// moment to draw two lines of text has no business loading a framework it will never
/// call. `JobNotificationCenter` is the only thing that posts, so the permission
/// belongs beside it.
enum NotificationPermission {
    /// Non-prompting, and that is the property the Privacy screen depends on:
    /// `notificationSettings()` reports what was already decided and raises nothing.
    /// Async is not a weakening of that — the rule is "does not ask", not "answers
    /// synchronously".
    static var current: PermissionState {
        get async {
            await state(for: UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        }
    }

    /// Raises the system prompt if it has never been answered, then reports where
    /// that left things.
    ///
    /// It re-reads `current` rather than mapping the returned `Bool`, for the reason
    /// `MicrophonePermission.request()` spells out: the Bool collapses outcomes that
    /// have to stay apart on screen.
    ///
    /// `[.alert, .sound]` and deliberately not `.provisional`. Provisional
    /// authorization delivers with no prompt at all — straight to Notification Centre,
    /// silently — which for "your install finished" means a message nobody sees. That
    /// is worse than not asking.
    static func request() async -> PermissionState {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await current
    }

    /// Pure, so a test can cover every case without touching the singleton.
    ///
    /// Two absences worth naming rather than leaving to be rediscovered:
    ///
    /// - `PermissionState.restricted` is **unreachable** here. `UNAuthorizationStatus`
    ///   has no restricted case at all, so the row can never say "blocked by device
    ///   policy" — the mirror of `AVAudioApplication.recordPermission` having no
    ///   `restricted` either.
    /// - `.ephemeral` is **not named on purpose**. It is `API_UNAVAILABLE(macos)`, so
    ///   spelling it in a cross-platform switch fails the build on the one CI job that
    ///   compiles every SwiftPM target. It is also App Clip only, and this app is not
    ///   one, so `@unknown default` covers a case that cannot arise.
    static func state(for status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional: .granted
        case .denied: .denied
        case .notDetermined: .undetermined
        @unknown default: .undetermined
        }
    }
}
