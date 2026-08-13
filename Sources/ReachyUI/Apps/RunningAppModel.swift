import Foundation
import Observation
import ReachyKit

/// Decides whether the global dock is on screen, keeps its reading fresh, and
/// carries the two actions it offers.
///
/// The *value* — which app holds the robot — lives on `RobotSession`, written by
/// the one funnel every app command already passes through. What lives here is
/// policy: how often to ask, when to stop asking, and which failures the user has
/// already waved away. That split is why the dock and the home-screen widget can
/// never disagree about what is running.
@MainActor
@Observable
final class RunningAppModel {
    typealias ConversationTurns = @MainActor (RobotSession, RobotApp) throws -> AsyncStream<ConversationTurn>
    typealias SetConversationMuted = @MainActor (RobotSession, RobotApp, Bool) async throws -> Void
    typealias InterruptConversation = @MainActor (RobotSession, RobotApp) async throws -> Void

    /// How long a deep link asking for the running app's page waits for one to
    /// appear.
    ///
    /// It has to wait at all: the tap that sends it usually launches the app from
    /// cold, and there is no status to show until a connection and a poll have both
    /// come back. It has to stop waiting too — a sheet opening over whatever the
    /// user went on to do a minute later is not the page they asked for.
    static let expansionRequestWindow: TimeInterval = 30

    /// Which app-and-error the user dismissed. Keyed on both: the same app failing
    /// a *second*, different way is news again.
    private struct Dismissal: Equatable {
        let app: String
        let error: String?

        init(_ status: RobotAppStatus) {
            app = status.app.name
            error = status.error
        }
    }

    /// A transition being timed: which app, into which state, since when.
    ///
    /// Keyed on the app *and* the state so that a different app, or the same app
    /// moving on to a different transition, starts the clock afresh instead of
    /// inheriting an older one's age.
    private struct TransitionWatch: Equatable {
        let app: String
        let state: RobotAppStatus.State
        let since: Date

        init(_ status: RobotAppStatus, at date: Date) {
            app = status.app.name
            state = status.state
            since = date
        }

        /// Same app, same transition — so the clock keeps running.
        func matches(_ status: RobotAppStatus) -> Bool {
            app == status.app.name && state == status.state
        }
    }

    var isExpanded = false
    private(set) var busy = false
    /// Why the last Stop or Restart refused. Read in a slot of its own by
    /// `AppDetailSheet` and in the dock's single caption line, which is why it is aged
    /// out rather than left standing until a later command succeeds — see
    /// ``Configuration/actionFailureWindow``.
    private(set) var lastError: String?
    /// The app stuck mid-transition, once it has been stuck longer than the
    /// deadline for that transition — or nil.
    ///
    /// **This exists because the daemon has a state it cannot leave.**
    /// `stop_current_app` sets `stopping` before any I/O and clears the slot only
    /// on its last line, after three unbounded awaits; a hang anywhere in between
    /// leaves the app dead, the slot taken, and both stop and start answering 400
    /// (`apps/manager.py:275-279`, `:355`). Nothing over REST clears it — not even
    /// `POST /api/daemon/restart`, which restarts the motor backend and not the
    /// process holding the slot. Only restarting the robot's software does.
    ///
    /// Every sibling loop in this app has a deadline. This one had none, so the
    /// dock said "Stopping…" indefinitely while offering two buttons that could
    /// only answer 400 — which is how one wedged app became a nine-step incident
    /// on 2026-08-08.
    private(set) var wedged: RobotAppStatus?
    /// The app's own state inside the daemon's broader `.running` process state.
    /// Nil for every other app, old Conversation App builds, and remote sessions
    /// whose daemon cannot relay `/rpc` yet.
    ///
    /// Everything about the conversation is written in
    /// `RunningAppModel+Conversation.swift` — this file is at SwiftLint's length
    /// limit — so these are `internal(set)` rather than `private(set)`. Stored
    /// properties cannot live in an extension, which is the whole of the reason.
    internal(set) var conversationTurn: ConversationTurn?
    /// What this dock last asked the robot's microphone to be.
    ///
    /// Remembered rather than read: `conversation.mic` is a command, and
    /// `conversation.status` answers with backend configuration, not with the mic.
    /// So this is right until something other than this dock mutes the app — which
    /// nothing else in this app does, and only the app's own web UI could.
    ///
    /// `internal(set)` rather than `private(set)`: the two controls live in
    /// `RunningAppModel+Conversation.swift`, because this file is at SwiftLint's
    /// length limit, and `private(set)` does not reach across files.
    internal(set) var isMicrophoneMuted = false
    /// Cleared for good once the app answers `-32601`. A build without these methods
    /// cannot grow them mid-session, and a control that always fails is worse than
    /// no control.
    internal(set) var offersConversationControls = true

    private let configuration: Configuration
    let conversationTurns: ConversationTurns
    let setConversationMuted: SetConversationMuted
    let interruptConversation: InterruptConversation
    private var dismissal: Dismissal?
    private var watch: TransitionWatch?
    /// When ``lastError`` was recorded, so the poll can retire it.
    private var failedAt: Date?
    /// When a deep link last asked for the page, while there was nothing to open.
    private var requestedExpansion: Date?

    init(
        configuration: Configuration = Configuration(),
        conversationTurns: @escaping ConversationTurns = { try $0.conversationTurns(for: $1) },
        setConversationMuted: @escaping SetConversationMuted = {
            try await $0.setConversationMicrophoneMuted($2, for: $1)
        },
        interruptConversation: @escaping InterruptConversation = { try await $0.interruptConversation(for: $1) }
    ) {
        self.configuration = configuration
        self.conversationTurns = conversationTurns
        self.setConversationMuted = setConversationMuted
        self.interruptConversation = interruptConversation
    }

    // MARK: - Visibility

    /// What the dock should render, or `nil` to stay out of the way.
    ///
    /// A pure function of the session, so the whole rule is testable without a
    /// robot, a timer or a view.
    func visibleStatus(for session: RobotSession) -> RobotAppStatus? {
        guard let status = session.runningApp else { return nil }
        switch session.phase {
        // `resetConnectionState()` clears `runningApp`, so this is belt and braces
        // rather than a reachable state — but a dock floating over the connection
        // screen is exactly the bug it would be.
        case .idle, .connecting: return nil
        case .connected, .unreachable: break
        }
        switch status.state {
        // A finished app is not news. An errored one is, until it has been read.
        case .done: return nil
        case .error where dismissal == Dismissal(status): return nil
        default: return status
        }
    }

    /// The robot stopped answering. The app is probably still running — but the
    /// controls cannot reach it, so they are shown inert rather than lying.
    func isReachable(_ session: RobotSession) -> Bool {
        if case .unreachable = session.phase {
            return false
        }
        return true
    }

    func dismissFailure(_ session: RobotSession) {
        guard let status = session.runningApp else { return }
        dismissal = Dismissal(status)
        isExpanded = false
    }

    /// A widget asking for the running app's page.
    ///
    /// Opened at once when there is something to open, held otherwise: the app is
    /// usually launching from cold, and a sheet cannot be presented over a status
    /// that has not arrived. `visibleStatusChanged` is what honours it when it does.
    func requestExpansion(for session: RobotSession, at date: Date = Date()) {
        // Dismissal suppresses an unsolicited repeat of a crash. A widget tap is
        // an explicit request to read it again, so let the same status back into
        // both the sheet binding and the sheet's content.
        if let status = session.runningApp, dismissal == Dismissal(status) {
            dismissal = nil
        }
        guard visibleStatus(for: session) == nil else {
            requestedExpansion = nil
            isExpanded = true
            return
        }
        requestedExpansion = date
    }

    func visibleStatusChanged(_ status: RobotAppStatus?, at date: Date = Date()) {
        guard status != nil else {
            isExpanded = false
            return
        }
        guard let requested = requestedExpansion else { return }
        requestedExpansion = nil
        guard date.timeIntervalSince(requested) <= Self.expansionRequestWindow else { return }
        isExpanded = true
    }

    // MARK: - Refresh

    /// One tick. `refreshCurrentApp()` writes the session through `recordRunning`, so
    /// nothing is assigned here — and a failed call leaves the last known app
    /// standing rather than blanking the dock, which is what a daemon mid-restart
    /// deserves.
    func refresh(session: RobotSession, at date: Date = Date()) async {
        guard canPoll(session) else { return }
        let read: Void? = try? await session.refreshCurrentApp()
        expireActionFailure(at: date)
        // **A reading that did not arrive is no evidence about a transition.** The
        // session goes on holding the last one, so timing that as if it were fresh
        // turns a network blip into a wedge — and the sheet then tells somebody whose
        // Wi-Fi dropped to restart the robot's software over Bluetooth. Any verdict
        // already reached stands; nothing new is concluded from silence.
        guard read != nil else { return }
        noteTransition(session.runningApp, at: date)
    }

    /// Retires a refused Stop or Restart once it has had its turn on the strip.
    ///
    /// **Driven by the poll, because the poll is the only thing already ticking.** A
    /// window enforced by a `Timer` would be a second clock to own, cancel and get
    /// wrong while backgrounded — and while backgrounded there is nothing on screen
    /// for the refusal to be stale on. Internal so a test can cross the window
    /// without waiting one out (project rule 7).
    func expireActionFailure(at date: Date) {
        guard let failedAt,
              Duration.seconds(date.timeIntervalSince(failedAt)) >= configuration.actionFailureWindow
        else { return }
        lastError = nil
        self.failedAt = nil
    }

    /// Times the transition the robot is in, and decides when it has gone on too
    /// long to still be called a transition.
    ///
    /// **The poll is the clock.** A transition is re-read every 1.5 s and each read
    /// writes `session.runningApp` through `recordRunning`, so observation
    /// re-evaluates this without a `Timer` — one less thing to own, cancel and get
    /// wrong while backgrounded. Only a read that *answered* calls this, because the
    /// session goes on holding the last status when one does not (``refresh``).
    ///
    /// `date` is a parameter so a test can cross a 40-second deadline without
    /// waiting one out (project rule 7).
    func noteTransition(_ status: RobotAppStatus?, at date: Date = Date()) {
        guard let status, let deadline = deadline(for: status.state) else {
            watch = nil
            wedged = nil
            return
        }
        guard let current = watch, current.matches(status) else {
            // A transition we have not seen before: start the clock, and do not
            // inherit a verdict from the last one.
            watch = TransitionWatch(status, at: date)
            wedged = nil
            return
        }
        // Compared as `Duration`, not converted to seconds: the two existing
        // conversions in this repo both hand-roll the attoseconds arithmetic, and a
        // truncating one would read an injected `.milliseconds(50)` deadline as zero
        // and call every transition stuck.
        let elapsed = Duration.seconds(date.timeIntervalSince(current.since))
        wedged = elapsed >= deadline ? status : nil
    }

    /// Only the two states the daemon passes *through* are timed.
    ///
    /// `.unknown` is deliberately not: `RobotAppStatus.State.isBusy` counts it as
    /// busy because offering Start for a taken slot is the worse mistake, but a word
    /// a later daemon invented is no evidence of a transition, and calling it stuck
    /// after 40 s would invent a fault for a state that may be perfectly stable.
    private func deadline(for state: RobotAppStatus.State) -> Duration? {
        switch state {
        case .stopping: configuration.stoppingDeadline
        case .starting: configuration.startingDeadline
        case .running, .done, .error, .unknown: nil
        }
    }

    /// Polls until cancelled. There is no push channel for which app holds the
    /// robot — `/api/state/ws/full` carries nothing about apps — so this is the
    /// only way to notice one started from the widget or from the robot itself.
    func poll(session: RobotSession) async {
        while !Task.isCancelled {
            await refresh(session: session)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: interval(for: session.runningApp))
        }
    }

    /// The app capability appears as soon as a handshake installs its client. Wait
    /// until compatibility and readiness have accepted that client before using it.
    func canPoll(_ session: RobotSession) -> Bool {
        guard session.canManageApps else { return false }
        return switch session.phase {
        case .connected, .unreachable: true
        case .idle, .connecting: false
        }
    }

    /// Internal rather than private so a test can assert the cadence directly,
    /// instead of waiting one out.
    func interval(for status: RobotAppStatus?) -> Duration {
        guard let status else { return configuration.idle }
        // A transition that has already blown its deadline is not being watched
        // finish any more — only the robot's software can end it, and asking 40
        // times a minute meanwhile buys nothing. Backing off rather than stopping,
        // because a restart done from the recovery screen has to be noticed.
        if wedged != nil {
            return configuration.running
        }
        return switch status.state {
        case .starting, .stopping: configuration.transitioning
        case .running, .unknown: configuration.running
        case .done, .error: configuration.idle
        }
    }

    // MARK: - Actions

    func stop(session: RobotSession) async {
        await run(session) {
            try await session.stopCurrentApp()
            isExpanded = false
        }
    }

    func restart(session: RobotSession) async {
        await run(session) { _ = try await session.restartCurrentApp() }
    }

    /// Both commands leave the session holding a fresh reading — `stopCurrentApp`
    /// re-reads, `restartCurrentApp` returns the new status — so the clock is set
    /// from that rather than waiting up to 1.5 s for the next tick to notice the
    /// transition began.
    private func run(_ session: RobotSession, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            lastError = nil
            failedAt = nil
        } catch {
            recordFailure(error)
        }
        noteTransition(session.runningApp)
    }

    /// The one writer of `lastError` and its clock, so both stay private to this
    /// file while `RunningAppModel+Conversation` can still report.
    func recordFailure(_ error: any Error) {
        let previous = lastError
        lastError.recordDaemonFailure(error)
        // Stamped only when the message actually changed: a cancelled call
        // reports nothing and leaves the slot as it was, so it must not restart
        // the clock on a refusal somebody is still reading.
        if lastError != previous {
            failedAt = Date()
        }
    }
}

#if DEBUG
    extension RunningAppModel {
        /// Lives here rather than in `Previews/`: it writes `private(set)` members,
        /// which `@testable` does not reach from another module.
        static func preview(
            isExpanded: Bool = false,
            busy: Bool = false,
            error: String? = nil,
            conversationTurn: ConversationTurn? = nil,
            wedged: RobotAppStatus? = nil
        ) -> RunningAppModel {
            let model = RunningAppModel()
            model.isExpanded = isExpanded
            model.busy = busy
            model.lastError = error
            model.conversationTurn = conversationTurn
            model.wedged = wedged
            return model
        }
    }
#endif
