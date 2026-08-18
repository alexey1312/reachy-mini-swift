import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// What the app *says* about which robot answered, as opposed to how it works that
/// out (`DaemonFlavourTests` in `ReachyKitTests`).
///
/// A pure mapping, so it needs no session and no client — the same split
/// `RunningAppCaptionTests` makes for the running-app caption.
@MainActor
@Suite("Daemon flavour caption")
struct DaemonFlavourCaptionTests {
    @Test("every flavour has a name", arguments: [
        (DaemonFlavour.wireless, "Wireless"),
        (.lite, "Lite"),
        (.simulation, "Simulation"),
        (.mockup, "Simulation (no physics)"),
        (.remote, "Hugging Face relay"),
    ])
    func names(flavour: DaemonFlavour, caption: String) {
        #expect(String(localized: DaemonFlavourCaption.text(for: flavour)) == caption)
    }

    /// The note explains why the Wi-Fi, update and maintenance cards are gone, so it
    /// belongs to exactly the flavours that lose them — and to no others, or a
    /// Wireless robot would carry a paragraph about an absence it does not have.
    @Test("only the flavours that lose settings explain the loss")
    func explainsOnlyWhereSomethingIsMissing() {
        let explained = DaemonFlavour.allCases.filter { DaemonFlavourCaption.absentSettings(for: $0) != nil }

        #expect(explained == [.lite, .simulation, .mockup])
    }

    /// The two sentences differ on purpose: a Lite robot's Wi-Fi is somewhere else,
    /// a simulated robot has none at all. Collapsing them into one would tell a
    /// simulator user to go and look on a computer for a network that does not
    /// exist.
    @Test("a Lite robot and a simulator are given different reasons")
    func liteAndSimulationReadDifferently() throws {
        let lite = try #require(DaemonFlavourCaption.absentSettings(for: .lite))
        let simulation = try #require(DaemonFlavourCaption.absentSettings(for: .simulation))

        #expect(String(localized: lite) != String(localized: simulation))
    }

    /// The set of flavours that run on a computer and the set that owe an
    /// explanation are the same set, and they have to stay that way: the note is
    /// about where the daemon lives, so a flavour that gains one without the other
    /// is a screen that either explains nothing or explains the wrong thing.
    @Test("the flavours that explain themselves are the ones whose daemon is on a computer")
    func explanationTracksWhereTheDaemonRuns() {
        let explained = DaemonFlavour.allCases.filter { DaemonFlavourCaption.absentSettings(for: $0) != nil }
        let onAComputer = DaemonFlavour.allCases.filter(\.runsOnAComputer)

        #expect(explained == onAComputer)
    }
}
