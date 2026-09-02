import Foundation
@testable import ReachyKit
import Testing

@Suite("Robot apps")
struct RobotAppsTests {
    @Test("an app with no card is titled from its slug, in words")
    func slugBecomesWords() {
        #expect(RobotApp.preview(name: "reachy_mini_dance", installed: true).title == "Reachy Mini Dance")
        #expect(RobotApp.preview(name: "face-tracking", installed: true).title == "Face Tracking")
        #expect(RobotApp.humanised("chess") == "Chess")
    }

    @Test("a card's own title wins over the slug")
    func cardTitleWins() {
        #expect(RobotApp.preview(name: "reachy_mini_dance", title: "Dance Party").title == "Dance Party")
    }

    /// One entry as `GET /api/apps/list-available` serves it: `extra` is the raw
    /// Hugging Face Spaces payload, verbatim (`hf_space._build_app_info`).
    private static let catalogueEntry = #"""
    {
      "name": "reachy-mini-dance",
      "source_kind": "hf_space",
      "description": "Make the robot dance",
      "url": "https://huggingface.co/spaces/pollen-robotics/reachy-mini-dance",
      "extra": {
        "id": "pollen-robotics/reachy-mini-dance",
        "author": "pollen-robotics",
        "likes": 42,
        "private": false,
        "createdAt": "2025-10-16T16:06:57.000Z",
        "lastModified": "2026-08-05T14:30:40.000Z",
        "tags": ["reachy_mini_python_app"],
        "cardData": {
          "title": "Dance Party",
          "emoji": "\#u{1F483}",
          "colorFrom": "pink",
          "colorTo": "indigo",
          "short_description": "Make the robot dance"
        }
      }
    }
    """#

    private func decode(_ json: String) throws -> RobotApp {
        try JSONDecoder().decode(RobotApp.self, from: Data(json.utf8))
    }

    @Test("reads the store card out of the raw Space payload")
    func parsesCatalogueEntry() throws {
        let app = try decode(Self.catalogueEntry)
        #expect(app.spaceID == "pollen-robotics/reachy-mini-dance")
        #expect(app.title == "Dance Party")
        #expect(app.emoji == "💃")
        #expect(app.gradient == RobotApp.Gradient(from: "pink", to: "indigo"))
        #expect(app.author == "pollen-robotics")
        #expect(app.likes == 42)
        #expect(app.isPrivate == false)
        #expect(app.isOfficial)
    }

    /// `POST /api/apps/install` takes the whole `AppInfo` back, and the daemon
    /// stores that `extra` as the app's metadata — anything dropped here is lost
    /// on the robot for good.
    @Test("survives a round trip through install")
    func roundTripsInstallBody() throws {
        let app = try decode(Self.catalogueEntry)
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app.info)) as? NSDictionary
        let received = try JSONSerialization.jsonObject(with: Data(Self.catalogueEntry.utf8)) as? NSDictionary
        #expect(sent == received)
    }

    /// Both dates reach `extra` through the daemon's `_normalize_space_data`, which
    /// folds the `HfApi` path's `created_at`/`last_modified` onto the camel case the
    /// HTTP path returns — so a client sees one spelling whichever way the daemon
    /// listed the Space. Verified against the live Hub API on 2026-08-13: both keys
    /// are present in `GET /api/spaces/{id}` and in `GET /api/spaces?full=true`.
    @Test("reads both Hub dates, in the one spelling the daemon normalises to")
    func parsesHubDates() throws {
        let app = try decode(Self.catalogueEntry)
        #expect(app.publishedAt?.ISO8601Format() == "2025-10-16T16:06:57Z")
        #expect(app.updatedAt?.ISO8601Format() == "2026-08-05T14:30:40Z")
    }

    /// Project rule 3: the Hub answers with whatever it answered that day, and a
    /// date arriving as a number — or not arriving at all — costs that one field
    /// rather than the whole app.
    @Test("a missing or malformed date costs the field, not the app")
    func toleratesBrokenDates() throws {
        let undated = try decode(#"""
        {"name": "d", "source_kind": "hf_space", "extra": {"id": "someone/d", "createdAt": 1760630817}}
        """#)

        #expect(undated.publishedAt == nil)
        #expect(undated.updatedAt == nil)
        #expect(undated.spaceID == "someone/d")
    }

    @Test("an app from anyone else is not official")
    func communityAppIsNotOfficial() throws {
        let app = try decode(Self.catalogueEntry.replacingOccurrences(of: "pollen-robotics", with: "someone"))
        #expect(app.isOfficial == false)
    }

    @Test("falls back to the app name when the card has no title")
    func fallsBackToName() throws {
        let app = try decode(#"""
        {"name": "reachy-mini-dance", "source_kind": "hf_space", "extra": {"id": "someone/reachy-mini-dance"}}
        """#)
        #expect(app.title == "Reachy Mini Dance")
        #expect(app.emoji == nil)
        #expect(app.gradient == nil)
    }

    /// A payload whose fields arrive with unexpected types must still produce an
    /// app: the daemon versions independently of this client (project rule 3).
    @Test("a malformed card costs the metadata, not the app")
    func toleratesMalformedExtra() throws {
        let app = try decode(#"""
        {"name": "odd", "source_kind": "hf_space", "extra": {"id": 7, "likes": "many"}}
        """#)
        #expect(app.name == "odd")
        #expect(app.spaceID == nil)
        #expect(app.title == "Odd")
    }

    // MARK: Installed apps

    /// `local_common_venv._save_app_metadata` writes the Space payload under the
    /// slug at install time and merges it back into the installed listing, so the
    /// space id usually survives.
    @Test("an installed app carries the space id the daemon saved with it")
    func installedAppKeepsSpaceID() throws {
        let app = try decode(#"""
        {
          "name": "reachy_mini_dance",
          "source_kind": "installed",
          "extra": {"id": "pollen-robotics/reachy-mini-dance", "venv_path": "/venvs/apps_venv"}
        }
        """#)
        #expect(app.isInstalled)
        #expect(app.spaceID == "pollen-robotics/reachy-mini-dance")
    }

    /// On a wireless robot the installed listing looks its metadata up by entry
    /// point name alone (`_load_app_metadata`), so an app whose Python entry point
    /// was named differently from its Space comes back with no id at all.
    @Test("an installed app whose metadata was never found has no space id")
    func installedAppWithoutMetadata() throws {
        let app = try decode(#"""
        {"name": "dance_party", "source_kind": "installed", "extra": {"venv_path": "/venvs/apps_venv"}}
        """#)
        #expect(app.spaceID == nil)
        #expect(app.title == "Dance Party")
    }

    // MARK: Identity

    private func catalogueEntry(slug: String, id: String?) throws -> RobotApp {
        let extra = id.map { #"{"id": "\#($0)"}"# } ?? "{}"
        return try decode(#"{"name": "\#(slug)", "source_kind": "hf_space", "extra": \#(extra)}"#)
    }

    private func installedEntry(name: String, id: String? = nil) throws -> RobotApp {
        let extra = id.map { #"{"id": "\#($0)"}"# } ?? "{}"
        return try decode(#"{"name": "\#(name)", "source_kind": "installed", "extra": \#(extra)}"#)
    }

    @Test("the space id settles it whenever both sides carry one")
    func matchesBySpaceID() throws {
        let card = try catalogueEntry(slug: "reachy-mini-dance", id: "pollen-robotics/reachy-mini-dance")
        let installed = try installedEntry(name: "dance_party", id: "pollen-robotics/reachy-mini-dance")

        #expect(card.matches(installed: installed))
    }

    /// Start, stop, remove and update are all keyed by the installed name. A wrong
    /// match does not show the wrong badge — it stops somebody else's app.
    @Test("two different spaces never match, however alike their names")
    func differentSpacesNeverMatch() throws {
        let card = try catalogueEntry(slug: "reachy-mini-dance", id: "pollen-robotics/reachy-mini-dance")
        let installed = try installedEntry(name: "reachy-mini-dance", id: "someone-else/reachy-mini-dance")

        #expect(card.matches(installed: installed) == false)
    }

    /// The realistic shape of the trap: the Space author's Python entry point uses
    /// different separators from the Space slug, so the daemon's metadata lookup
    /// (by exact name) misses and the installed entry arrives with no id. The
    /// daemon's own fallback normalises exactly this way.
    @Test("without an id, separators and case are what differ — and are ignored")
    func matchesByNormalisedName() throws {
        let card = try catalogueEntry(slug: "reachy-mini-dance", id: "pollen-robotics/reachy-mini-dance")

        #expect(try card.matches(installed: installedEntry(name: "reachy_mini_dance")))
        #expect(try card.matches(installed: installedEntry(name: "ReachyMiniDance")))
    }

    @Test("an unrelated app does not match on name either")
    func unrelatedNamesDoNotMatch() throws {
        let card = try catalogueEntry(slug: "reachy-mini-dance", id: "pollen-robotics/reachy-mini-dance")

        #expect(try card.matches(installed: installedEntry(name: "chess")) == false)
    }

    /// Two empty names normalise to the same empty string, which is not a match.
    @Test("nothing matches nothing")
    func emptyNamesDoNotMatch() throws {
        let card = try catalogueEntry(slug: "", id: nil)

        #expect(try card.matches(installed: installedEntry(name: "")) == false)
    }

    // MARK: - The app's own control port

    /// `extra["custom_app_url"]` as the daemon really sends it: the literal the
    /// app declares in its `main.py`, bind address and all.
    @Test("takes the port out of custom_app_url and nothing else")
    func readsCustomAppPort() throws {
        let app = try decode(#"""
        {"name": "reachy_mini_conversation_app", "source_kind": "installed",
         "extra": {"custom_app_url": "http://0.0.0.0:7860/",
                   "venv_path": "/home/pollen/.local/share/reachy_mini/apps_venv"}}
        """#)

        #expect(app.customAppPort == 7860)
    }

    @Test("a port the app moved to is the one that is used")
    func followsARelocatedPort() throws {
        let app = try decode(#"""
        {"name": "reachy_mini_conversation_app", "source_kind": "installed",
         "extra": {"custom_app_url": "http://0.0.0.0:8123/"}}
        """#)

        #expect(app.customAppPort == 8123)
    }

    /// The daemon writes the key with a null value when its scrape of `main.py`
    /// found nothing, and catalogue entries never carry it at all. Both have to
    /// read as "no port", not as a decoding failure that costs the whole app.
    @Test("no port survives a missing, null or portless url", arguments: [
        #"{"venv_path": "/apps_venv"}"#,
        #"{"custom_app_url": null}"#,
        #"{"custom_app_url": "http://0.0.0.0"}"#,
        #"{"custom_app_url": ""}"#,
        #"{"custom_app_url": 7860}"#,
    ])
    func absentCustomAppPort(extra: String) throws {
        let app = try decode(#"{"name": "app", "source_kind": "installed", "extra": \#(extra)}"#)

        #expect(app.customAppPort == nil)
        #expect(app.name == "app")
    }
}
