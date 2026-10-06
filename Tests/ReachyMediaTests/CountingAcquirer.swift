@testable import ReachyMedia

/// Counts the media acquires a session makes, where a robot would be sent a POST.
actor CountingAcquirer: MediaAcquiring {
    private(set) var calls = 0

    func acquireMedia() {
        calls += 1
    }
}
