import Foundation
import ReachyJSON

#if DEBUG
    public extension RobotApp {
        /// A store entry, built the way the daemon serves one: the Space payload
        /// verbatim under `extra`.
        ///
        /// Lives on `RobotApp` rather than on a screen's model because Prefire copies
        /// each preview body into a generated file, where a leading-dot call resolves
        /// against the type expected *there*.
        static func preview(
            name: String,
            title: String? = nil,
            emoji: String? = nil,
            author: String? = "pollen-robotics",
            likes: Int? = 42,
            summary: String? = nil,
            gradient: (from: String, to: String)? = ("pink", "indigo"),
            isPrivate: Bool = false,
            installed: Bool = false,
            customAppURL: String? = nil
        ) -> RobotApp {
            var card: [String] = []
            if let title {
                card.append("\"title\": \"\(title)\"")
            }
            if let emoji {
                card.append("\"emoji\": \"\(emoji)\"")
            }
            if let gradient {
                card.append("\"colorFrom\": \"\(gradient.from)\", \"colorTo\": \"\(gradient.to)\"")
            }
            if let summary {
                card.append("\"short_description\": \"\(summary)\"")
            }

            var extra = ["\"id\": \"\(author ?? "someone")/\(name)\""]
            if let author {
                extra.append("\"author\": \"\(author)\"")
            }
            if let likes {
                extra.append("\"likes\": \(likes)")
            }
            if isPrivate {
                extra.append("\"private\": true")
            }
            if let customAppURL {
                extra.append("\"custom_app_url\": \"\(customAppURL)\"")
            }
            if !card.isEmpty {
                extra.append("\"cardData\": {\(card.joined(separator: ", "))}")
            }

            let json = """
            {"name": "\(name)", "source_kind": "\(installed ? "installed" : "hf_space")",
             "extra": {\(extra.joined(separator: ", "))}}
            """
            // swiftlint:disable:next force_try
            return try! JSONCodec.stored.decode(RobotApp.self, from: Data(json.utf8))
        }

        static let previewCatalogue: [RobotApp] = [
            .preview(
                name: "reachy-mini-dance",
                title: "Dance Party",
                emoji: "💃",
                likes: 214,
                summary: "Ten choreographies, one very determined robot."
            ),
            .preview(
                name: "face-tracking",
                title: "Face Tracking",
                emoji: "👀",
                likes: 187,
                summary: "Reachy follows whoever is talking.",
                gradient: ("blue", "cyan")
            ),
            .preview(
                name: "chess-coach",
                title: "Chess Coach",
                emoji: "♟️",
                author: "someone",
                likes: 12,
                summary: "Narrates your blunders out loud.",
                gradient: ("green", "yellow")
            ),
            .preview(
                name: "lab-notebook",
                title: "Lab Notebook",
                emoji: "🔬",
                author: "someone",
                likes: 0,
                summary: "Private research build.",
                gradient: ("gray", "slate"),
                isPrivate: true
            ),
        ]

        static let previewInstalled: [RobotApp] = [
            .preview(name: "reachy_mini_dance", title: nil, emoji: nil, author: nil, likes: nil, installed: true),
            .preview(name: "face_tracking", title: nil, emoji: nil, author: nil, likes: nil, installed: true),
        ]

        /// Carries the bind address the daemon really reports for this app, so a
        /// test or a preview built on it meets the `0.0.0.0` host head-on.
        static let previewConversation = RobotApp.preview(
            name: "reachy_mini_conversation_app",
            title: "Conversation App",
            emoji: "🎤",
            installed: true,
            customAppURL: "http://0.0.0.0:7860/"
        )
    }

    public extension RobotAppStatus {
        /// On the status rather than on a screen's model, for the same reason
        /// `RobotApp.preview` is: Prefire copies each preview body into a generated
        /// file, where a leading-dot call resolves against the type expected *there*.
        static func preview(_ state: State = .running, error: String? = nil) -> RobotAppStatus {
            RobotAppStatus(app: RobotApp.previewInstalled[0], state: state, error: error)
        }

        /// The last ten stderr lines are all the daemon keeps, and on a robot whose
        /// journal is not served over the network they are the only crash output
        /// there is.
        ///
        /// **Several lines on purpose.** This was one line — an exception and
        /// nothing else — and a one-line tail renders identically whether a
        /// surface prints it once or twice, so the references passed over the
        /// running-app sheet printing it in both its state row and its output row.
        /// A real tail opens with the daemon's own summary and carries a traceback
        /// under it, and that shape is what the two rows have to be captured
        /// against.
        static let previewCrashed = RobotAppStatus.preview(
            .error,
            error: """
            Process exited with code 1
            Traceback (most recent call last):
              File "/venvs/apps_venv/lib/python3.12/site-packages/reachy_mini_dance/main.py", line 12, in <module>
                import cv2
            ModuleNotFoundError: No module named 'cv2'
            """
        )

        static let previewConversation = RobotAppStatus(app: .previewConversation, state: .running)
    }
#endif

#if DEBUG
    /// The robot's own Hugging Face account, for previews of the account card.
    ///
    /// A separate conformance rather than more stored properties on the client:
    /// `canLinkHuggingFace` asks whether the client speaks this protocol at all, so
    /// a preview of a robot that cannot be linked is simply one built on a client
    /// without it.
    public struct PreviewHFRobotClient: RobotAPIClient, HFAuthClient {
        public var base: PreviewRobotClient
        public var account: HFAuthStatus
        public var relay: RelayStatus

        public init(
            base: PreviewRobotClient = PreviewRobotClient(),
            account: HFAuthStatus = HFAuthStatus(isLoggedIn: false),
            relay: RelayStatus = RelayStatus(state: .stopped, message: "Relay not initialized", isConnected: false)
        ) {
            self.base = base
            self.account = account
            self.relay = relay
        }

        public func handshake() async throws -> RobotConnection.Handshake {
            try await base.handshake()
        }

        public func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
            try await base.daemonStatus()
        }

        public func wakeUp() async throws -> String {
            try await base.wakeUp()
        }

        public func gotoSleep() async throws -> String {
            try await base.gotoSleep()
        }

        public func hfAuthStatus() async throws -> HFAuthStatus {
            account
        }

        public func relayStatus() async throws -> RelayStatus {
            relay
        }
    }
#endif
