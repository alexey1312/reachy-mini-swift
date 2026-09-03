import Foundation
import ReachyKit

/// What the screen can ask the conversation to do, and what it may conclude from a
/// refusal.
extension ConversationModel {
    // MARK: Priming

    /// Reads everything that *can* be read when the screen opens.
    ///
    /// **Everything except the turn has a read.** `conversation.mic` answers the true
    /// mute state, `conversation.status` answers whether there is a backend at all. The
    /// turn alone is push-only and emitted on change, so it stays unknown until the
    /// conversation next moves — and the screen says so in words rather than showing a
    /// "Ready" nobody reported.
    ///
    /// A first failure is not fatal: the backend takes up to a minute and a half to come
    /// up and answers `loop_unavailable` throughout, which is a state to narrate rather
    /// than a refusal. The retry is here rather than in the transport for that reason —
    /// a transport that swallowed it would hide the one thing this screen has to say.
    func prime(app: RobotApp?, session: RobotSession) async {
        guard let app else { return }
        preparingSince = preparingSince ?? Date()
        while !Task.isCancelled {
            do {
                let status = try await readStatus(session, app)
                backend = status
                isMicrophoneMuted = try await readMicrophone(session, app)
                settle(with: status)
                return
            } catch {
                guard !Task.isCancelled, keepWaiting(after: error) else { return }
                try? await Task.sleep(for: configuration.retryInterval)
            }
        }
    }

    /// What a successful status read means.
    ///
    /// A frame already seen outranks it: the conversation demonstrably works, and a
    /// backend flag is about configuration rather than about whether this screen is
    /// receiving anything.
    private func settle(with status: ConversationBackendStatus) {
        preparingSince = nil
        guard phase != .live else { return }
        phase = status.canProceed ? .live : .backendUnconfigured
    }

    /// Whether a failed priming read is worth trying again.
    ///
    /// Only `loop_unavailable`, and only inside the budget. Everything else is an answer:
    /// `-32601` means this build has no such method, `not_running` means the app is gone,
    /// and both are verdicts the screen should show rather than retry into.
    private func keepWaiting(after error: any Error) -> Bool {
        guard let failure = error as? ConversationFailure else {
            record(failure: error)
            return false
        }
        guard failure.reason == .loopUnavailable else {
            conclude(failure)
            return false
        }
        let waited = preparingSince.map { Date().timeIntervalSince($0) } ?? 0
        guard waited < configuration.startupBudget else {
            phase = .unavailable(.appUnavailable)
            return false
        }
        phase = .preparing
        return true
    }

    // MARK: Commands

    /// Mutes or unmutes the **robot's** microphone.
    ///
    /// The rendered flag is always the one the app answered with, never the one that was
    /// asked for. That is the whole reason this button can be trusted: another client
    /// could have muted it a moment ago, and a control claiming a state the robot is not
    /// in is worse than one that did nothing.
    func setMicrophoneMuted(_ muted: Bool, app: RobotApp, session: RobotSession) async {
        await run(session) {
            self.isMicrophoneMuted = try await self.setMicrophone(session, app, muted)
        }
    }

    /// The release half of push-to-talk.
    ///
    /// **Sent unconditionally, even when the press failed.** The two failures are not
    /// symmetric: a mute that did not take leaves a robot listening when somebody thinks
    /// it is not, and that is the one outcome a microphone control cannot produce. If
    /// this fails too the button keeps showing *live* and says so, rather than snapping
    /// back to a comforting lie.
    func endHold(app: RobotApp, session: RobotSession) async {
        await setMicrophoneMuted(true, app: app, session: session)
    }

    func interrupt(app: RobotApp, session: RobotSession) async {
        await run(session) { try await self.interruptConversation(session, app) }
    }

    /// Sends the composer's text.
    ///
    /// The draft survives a failure on purpose — clearing it would turn a retry into a
    /// retype. The typed row is appended only once the app accepted it, so the transcript
    /// never claims something was sent that was not.
    func send(app: RobotApp, session: RobotSession) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await run(session) {
            try await self.say(session, app, text)
            self.appendTyped(text)
            self.draft = ""
        }
    }

    // MARK: -

    /// Runs one command, and decides what its failure means.
    ///
    /// `-32601` is not reported: an app build without the method cannot grow one
    /// mid-session, so there is nothing a reader could act on and the controls go
    /// instead. `not_running` is a verdict — the app is gone — and it is the one thing
    /// here allowed to reach that conclusion, because it *arrived*. Everything else lands
    /// in `lastError`, which the screen renders in a slot of its own.
    private func run(_ session: RobotSession, _ work: () async throws -> Void) async {
        // The dock and this screen both stay up over an unreachable robot on purpose,
        // so their controls have to refuse rather than reach for a socket that cannot
        // open — and refusing is not a failure to report: nothing was attempted.
        guard isReachable(session), !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
        } catch let failure as ConversationFailure {
            conclude(failure)
        } catch {
            record(failure: error)
        }
    }

    /// The only place a failure becomes a phase.
    ///
    /// **A verdict may only be reached from a reading that arrived** — the rule
    /// `RunningAppModel.noteTransition` holds one layer down, in a second place. A
    /// timeout and an unreachable socket conclude nothing: the robot may be behind a Wi-Fi
    /// blip and the transport reconnects on its own, so the phase is left where it was and
    /// the failure is merely reported.
    private func conclude(_ failure: ConversationFailure) {
        switch failure {
        case .methodNotFound:
            offersControls = false
        case let .rejected(_, reason, _):
            switch reason {
            case .notRunning:
                phase = .unavailable(.appStopped)
            case .appUnavailable:
                phase = .unavailable(.appUnavailable)
            case .loopUnavailable:
                phase = .preparing
                record(failure: failure)
            default:
                record(failure: failure)
            }
        case .timedOut, .unreachable:
            record(failure: failure)
        }
    }

    private func record(failure: any Error) {
        lastError.recordDaemonFailure(failure)
    }

    /// The robot stopped answering. The app is probably still running — but nothing here
    /// can reach it, so the controls are shown inert rather than lying.
    private func isReachable(_ session: RobotSession) -> Bool {
        if case .unreachable = session.phase {
            return false
        }
        return true
    }

    /// The app is gone, said by something other than a call — the running-app poll
    /// noticing it stopped, or its removal.
    ///
    /// Appends the ending to the transcript so the record says where it stops. The
    /// transcript itself is kept: it cannot be fetched again from anywhere, and a screen
    /// that discarded it to show a sentence already on it would be the worse of the two
    /// wrongs.
    func noteAppEnded() {
        guard phase != .unavailable(.appStopped) else { return }
        phase = .unavailable(.appStopped)
        turn = nil
        level = nil
        offersControls = true
        guard hasTranscript, !isEndedAlready else { return }
        add(TranscriptEntry(kind: .ended(.appStopped), text: String(localized: .reachy("The app stopped here."))))
    }

    private var isEndedAlready: Bool {
        if case .ended = entries.last?.kind {
            return true
        }
        return false
    }
}
