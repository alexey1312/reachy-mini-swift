import Foundation
@testable import ReachyUI

/// Records what a model handed the notification seam.
///
/// Per-test rather than shared: `--parallel` runs suites concurrently, and a
/// recorder held statically would make one suite's assertions depend on another's
/// timing — the hazard `StubURLProtocol` binds its stubs to a session to avoid.
@MainActor
final class JobEventLog {
    private(set) var events: [JobNotificationPlan.Event] = []

    /// Handed to a model as its `notify` seam.
    func record(_ event: JobNotificationPlan.Event) {
        events.append(event)
    }

    var startCount: Int {
        events.filter { event in
            guard case .started = event else { return false }
            return true
        }.count
    }

    /// Just the outcomes, which is what every policy assertion is actually about.
    var results: [JobNotificationPlan.Result] {
        events.compactMap { event in
            guard case let .settled(_, result, _) = event else { return nil }
            return result
        }
    }

    var notices: [JobNotificationPlan.Notice] {
        events.map { event in
            switch event {
            case let .started(notice, _), let .settled(notice, _, _): notice
            }
        }
    }
}
