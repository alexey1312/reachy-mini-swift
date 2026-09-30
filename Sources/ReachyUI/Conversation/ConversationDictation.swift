import Foundation
import ReachyKit
import ReachyMedia

/// The seam over `DeviceDictation`: one recording on this device, turned into text and
/// handed to the robot with `conversation.say`.
///
/// Closures with defaults, the shape the rest of ``ConversationModel`` uses, so a test
/// can drive a whole take — permission, recording, words, silence, preemption — without
/// a microphone. `live()` holds one `DeviceDictation` per take and builds it on `start`,
/// never before: `ReachyTabShell` builds a `ConversationModel()` inside previews, and a
/// model that touched the audio session or Speech on construction would do it there.
struct ConversationDictation {
    typealias Authorize = @MainActor () async -> DeviceDictation.Authorization
    typealias Start = @MainActor (@escaping @MainActor (DeviceDictation.Event) -> Void) async throws -> Void
    typealias Finish = @MainActor (Duration) async -> DeviceDictation.Outcome
    typealias Cancel = @MainActor () -> Void

    let authorize: Authorize
    let start: Start
    let finish: Finish
    let cancel: Cancel

    @MainActor
    static func live() -> ConversationDictation {
        let slot = Slot()
        return ConversationDictation(
            authorize: { await DeviceDictation.authorize() },
            start: { events in
                let take = DeviceDictation()
                slot.current = take
                try await take.start(events: events)
            },
            finish: { timeout in
                guard let take = slot.current else { return .nothing }
                slot.current = nil
                return await take.finish(timeout: timeout)
            },
            cancel: {
                slot.current?.cancel()
                slot.current = nil
            }
        )
    }

    /// Answers as if every permission were granted and nothing were ever heard. For a
    /// preview, where no take is ever started.
    static var inert: ConversationDictation {
        ConversationDictation(
            authorize: { .ready },
            start: { _ in },
            finish: { _ in .nothing },
            cancel: {}
        )
    }

    @MainActor
    private final class Slot {
        var current: DeviceDictation?
    }
}

/// Where a take is. Only ``idle`` lets the other controls through.
enum DictationPhase: Equatable {
    case idle
    /// Asking for permission, or opening the microphone.
    case preparing
    /// `isLatched` is the tap-to-start form: the finger has lifted and a second tap sends.
    case recording(heard: String, isLatched: Bool)
    case sending(heard: String)

    var isIdle: Bool {
        self == .idle
    }

    /// The words so far, whichever phase is carrying them.
    var heard: String {
        switch self {
        case .idle, .preparing: ""
        case let .recording(heard, _), let .sending(heard): heard
        }
    }
}

/// A sentence about the last take that is not a failure — nothing was wrong, but
/// nothing was sent either, and a take that ends in silence has to say so.
enum DictationNotice: Equatable {
    case nothingHeard
    case preempted
    /// The press that raised the system prompts records nothing.
    case allowedNow

    var message: String {
        switch self {
        case .nothingHeard:
            String(localized: .reachy("Didn't catch that. Nothing was sent."))
        case .preempted:
            String(localized: .reachy("The microphone was needed elsewhere. Nothing was sent."))
        case .allowedNow:
            String(localized: .reachy("You can talk from this device now."))
        }
    }
}

/// Why a take could not run, in a slot of its own: `lastError` is cleared only by a
/// later successful command, and a refusal has to go on the next press.
///
/// Resolved `String`s, because the failure line also shows `lastError`, which is one.
enum DictationRefusal: Equatable {
    case microphone(PermissionState)
    case speech(PermissionState)
    case callInProgress
    case recognizerUnavailable
    case microphoneUnavailable
    case transcriptionFailed

    init(_ refusal: DeviceDictation.Refusal) {
        switch refusal {
        case .callInProgress: self = .callInProgress
        case .recognizerUnavailable: self = .recognizerUnavailable
        case .microphoneUnavailable: self = .microphoneUnavailable
        }
    }

    var message: String {
        switch self {
        case .microphone(.restricted):
            String(localized: .reachy("Microphone access is blocked by device policy"))
        case .microphone:
            String(localized: .reachy("Microphone access is turned off"))
        case .speech(.restricted):
            String(localized: .reachy("Speech recognition is blocked by device policy"))
        case .speech:
            String(localized: .reachy("Speech recognition is turned off"))
        case .callInProgress:
            // swiftlint:disable:next line_length
            String(
                localized: .reachy(
                    "End the call first. During a call, this device's microphone already goes to Reachy's speaker."
                )
            )
        case .recognizerUnavailable:
            String(localized: .reachy("Speech recognition isn't available for this language on this device."))
        case .microphoneUnavailable:
            String(localized: .reachy("This device's microphone couldn't start."))
        case .transcriptionFailed:
            String(localized: .reachy("Couldn't turn what you said into text. Nothing was sent."))
        }
    }

    /// Where a reader can do something about it. Restricted goes there too, as it does on
    /// the Privacy screen: the caption says the toggle is not theirs to move, and
    /// Settings is still where they would go to see so.
    var pane: PrivacySettingsLink.Pane? {
        switch self {
        case .microphone: .microphone
        case .speech: .speechRecognition
        case .callInProgress, .recognizerUnavailable, .microphoneUnavailable, .transcriptionFailed: nil
        }
    }
}

/// One gesture on the talk button, in the model's terms.
enum TalkGesture: Equatable {
    case pressed
    case released(heldFor: Duration)
    /// The button's own action: VoiceOver, Switch Control, Full Keyboard Access. Starts a
    /// latched take when idle and sends one that is recording.
    case toggled
    case discarded
}

/// The take in flight. A value, so a stale task can tell by `id` that it is no longer
/// the one on screen.
struct DictationTake {
    let id = UUID()
    /// Where the take was pressed, so a cancel from anywhere can give the robot's
    /// microphone back to the right conversation.
    let app: RobotApp
    let session: RobotSession
    var isLatched: Bool
    /// A release that arrived while the take was still preparing. Stored, never dropped.
    var pendingRelease: Duration?
    /// The robot's microphone was muted for this take, and the robot said so.
    var owesUnmute = false
    /// Permission, the recording, then the robot's interrupt and mute.
    var preparation: Task<Void, Never>?
    var limit: Task<Void, Never>?
}
