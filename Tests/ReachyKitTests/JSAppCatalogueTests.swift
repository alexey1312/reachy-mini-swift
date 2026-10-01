import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// Pollen's JS app catalogue, decoded from the shape `/api/js-apps` answered with
/// on 2026-10-01, trimmed to a few entries and the fields that matter.
@Suite("JS app catalogue", .timeLimit(.minutes(1)))
struct JSAppCatalogueTests {
    static let telepresence = #"""
    {"id":"pollen-robotics/telepresence","name":"telepresence",
     "description":"Control your robot from anywhere and see what it sees.",
     "url":"https://huggingface.co/spaces/pollen-robotics/telepresence","source_kind":"hf_space",
     "isOfficial":true,"isBlocked":false,
     "iconUrl":"https://huggingface.co/spaces/pollen-robotics/telepresence/resolve/main/public/icon.svg",
     "extra":{"id":"pollen-robotics/telepresence","author":"pollen-robotics","likes":56,"downloads":0,
       "runtime":null,"tags":["docker","reachy_mini_js_app"],"isPythonApp":false,
       "cardData":{"emoji":"🤖","short_description":"Control your robot from anywhere and see what it sees.",
         "sdk":"docker","title":"Telepresence","app_port":8080,"hf_oauth":true}},
     "categories":["vision"],"categories_source":"inferred","mobile_visible":true,
     "moderation":{"visible":true,"source":"official","decision":"allow","category":"none","reason":"official"}}
    """#

    static let helloWorld = #"""
    {"id":"tfrere/reachy-mini-sdkjs-demo-static","name":"reachy-mini-sdkjs-demo-static",
     "description":"Hello-world Reachy Mini JS SDK scaffold (Hello + Wave).","isOfficial":false,"isBlocked":false,
     "iconUrl":null,
     "extra":{"author":"tfrere","likes":0,
       "cardData":{"emoji":"👋","sdk":"static","title":"Reachy Mini Hello World",
         "app_build_command":"npm ci && npm run build","app_file":"dist/index.html"}},
     "categories":["dev-tools"],"mobile_visible":true}
    """#

    static let marionette = #"""
    {"id":"pollen-robotics/marionette-js","name":"marionette-js","isOfficial":false,"isBlocked":false,
     "extra":{"author":"pollen-robotics","likes":12,
       "cardData":{"sdk":"static","title":"Marionette","hf_oauth_scopes":["read-repos","write-repos","manage-repos"]}},
     "mobile_visible":true}
    """#

    private static func listingJSON(_ apps: [String]) -> String {
        #"{"apps":[\#(apps.joined(separator: ","))],"cached":true,"count":\#(apps.count)}"#
    }

    private static func listing(_ apps: [String]) -> Data {
        Data(listingJSON(apps).utf8)
    }

    @Test("an app is read from the card the Hub describes it with")
    func readsTheCard() throws {
        let apps = try JSAppCatalogue.apps(in: Self.listing([Self.telepresence]))

        let app = try #require(apps.first)
        #expect(app.id == "pollen-robotics/telepresence")
        #expect(app.title == "Telepresence")
        #expect(app.emoji == "🤖")
        #expect(app.summary == "Control your robot from anywhere and see what it sees.")
        #expect(app.author == "pollen-robotics")
        #expect(app.likes == 56)
        #expect(app.sdk == .server("docker"))
        #expect(app.isOfficial)
        #expect(app.categories == ["vision"])
        #expect(app.iconURL?.lastPathComponent == "icon.svg")
        #expect(app.declaredScopes.isEmpty)
        #expect(!app.needsMoreThanSignIn)
    }

    @Test("a static Space is told apart from one with a server")
    func readsTheSDK() throws {
        let apps = try JSAppCatalogue.apps(in: Self.listing([Self.helloWorld]))

        #expect(apps.first?.sdk == .static)
        #expect(apps.first?.iconURL == nil)
    }

    /// Four apps declared more than a sign-in on 2026-10-01; the host hands them
    /// `openid profile` alone, so they are the ones a narrow token cannot serve.
    @Test("scopes beyond the sign-in are read and flagged")
    func readsDeclaredScopes() throws {
        let apps = try JSAppCatalogue.apps(in: Self.listing([Self.marionette]))

        #expect(apps.first?.declaredScopes == ["read-repos", "write-repos", "manage-repos"])
        #expect(apps.first?.needsMoreThanSignIn == true)
    }

    @Test("the server's order is kept")
    func keepsTheOrder() throws {
        let apps = try JSAppCatalogue.apps(in: Self.listing([Self.telepresence, Self.helloWorld, Self.marionette]))

        #expect(apps.map(\.id) == [
            "pollen-robotics/telepresence",
            "tfrere/reachy-mini-sdkjs-demo-static",
            "pollen-robotics/marionette-js",
        ])
    }

    /// The server filters these already; a second filter costs nothing should
    /// that change, and an odd entry must not cost the others (rule 3).
    @Test("hidden, blocked and malformed entries are dropped, the rest kept")
    func dropsWhatCannotBeShown() throws {
        let blocked = #"{"id":"someone/blocked","isBlocked":true,"mobile_visible":true}"#
        let hidden = #"{"id":"someone/hidden","mobile_visible":false}"#
        let noID = #"{"name":"nameless"}"#
        let notAnObject = #""just a string""#

        let apps = try JSAppCatalogue.apps(in: Self.listing([blocked, hidden, noID, notAnObject, Self.helloWorld]))

        #expect(apps.map(\.id) == ["tfrere/reachy-mini-sdkjs-demo-static"])
    }

    @Test("a missing card falls back to the server's own name and summary")
    func fallsBackWithoutACard() throws {
        let bare = #"{"id":"someone/bare_app","name":"bare_app","description":"Plain."}"#

        let app = try #require(try JSAppCatalogue.apps(in: Self.listing([bare])).first)

        #expect(app.title == "bare_app")
        #expect(app.summary == "Plain.")
        #expect(app.sdk == .server("unknown"))
    }

    @Test("the catalogue is asked for without a token, and a refusal is an error")
    func fetches() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/js-apps": .init(
                statusCode: 200,
                json: Self.listingJSON([Self.helloWorld])
            ),
        ])

        let apps = try await JSAppCatalogue(session: session).apps()

        #expect(apps.count == 1)
        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.url?.host == "pollen-robotics-reachy-mini-api.hf.space")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let refusing = StubURLProtocol.makeSession(["/api/js-apps": .init(statusCode: 503, json: "{}")])
        await #expect(throws: JSAppCatalogue.Failure.http(503)) {
            try await JSAppCatalogue(session: refusing).apps()
        }
    }

    @Test("the report link is the Hub's own form for the Space")
    func reportLink() {
        let app = JSApp(id: "tfrere/reachy-mini-sdkjs-demo-static", title: "Hello")

        #expect(app.cardURL?.absoluteString == "https://huggingface.co/spaces/tfrere/reachy-mini-sdkjs-demo-static")
        #expect(app.reportURL?.absoluteString
            == "https://huggingface.co/spaces/tfrere/reachy-mini-sdkjs-demo-static?report=true")
    }
}
