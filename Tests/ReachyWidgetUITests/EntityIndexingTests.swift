import CoreSpotlight
import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// Nothing here can be read back out of Spotlight — no API returns an indexed
/// item — so what is assertable is the attribute set handed over, and that is
/// where the whole value of indexing entities sits: the words a person types are
/// rarely the title, and the default `attributeSet` carries the title alone.
@Suite("Entity indexing")
struct EntityIndexingTests {
    private func app(
        id: String = "pollen-robotics/dance-party",
        name: String = "dance_party",
        title: String = "Dance Party",
        isInstalled: Bool = true
    ) -> RobotAppEntity {
        RobotAppEntity(RobotAppSummary(id: id, name: name, title: title), isInstalled: isInstalled)
    }

    // MARK: - Apps

    @Test("an app is indexed under its title")
    func namesAnApp() {
        let attributes = app().attributeSet

        #expect(attributes.title == "Dance Party")
        #expect(attributes.displayName == "Dance Party")
    }

    /// The entry point is not a name anybody chose, but it is what the daemon's
    /// status, the robot's journal and every log line call this app — so somebody
    /// who has read any of them will type it.
    @Test("an app is findable by its Python entry point as well as its title")
    func indexesAnAppsEntryPoint() {
        let keywords = app().attributeSet.keywords ?? []

        #expect(keywords.contains("dance_party"))
        #expect(keywords.contains("Dance Party"))
    }

    /// `dance_party` is one token to a search index. Splitting it is what puts
    /// `dance` in as a term of its own, which no amount of prefix matching on the
    /// whole string would reach.
    @Test("an underscored entry point contributes its words separately")
    func splitsAnEntryPointIntoWords() {
        let keywords = app().attributeSet.keywords ?? []

        #expect(keywords.contains("dance"))
        #expect(keywords.contains("party"))
    }

    /// A row that offers to start an app the robot does not have is a row that
    /// cannot do what it promises. The index still carries it — `ReachyEntityIndex`
    /// only ever hands over installed apps — but the description has to be honest
    /// about a placeholder resolved from a saved configuration.
    @Test("an app that is not installed says so")
    func marksAnUninstalledApp() {
        let installed = app().attributeSet.contentDescription ?? ""
        let missing = app(isInstalled: false).attributeSet.contentDescription ?? ""

        #expect(installed != missing)
        #expect(missing.localizedCaseInsensitiveContains("not installed"))
    }

    @Test("the same word is not indexed twice")
    func deduplicatesAppKeywords() {
        let keywords = app(name: "dance", title: "Dance").attributeSet.keywords ?? []

        #expect(keywords.filter { $0.caseInsensitiveCompare("dance") == .orderedSame }.count == 1)
    }

    @Test("no keyword is blank or carries the separator's whitespace")
    func trimsAppKeywords() {
        let keywords = app().attributeSet.keywords ?? []

        let untrimmed = keywords.map { $0 != $0.trimmingCharacters(in: .whitespaces) }
        #expect(untrimmed.contains(true) == false)
        #expect(keywords.map(\.isEmpty).contains(true) == false)
    }

    // MARK: - Moves

    /// The daemon gives a move no title at all — the id is two path components and
    /// the name is a file stem. `MoveLibrary.displayName` is the only title there
    /// is, and it is what a person would say out loud.
    @Test("a move is indexed under its spoken name, not its file stem")
    func namesAMove() {
        let entity = MoveEntity(dataset: "pollen-robotics/reachy-mini-dances-library", move: "happy_dance")

        let attributes = entity.attributeSet

        #expect(attributes.title == "happy dance")
        #expect(attributes.keywords?.contains("happy_dance") == true)
    }

    /// "Happy" from Emotions and "Happy" from Dances are two different moves. The
    /// library is what tells them apart in the picker, and it has to do the same job
    /// in a search result.
    @Test("a move carries its library so two of the same name are distinguishable")
    func namesAMovesLibrary() {
        let dance = MoveEntity(dataset: "pollen-robotics/reachy-mini-dances-library", move: "happy")
        let emotion = MoveEntity(dataset: "pollen-robotics/reachy-mini-emotions-library", move: "happy")

        #expect(dance.attributeSet.contentDescription != emotion.attributeSet.contentDescription)
        #expect(dance.attributeSet.keywords?.contains("Dances") == true)
        #expect(emotion.attributeSet.keywords?.contains("Emotions") == true)
    }

    /// No route lists the datasets, so which libraries exist is a decision this app
    /// makes — and a robot can answer for one it has never heard of. Naming it as
    /// the robot spells it beats hiding the move.
    @Test("a move from an unknown library is named as the robot spells it")
    func namesAnUnknownLibrary() {
        let entity = MoveEntity(dataset: "somebody/experimental", move: "wobble")

        let description = entity.attributeSet.contentDescription ?? ""

        #expect(description.contains("somebody/experimental"))
    }

    // MARK: - The keyword list itself

    /// One comma-separated catalogue string per caller, so a translator replaces the
    /// list wholesale — the words somebody would type are not a translation of these
    /// words, and there are not necessarily this many of them.
    @Test("a comma-separated argument is read as a list")
    func splitsACatalogueList() {
        let keywords = ReachyEntityKeywords.list("Dance Party", "robot app, app, Reachy Mini")

        #expect(keywords.contains("robot app"))
        #expect(keywords.contains("app"))
        #expect(keywords.contains("Reachy Mini"))
    }

    @Test("order is kept, so the title leads")
    func keepsKeywordOrder() {
        let keywords = ReachyEntityKeywords.list("Dance Party", "move, dance")

        #expect(keywords.first == "Dance Party")
    }
}
