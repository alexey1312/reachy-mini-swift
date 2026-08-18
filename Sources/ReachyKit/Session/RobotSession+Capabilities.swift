import Foundation

public extension RobotSession {
    /// The connected client, if it speaks `type`.
    ///
    /// **Capabilities in this app are conformances, not flags** — `canTeleoperate`
    /// is `client is any TeleopClient`, `canReadDaemonLogs` the same shape — and
    /// each of those answers a question `ReachyKit` already knows to ask. This is
    /// the same probe for a protocol `ReachyKit` cannot know about: a simulator
    /// lives in a target above this one, and the viewport needs the object itself
    /// rather than a yes.
    ///
    /// Deliberately not a way around `client` being internal. It hands back exactly
    /// what a conformance check would have found, and nothing that fails the cast.
    ///
    /// In a file of its own because `RobotSession.swift` sits at SwiftLint's 400-line
    /// ceiling, which `--strict` makes a build failure.
    func capability<T>(_ type: T.Type) -> T? {
        client as? T
    }
}
