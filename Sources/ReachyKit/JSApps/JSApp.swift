import Foundation

/// A Reachy Mini app that is a web page: a Hugging Face Space the robot never
/// installs, opened by the host and connected to the robot through central
/// (`docs/adr/0006-js-apps.md`).
///
/// Read off Pollen's catalogue (`JSAppCatalogue`), which already applies the
/// moderation: an entry it returns is `mobile_visible` and not blocked. Only the
/// fields something here reads are kept, and every one but the id may be
/// missing — the catalogue is a Space Pollen redeploys at will (project rule 3).
public struct JSApp: Sendable, Equatable, Identifiable {
    /// How the Space is served, which decides its host name (`JSAppEmbed`).
    public enum SDK: Sendable, Equatable {
        /// Built files served from `<slug>.static.hf.space`.
        case `static`
        /// Anything with a server of its own — `docker` today, `gradio` in
        /// principle — served from `<slug>.hf.space`.
        case server(String)
    }

    /// `owner/name`, the Space's repository id.
    public let id: String
    public let title: String
    public let summary: String?
    public let emoji: String?
    public let iconURL: URL?
    public let author: String?
    public let likes: Int
    public let sdk: SDK
    public let isOfficial: Bool
    public let categories: [String]
    /// What the Space's card says it needs from a Hugging Face token beyond the
    /// sign-in itself (`hf_oauth_scopes`). Hey Reachy hands a web app
    /// `openid profile` and nothing more, so a non-empty list is an app this host
    /// cannot run as its author meant it to (ADR 0006).
    public let declaredScopes: [String]

    public init(
        id: String,
        title: String,
        summary: String? = nil,
        emoji: String? = nil,
        iconURL: URL? = nil,
        author: String? = nil,
        likes: Int = 0,
        sdk: SDK = .static,
        isOfficial: Bool = false,
        categories: [String] = [],
        declaredScopes: [String] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.emoji = emoji
        self.iconURL = iconURL
        self.author = author
        self.likes = likes
        self.sdk = sdk
        self.isOfficial = isOfficial
        self.categories = categories
        self.declaredScopes = declaredScopes
    }

    /// The Space's own page on the Hub — where its README, its author and its
    /// report link live.
    public var cardURL: URL? {
        HubSpacePage.url(for: id)
    }

    /// The Hub's own report form for this Space, the one upstream opens from its
    /// "Report this app" item (App Review 1.2; ADR 0006).
    public var reportURL: URL? {
        HubSpacePage.reportURL(for: id)
    }

    /// Scopes the app asks for that the narrow token does not carry.
    public var needsMoreThanSignIn: Bool {
        !declaredScopes.filter { !["openid", "profile"].contains($0) }.isEmpty
    }
}
