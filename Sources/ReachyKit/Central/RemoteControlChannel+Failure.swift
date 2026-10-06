import Foundation

public extension RemoteControlChannel {
    enum Failure: Error, Equatable, Sendable {
        /// The robot answered, and said no. The text is its own.
        case robot(String)
        /// Nothing came back in time. Nothing on this channel promises a deadline,
        /// so one is imposed here — a caller left awaiting forever is worse off
        /// than one told the robot went quiet.
        case timedOut
        case closed
        /// A JSON-RPC refusal, with the two fields a caller can branch on.
        ///
        /// **Appended, and it has to be**: `NSError` numbers a bridged case by its
        /// declaration index, so inserting this beside ``robot(_:)`` where it reads
        /// better would renumber ``closed`` — which the notes record as "error 2".
        ///
        /// Separate from ``robot(_:)`` rather than a payload on it because the two
        /// answer different questions. `robot` carries the `{"error": "…"}` string
        /// the `{type, command}` protocol uses, which has no code and never had one.
        /// This one carries JSON-RPC's, and the code is the whole point: `-32601`
        /// means the app's build has no such method and the control should go,
        /// while `-32000` with `not_running` means the app is gone — two different
        /// screens that were previously one string. ``errorDescription`` composes
        /// that same string, so nothing a user reads changes.
        case rpc(code: Int, message: String, reason: String?)
        /// A JSON-RPC call went unanswered, the relay's own `apps.status` went
        /// unanswered too, and the robot still answers plain commands on the same
        /// channel. Appended, like ``rpc(code:message:reason:)``.
        case relaySilent
    }
}
