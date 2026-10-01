import Foundation
import ReachyJSON

/// The web apps Pollen lists for its own mobile app — the JS half of the store,
/// which the robot's catalogue does not carry (`HubAppCatalogue` says why).
///
/// One request, no token: `GET /api/js-apps` on Pollen's API Space answers with
/// everything at once, already moderated — an entry the server returns is
/// `mobile_visible` and not blocked, and upstream sends no credentials with it
/// (`useApps.ts` fetches with `credentials: 'omit'`). The answer is
/// `public, max-age=60`, so this asks afresh rather than keeping a copy of its
/// own.
///
/// Measured on 2026-10-01: 69 apps out of 91 moderated, 62 `static` and 7
/// `docker`, official ones first and then by likes. That order is kept.
public struct JSAppCatalogue: Sendable {
    public static let appsURL = URL(string: "https://pollen-robotics-reachy-mini-api.hf.space/api/js-apps")!

    /// The server's answer was not a success. English like `HubAppCatalogue.Failure`;
    /// a screen says what it means in its own words.
    public enum Failure: Error, Equatable, LocalizedError {
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case let .http(statusCode): "The web app catalogue answered HTTP \(statusCode)"
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func apps() async throws -> [JSApp] {
        let (data, response) = try await session.data(from: Self.appsURL)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(statusCode) else { throw Failure.http(statusCode) }
        return try Self.apps(in: data)
    }

    /// The decoding on its own, for a test to hand a recorded answer to.
    static func apps(in data: Data) throws -> [JSApp] {
        try JSONCodec.web.decode(Listing.self, from: data).apps.compactMap(\.value).compactMap(\.app)
    }

    private struct Listing: Decodable {
        let apps: [Lenient<Entry>]
    }

    /// One app as the server sends it. The top level is the server's summary and
    /// `extra` is the Space as the Hub describes it; the title, emoji and SDK are
    /// only in the second, the moderation verdict only in the first.
    private struct Entry: Decodable {
        let id: String
        let name: String?
        let description: String?
        let isOfficial: Bool?
        let isBlocked: Bool?
        let iconUrl: String?
        let categories: [String]?
        let mobileVisible: Bool?
        let extra: Extra?

        private enum CodingKeys: String, CodingKey {
            case id, name, description, isOfficial, isBlocked, iconUrl, categories, extra
            case mobileVisible = "mobile_visible"
        }

        struct Extra: Decodable {
            let author: String?
            let likes: Int?
            let cardData: Card?
        }

        struct Card: Decodable {
            let title: String?
            let emoji: String?
            let shortDescription: String?
            let sdk: String?
            let scopes: [String]?

            private enum CodingKeys: String, CodingKey {
                case title, emoji, sdk
                case shortDescription = "short_description"
                case scopes = "hf_oauth_scopes"
            }
        }

        /// `nil` for anything the server marks as hidden — it filters those out
        /// already, and a second filter here costs nothing should that change.
        var app: JSApp? {
            guard isBlocked != true, mobileVisible != false, id.contains("/") else { return nil }
            let card = extra?.cardData
            let sdk: JSApp.SDK = switch card?.sdk {
            case "static": .static
            case let other?: .server(other)
            // Upstream treats a missing SDK as "not static", and so does the
            // host name: a static Space is the only one with a host of its own.
            case nil: .server("unknown")
            }
            return JSApp(
                id: id,
                title: card?.title ?? name ?? id,
                summary: card?.shortDescription ?? description,
                emoji: card?.emoji,
                iconURL: iconUrl.flatMap(URL.init(string:)),
                author: extra?.author,
                likes: extra?.likes ?? 0,
                sdk: sdk,
                isOfficial: isOfficial ?? false,
                categories: categories ?? [],
                declaredScopes: card?.scopes ?? []
            )
        }
    }

    /// One element of a list that may hold anything: one odd entry must not cost
    /// the other sixty-eight (project rule 3).
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
