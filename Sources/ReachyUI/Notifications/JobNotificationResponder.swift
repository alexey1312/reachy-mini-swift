import Foundation
import ReachyKit
import UserNotifications
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Where a tapped job notification goes: the job it was about.
///
/// It opens the app's own deep link rather than routing anything itself, so a tap
/// takes exactly the path a widget's link takes — `RootLifecycle`'s `onOpenURL` —
/// and there stays one place that turns a destination into a tab. That also covers
/// the tap that *launches* the app: the link is held until a scene can take it.
///
/// A delegate also decides foreground presentation, and before there was one the
/// answer was "none". `willPresent` keeps that answer, so the policy in
/// `JobNotificationPlan` — never while the reader is looking — is unchanged.
///
/// Installed from `App.init`, which runs before launch finishes, so macOS needs no
/// `NSApplicationDelegateAdaptor` for it; `UNUserNotificationCenter.current()` is
/// reached only inside `install()`, for the reason `JobNotificationSystem` gives.
public final class JobNotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// The centre holds its delegate weakly, so something has to own this one.
    public static let shared = JobNotificationResponder()

    @MainActor
    public static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let url = JobNotificationLink.url(in: response.notification.request.content.userInfo)
        else { return }
        await Self.open(url)
    }

    public func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    @MainActor
    private static func open(_ url: URL) {
        #if os(iOS)
            UIApplication.shared.open(url)
        #elseif os(macOS)
            // This copy of the app rather than whichever one LaunchServices would pick
            // for the scheme: a Mac that has run a Debug build from DerivedData and has
            // a release in /Applications registers the scheme twice.
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: Bundle.main.bundleURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        #endif
    }
}

/// How a notification carries its link: one `userInfo` entry, read back only when
/// it is a destination this app owns.
enum JobNotificationLink {
    static let key = "reachy.link"

    static func userInfo(for target: ReachyDeepLink.Target) -> [String: String] {
        [key: target.url.absoluteString]
    }

    /// Nil for anything that is not one of this app's destinations — the OAuth
    /// callback shares the scheme, and a notification is no place to replay it.
    static func url(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo[key] as? String,
              let url = URL(string: raw),
              ReachyDeepLink.Target(url: url) != nil
        else { return nil }
        return url
    }
}
