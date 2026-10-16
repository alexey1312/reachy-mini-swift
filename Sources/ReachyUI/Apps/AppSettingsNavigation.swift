import Foundation

/// Where an app's settings page may take itself.
///
/// The page is served over plain, unauthenticated HTTP by whatever app runs on the
/// robot, and the sheet around it has no address bar. A page that navigated off its
/// own origin would therefore show somebody else's site under a title that reads
/// "Settings" — a sign-in form there would look like this app asking. So the main
/// frame stays on the page's own scheme, host and port, and a link anywhere else
/// goes to the system browser, where the address is visible.
enum AppSettingsNavigation: Equatable {
    case allow
    case openExternally
    case refuse

    /// Subframes are the page's own business, as in the JS app host: only where the
    /// page itself goes is this app's.
    static func decide(_ target: URL?, isMainFrame: Bool, page: URL) -> AppSettingsNavigation {
        guard isMainFrame, let target else { return .allow }
        if target.scheme == "about" || isSameOrigin(target, page) {
            return .allow
        }
        return target.scheme == "https" || target.scheme == "http" ? .openExternally : .refuse
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host()?.lowercased() == rhs.host()?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}
