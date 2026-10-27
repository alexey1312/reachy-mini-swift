import Foundation
import ReachyJSON

/// The apps a relayed robot can be asked to install, read off the Hub by this
/// device.
///
/// Over the LAN the daemon serves its own catalogue (`/api/apps/list-available`).
/// Over the relay nothing does — the JSON-RPC relay has `apps.install` and no
/// `apps.list` — but the catalogue is the Hub's to begin with, and this is the
/// query the robot itself runs when `apps.install` looks a name up:
/// `ensure_startup_app_installed` searches `hf_space.list_all_apps`, which up to
/// daemon 1.12 is `HfApi.list_spaces(filter="reachy_mini_python_app", sort="likes",
/// limit=500)`. From 1.13.0 the daemon reads the same query over plain HTTP and
/// follows the `Link` header past the first 500 (pollen-robotics/reachy_mini#1420),
/// and so does this. Listing that query is what keeps every card here installable
/// by name. A wider list would offer apps the robot then refuses as "not in the
/// catalog". Up to 1.12 the robot still stops at 500, which the Hub's 471 apps of
/// 2026-10-01 do not reach.
///
/// So this is narrower than the LAN store, and on purpose:
///
/// - **JS apps are absent.** They carry `reachy_mini_js_app`, which the daemon's
///   search does not ask for, and so are four of the eleven entries in Pollen's
///   curated `app-list.json` (measured on 2026-10-01: `marionette`,
///   `marionette-js`, `emotions`, `telepresence`). The daemon's LAN catalogue
///   fetches those one by one, and only its HTTP install can install them.
/// - **Private Spaces are absent.** The robot searches with its own token and this
///   device asks without one, so a private Space could be listed here only by
///   guessing which account the robot is linked to.
/// - **A slug is listed once.** The daemon takes the first Space with that name in
///   its likes-ordered list (`next(a for a in catalog if a.name == name)`), and 32
///   slugs were shared by 97 of 471 Spaces on 2026-10-01 — four
///   `reachy_mini_conversation_app`s, four `clawbody`s. A fork's card would install
///   somebody else's Space and then read as installed itself, so only the Space the
///   robot would resolve is offered. Ties in likes are ordered by the Hub, the same
///   answer the robot gets from the same query.
///
/// The curated list is read only for its order: the daemon puts those entries
/// first (`list_all_available_apps`), and `AppStoreModel.Sort.recommended` is
/// that order. It is best effort, as it is on the robot — a curated list that
/// fails to load leaves the Hub's own order, not an error.
///
/// `expand[]` names the fields `RobotApp.Card` reads. Without it the Hub answers
/// with every Space's file listing: 2.6 MB for 471 apps against 262 KB with it.
public struct HubAppCatalogue: Sendable {
    public static let spacesURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/spaces"
        components.queryItems = [
            URLQueryItem(name: "filter", value: "reachy_mini_python_app"),
            URLQueryItem(name: "sort", value: "likes"),
            URLQueryItem(name: "limit", value: "500"),
        ] + ["author", "cardData", "createdAt", "lastModified", "likes", "private"].map {
            URLQueryItem(name: "expand[]", value: $0)
        }
        // A literal host and path with a fixed query; nothing here can fail to form.
        // swiftlint:disable:next force_unwrapping
        return components.url!
    }()

    public static let curatedURL = URL(
        string: "https://huggingface.co/datasets/pollen-robotics/reachy-mini-official-app-store/raw/main/app-list.json"
    )!

    /// The Hub's answer was not a success. English like every `ReachyKitError`;
    /// the screen that shows it says what it means in its own words.
    public enum Failure: Error, Equatable, LocalizedError {
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case let .http(statusCode): "Hugging Face answered HTTP \(statusCode)"
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Curated entries first, in the curated order, then everything else in the
    /// Hub's — most liked first.
    public func apps() async throws -> [RobotApp] {
        async let curated = curatedIDs()
        let spaces = try await listing()
        var slugs = Set<String>()
        let apps = spaces.compactMap(Self.app).filter { slugs.insert($0.name).inserted }
        let order = await curated
        let first = order.compactMap { id in apps.first { $0.spaceID == id } }
        let rest = apps.filter { app in !order.contains { $0 == app.spaceID } }
        return first + rest
    }

    /// Pages the Hub hands out after the first. Twenty pages is ten thousand apps;
    /// a `Link` that never ends is a bug on one side or the other, not a catalogue.
    static let maxPages = 20

    private func listing() async throws -> [Space] {
        var spaces: [Space] = []
        var next: URL? = Self.spacesURL
        var pages = 0
        while let url = next, pages <= Self.maxPages {
            let (data, response) = try await session.data(from: url)
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? -1
            guard (200 ..< 300).contains(statusCode) else { throw Failure.http(statusCode) }
            spaces += try JSONCodec.web.decode([Lenient<Space>].self, from: data).compactMap(\.value)
            next = Self.nextPage(in: http?.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return spaces
    }

    /// The `rel="next"` target of an RFC 8288 `Link` header, the Hub's pagination.
    static func nextPage(in header: String?) -> URL? {
        guard let header else { return nil }
        for link in header.split(separator: ",") {
            let parts = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  parts.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == #"rel="next""# })
            else { continue }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }

    private func curatedIDs() async -> [String] {
        guard let (data, response) = try? await session.data(from: Self.curatedURL),
              let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200 ..< 300).contains(statusCode),
              let ids = try? JSONCodec.web.decode([Lenient<String>].self, from: data)
        else { return [] }
        return ids.compactMap(\.value)
    }

    /// The app the daemon would have built from the same Space: named after the
    /// slug, described by the card, the payload kept whole under `extra`
    /// (`hf_space._build_app_info`). Every screen downstream reads a `RobotApp`
    /// through `extra`, so building it the daemon's way is what lets the store
    /// draw these exactly as it draws the robot's own catalogue.
    private static func app(from space: Space) -> RobotApp? {
        guard let id = space.id, let slug = id.split(separator: "/").last.map(String.init), !slug.isEmpty else {
            return nil
        }
        return RobotApp(Components.Schemas.AppInfo(
            name: slug,
            sourceKind: .hfSpace,
            description: space.shortDescription ?? "",
            // Built, not interpolated (rule 5): the id is the Hub's free text.
            url: HubSpacePage.url(for: id)?.absoluteString,
            extra: space.payload
        ))
    }

    /// One Space: the whole object, and the two fields the app is named and
    /// described by.
    private struct Space: Decodable {
        let id: String?
        let shortDescription: String?
        let payload: Components.Schemas.AppInfo.ExtraPayload

        private enum Keys: String, CodingKey {
            case id, cardData
        }

        private enum CardKeys: String, CodingKey {
            case shortDescription = "short_description"
        }

        init(from decoder: any Decoder) throws {
            payload = try Components.Schemas.AppInfo.ExtraPayload(from: decoder)
            let container = try decoder.container(keyedBy: Keys.self)
            id = try? container.decode(String.self, forKey: .id)
            let card = try? container.nestedContainer(keyedBy: CardKeys.self, forKey: .cardData)
            shortDescription = try? card?.decode(String.self, forKey: .shortDescription)
        }
    }

    /// One element of a list that may hold anything: the daemon keeps only the
    /// dict-shaped entries (`_coerce_space_list`), and one odd entry must not cost
    /// the other four hundred (project rule 3).
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
