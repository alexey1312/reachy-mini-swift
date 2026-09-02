import Foundation
import Observation

/// Something to do on the Apps tab, asked for from outside the running interface —
/// today from the two App Intents schemas the app answers.
///
/// One inbox and not two, because the two requests differ only in payload: both
/// select the tab, both are honoured by `ReachyTabShell` (which owns
/// `AppStoreModel`), and both have to survive the connect gate being up. It arrived
/// as `AppSearchInbox` when search was the only one.
///
/// The `shared`/token shape is `CallRequestInbox`'s and `QuickActionInbox`'s, for
/// the same two reasons: an intent runs with no initialiser to inject through, and
/// SwiftUI notices a *change*, so two identical requests have to arrive as two
/// values or `onChange` never fires for the second.
///
/// **Unlike a call request it does not expire, and the difference is the point.** A
/// redial that waits out a slow connection and then opens the microphone minutes
/// after the tap is a privacy bug, which is what `CallRequest.timeToLive` answers.
/// Filling a search field or opening a page opens nothing; a request that waits for
/// the gate to lift and is then honoured is the behaviour somebody asked for,
/// however long the robot took to answer.
@MainActor
@Observable
public final class AppStoreRequestInbox {
    public enum Request: Equatable, Sendable {
        /// Fill the store's search field. `SearchRobotAppsIntent` (`.system.search`).
        case search(term: String)
        /// Open one app's page. `OpenRobotAppIntent` (`.system.open`), and every
        /// other arrival of a `reachy-mini-swift://apps?id=…` URL — a tapped
        /// Spotlight row for an app entity reaches this too.
        case openApp(id: String)
    }

    public struct Pending: Equatable, Sendable {
        public let request: Request
        let token: Int
    }

    public static let shared = AppStoreRequestInbox()

    public private(set) var pending: Pending?
    private var issued = 0

    public init() {}

    /// A blank term is dropped rather than filed: it would select the Apps tab and
    /// change nothing, which reads as a search that failed.
    public func receive(term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        file(.search(term: term))
    }

    /// A blank id is dropped for the same reason, and an id this robot has never
    /// heard of is *not* — resolving it is the screen's job, and it may take a
    /// catalogue load to answer.
    public func receive(appID: String) {
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return }
        file(.openApp(id: appID))
    }

    /// The request has been honoured. Spent rather than left standing, so returning
    /// to the Apps tab later does not re-fill a field the reader has since cleared,
    /// or re-open a page they closed.
    func drop() {
        pending = nil
    }

    private func file(_ request: Request) {
        issued += 1
        pending = Pending(request: request, token: issued)
    }
}
