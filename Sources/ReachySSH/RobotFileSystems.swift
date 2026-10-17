/// A file system that can pin the host key a person has just accepted.
///
/// `SSHFileSystem` is one. A stub has no key to pin, so a screen that holds one
/// treats acceptance as a plain retry.
public protocol HostKeyPinning: RobotFileSystem {
    func trustOfferedHostKey(_ fingerprint: HostKeyFingerprint) async throws
}

/// Where this package can open SFTP at all.
///
/// Citadel is linked on iOS and macOS only: its fork of swift-nio-ssh imports `NIO`
/// without depending on it, and that fails the tvOS and visionOS builds. Elsewhere
/// there is no SSH client, and a screen settles in the state it takes for a robot
/// with no LAN address.
public enum RobotFileSystems {
    public static var hasSSH: Bool {
        #if os(iOS) || os(macOS)
            true
        #else
            false
        #endif
    }

    /// SFTP to `robot`, keyed by its identity, or `nil` where `hasSSH` is false.
    public static func ssh(robot: String) -> (any HostKeyPinning)? {
        #if os(iOS) || os(macOS)
            SSHFileSystem(robot: robot)
        #else
            nil
        #endif
    }
}
