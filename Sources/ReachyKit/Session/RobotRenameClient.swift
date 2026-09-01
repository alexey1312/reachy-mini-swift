import Foundation

/// A transport that can rename the robot without an HTTP route.
///
/// A marker beside ``RobotAPIClient/setRobotName(_:)`` rather than a second way to
/// call it: the method is already on the connection surface, and what this adds is
/// the answer to "can this one really do it". The LAN connection is told by the
/// daemon — `/api/daemon/robot-name` is 404 before 1.9.0, which is what
/// `Handshake.supportsRename` carries. The relay has no route to probe, so it says
/// so by conforming.
public protocol RobotRenameClient: Sendable {}

extension RemoteRobotConnection: RobotRenameClient {}
