import Foundation
import ReachyJSON

/// One app as the daemon describes it, with the Hugging Face Space card behind
/// `extra` read out into something a screen can render.
///
/// The generated `AppInfo` is kept verbatim rather than unpacked into fields of
/// our own: `POST /api/apps/install` takes the entire object back, and the daemon
/// files that `extra` away as the app's stored metadata
/// (`local_common_venv._save_app_metadata`). A field dropped in translation here
/// is a field the robot never gets.
public struct RobotApp: Sendable, Equatable, Identifiable, Codable {
    /// Exactly what the daemon sent, ready to hand back to `install`.
    public let info: Components.Schemas.AppInfo
    /// What `extra` turned out to contain. Empty rather than absent when the
    /// payload made no sense — an app with no card is still an app.
    public let card: Card

    public init(_ info: Components.Schemas.AppInfo) {
        self.info = info
        card = Card(extra: info.extra)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Components.Schemas.AppInfo.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(info)
    }

    /// The Space id when there is one, so the same app keeps its identity across
    /// the catalogue and the installed list — where `name` does not (see
    /// `matches(installed:)`).
    public var id: String {
        spaceID ?? name
    }

    /// Catalogue entries are named after the Space slug, installed ones after the
    /// Python entry point, and the two need not agree.
    public var name: String {
        info.name
    }

    public var spaceID: String? {
        card.id
    }

    public var author: String? {
        card.author
    }

    public var likes: Int? {
        card.likes
    }

    public var isPrivate: Bool {
        card.isPrivate ?? false
    }

    public var isInstalled: Bool {
        info.sourceKind == .installed
    }

    /// The store's own apps. There is no verified flag on a Space — the owner is
    /// all there is to go on.
    public var isOfficial: Bool {
        card.author == Self.officialAuthor
    }

    /// Cards carry a display title; installed apps that lost their metadata have
    /// only the entry point name.
    public var title: String {
        card.title.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    public var summary: String? {
        let text = card.shortDescription ?? info.description
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Spaces have no thumbnails — an emoji on a two-colour gradient is the whole
    /// visual identity the Hub gives them.
    public var emoji: String? {
        card.emoji
    }

    public var gradient: Gradient? {
        guard let from = card.colorFrom, let to = card.colorTo else { return nil }
        return Gradient(from: from, to: to)
    }

    static let officialAuthor = "pollen-robotics"

    /// Conversation App 1.0's entry point and Space identity. The daemon may lose
    /// installed-app metadata, so either exact identity is enough to opt into its
    /// JSON-RPC surface. Forks retaining the entry point work too.
    public var exposesConversationRPC: Bool {
        name == "reachy_mini_conversation_app"
            || spaceID == "pollen-robotics/reachy_mini_conversation_app"
    }

    /// The port an app's own settings/control server binds, from
    /// `extra["custom_app_url"]`.
    ///
    /// **Only the port is usable.** The daemon does not resolve that string, it
    /// regex-scrapes it out of the app's `main.py`
    /// (`local_common_venv._get_custom_app_url_from_file`), so what arrives is the
    /// app's *bind* address: the conversation app declares
    /// `http://0.0.0.0:7860/`. Dialling that host reaches this device rather than
    /// the robot — the host belongs to whoever holds the session. The daemon's own
    /// relay rewrites it to `127.0.0.1` for the same reason, from the other side.
    ///
    /// Nil for catalogue entries, for an installed app whose metadata the daemon
    /// lost, and whenever the scrape found nothing, so a caller needs a default.
    public var customAppPort: Int? {
        card.customAppURL.flatMap { URLComponents(string: $0)?.port }
    }

    /// The Hub's own palette names (`cardData.colorFrom` / `colorTo`), passed
    /// through unresolved — mapping them to colours is the UI layer's business.
    ///
    /// `Codable` for `RobotAppSummary`, which the widget reads out of the App
    /// Group. It is not part of `RobotApp`'s own coding, which is a passthrough of
    /// the generated `AppInfo`.
    public struct Gradient: Codable, Sendable, Equatable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// The handful of `extra` keys worth reading, decoded defensively.
    ///
    /// Every field is optional and every failure is local: `extra` is whatever the
    /// Hugging Face API returned that day, and one field arriving as a number must
    /// not cost the whole app (project rule 3).
    public struct Card: Sendable, Equatable, Decodable {
        public var id: String?
        public var author: String?
        public var likes: Int?
        public var isPrivate: Bool?
        public var title: String?
        public var emoji: String?
        public var colorFrom: String?
        public var colorTo: String?
        public var shortDescription: String?
        /// Sits beside the card keys rather than inside `cardData`: the daemon adds
        /// it to `extra` itself, so it is never part of what the Hub returned.
        public var customAppURL: String?

        public static let empty = Card()

        public init() {}

        init(extra: Components.Schemas.AppInfo.ExtraPayload?) {
            guard let extra,
                  let data = try? JSONCodec.daemon.encode(extra),
                  let card = try? JSONCodec.daemon.decode(Card.self, from: data)
            else {
                self = .empty
                return
            }
            self = card
        }

        private enum CodingKeys: String, CodingKey {
            case id, author, likes, cardData
            case isPrivate = "private"
            case customAppURL = "custom_app_url"
        }

        private enum CardDataKeys: String, CodingKey {
            case title, emoji, colorFrom, colorTo
            case shortDescription = "short_description"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.value(String.self, .id)
            author = container.value(String.self, .author)
            likes = container.value(Int.self, .likes)
            isPrivate = container.value(Bool.self, .isPrivate)
            customAppURL = container.value(String.self, .customAppURL)

            guard let card = try? container.nestedContainer(keyedBy: CardDataKeys.self, forKey: .cardData) else {
                return
            }
            title = card.value(String.self, .title)
            emoji = card.value(String.self, .emoji)
            colorFrom = card.value(String.self, .colorFrom)
            colorTo = card.value(String.self, .colorTo)
            shortDescription = card.value(String.self, .shortDescription)
        }
    }
}

public extension RobotApp {
    /// Whether `installed` is this catalogue entry, already on the robot.
    ///
    /// Nothing else in this file needs a decision; this does. The two lists do not
    /// share a key:
    ///
    /// - a catalogue entry is named after the Space slug and carries
    ///   `extra["id"] == "owner/slug"`;
    /// - an installed entry is named after the Python **entry point**, which the
    ///   Space author chose independently, and carries `extra["id"]` only when the
    ///   daemon found the metadata it saved at install time. On a wireless robot
    ///   that lookup is by exact entry point name (`_load_app_metadata`), so an app
    ///   whose entry point was named differently from its Space arrives with no id
    ///   at all.
    ///
    /// The daemon's own fallback, when it has to guess, is
    /// `name.lower().replace("_", "").replace("-", "")` on both sides
    /// (`_find_metadata_for_entry_point`).
    ///
    /// Everything downstream rides on this: start, stop, remove and update are all
    /// keyed by the installed name, so a card that cannot find its twin shows a
    /// "Install" button for an app that is already there.
    /// So: the id decides whenever both sides have one — two different Spaces are
    /// two different apps, however alike they are named. Only when the installed
    /// entry lost its metadata does the name get a say, normalised the daemon's own
    /// way. That asymmetry is deliberate: a missed match offers "Install" for
    /// something already installed, which the daemon absorbs by reinstalling over
    /// it, while a wrong match sends `stop` or `remove` to somebody else's app.
    func matches(installed: RobotApp) -> Bool {
        if let mine = spaceID, let theirs = installed.spaceID {
            return mine == theirs
        }
        let mine = Self.normalized(slug)
        return !mine.isEmpty && mine == Self.normalized(installed.slug)
    }

    /// The last path component of the Space id — what the daemon files an app's
    /// metadata under — falling back to the name the daemon listed it by.
    var slug: String {
        spaceID?.split(separator: "/").last.map(String.init) ?? name
    }

    /// `_find_metadata_for_entry_point`'s own `normalize`. Space authors pick the
    /// Python entry point name independently of the Space slug, and separators are
    /// what usually differ.
    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

private extension KeyedDecodingContainer {
    /// A key of the wrong type reads as absent rather than throwing.
    func value<T: Decodable>(_: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
