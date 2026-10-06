import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The catalogue a relayed robot installs from, read by this device. Every shape
/// here is the Hub's own answer to the query the daemon runs in
/// `hf_space.list_all_apps`, trimmed to the fields `RobotApp.Card` reads.
@Suite("Hub app catalogue", .timeLimit(.minutes(1)))
struct HubAppCatalogueTests {
    private static let curatedPath = "/datasets/pollen-robotics/reachy-mini-official-app-store/raw/main/app-list.json"

    private static func space(_ id: String, likes: Int = 0, title: String? = nil, summary: String? = nil) -> String {
        let card = [
            title.map { #""title":"\#($0)""# },
            summary.map { #""short_description":"\#($0)""# },
            #""emoji":"🤖""#,
        ].compactMap(\.self).joined(separator: ",")
        let author = id.split(separator: "/").first.map(String.init) ?? ""
        return #"{"id":"\#(id)","author":"\#(author)","likes":\#(likes),"private":false,"cardData":{\#(card)}}"#
    }

    private func catalogue(
        spaces: [String],
        curated: [String]? = nil,
        spacesStatus: Int = 200
    ) -> (HubAppCatalogue, URLSession) {
        var stubs: [String: StubURLProtocol.Stub] = [
            "/api/spaces": .init(statusCode: spacesStatus, json: "[\(spaces.joined(separator: ","))]"),
        ]
        if let curated {
            let list = curated.map { #""\#($0)""# }.joined(separator: ",")
            stubs[Self.curatedPath] = .init(statusCode: 200, json: "[\(list)]")
        }
        let session = StubURLProtocol.makeSession(stubs)
        return (HubAppCatalogue(session: session), session)
    }

    /// What `apps.install` looks a name up in — the daemon's own query, so every
    /// card on screen is one the robot can find by name.
    @Test("the query is the one the daemon installs from")
    func asksTheDaemonsQuestion() async throws {
        let (catalogue, session) = catalogue(spaces: [Self.space("pollen-robotics/reachy_mini_radio")])

        _ = try await catalogue.apps()

        let request = try #require(StubURLProtocol.requests(for: session).first { $0.url?.path == "/api/spaces" })
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "filter", value: "reachy_mini_python_app")))
        #expect(items.contains(URLQueryItem(name: "sort", value: "likes")))
        #expect(items.contains(URLQueryItem(name: "limit", value: "500")))
        #expect(items.contains(URLQueryItem(name: "expand[]", value: "cardData")))
    }

    /// `hf_space._build_app_info`: named after the slug, described by the card, the
    /// Space kept whole under `extra`. The store reads every card through `extra`,
    /// so this is what lets it draw the Hub's list the way it draws the robot's.
    @Test("each Space becomes the app the daemon would have built from it")
    func buildsTheDaemonsApp() async throws {
        let (catalogue, _) = catalogue(spaces: [
            Self.space("pollen-robotics/reachy_mini_radio", likes: 40, title: "Radio", summary: "Tunes in."),
        ])

        let app = try #require(try await catalogue.apps().first)

        #expect(app.name == "reachy_mini_radio")
        #expect(app.spaceID == "pollen-robotics/reachy_mini_radio")
        #expect(app.info.sourceKind == .hfSpace)
        #expect(app.info.url == "https://huggingface.co/spaces/pollen-robotics/reachy_mini_radio")
        #expect(app.title == "Radio")
        #expect(app.summary == "Tunes in.")
        #expect(app.emoji == "🤖")
        #expect(app.likes == 40)
        #expect(app.isOfficial)
        #expect(!app.isInstalled)
    }

    /// The id is the Hub's free text, so the page is built rather than interpolated
    /// (rule 5): a character a URL cannot carry is escaped, not left to break it.
    @Test("a Space's page is built with URLComponents, the way every other page is")
    func buildsThePageURL() async throws {
        let id = "someone/odd name"
        let (catalogue, _) = catalogue(spaces: [Self.space(id)])

        let app = try #require(try await catalogue.apps().first)

        #expect(app.info.url == "https://huggingface.co/spaces/someone/odd%20name")
        #expect(app.info.url == HubSpacePage.url(for: id)?.absoluteString)
    }

    /// The daemon puts the curated list first, and `.recommended` is that order —
    /// so a curated entry ranks ahead of a more liked one. An entry the tagged list
    /// does not have is one `apps.install` could not find either, and is dropped
    /// rather than fetched on its own.
    @Test("curated apps come first, in the curated order, and only if installable")
    func putsTheCuratedFirst() async throws {
        let (catalogue, _) = catalogue(
            spaces: [
                Self.space("someone/popular", likes: 300),
                Self.space("pollen-robotics/reachy_mini_radio", likes: 40),
                Self.space("cdeplanne/wake_me_up", likes: 20),
            ],
            curated: ["cdeplanne/wake_me_up", "tfrere/telepresence", "pollen-robotics/reachy_mini_radio"]
        )

        let ids = try await catalogue.apps().map(\.spaceID)

        #expect(ids == ["cdeplanne/wake_me_up", "pollen-robotics/reachy_mini_radio", "someone/popular"])
    }

    /// The daemon resolves a name to the first Space with it in likes order, so a
    /// fork's card would install somebody else's app and then read as installed. 32
    /// slugs were shared like this on 2026-10-01.
    @Test("a slug shared by several Spaces is offered once, as the one the robot would install")
    func listsEachSlugOnce() async throws {
        let (catalogue, _) = catalogue(spaces: [
            Self.space("pollen-robotics/reachy_mini_conversation_app", likes: 176),
            Self.space("someone/popular", likes: 90),
            Self.space("dillera/reachy_mini_conversation_app", likes: 3),
        ])

        let ids = try await catalogue.apps().map(\.spaceID)

        #expect(ids == ["pollen-robotics/reachy_mini_conversation_app", "someone/popular"])
    }

    /// Best effort, as it is on the robot: without its curation the store is still
    /// the whole catalogue, in the Hub's order.
    @Test("a curated list that does not load leaves the Hub's order")
    func survivesAMissingCuratedList() async throws {
        let (catalogue, _) = catalogue(spaces: [
            Self.space("someone/popular", likes: 300),
            Self.space("pollen-robotics/reachy_mini_radio", likes: 40),
        ])

        let ids = try await catalogue.apps().map(\.spaceID)

        #expect(ids == ["someone/popular", "pollen-robotics/reachy_mini_radio"])
    }

    @Test("a listing the Hub refused is an error, not an empty store")
    func reportsARefusal() async {
        let (catalogue, _) = catalogue(spaces: [], spacesStatus: 503)

        await #expect(throws: HubAppCatalogue.Failure.http(503)) {
            _ = try await catalogue.apps()
        }
    }

    /// One odd entry must not cost the rest (project rule 3), and an entry with no
    /// id has nothing to be installed by.
    @Test("an entry that is not a Space is skipped, not fatal")
    func skipsOddEntries() async throws {
        let (catalogue, _) = catalogue(spaces: [
            #""not a space""#,
            #"{"author":"nobody"}"#,
            Self.space("pollen-robotics/reachy_mini_radio"),
        ])

        #expect(try await catalogue.apps().map(\.name) == ["reachy_mini_radio"])
    }
}
