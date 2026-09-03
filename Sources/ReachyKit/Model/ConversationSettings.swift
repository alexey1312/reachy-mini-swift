import Foundation

/// The personalities the conversation app has, and which one is in use.
///
/// `choices` are the app's own profile directory names — `default`, `noir_detective`,
/// and anything under `user_personalities/`. They are identifiers rather than titles;
/// prettifying one is the screen's business, not this type's.
public struct ConversationPersonalities: Sendable, Equatable, Decodable {
    public let choices: [String]
    /// The personality in use now. Absent while the app has not settled on one.
    public let current: String?
    /// The one the app loads at startup, which ``current`` may differ from until
    /// somebody asks for it to be persisted.
    public let startup: String?
    /// The app has been configured to refuse a switch. A picker showing this must
    /// disable rather than let `profile_locked` come back from a tap — and it has to
    /// name ``lockedTo``, because a disabled control with no reason attached tells
    /// the reader nothing to act on.
    public let isLocked: Bool
    public let lockedTo: String?

    public init(
        choices: [String],
        current: String? = nil,
        startup: String? = nil,
        isLocked: Bool = false,
        lockedTo: String? = nil
    ) {
        self.choices = choices
        self.current = current
        self.startup = startup
        self.isLocked = isLocked
        self.lockedTo = lockedTo
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            choices: container.decodeIfPresent([String].self, forKey: .choices) ?? [],
            current: container.decodeIfPresent(String.self, forKey: .current),
            startup: container.decodeIfPresent(String.self, forKey: .startup),
            isLocked: container.decodeIfPresent(Bool.self, forKey: .locked) ?? false,
            lockedTo: container.decodeIfPresent(String.self, forKey: .lockedTo)
        )
    }

    /// Spelled out because `JSONCodec.daemon` sets no key decoding strategy — there
    /// is no `convertFromSnakeCase` anywhere in this app, deliberately. A missing
    /// mapping here would decode to nil in silence and read as "the app did not send
    /// it", which is why a test pins this one.
    private enum CodingKeys: String, CodingKey {
        case choices
        case current
        case startup
        case locked
        case lockedTo = "locked_to"
    }
}

/// What the app said after being asked to change something.
///
/// One type for `personalities.apply` and `voices.apply` alike: both answer `ok` and
/// a `status` sentence the app composes for itself, and only the first carries a
/// startup choice. That sentence is the robot's own words — a slot that also holds
/// runtime text, so it stays a `String` rather than becoming a localised key.
public struct ConversationApplyResult: Sendable, Equatable, Decodable {
    public let isApplied: Bool
    /// The app's own account of what happened — "Personality unchanged.", and so on.
    public let status: String?
    /// What will load at startup now. Nil from `voices.apply`, which has no opinion.
    public let startup: String?

    public init(isApplied: Bool = true, status: String? = nil, startup: String? = nil) {
        self.isApplied = isApplied
        self.status = status
        self.startup = startup
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            isApplied: container.decodeIfPresent(Bool.self, forKey: .ok) ?? true,
            status: container.decodeIfPresent(String.self, forKey: .status),
            startup: container.decodeIfPresent(String.self, forKey: .startup)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case status
        case startup
    }
}

/// Whether the conversation app has a voice backend it can actually talk through.
///
/// **This is configuration, not a turn.** `conversation.status` is the only verb on
/// the app's surface that can explain a screen with nothing on it: no key, a backend
/// still coming up, or a backend that failed. Without it a silent conversation and a
/// misconfigured one look identical.
///
/// Only the fields a screen can act on are modelled. The app also answers half a
/// dozen Hugging Face connection details that belong to its own settings page.
public struct ConversationBackendStatus: Sendable, Equatable, Decodable {
    /// The app has what it needs to run — an API key or a Hugging Face connection.
    public let canProceed: Bool
    /// A live connection to the voice backend right now.
    public let isConnected: Bool
    /// The app's own word for where it has got to: `not_started`, `connected`, and
    /// whatever it grows next. Carried rather than mapped — this client has no branch
    /// on it, and a screen showing the robot's own word beats one showing nothing.
    public let connectionState: String?
    /// Why it is not connected, when the app knows. Nil while it is.
    public let error: String?
    /// A setting was saved that only a restart of the app will pick up.
    public let requiresRestart: Bool

    public init(
        canProceed: Bool,
        isConnected: Bool = false,
        connectionState: String? = nil,
        error: String? = nil,
        requiresRestart: Bool = false
    ) {
        self.canProceed = canProceed
        self.isConnected = isConnected
        self.connectionState = connectionState
        self.error = error
        self.requiresRestart = requiresRestart
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            canProceed: container.decodeIfPresent(Bool.self, forKey: .canProceed) ?? false,
            isConnected: container.decodeIfPresent(Bool.self, forKey: .backendConnected) ?? false,
            connectionState: container.decodeIfPresent(String.self, forKey: .backendConnectionState),
            error: container.decodeIfPresent(String.self, forKey: .backendError),
            requiresRestart: container.decodeIfPresent(Bool.self, forKey: .requiresRestart) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case canProceed = "can_proceed"
        case backendConnected = "backend_connected"
        case backendConnectionState = "backend_connection_state"
        case backendError = "backend_error"
        case requiresRestart = "requires_restart"
    }
}

/// The reply to `conversation.mic`, which answers the same shape whether it was asked
/// to read the flag or to write it.
struct ConversationMicrophoneReply: Decodable {
    let muted: Bool
}

/// The reply to `voices.current`.
struct ConversationVoiceReply: Decodable {
    let voice: String?
}
