import Foundation
import ReachyJSON

/// The messages a hosted JS app and its host exchange — protocol v1 of
/// Pollen's embed SDK (`ts/host/src/lib/protocol.ts` in `reachy_mini`, read as a
/// specification).
///
/// Every message is an object carrying `source: "reachy-mini"` and `version: 1`;
/// anything else is not this protocol and is ignored, which is also how the SDK
/// treats a future version. **No message carries a secret**: the token travels in
/// the URL fragment and nowhere else (`JSAppEmbed`), so `host:init` is not needed
/// by a page loaded on its own rather than in an iframe — the SDK then resolves
/// its credentials from the fragment at once, which is how this host loads it.
public enum JSAppHostProtocol {
    public static let source = "reachy-mini"
    public static let version = 1

    /// What the page tells its host.
    public enum PageMessage: Sendable, Equatable {
        /// The SDK has loaded and the bridge is listening.
        case ready
        case appState(AppState)
        /// The app asks to be closed — its own Exit button.
        case requestLeave
        /// The app has finished leaving: the robot is put to sleep and its session
        /// stopped, so the host may tear the page down.
        case left
        /// `fatal` decides whether the app is over; a non-fatal one is a toast at
        /// most.
        case error(message: String, fatal: Bool)
        /// Anything else in the protocol — `embed:debug`, update progress. Kept by
        /// type so a diagnostic view can show it.
        case other(type: String)
    }

    public struct AppState: Sendable, Equatable {
        public enum Phase: String, Sendable, Equatable {
            case boot, connecting, live, leaving, error
        }

        /// Where a `connecting` page is: reaching central, opening the session,
        /// waiting for the robot's wake-up animation to finish.
        public enum Step: String, Sendable, Equatable {
            case link, session, wake
        }

        public let phase: Phase
        public let step: Step?
        public let message: String?
        public let daemonVersion: String?

        public init(phase: Phase, step: Step? = nil, message: String? = nil, daemonVersion: String? = nil) {
            self.phase = phase
            self.step = step
            self.message = message
            self.daemonVersion = daemonVersion
        }
    }

    /// Why the host is closing the app — logged by the page, and nothing more.
    public enum LeavingReason: String, Sendable {
        case userAction = "user-action"
        case sessionStopped = "session-stopped"
        case error
        case pagehide
    }

    /// One message as the page posted it, `nil` for anything outside protocol v1
    /// or a phase this build does not know.
    public static func pageMessage(from data: Data) -> PageMessage? {
        guard let envelope = try? JSONCodec.web.decode(Envelope.self, from: data),
              envelope.source == source, envelope.version == version
        else { return nil }
        switch envelope.type {
        case "embed:ready":
            return .ready
        case "embed:request-leave":
            return .requestLeave
        case "embed:left":
            return .left
        case "embed:error":
            return .error(message: envelope.message ?? "", fatal: envelope.fatal ?? false)
        case "embed:app-state":
            guard let phase = envelope.phase.flatMap(AppState.Phase.init(rawValue:)) else {
                return .other(type: envelope.type)
            }
            return .appState(AppState(
                phase: phase,
                step: envelope.connectingStep.flatMap(AppState.Step.init(rawValue:)),
                message: envelope.message,
                daemonVersion: envelope.daemonVersion
            ))
        default:
            return .other(type: envelope.type)
        }
    }

    /// `host:leaving`, as JSON to post into the page. The page answers with
    /// `embed:left` once it has put the robot to sleep, or the host gives up at
    /// `timeout`, which it also tells the page.
    public static func leaving(reason: LeavingReason, timeout: Duration) throws -> String {
        let milliseconds = Int(timeout.components.seconds * 1000)
            + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
        return try json(Leaving(reason: reason.rawValue, timeoutMs: milliseconds))
    }

    /// `host:theme-changed`.
    public static func themeChanged(_ theme: JSAppEmbed.Theme) throws -> String {
        try json(ThemeChanged(theme: theme.rawValue))
    }

    private static func json(_ message: some Encodable) throws -> String {
        guard let json = try String(bytes: JSONCodec.web.encode(message), encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }

    /// Every field any page message carries, all optional: the type decides
    /// which matter, and an unknown field must not cost the message (rule 3).
    private struct Envelope: Decodable {
        let source: String
        let version: Int
        let type: String
        let phase: String?
        let connectingStep: String?
        let message: String?
        let fatal: Bool?
        let daemonVersion: String?
    }

    private struct Leaving: Encodable {
        let source = JSAppHostProtocol.source
        let version = JSAppHostProtocol.version
        let type = "host:leaving"
        let reason: String
        let timeoutMs: Int
    }

    private struct ThemeChanged: Encodable {
        let source = JSAppHostProtocol.source
        let version = JSAppHostProtocol.version
        let type = "host:theme-changed"
        let theme: String
    }
}
