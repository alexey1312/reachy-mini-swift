import Foundation

/// Somewhere in the app a widget can send the user.
///
/// The scheme is the one the OAuth callback already uses, because an app gets one
/// and registering a second buys nothing. Parsing is therefore exact rather than
/// forgiving: `oauth-callback` belongs to `ASWebAuthenticationSession`, and
/// anything else in this scheme is not ours to interpret.
public enum ReachyDeepLink: String, CaseIterable, Sendable {
    case robot
    case apps
    /// The app holding the robot, rather than the catalogue it came from — its
    /// logs, its restart and its stop, or the traceback it died with.
    ///
    /// Hyphenated rather than camel-cased because the destination is a URL *host*,
    /// which is case-insensitive and normalised as such; a raw value that survives
    /// that normalisation is one that carries no case to lose.
    case runningApp = "running-app"

    public static let scheme = "reachy-mini-swift"

    /// The one query item a destination may carry: *which* entity it is about.
    ///
    /// It exists for `OpenIntent`, whose URL is a string-interpolation template the
    /// app writes (`EntityURLRepresentation`) — so an entity's URL is a destination
    /// this type already knows plus the entity's own id. A reader that ignores the
    /// query still lands on the right tab, which is why the identifier is a query
    /// item rather than a path: it is additional, never load-bearing.
    static let identifierQuery = "id"

    /// The destination alone, for the callers that have no entity to name — a
    /// `widgetURL`, a menu bar row, a Spotlight destination.
    public var url: URL {
        url(identifier: nil)
    }

    public func url(identifier: String?) -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = rawValue
        if let identifier, !identifier.isEmpty {
            components.queryItems = [URLQueryItem(name: Self.identifierQuery, value: identifier)]
        }
        // The components above are fixed and valid; a nil here would be a bug in
        // this type rather than anything a caller can cause.
        guard let url = components.url else {
            preconditionFailure("deep link components do not form a URL: \(rawValue)")
        }
        return url
    }

    public init?(url: URL) {
        guard let target = Target(url: url) else { return nil }
        self = target.destination
    }
}

public extension ReachyDeepLink {
    /// A destination and, where one arrived, the entity it is about.
    ///
    /// Kept beside the enum rather than folded into it: the destination is what
    /// `ReachyRouter` selects a tab from and what `CaseIterable` enumerates, while
    /// the identifier belongs to one arrival. Every existing caller reads
    /// ``ReachyDeepLink`` and is unaffected; only a caller that can *act* on an
    /// entity — `RootLifecycle` — reads this.
    struct Target: Equatable, Sendable {
        public let destination: ReachyDeepLink
        public let identifier: String?

        public init(destination: ReachyDeepLink, identifier: String? = nil) {
            self.destination = destination
            // An empty query item is not an identifier. Normalising here rather
            // than at each reader is what keeps `Equatable` meaning what it says.
            self.identifier = (identifier?.isEmpty == true) ? nil : identifier
        }

        /// Exact, for the reason the type's own doc comment gives: an unknown host
        /// in this scheme belongs to somebody else, and a query item nobody
        /// declared is not an identifier.
        public init?(url: URL) {
            guard url.scheme == ReachyDeepLink.scheme,
                  let host = url.host(),
                  let destination = ReachyDeepLink(rawValue: host)
            else { return nil }
            let identifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == ReachyDeepLink.identifierQuery }?
                .value
            self.init(destination: destination, identifier: identifier)
        }

        public var url: URL {
            destination.url(identifier: identifier)
        }
    }
}
