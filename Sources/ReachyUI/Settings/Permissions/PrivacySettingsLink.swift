import ReachyDesign
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// The one way this app sends someone to the system's privacy settings.
///
/// It exists because the same six lines were copied into three screens, each wrapped
/// in `#if os(iOS)` — so on macOS, which this app also ships, a refusal was reported
/// with no way at all to act on it. The platform fork lives here now and call sites
/// name a pane.
///
/// The two platforms are not symmetrical, and the copy around this must not pretend
/// otherwise:
///
/// - **iOS has one page per app and no anchors.** `openSettingsURLString` lands on
///   this app's own page, where all three toggles sit together, so `pane` is ignored.
/// - **macOS has no per-app page at all.** The link opens a *system* pane listing every
///   app, and the user still has to find this one in it. Hence the anchors — they at
///   least pick the right list.
public enum PrivacySettingsLink {
    /// Which privacy list to open. Ignored on iOS, which has only one destination.
    public enum Pane: Sendable {
        case bluetooth
        case microphone
        case localNetwork
        /// Not a privacy pane on macOS at all — see `macOSURL(_:)`.
        case notifications
    }

    @MainActor
    public static func open(_ pane: Pane) {
        #if os(iOS)
            // `pane` goes unused here on purpose: there is one destination.
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #elseif os(macOS)
            guard let url = URL(string: macOSURL(pane)) else { return }
            NSWorkspace.shared.open(url)
        #endif
    }

    #if os(macOS)
        /// `com.apple.settings.PrivacySecurity.extension` is the Ventura-and-later pane
        /// id; the older `com.apple.preference.security` is aliased but anchors less
        /// reliably.
        ///
        /// Built by string rather than `URLComponents` — project rule 5 is about robot
        /// addresses, where an IPv6 literal has to be bracketed. This scheme has no host
        /// and no path, and `URLComponents` mangles that form.
        ///
        /// **A wrong anchor has no runtime signal.** `NSWorkspace.open` returns `true`
        /// and shows whatever pane it managed to find, so these were checked by hand
        /// rather than inferred.
        /// Notifications is the one destination that is **not** an anchor on the shared
        /// prefix: on macOS it is a pane of its own rather than a list inside Privacy &
        /// Security, so the whole URL differs and not just the fragment. That is why
        /// this is a switch over URLs and no longer a switch over anchors.
        static func macOSURL(_ pane: Pane) -> String {
            switch pane {
            case .notifications:
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            case .bluetooth, .microphone, .localNetwork:
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(privacyAnchor(pane))"
            }
        }

        private static func privacyAnchor(_ pane: Pane) -> String {
            switch pane {
            case .bluetooth: "Privacy_Bluetooth"
            case .microphone: "Privacy_Microphone"
            case .localNetwork: "Privacy_LocalNetwork"
            // Unreachable: `macOSURL` routes it to its own pane above.
            case .notifications: "Privacy_LocalNetwork"
            }
        }
    #endif
}

/// "Open Settings", wherever a refusal is reported in place.
///
/// A view rather than a bare call so the four sites that show a refusal cannot drift
/// apart again in wording or in which platforms they compile on.
public struct PrivacySettingsButton: View {
    private let pane: PrivacySettingsLink.Pane

    public init(pane: PrivacySettingsLink.Pane) {
        self.pane = pane
    }

    public var body: some View {
        Button(.reachy("Open Settings")) {
            PrivacySettingsLink.open(pane)
        }
    }
}
