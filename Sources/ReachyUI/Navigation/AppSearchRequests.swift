import Foundation
import Observation

/// A request to search the robot's app catalogue, arriving from outside the running
/// interface — today only from `SearchRobotAppsIntent`, the app's `.system.search`
/// conformance.
///
/// The `shared`/token shape is `CallRequestInbox`'s and `QuickActionInbox`'s, for
/// the same two reasons: an intent runs with no initialiser to inject through, and
/// SwiftUI notices a *change*, so two identical searches have to arrive as two
/// values or `onChange` never fires for the second.
///
/// **Unlike a call request it does not expire, and the difference is the point.** A
/// redial that waits out a slow connection and then opens the microphone minutes
/// after the tap is a privacy bug, which is what `CallRequest.timeToLive` answers.
/// Filling a search field opens nothing; a request that waits for the gate to lift
/// and then fills it is the behaviour somebody asked for, however long the robot
/// took to answer.
@MainActor
@Observable
public final class AppSearchInbox {
    public struct Pending: Equatable, Sendable {
        public let term: String
        let token: Int
    }

    public static let shared = AppSearchInbox()

    public private(set) var pending: Pending?
    private var issued = 0

    public init() {}

    /// A blank term is dropped rather than filed: it would select the Apps tab and
    /// change nothing, which reads as a search that failed.
    public func receive(term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        issued += 1
        pending = Pending(term: term, token: issued)
    }

    /// The request has been honoured. Spent rather than left standing, so returning
    /// to the Apps tab later does not re-fill a field the reader has since cleared.
    func drop() {
        pending = nil
    }
}
