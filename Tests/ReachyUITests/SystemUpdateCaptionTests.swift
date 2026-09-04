import ReachyDesign
@testable import ReachyUI
import Testing

/// The mapping the settings card and the too-old-daemon gate now share.
///
/// It is here rather than in `SystemUpdateModelTests` for the reason
/// `RunningAppCaptionTests` is split off from its model's: this is a pure function
/// over the state machine's output, and the model's suite is about how the state
/// machine reaches those values in the first place.
@Suite("System update captions")
struct SystemUpdateCaptionTests {
    /// Every case, listed by hand because `State` carries associated values and
    /// cannot be `CaseIterable`. The `switch` with no `default` is what makes a
    /// tenth case a compile error in this file — it proves each listed value is a
    /// case, not that the list is complete, and the weaker claim is the honest one.
    private static let states: [SystemUpdateModel.State] = [
        .idle,
        .checking,
        .upToDate(current: "1.10.0"),
        .robotOffline(current: "1.10.0"),
        .available(current: "1.10.0", latest: "1.11.0"),
        .installing,
        .restarting,
        .finished(version: "1.11.0"),
        .failed("the installer gave up"),
    ]

    @Test("every state is answered on both purposes")
    func everyStateIsAnswered() {
        for state in Self.states {
            switch state {
            case .idle, .checking, .upToDate, .robotOffline, .available,
                 .installing, .restarting, .finished, .failed:
                break
            }
            for purpose in [SystemUpdateCaption.Purpose.offered, .required] {
                let row = SystemUpdateCaption.row(for: state, purpose: purpose)
                #expect(text(of: row).isEmpty == false)
            }
        }
    }

    /// Rule 10's assertion, and the reason the two screens share a mapping at all:
    /// four of the nine arms were already identical, and a user who reads one
    /// wording on the card and another on the gate has been told two things about
    /// one robot.
    @Test("the four in-flight states say the same thing on both screens")
    func inFlightStatesDoNotDiverge() {
        for state in [
            SystemUpdateModel.State.installing,
            .restarting,
            .finished(version: "1.11.0"),
            .failed("the installer gave up"),
        ] {
            #expect(
                SystemUpdateCaption.row(for: state, purpose: .offered)
                    == SystemUpdateCaption.row(for: state, purpose: .required)
            )
        }
    }

    /// The one state that means opposite things. On the card it is the good news;
    /// on the gate the newest published release is still too old and nothing here
    /// can fix it. This is the test that goes red the day somebody "unifies" the
    /// two screens by deleting `Purpose`, which is the refactor that would
    /// otherwise break it silently.
    @Test("up to date is success on the card and a warning on the gate")
    func upToDateMeansOppositeThings() {
        let state = SystemUpdateModel.State.upToDate(current: "1.10.0")
        let offered = SystemUpdateCaption.row(for: state, purpose: .offered)
        let required = SystemUpdateCaption.row(for: state, purpose: .required)

        #expect(offered == .label(
            String(localized: .reachy("Up to date — 1.10.0")),
            symbol: "checkmark.circle",
            tone: .success
        ))
        #expect(required == .label(
            String(localized: .reachy("The robot is on 1.10.0, the newest release available to it.")),
            symbol: "exclamationmark.triangle",
            tone: .warning
        ))
    }

    /// The daemon's own sentence passes through untranslated, the way an unknown
    /// recovery script keeps its file name. Project rule 3: what the robot said is
    /// carried, never replaced.
    @Test("a failure carries the daemon's own sentence")
    func failureCarriesTheDaemonSentence() {
        #expect(
            SystemUpdateCaption.row(for: .failed("boom"), purpose: .offered)
                == .label("boom", symbol: "xmark.octagon", tone: .danger)
        )
    }

    /// The two `LabeledContent` shapes are separate cases on purpose — one plain,
    /// one monospaced — and the references pin the difference. Named here so a
    /// future "simplify to one case" has an assertion to argue with.
    @Test("the installed version and the version pair are different shapes")
    func labeledContentShapesStayApart() {
        #expect(
            SystemUpdateCaption.row(for: .idle, purpose: .offered)
                == .value(title: String(localized: .reachy("Installed")), value: "—")
        )
        #expect(
            SystemUpdateCaption.row(for: .idle, purpose: .offered, installed: "1.10.0")
                == .value(title: String(localized: .reachy("Installed")), value: "1.10.0")
        )
        #expect(
            SystemUpdateCaption.row(for: .available(current: "1.10.0", latest: "1.11.0"), purpose: .offered)
                == .versions(
                    title: String(localized: .reachy("Update available")),
                    value: String(localized: .reachy("1.10.0 → 1.11.0"))
                )
        )
    }

    private func text(of row: SystemUpdateCaption.Row) -> String {
        switch row {
        case let .label(text, _, _): text
        case let .value(title, _), let .versions(title, _): title
        }
    }
}
