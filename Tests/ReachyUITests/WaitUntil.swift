import Testing

/// Polls rather than sleeping: the suites are `@MainActor` and a loaded runner starves
/// them, so a fixed wait before an assertion is a flake in waiting (rule 7).
///
/// **`@MainActor` is load-bearing, and dropping it fails at the call site rather than
/// here.** Every suite using this is main-actor isolated, so `condition` captures
/// main-actor state; without the attribute that `() -> Bool` crosses an isolation
/// boundary and Swift 6 rejects it — `sending value of non-Sendable type '() -> Bool'
/// risks causing data races`, once per `await waitUntil`, with a cascade of `@const`
/// and `@section` errors out of the swift-testing macro expansions on top. None of
/// those name this function.
///
/// One copy, and that is the point. Three byte-identical `private` ones stood in
/// `KnownRobotsModelTests`, `PresenceModelTests` and `BLEConsoleModelTests`, and a
/// fourth written by hand from a `grep` that began at the `func` line dropped the
/// attribute sitting one line above it. CI is what found that.
/// `ConnectProgressModelTests` keeps a copy of its own on purpose: its assertions are
/// about `dwell`, so it polls every 5 ms rather than 20.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
