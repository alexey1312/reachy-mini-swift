import Foundation

/// Every decision the call framing makes, as a pure reducer — the one part of
/// the LiveCommunicationKit integration a test can hold, because the framework
/// itself cannot be stood up off a device (`RobotCallController` is the thin
/// adapter over it, untested by design the way `WebRTCDataChannel` is).
///
/// The model the user chose (issue #78): a call *starts* when the microphone is
/// unmuted — "call the robot" is literally what opening the camera tab and
/// unmuting is. Muting during a call does not end it (an ordinary in-call
/// mute); the call ends from an End button — the system UI's or the app's own,
/// which are one funnel — from the session becoming ineligible (robot asleep,
/// stream failed, viewport target gone), or from a manager reset. Passive
/// viewing is never a call.
///
/// The invariant every path holds: **the microphone is live only while a call
/// is active.** Each ending effect list carries `.applyMic(false)`. The one
/// deliberate exception is a start the *system* refused (`startFailed`): the
/// framing is garnish and the microphone is the meal, so the mic opens bare —
/// see that case for the reasoning.
struct CallLifecycle: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        /// A start was requested; the permission ask and the system's
        /// `StartConversationAction` round trip are in flight.
        case starting
        case active
    }

    private(set) var state: State = .idle

    /// Why a call ended without the user asking, in the vocabulary the system
    /// call UI understands.
    enum EndCause: Equatable, Sendable {
        /// The stream failed under the call.
        case failed
        /// The far side went away on its own terms — the robot slept, was
        /// disconnected, or the viewport target dissolved.
        case remoteEnded
    }

    enum Event: Equatable, Sendable {
        /// The mic button (or a redial) asked for the microphone.
        case unmuteTapped
        /// The mic button asked for silence.
        case muteTapped
        /// The permission ask came back refused.
        case micPermissionDenied
        /// `ConversationManager.perform` threw before the system took the start.
        case startFailed
        /// The system delivered the `StartConversationAction` for us to do.
        case performedStart
        /// The system delivered a `MuteConversationAction` (its own UI and the
        /// in-app button arrive identically — one funnel).
        case performedMute(isMuted: Bool)
        /// The red button beside the microphone, inside the app.
        case endTapped
        /// The system delivered an `EndConversationAction`.
        case performedEnd
        /// The session under the call went away: robot asleep, stream failed,
        /// or no viewport target left.
        case sessionBecameIneligible(EndCause)
        /// `conversationManagerDidReset` — everything is already torn down.
        case managerReset
    }

    /// What the adapter must now do, in order. Reporting is separate from
    /// fulfillment on purpose: fulfilling an `EndConversationAction` *is* the
    /// end signal, so `performedEnd` carries no `.reportEnded` — only endings
    /// the system did not initiate are reported.
    enum Effect: Equatable, Sendable {
        /// Hand audio-session ownership to the call (`MediaAudioSession`),
        /// before the start is fulfilled — the CallKit contract's ordering.
        case takeAudioOwnership
        /// Ask for the microphone permission; granted continues into the
        /// system start, refused comes back as `.micPermissionDenied`.
        case requestMicPermissionThenStart
        /// Route an in-call mute change through the system so its UI stays in
        /// step (`MuteConversationAction`); the change lands via
        /// `performedMute`.
        case performMuteAction(isMuted: Bool)
        /// Route the in-app End through the system (`EndConversationAction`),
        /// so the button beside the microphone and the one on the Lock Screen
        /// are one funnel; the ending itself lands back via `performedEnd`.
        case performEndAction
        /// Actually flip the microphone track.
        case applyMic(Bool)
        /// Fulfill the system action currently being performed.
        case fulfillPendingAction
        /// Refuse the system action currently being performed.
        case failPendingAction
        /// Tell the system the outgoing conversation is on its way. Reported
        /// back-to-back with `.reportConnected`, legitimately: a call can only
        /// start from a stream already up (`CameraMicButton` is disabled until
        /// `.streaming`), so there is no connecting interval to wait out.
        case reportStartedConnecting
        case reportConnected
        case reportEnded(EndCause)
        /// Donate the start-call intent so Recents redial and Siri suggestions
        /// have something to hand back.
        case donate
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .unmuteTapped: unmuteTapped()
        case .muteTapped: muteTapped()
        case .micPermissionDenied: startAbandoned()
        case .startFailed: startFailed()
        case .performedStart: performedStart()
        case let .performedMute(isMuted): performedMute(isMuted: isMuted)
        case .endTapped: endTapped()
        case .performedEnd: performedEnd()
        case let .sessionBecameIneligible(cause): becameIneligible(cause)
        case .managerReset: managerReset()
        }
    }

    /// The permission was refused: the start never happened, nothing was
    /// reported, and the mic must stay shut — there is nothing to undo.
    private mutating func startAbandoned() -> [Effect] {
        guard state == .starting else { return [] }
        state = .idle
        return []
    }

    /// The *system* refused or lost the start — `perform` threw, the action
    /// timed out, or no robot identity was known. Permission is already
    /// granted by the time a start can fail this way, so the microphone opens
    /// bare: the user asked to talk to the robot, and a button that silently
    /// does nothing because the call *framing* was refused is the bug this
    /// case exists to end (shipped once — the whole chain swallowed failures
    /// and the tap read as dead). The controller logs the reason; a later
    /// unmute simply tries the framing again.
    private mutating func startFailed() -> [Effect] {
        guard state == .starting else { return [] }
        state = .idle
        return [.applyMic(true)]
    }

    private mutating func performedStart() -> [Effect] {
        guard state == .starting else { return [.failPendingAction] }
        state = .active
        return [
            .takeAudioOwnership, .fulfillPendingAction, .applyMic(true),
            .reportStartedConnecting, .reportConnected, .donate,
        ]
    }

    private mutating func performedMute(isMuted: Bool) -> [Effect] {
        guard state == .active else { return [.failPendingAction] }
        return [.applyMic(!isMuted), .fulfillPendingAction]
    }

    /// The app's own End. It asks the *system* rather than ending here, for the
    /// reason `muteTapped` does: the Lock Screen's button and this one must be
    /// one funnel, or the two UIs disagree about whether a call is up. The
    /// ending arrives back as `performedEnd`.
    ///
    /// `.starting` is refused rather than queued — there is no conversation for
    /// the system to end yet, and the button is not on screen in that phase
    /// (it is gated on `activeCall`, which fills at `.active`).
    private mutating func endTapped() -> [Effect] {
        guard state == .active else { return [] }
        return [.performEndAction]
    }

    /// `.starting` accepted too: the system can end a call it is still
    /// validating.
    private mutating func performedEnd() -> [Effect] {
        guard state != .idle else { return [.failPendingAction] }
        state = .idle
        return [.applyMic(false), .fulfillPendingAction]
    }

    private mutating func becameIneligible(_ cause: EndCause) -> [Effect] {
        guard state != .idle else { return [] }
        state = .idle
        return [.applyMic(false), .reportEnded(cause)]
    }

    /// The reset already tore everything down system-side; only the microphone
    /// is left to close.
    private mutating func managerReset() -> [Effect] {
        guard state != .idle else { return [] }
        state = .idle
        return [.applyMic(false)]
    }

    private mutating func unmuteTapped() -> [Effect] {
        switch state {
        case .idle:
            state = .starting
            return [.requestMicPermissionThenStart]
        case .starting:
            // Double tap while the round trip runs: one start is enough.
            return []
        case .active:
            return [.performMuteAction(isMuted: false)]
        }
    }

    private mutating func muteTapped() -> [Effect] {
        switch state {
        case .idle:
            // Defensive: a live mic with no call should not exist on iOS, but a
            // mute request must always be able to mute.
            [.applyMic(false)]
        case .starting:
            // The start is already with the system; landing active-and-unmuted
            // and letting the next tap mute is simpler than a cancel path for a
            // window measured in milliseconds.
            []
        case .active:
            [.performMuteAction(isMuted: true)]
        }
    }
}
