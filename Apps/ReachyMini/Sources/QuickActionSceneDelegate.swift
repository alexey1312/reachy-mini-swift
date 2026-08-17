#if os(iOS)
    import ReachyUI
    import UIKit

    /// The only UIKit in this app, and it exists because SwiftUI has no equivalent
    /// of `windowScene(_:performActionFor:)` — the callback for a Home Screen quick
    /// action tapped while the app is already running. `onOpenURL` covers the
    /// widget's deep links; nothing covers this one.
    ///
    /// SwiftUI still owns the window: a scene configuration only names the delegate
    /// class, and `WindowGroup` attaches to the scene regardless of who that is.
    final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
        /// A cold launch, where the tap arrives folded into the connection options.
        func scene(
            _: UIScene,
            willConnectTo _: UISceneSession,
            options connectionOptions: UIScene.ConnectionOptions
        ) {
            deliver(connectionOptions.shortcutItem)
        }

        /// The app was already running. The boolean is UIKit asking whether the
        /// action was one of ours.
        func windowScene(
            _: UIWindowScene,
            performActionFor shortcutItem: UIApplicationShortcutItem,
            completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(deliver(shortcutItem))
        }

        @discardableResult
        private func deliver(_ item: UIApplicationShortcutItem?) -> Bool {
            guard let item else { return false }
            return QuickActionInbox.shared.receive(type: item.type)
        }
    }

    /// Exists only to name the scene delegate above — a SwiftUI app has no other
    /// place to hand one to UIKit.
    ///
    /// **This is what the UIScene launch requirement lands on.** Under the iOS 27
    /// SDK an app must adopt the scene lifecycle, and SwiftUI's `App` already has —
    /// but the declaration is an Info.plist key, and `Apps/Project.swift` now
    /// carries a `UIApplicationSceneManifest` with **no** `UISceneConfigurations`
    /// under it. That absence belongs to this type: the configuration returned
    /// below is the one UIKit uses, and a listed configuration would be a second
    /// answer about `delegateClass`.
    final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _: UIApplication,
            configurationForConnecting connectingSceneSession: UISceneSession,
            options _: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            let configuration = UISceneConfiguration(
                name: nil,
                sessionRole: connectingSceneSession.role
            )
            configuration.delegateClass = QuickActionSceneDelegate.self
            return configuration
        }
    }
#endif
