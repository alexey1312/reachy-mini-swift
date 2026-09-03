import ReachyKit
@testable import ReachyUI
import Testing
import UserNotifications

/// Only the pure mapping. **Naming `UNAuthorizationStatus` is safe; calling
/// `UNUserNotificationCenter.current()` is not** — it traps in a process with no
/// bundle identifier, which is what `mise run test` runs in, and it would take the
/// whole suite rather than this one case. Nothing here crosses that line.
@Suite("Notification permission")
struct NotificationPermissionTests {
    @Test("provisional authorization counts as granted, because it can already deliver")
    func provisionalIsGranted() {
        #expect(NotificationPermission.state(for: .provisional) == .granted)
        #expect(NotificationPermission.state(for: .authorized) == .granted)
    }

    @Test("a refusal and a question never asked stay apart")
    func deniedAndUndeterminedAreDistinct() {
        #expect(NotificationPermission.state(for: .denied) == .denied)
        #expect(NotificationPermission.state(for: .notDetermined) == .undetermined)
    }

    /// `UNAuthorizationStatus` has no restricted case, so this row can never claim a
    /// device policy is holding the toggle. Asserted rather than assumed: a future
    /// SDK adding one would land in `@unknown default` and this would go red.
    @Test("nothing maps to restricted, because the system has no such answer here")
    func restrictedIsUnreachable() {
        let statuses: [UNAuthorizationStatus] = [.notDetermined, .denied, .authorized, .provisional]
        #expect(statuses.map(NotificationPermission.state(for:)).contains(.restricted) == false)
    }
}
