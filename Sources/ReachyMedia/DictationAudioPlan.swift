import Foundation

/// What a recording on this device does to the audio session, as a pure reducer.
///
/// `MediaAudioSession` is the one owner of `AVAudioSession` and of WebRTC's audio unit,
/// and a take is a fourth party wanting the microphone — so every rule about who gives
/// way to whom is decided here and only carried out there, the `CallLifecycle` shape.
/// That is also what makes it testable: the session itself only exists on a device.
///
/// The rules, one line each:
///
/// - **A call refuses a take.** During a call this device's microphone already goes to
///   the robot's speaker, and the system owns activation.
/// - **Over a camera session, WebRTC's audio unit goes down for the take and comes back
///   after it.** Two audio units recording one microphone is what nothing here can
///   promise works, and the robot's voice playing out of this device's speaker would be
///   transcribed with everything else.
/// - **With nothing running, the take activates the session itself and owes the
///   release** — the same release, with the same retry, a camera session gets.
/// - **A camera starting or stopping mid-take moves the ownership, never the audio
///   unit.** The engine holds the microphone until the take ends; the plan settles who
///   restores what at that moment.
/// - **A call or an interruption mid-take ends the take first**, before anything else
///   touches the session.
struct DictationAudioPlan: Equatable, Sendable {
    private(set) var isActive = false
    /// The take activated the session on its own authority and must hand it back.
    private(set) var owesRelease = false

    enum Effect: Equatable, Sendable {
        case refuseCallInProgress
        /// An app-owned transition still in flight — a release retry after a camera
        /// stopped — would deactivate the session the take is about to use.
        case cancelTransition
        case configureAndActivate
        case disableWebRTCAudio
        case enableWebRTCAudio
        case release
        /// Tell the take it is over. Always the first effect, so the engine has let go
        /// of the microphone before anything else moves.
        case preempt
    }

    /// The owner, in this reducer's own terms: `MediaAudioSession.Owner` is the source
    /// of truth and is mapped onto this at each call.
    enum Owner: Equatable, Sendable {
        case nobody
        case app
        case call
    }

    mutating func willStart(owner: Owner) -> [Effect] {
        guard !isActive else { return [] }
        switch owner {
        case .call:
            return [.refuseCallInProgress]
        case .app:
            isActive = true
            owesRelease = false
            return [.cancelTransition, .disableWebRTCAudio]
        case .nobody:
            isActive = true
            owesRelease = true
            return [.cancelTransition, .configureAndActivate]
        }
    }

    /// The take ended on its own terms. Safe to call twice: a preempted take's own
    /// teardown arrives here after the plan has already let it go.
    mutating func didEnd(owner: Owner) -> [Effect] {
        guard isActive else { return [] }
        isActive = false
        defer { owesRelease = false }
        switch owner {
        case .app:
            // A real transition from `false`, which is what brings WebRTC's unit back.
            return [.enableWebRTCAudio]
        case .nobody:
            return owesRelease ? [.release] : []
        case .call:
            // The call owns activation now; touching the session would be touching
            // the system's.
            return []
        }
    }

    /// A camera session started while a take holds the microphone. The session is
    /// configured the same way either way, so only two things change: the camera now
    /// owns it (no release is owed), and WebRTC's audio unit waits for the take.
    ///
    /// - Returns: whether the camera may turn WebRTC's audio on now.
    mutating func cameraStarted() -> Bool {
        guard isActive else { return true }
        owesRelease = false
        return false
    }

    /// A camera session stopped while a take holds the microphone.
    ///
    /// - Returns: whether the camera may release the session now. While a take runs it
    ///   may not — the engine is still recording — so the take owes it instead.
    mutating func cameraStopped() -> Bool {
        guard isActive else { return true }
        owesRelease = true
        return false
    }

    /// A call is about to take the session. The take ends first, and the call's own
    /// handover then runs exactly as it would have.
    mutating func callWillStart() -> [Effect] {
        guard isActive else { return [] }
        return [.preempt] + didEnd(owner: .call)
    }

    /// The system interrupted the session — a phone call, Siri, an alarm.
    mutating func interrupted(owner: Owner) -> [Effect] {
        guard isActive else { return [] }
        return [.preempt] + didEnd(owner: owner)
    }
}
