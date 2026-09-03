import Foundation
import ReachyKit

/// Everything the conversation screen and the running-app dock know about the one app
/// that speaks the robot's JSON-RPC conversation protocol.
///
/// **Owned by `ReachyTabShell`, not by the screen**, for the reason `store` and
/// `install` are: the dock expands from every tab, and a model built inside a
/// destination closure dies with the sheet that presented it. Here that is not tidiness
/// but the feature — the robot keeps no transcript, so a record this model dropped is
/// gone for good. Living at the shell is what makes it survive a Back, a tab switch and
/// a sheet dismissal, and it is destroyed only when the connection is.
///
/// It is also why there is **one** of these rather than one per surface. The mute flag
/// is a remembered answer, and two models would remember two answers about one robot's
/// microphone — a disagreement nothing on screen could resolve.
@MainActor
@Observable
final class ConversationModel {
    /// How much of a conversation is reachable right now.
    ///
    /// Ordered by how much the screen can offer, not by severity: only ``live`` accepts
    /// input, and everything below it is a reason the controls are not there.
    enum Phase: Equatable {
        /// Nothing has arrived and no call has succeeded yet. The backend can take a
        /// minute and a half to come up, so this is patient by design.
        case preparing
        case live
        /// The feed dropped after having worked. The transcript stands; the controls
        /// cannot reach anything.
        case interrupted
        case unavailable(Reason)
        /// The app is running and has no voice backend configured — no key, or one it
        /// could not reach. Told apart from ``unavailable`` because the fix is on the
        /// robot rather than here.
        case backendUnconfigured

        enum Reason: Equatable {
            /// The app answered that nothing is running, or the daemon did.
            case appStopped
            /// The app is there and not answering.
            case appUnavailable
            /// This build of the app has no conversation methods at all.
            case methodMissing
            /// This connection cannot carry the app's control surface.
            case noTransport
        }
    }

    // MARK: Seams

    //
    // Closures with defaults, the shape `WiFiJoinModel` established: cheaper than a
    // protocol, adds no conformance to `RobotSession`, and — unlike a recorded image —
    // able to catch the second call, the `defer` and the branch that must not run.

    typealias Events = @MainActor (RobotSession, RobotApp) throws -> AsyncStream<ConversationEvent>
    typealias ReadStatus = @MainActor (RobotSession, RobotApp) async throws -> ConversationBackendStatus
    typealias ReadMicrophone = @MainActor (RobotSession, RobotApp) async throws -> Bool
    typealias SetMicrophone = @MainActor (RobotSession, RobotApp, Bool) async throws -> Bool
    typealias Interrupt = @MainActor (RobotSession, RobotApp) async throws -> Void
    typealias Say = @MainActor (RobotSession, RobotApp, String) async throws -> Void

    struct Configuration: Sendable {
        /// How long a still-starting backend is given before the screen stops calling it
        /// starting. The app's own web client polls every two seconds against ninety;
        /// injected so a test can cross it without waiting one out.
        var startupBudget: TimeInterval = 90
        var retryInterval: Duration = .seconds(2)
        /// Rows kept. A transcript arrives at the speed of somebody talking, so this is
        /// a ceiling on a long afternoon rather than a rate limit.
        var capacity = 2000
    }

    // MARK: State

    //
    // Module-visible setters rather than `private(set)`, for the reason
    // `RunningAppModel` records: the listening half lives in
    // `ConversationModel+Feed.swift` and the commands in `+Commands.swift`, because one
    // file would be past SwiftLint's length limit — and `private(set)` does not reach
    // across files. Stored properties cannot live in an extension, which is the whole of
    // it. Spelling it `internal(set)` is what the compiler calls redundant.

    var entries: [TranscriptEntry] = []
    /// Nil until the conversation next moves. **Never faked**: the app emits a turn only
    /// on change, and `conversation.status` answers backend configuration rather than a
    /// state, so there is genuinely nothing to seed the first frame from. A screen that
    /// showed "Ready" here would be inventing it.
    var turn: ConversationTurn?
    /// The newest audio sample, or nil between turns. Only the meter reads it, and
    /// `@Observable` invalidates per property — so writing it fifteen times a second
    /// redraws the meter and nothing else.
    var level: ConversationLevel?
    var phase: Phase = .preparing
    var backend: ConversationBackendStatus?
    /// What the **robot** answered, not what was asked for.
    var isMicrophoneMuted = false
    /// Cleared for good once the app answers `-32601`. A build without these methods
    /// cannot grow them mid-session, so the controls go rather than fail forever.
    var offersControls = true
    /// A call is in flight. One at a time: two overlapping mute gestures let the first
    /// one's completion write over the second's.
    var isBusy = false
    var lastError: String?
    /// Text in the composer. Owned here so a test can assert it is cleared only on
    /// success — leaving somebody's sentence in place when the send failed is the
    /// difference between a retry and a retype.
    var draft = ""

    let configuration: Configuration
    let events: Events
    let readStatus: ReadStatus
    let readMicrophone: ReadMicrophone
    let setMicrophone: SetMicrophone
    let interruptConversation: Interrupt
    let say: Say

    /// When this screen started waiting for a backend that is still coming up.
    var preparingSince: Date?

    init(
        configuration: Configuration = Configuration(),
        events: @escaping Events = { try $0.conversationEvents(for: $1) },
        readStatus: @escaping ReadStatus = { try await $0.conversationStatus(for: $1) },
        readMicrophone: @escaping ReadMicrophone = { try await $0.conversationMicrophoneMuted(for: $1) },
        setMicrophone: @escaping SetMicrophone = { try await $0.setConversationMicrophoneMuted($2, for: $1) },
        interruptConversation: @escaping Interrupt = { try await $0.interruptConversation(for: $1) },
        say: @escaping Say = { try await $0.sayInConversation($2, for: $1) }
    ) {
        self.configuration = configuration
        self.events = events
        self.readStatus = readStatus
        self.readMicrophone = readMicrophone
        self.setMicrophone = setMicrophone
        self.interruptConversation = interruptConversation
        self.say = say
    }

    // MARK: Derived

    /// Whether the controls can reach anything. The screen draws them inert rather than
    /// hiding them, so a reader can see what the conversation *would* offer.
    var isLive: Bool {
        phase == .live
    }

    /// Whether anything was recorded. What decides whether a failure replaces the list
    /// or merely ends it: an empty screen has no record to protect.
    var hasTranscript: Bool {
        entries.contains(where: \.isUtterance)
    }

    var canSend: Bool {
        isLive && offersControls && !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Clearing empties something nothing refills, so the count is named: the robot
    /// keeps no copy, and this is the last moment those words exist anywhere.
    ///
    /// The copy lives on the model rather than in the view because a `confirmationDialog`
    /// captures as nothing in a reference image — so the only place it can be checked is
    /// a model test.
    var clearConfirmation: Confirmation {
        Confirmation(
            title: .reachy("Clear the transcript?"),
            message: .reachy("\(entries.filter(\.isUtterance).count) lines go. Nothing on the robot keeps a copy."),
            confirm: .reachy("Clear")
        )
    }

    /// The whole transcript as text, for Copy and Share. Utterances only — the gaps and
    /// endings are this client's own commentary on its record, not part of it.
    var transcriptText: String {
        entries.filter(\.isUtterance).map { entry in
            "\(TranscriptEntry.exportPrefix(for: entry.kind))\(entry.text)"
        }.joined(separator: "\n")
    }
}

#if DEBUG
    extension ConversationModel {
        /// A model already in its end state.
        ///
        /// **A preview must be final on its first frame** — Prefire captures
        /// synchronously and `.snapshot(delay:)` is unavailable here — so every state is
        /// built rather than reached. Passing the model is also what makes the screen's
        /// `.task` inert: it guards on `reachyPreviewMode`, and nothing here opens a
        /// socket.
        ///
        /// In this file rather than under `Previews/` because it writes members a
        /// `@testable import` would not reach and a preview file has no business owning.
        static func preview(
            entries: [TranscriptEntry] = [],
            turn: ConversationTurn? = nil,
            level: ConversationLevel? = nil,
            phase: Phase = .live,
            isMicrophoneMuted: Bool = false,
            offersControls: Bool = true,
            draft: String = "",
            lastError: String? = nil
        ) -> ConversationModel {
            let model = ConversationModel(
                events: { _, _ in AsyncStream { $0.finish() } },
                readStatus: { _, _ in ConversationBackendStatus(canProceed: true) },
                readMicrophone: { _, _ in isMicrophoneMuted },
                setMicrophone: { _, _, muted in muted },
                interruptConversation: { _, _ in },
                say: { _, _, _ in }
            )
            model.entries = entries
            model.turn = turn
            model.level = level
            model.phase = phase
            model.isMicrophoneMuted = isMicrophoneMuted
            model.offersControls = offersControls
            model.draft = draft
            model.lastError = lastError
            return model
        }

        /// A short exchange, in the order the app would have delivered it.
        static let previewExchange: [TranscriptEntry] = [
            TranscriptEntry(kind: .spoken(.user), text: "Reachy, what's the weather like where you are?"),
            TranscriptEntry(
                kind: .spoken(.assistant),
                text: "Indoors and about twenty-one degrees, which is all I can really tell from here."
            ),
            TranscriptEntry(kind: .spoken(.user), text: "Fair enough. Can you look to your left?"),
            TranscriptEntry(kind: .spoken(.assistant), text: "Turning now. There is a bookshelf and a very full mug."),
        ]

        /// The same, with a typed message and the answer it drew — the one frame that
        /// shows a sent message is not read out verbatim.
        static let previewTypedExchange: [TranscriptEntry] = previewExchange + [
            TranscriptEntry(kind: .typed, text: "happy birthday"),
            TranscriptEntry(
                kind: .spoken(.assistant),
                text: "Many happy returns! I would sing, but I have been asked not to."
            ),
        ]
    }

    extension ConversationVoiceModel {
        static func preview(
            personalities: ConversationPersonalities? = ConversationPersonalities(
                choices: ["default", "noir_detective", "victorian_butler", "mars_rover"],
                current: "noir_detective",
                startup: "default"
            ),
            voices: [String] = ["alloy", "verse", "coral"],
            currentVoice: String? = "verse",
            hasLoaded: Bool = true,
            failure: String? = nil
        ) -> ConversationVoiceModel {
            let model = ConversationVoiceModel(
                readPersonalities: { _, _ in personalities ?? ConversationPersonalities(choices: []) },
                applyPersonality: { _, _, _, _ in },
                readVoices: { _, _ in voices },
                readCurrentVoice: { _, _ in currentVoice },
                applyVoiceCommand: { _, _, _ in }
            )
            model.personalities = personalities
            model.voices = voices
            model.currentVoice = currentVoice
            model.hasLoaded = hasLoaded
            model.failure = failure
            return model
        }
    }
#endif
