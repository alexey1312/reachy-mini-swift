import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The store over a daemon 1.13.0 relay draws what the LAN draws, but for the
/// startup app. Each test here goes red when the matching branch of
/// `AppStoreModel+Relay` falls back to the 1.10 store (checked by mutating it).
@MainActor
@Suite("The store over a 1.13 relay")
struct AppStoreRelay113Tests {
    private func session(version: String) -> RobotSession {
        RobotSession.preview(
            status: .preview(wirelessVersion: false, version: version),
            address: nil,
            link: .remote,
            client: PreviewRelayStoreClient(carriesRelayAppStore: true)
        )
    }

    @Test("Installed is back from 1.13.0, and only from it")
    func installedSectionFollowsTheVersion() {
        let current = AppStoreModel.preview(session: session(version: "1.13.0"))
        let older = AppStoreModel.preview(session: session(version: "1.12.0"))

        #expect(current.isOverRelay)
        #expect(current.listsInstalled)
        #expect(current.sections == AppStoreModel.Section.allCases)
        #expect(older.isOverRelay)
        #expect(!older.listsInstalled)
        #expect(older.sections == [.discover])
    }

    /// With a list to read, a card is installed because the robot says so, never
    /// because this visit guessed it.
    @Test("the installed list answers, not this visit's guess")
    func noGuessedTwinOnACurrentRelay() {
        let card = RobotApp.previewCatalogue[0]
        let model = AppStoreModel.preview(
            session: session(version: "1.13.0"),
            installed: [],
            installedOverRelay: [card.id]
        )

        #expect(model.installedTwin(of: card) == nil)
    }

    @Test("one app's update check answers for it")
    func relayUpdateCheckAnswers() {
        let card = RobotApp.previewCatalogue[0]
        let installed = RobotApp.preview(name: "reachy-mini-dance", installed: true)
        let model = AppStoreModel.preview(session: session(version: "1.13.0"), installed: [installed])

        #expect(!model.hasUpdate(card))
        model.relayUpdates[installed.name] = true
        #expect(model.hasUpdate(card))
    }
}

/// The relay's refusals in this app's words, and the daemon's own for the rest.
@Suite("Relay refusals")
struct AppStoreRefusalCaptionTests {
    private func refusal(_ reason: String?, code: Int = -32000) -> RemoteControlChannel.Failure {
        .rpc(code: code, message: "daemon words", reason: reason)
    }

    @Test(
        "each refusal a reader can act on has a sentence",
        arguments: ["busy", "app_running", "startup_app", "not_found", "already_running"]
    )
    func knownReasons(reason: String) throws {
        let sentence = try #require(AppStoreRefusalCaption.sentence(for: refusal(reason)))

        #expect(!sentence.contains("daemon words"))
    }

    /// The startup app is HTTP alone, so over the relay the way out is elsewhere.
    @Test("the startup app refusal says where to go")
    func startupAppSaysWhere() throws {
        let sentence = try #require(AppStoreRefusalCaption.sentence(for: refusal("startup_app")))

        #expect(sentence.contains("robot's own network"))
    }

    @Test("an older robot's missing verb is said as such")
    func missingVerb() throws {
        let sentence = try #require(AppStoreRefusalCaption.sentence(for: refusal("method_not_found", code: -32601)))

        #expect(sentence.contains("Hugging Face"))
    }

    @Test("an unknown reason, and anything but a relay refusal, keep their own words")
    func unknownKeepsItsWords() {
        #expect(AppStoreRefusalCaption.sentence(for: refusal("gremlins")) == nil)
        #expect(AppStoreRefusalCaption.sentence(for: URLError(.timedOut)) == nil)
    }
}
