import ReachyDesign
import ReachyKit
import SwiftUI

/// The Robot menu on macOS: the three things a keyboard reaches for on a
/// connected robot, with the shortcuts a Mac reader expects to exist.
///
/// The session arrives through the focused scene rather than being handed in:
/// `App` builds its commands before any window has a session, and the menu has
/// to grey itself out on the gate, where there is nothing to command.
public struct RobotCommands: Commands {
    @FocusedValue(\.robotSession) private var session

    public init() {}

    public var body: some Commands {
        CommandMenu(Text(.reachy("Robot"))) {
            Button(.reachy("Wake up")) {
                Task { await session?.wake() }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(session.map { $0.isAwake || $0.powerTransition != nil } ?? true)

            Button(.reachy("Go to sleep")) {
                Task { await session?.sleep() }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session.map { !$0.isAwake || $0.powerTransition != nil } ?? true)

            Divider()

            Button(.reachy("Stop the move")) {
                Task { _ = await session?.stopMove() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(session?.moveActivity == nil)
        }
    }
}

extension FocusedValues {
    /// The connected session, published by the root once the gate is down and
    /// withdrawn while it is up — so the Robot menu answers for the window in front.
    var robotSession: RobotSession? {
        get { self[RobotSessionFocusKey.self] }
        set { self[RobotSessionFocusKey.self] = newValue }
    }
}

private struct RobotSessionFocusKey: FocusedValueKey {
    typealias Value = RobotSession
}
