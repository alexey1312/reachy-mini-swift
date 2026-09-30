import Foundation
import ReachyKit
import ReachyMedia

/// Talking to Reachy from this device: a take records here, is transcribed here, and
/// goes to the robot as text through `conversation.say`.
///
/// The robot's conversation app hears the robot's own microphone and nothing else, so
/// this is the only way a better microphone reaches it. The order of the robot calls is
/// what the file is for:
///
/// 1. permission — a take that had to ask records nothing, and a refusal touches
///    neither the robot nor the audio session;
/// 2. the recording;
/// 3. an interrupt, if the robot is talking, so its voice does not end up in the take;
/// 4. the robot's microphone muted, so it does not hear the room as well —
///    owed back only if the robot answered that it muted;
/// 5. on release, the recording stops, then the robot's own calls are allowed to
///    settle, then `say`, then the unmute.
///
/// **One synchronous entry point**, `talk(_:app:session:)`. A press and its release
/// arriving as two `Task { await … }` from the view have no order between them — the
/// hazard the robot microphone's own hold has. Here the press's state change is applied
/// before the call returns, and a release that arrives while the take is still
/// preparing is stored rather than dropped.
extension ConversationModel {
    /// Whether a take may start now.
    func canTalk(_ session: RobotSession) -> Bool {
        isLive && offersControls && dictation.isIdle && take == nil && !isBusy && isReachable(session)
    }

    /// One gesture on the talk button.
    ///
    /// - Returns: the work it started, so a test can await it rather than sleep. Nil
    ///   when the gesture changed nothing, or only changed state.
    @discardableResult
    func talk(_ gesture: TalkGesture, app: RobotApp, session: RobotSession) -> Task<Void, Never>? {
        switch gesture {
        case .pressed:
            return press(isLatched: false, app: app, session: session)
        case let .released(held):
            return release(heldFor: held, app: app, session: session)
        case .toggled:
            switch dictation {
            case .idle:
                return press(isLatched: true, app: app, session: session)
            case .preparing:
                take?.isLatched = false
                take?.pendingRelease = configuration.latchThreshold
                return nil
            case .recording:
                return end(app: app, session: session)
            case .sending:
                return nil
            }
        case .discarded:
            return cancelTake()
        }
    }

    /// Ends a take and sends nothing. Called from the screen going away, from a verdict
    /// on the app, and from a preemption.
    ///
    /// - Returns: the unmute it owed, if any.
    @discardableResult
    func cancelTake() -> Task<Void, Never>? {
        guard let take else { return nil }
        deviceDictation.cancel()
        take.limit?.cancel()
        self.take = nil
        dictation = .idle
        dictationLevel = nil
        // A mute still in flight is undone by the preparation itself, when it sees the
        // take is gone; only one that has already landed is owed back here.
        guard take.owesUnmute else { return nil }
        return Task { await self.unmute(app: take.app, session: take.session) }
    }

    // MARK: Press

    private func press(isLatched: Bool, app: RobotApp, session: RobotSession) -> Task<Void, Never>? {
        guard canTalk(session) else { return nil }
        let take = DictationTake(app: app, session: session, isLatched: isLatched)
        self.take = take
        dictation = .preparing
        dictationNotice = nil
        dictationRefusal = nil
        dictationLevel = nil
        let work = Task { await self.prepare(take.id, app: app, session: session) }
        self.take?.preparation = work
        return work
    }

    private func prepare(_ id: UUID, app: RobotApp, session: RobotSession) async {
        switch await deviceDictation.authorize() {
        case .ready:
            break
        case .askedJustNow:
            abandon(id, notice: .allowedNow)
            return
        case let .microphoneBlocked(state):
            abandon(id, refusal: .microphone(state))
            return
        case let .speechBlocked(state):
            abandon(id, refusal: .speech(state))
            return
        }
        guard take?.id == id else { return }

        do {
            try await deviceDictation.start { [weak self] event in self?.dictationEvent(event, for: id) }
        } catch {
            let refusal = (error as? DeviceDictation.Refusal).map(DictationRefusal.init)
            abandon(id, refusal: refusal ?? .microphoneUnavailable)
            return
        }
        guard let isLatched = take?.isLatched, take?.id == id else {
            deviceDictation.cancel()
            return
        }
        dictation = .recording(heard: "", isLatched: isLatched)
        armLimit(id, app: app, session: session)
        applyPendingRelease(app: app, session: session)

        await quietTheRobot(id, app: app, session: session)
    }

    /// The robot's half of a press: stop it talking over the take, and stop it hearing
    /// the room while the take runs.
    private func quietTheRobot(_ id: UUID, app: RobotApp, session: RobotSession) async {
        if turn == .speaking || turn == .thinking {
            do {
                try await interruptConversation(session, app)
            } catch {
                judge(error)
            }
        }
        guard take?.id == id, !isMicrophoneMuted else { return }
        do {
            let muted = try await setMicrophone(session, app, true)
            isMicrophoneMuted = muted
            guard take?.id == id else {
                // The take went while the mute was in flight, so nothing else knows
                // this press muted the robot. It gives it back itself.
                if muted {
                    await unmute(app: app, session: session)
                }
                return
            }
            take?.owesUnmute = muted
        } catch {
            judge(error)
        }
    }

    // MARK: Release

    private func release(heldFor held: Duration, app: RobotApp, session: RobotSession) -> Task<Void, Never>? {
        switch dictation {
        case .preparing:
            take?.pendingRelease = held
            return nil
        case let .recording(heard, isLatched):
            guard isLatched || held >= configuration.latchThreshold else {
                // A tap: the take goes on, and the next tap sends it.
                take?.isLatched = true
                dictation = .recording(heard: heard, isLatched: true)
                return nil
            }
            return end(app: app, session: session)
        case .idle, .sending:
            return nil
        }
    }

    private func applyPendingRelease(app: RobotApp, session: RobotSession) {
        guard let held = take?.pendingRelease else { return }
        take?.pendingRelease = nil
        _ = release(heldFor: held, app: app, session: session)
    }

    // MARK: End

    private func end(app: RobotApp, session: RobotSession) -> Task<Void, Never>? {
        guard let take, case let .recording(heard, _) = dictation else { return nil }
        dictation = .sending(heard: heard)
        take.limit?.cancel()
        let id = take.id
        let preparation = take.preparation
        return Task {
            let outcome = await deviceDictation.finish(configuration.transcriptionTimeout)
            // The press's own robot calls land first, so an unmute cannot overtake the
            // mute it answers.
            await preparation?.value
            guard self.take?.id == id else { return }
            await deliver(outcome, app: app, session: session)
            guard self.take?.id == id else { return }
            let owesUnmute = self.take?.owesUnmute ?? false
            self.take = nil
            dictation = .idle
            dictationLevel = nil
            if owesUnmute {
                await unmute(app: app, session: session)
            }
        }
    }

    /// Sends what was heard, and records it only once the app accepted it.
    private func deliver(_ outcome: DeviceDictation.Outcome, app: RobotApp, session: RobotSession) async {
        switch outcome {
        case let .heard(text):
            do {
                try await say(session, app, text)
                appendDictated(text)
            } catch {
                // A retry rather than a retalk: the words go where a retry is one tap.
                draft = text
                judge(error)
            }
        case .nothing:
            dictationNotice = .nothingHeard
        case .failed:
            dictationRefusal = .transcriptionFailed
        }
    }

    /// A take that never recorded — it had to ask, or it was refused.
    private func abandon(_ id: UUID, notice: DictationNotice? = nil, refusal: DictationRefusal? = nil) {
        guard take?.id == id else { return }
        take = nil
        dictation = .idle
        dictationLevel = nil
        dictationNotice = notice
        dictationRefusal = refusal
    }

    private func armLimit(_ id: UUID, app: RobotApp, session: RobotSession) {
        let limit = configuration.takeLimit
        take?.limit = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, take?.id == id else { return }
            _ = end(app: app, session: session)
        }
    }

    // MARK: -

    private func dictationEvent(_ event: DeviceDictation.Event, for id: UUID) {
        guard take?.id == id else { return }
        switch event {
        case let .heard(text):
            guard case let .recording(_, isLatched) = dictation else { return }
            dictation = .recording(heard: text, isLatched: isLatched)
        case let .level(value):
            dictationLevel = ConversationLevel(role: .user, rms: value)
        case .preempted:
            cancelTake()
            dictationNotice = .preempted
        }
    }

    private func unmute(app: RobotApp, session: RobotSession) async {
        do {
            isMicrophoneMuted = try await setMicrophone(session, app, false)
        } catch {
            judge(error)
        }
    }

    /// The same rules every other command is judged by.
    private func judge(_ error: any Error) {
        if let failure = error as? ConversationFailure {
            conclude(failure)
        } else {
            record(failure: error)
        }
    }
}
