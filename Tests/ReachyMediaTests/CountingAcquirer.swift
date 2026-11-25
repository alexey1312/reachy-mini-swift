@testable import ReachyMedia

/// Counts the media acquires a session makes, where a robot would be sent a POST.
///
/// `refusals` is what the robot answers to the first calls, in order; every call after
/// them succeeds.
actor CountingAcquirer: MediaAcquiring {
    private(set) var calls = 0
    private var refusals: [any Error]

    init(refusing refusals: [any Error] = []) {
        self.refusals = refusals
    }

    func acquireMedia() throws {
        calls += 1
        if !refusals.isEmpty {
            throw refusals.removeFirst()
        }
    }
}
