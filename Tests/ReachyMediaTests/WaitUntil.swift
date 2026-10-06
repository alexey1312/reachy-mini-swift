import Testing

@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(20),
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
