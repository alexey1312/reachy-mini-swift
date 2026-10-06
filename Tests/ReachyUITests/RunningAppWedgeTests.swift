import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// A client that speaks the apps protocol and answers nothing, which is what an
/// unreachable robot looks like from here: the capability is present, the reading
/// never arrives. Every route falls through to the protocol's throwing default.
private struct UnansweringAppsClient: RobotAPIClient, RobotAppsClient {
    private let base = PreviewRobotClient()

    func handshake() async throws -> RobotConnection.Handshake {
        try await base.handshake()
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        try await base.daemonStatus()
    }

    func wakeUp() async throws -> String {
        try await base.wakeUp()
    }

    func gotoSleep() async throws -> String {
        try await base.gotoSleep()
    }
}

/// The deadline on a transition, what the dock does once it has passed, and how
/// long a refused command stays in the one caption line the dock has.
///
/// Split from `RunningAppModelTests` the way `RunningAppCaptionTests` was — that
/// file is at SwiftLint's length limit, and these assertions share nothing with
/// visibility or deep links beyond the model they run against.
///
/// **Every assertion here injects its own date.** Crossing a 40-second deadline by
/// waiting one out would be a 40-second test and a flake on a loaded runner, and the
/// wrong branch would pass it anyway — just later (project rule 7).
@MainActor
@Suite("A transition that never ends", .timeLimit(.minutes(1)))
struct RunningAppWedgeTests {
    private static let app = RobotApp.previewInstalled[0]

    private func status(_ state: RobotAppStatus.State) -> RobotAppStatus {
        RobotAppStatus(app: Self.app, state: state)
    }

    /// A robot that holds a status and answers no poll — the shape of a network
    /// blip, not of a robot that said anything.
    private func deafSession(_ state: RobotAppStatus.State) -> RobotSession {
        .preview(
            phase: .connected(.preview),
            runningApp: status(state),
            client: UnansweringAppsClient()
        )
    }

    /// **The daemon has a state it cannot leave**, and this is the whole reason the
    /// deadline exists. `stop_current_app` sets `stopping` before any I/O and clears
    /// the slot only on its last line, past three unbounded awaits; a hang in
    /// between leaves the app dead, the slot taken and both stop and start answering
    /// 400 (`apps/manager.py:275-279`, `:355`). Nothing over REST ends it.
    @Test("a transition is stuck only once it outlasts its deadline")
    func namesAWedgedTransition() {
        let model = RunningAppModel()
        let configuration = RunningAppModel.Configuration()
        let began = Date()
        let stopping = status(.stopping)

        model.noteTransition(stopping, at: began)
        #expect(model.wedged == nil)

        // One second short of the deadline is still a transition.
        model.noteTransition(stopping, at: began.addingTimeInterval(39))
        #expect(model.wedged == nil)

        model.noteTransition(stopping, at: began.addingTimeInterval(41))
        #expect(model.wedged?.state == .stopping)
        #expect(configuration.stoppingDeadline == .seconds(40))
    }

    /// A cold start pays for an interpreter, a model load and whatever the app
    /// fetches, so it gets three times the budget — and 41 seconds, which condemns a
    /// stop, must leave a start alone.
    @Test("starting is given far longer than stopping")
    func startingHasItsOwnDeadline() {
        let model = RunningAppModel()
        let began = Date()
        let starting = status(.starting)

        model.noteTransition(starting, at: began)
        model.noteTransition(starting, at: began.addingTimeInterval(41))
        #expect(model.wedged == nil)

        model.noteTransition(starting, at: began.addingTimeInterval(121))
        #expect(model.wedged?.state == .starting)
    }

    /// The clock is keyed on the app and the state together, so a transition that
    /// actually moves cannot inherit the age of the one before it.
    @Test("a transition that progresses starts the clock again")
    func resetsTheClockOnANewTransition() {
        let model = RunningAppModel()
        let began = Date()

        model.noteTransition(status(.starting), at: began)
        // Same app, next state: `starting` had been running for 200 s, but this is
        // a `stopping` one second old.
        model.noteTransition(status(.stopping), at: began.addingTimeInterval(200))
        #expect(model.wedged == nil)

        model.noteTransition(status(.stopping), at: began.addingTimeInterval(241))
        #expect(model.wedged?.state == .stopping)
    }

    @Test("reaching a settled state clears the verdict")
    func clearsTheWedgeWhenItResolves() {
        let model = RunningAppModel()
        let began = Date()

        model.noteTransition(status(.stopping), at: began)
        model.noteTransition(status(.stopping), at: began.addingTimeInterval(41))
        #expect(model.wedged != nil)

        // What a restart of the robot's software looks like from here.
        model.noteTransition(nil, at: began.addingTimeInterval(42))
        #expect(model.wedged == nil)
    }

    /// `RobotAppStatus.State.isBusy` counts an unfamiliar state as busy, because
    /// offering Start for a taken slot is the worse mistake. That is not evidence of
    /// a *transition*, so a word a later daemon invented is never called stuck — it
    /// may be perfectly stable, and inventing a fault for it would be worse than
    /// saying nothing (project rule 3).
    @Test("an unfamiliar state is never called stuck, however long it lasts")
    func neverWedgesAnUnknownState() {
        let model = RunningAppModel()
        let began = Date()
        let unknown = status(.unknown("reloading"))

        model.noteTransition(unknown, at: began)
        model.noteTransition(unknown, at: began.addingTimeInterval(6000))

        #expect(model.wedged == nil)
    }

    /// A wedge is not ending in the next second and a half. Backing off rather than
    /// stopping, because a restart done from the recovery screen has to be noticed.
    @Test("a wedged transition stops being polled like one")
    func backsOffOnceWedged() {
        let model = RunningAppModel()
        let configuration = RunningAppModel.Configuration()
        let began = Date()
        let stopping = status(.stopping)

        model.noteTransition(stopping, at: began)
        #expect(model.interval(for: stopping) == configuration.transitioning)

        model.noteTransition(stopping, at: began.addingTimeInterval(41))
        #expect(model.interval(for: stopping) == configuration.running)
    }

    /// **A reading that did not arrive is no evidence about a transition.** The poll
    /// swallows its own failure and the session goes on holding the last status, so
    /// timing that as if it were fresh calls a network blip a wedge — and the sheet
    /// then tells somebody whose Wi-Fi dropped to go and restart the robot's software
    /// over Bluetooth. `canPoll` admits the `.unreachable` phase on purpose, so this
    /// is the ordinary shape of a robot that stopped answering mid-stop.
    @Test("a poll that answered nothing does not age the transition")
    func ignoresAReadingThatDidNotArrive() async {
        let model = RunningAppModel()
        let session = deafSession(.stopping)
        let began = Date()

        await model.refresh(session: session, at: began)
        await model.refresh(session: session, at: began.addingTimeInterval(41))

        #expect(model.wedged == nil)
    }

    /// **The strip has one caption line and the refusal has to go in it** — the dock
    /// rendered no error at all before, and the next poll then removed the dock, which
    /// reads as the Stop having worked. It has to leave again too: `lastError` is
    /// cleared only by a later *successful* command, so a refused Restart on an app
    /// that goes on running kept the state phrase — and the conversation turn with it
    /// — off the strip for the rest of the session.
    ///
    /// The poll is what ages it out, because the poll is the only thing already
    /// ticking. A window enforced by a `Timer` would be a second clock to own, cancel
    /// and get wrong while backgrounded.
    @Test("a refused command leaves the caption after its turn, not after the session")
    func agesOutARefusedCommand() async {
        let model = RunningAppModel()
        let session = deafSession(.running)

        await model.stop(session: session)
        #expect(model.lastError != nil)

        // Still there a tick later: a refusal nobody had time to read is a refusal
        // shown nowhere, and the poll can land milliseconds after the tap.
        await model.refresh(session: session, at: Date())
        #expect(model.lastError != nil)

        await model.refresh(session: session, at: Date().addingTimeInterval(600))
        #expect(model.lastError == nil)
    }

    /// **A stuck start and a stuck stop are not the same situation**, and the notice
    /// under the caption has to say which — `RunningAppCaption.stuck(in:)` already
    /// splits the phrase for exactly that reason. It claimed the app "has already
    /// stopped" for both, which is false for a start that never finished: nothing ran,
    /// so nothing stopped, and the reader is told the opposite of what happened.
    ///
    /// Asserted here rather than in a reference image because only the sheet renders
    /// it, and `Running app — stuck starting` covers the layout; this covers the claim.
    @Test("the notice says which transition wedged")
    func namesTheWedgedTransition() {
        let stopping = WedgedAppNotice.situation(in: .stopping)
        let starting = WedgedAppNotice.situation(in: .starting)

        #expect(stopping != starting)
        #expect(stopping.contains("already stopped"))
        #expect(starting.contains("never finished starting"))
        #expect(!starting.contains("already stopped"))
    }

    /// The way out names the command as the recovery screen titles its row. It ended
    /// in the script's file name, "RESTART_DAEMON", which no screen shows, so the
    /// reader had to match a raw daemon word against a row in plain words.
    @Test("the way out names the command by its row title, not its file name")
    func namesTheCommandAsTheRecoveryScreenDoes() {
        let restart = BLERecoveryScript.describing("RESTART_DAEMON")

        #expect(WedgedAppNotice.wayOut.contains(BLERecoveryScriptCaption.title(for: restart)))
        #expect(!WedgedAppNotice.wayOut.contains(restart.name))
    }
}
