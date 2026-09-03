import Foundation
import UserNotifications

/// The boundary itself: three closures over `UserNotifications`, deciding nothing.
///
/// Separate from the controller for the same reason `RunningAppActivitySystem` is —
/// so that nothing which makes a decision sits next to a framework call. Here the
/// division carries a second, harder duty:
///
/// > **`UNUserNotificationCenter.current()` appears only inside a closure body.**
/// > It traps in a process with no bundle identifier, which is exactly what
/// > `mise run test` is. A `static let` storing a closure is evaluated lazily and
/// > stores only the closure, so nothing here runs until something asks it to — and
/// > under SwiftPM nothing ever does.
///
/// Moving any of these into an initialiser, a computed property that is read at
/// construction, or file scope would put a crash back into the test suite.
enum JobNotificationSystem {
    static let isEnabled: JobNotificationCenter.IsEnabled = {
        JobNotificationSettings.isOn()
    }

    static let authorization: JobNotificationCenter.Authorization = {
        await NotificationPermission.current
    }

    /// `.active` rather than `.timeSensitive`: the latter needs its own entitlement
    /// and a review justification, and a finished install is not time-sensitive — it
    /// already happened and nothing is waiting on the reader.
    static let post: JobNotificationCenter.Post = { request in
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.sound = .default
        content.interruptionLevel = .active
        // `trigger: nil` delivers immediately. A failed add is not worth surfacing:
        // the job's own screen already says what happened, and the notification was
        // only ever the copy for someone who is not looking at it.
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)
        )
    }
}
