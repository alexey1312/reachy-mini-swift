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
/// One copy, and that is the point. Four near-identical `private` ones stood in this
/// target — `KnownRobotsModelTests`, `PresenceModelTests`, `BLEConsoleModelTests`,
/// `ConnectProgressModelTests` — and a fifth written by hand from a `grep` that began
/// at the `func` line dropped the attribute sitting one line above it. CI is what
/// found that.
///
/// **`private` at file scope does not buy a namespace**: two top-level functions with
/// the same name and signature are a redeclaration whichever access level they carry,
/// so leaving one copy behind fails as `invalid redeclaration of
/// 'waitUntil(_:timeout:_:sourceLocation:)'` rather than shadowing quietly. That is why
/// `poll` is a parameter — `ConnectProgressModelTests` is the one suite that needs a
/// finer grain, because its assertions measure `dwell` against a `ContinuousClock` and
/// a 20 ms step would put up to 20 ms of overshoot into a 120 ms budget.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    poll: Duration = .milliseconds(20),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: poll)
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
