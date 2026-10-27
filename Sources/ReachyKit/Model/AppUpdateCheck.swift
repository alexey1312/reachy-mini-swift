import Foundation

/// One app's update, as daemon 1.13.0's relay answers `apps.check_update`:
/// `{installed, version, update_available, checkable, updating, error}`.
///
/// One Hugging Face call per app on the robot, so it is asked for the app on
/// screen and not for a whole list.
public struct AppUpdateCheck: Equatable, Sendable, Decodable {
    public let installed: Bool
    /// The installed distribution's version, when the robot can find it.
    public let version: String?
    public let updateAvailable: Bool
    /// False when the source cannot be checked — not from the Hub, or the Hub call
    /// failed — so "no update" is not read as "up to date".
    public let checkable: Bool
    /// An update job for this app is running now.
    public let updating: Bool
    /// The last update job's failure, until the next update starts.
    public let error: String?

    public init(
        installed: Bool,
        version: String? = nil,
        updateAvailable: Bool,
        checkable: Bool = true,
        updating: Bool = false,
        error: String? = nil
    ) {
        self.installed = installed
        self.version = version
        self.updateAvailable = updateAvailable
        self.checkable = checkable
        self.updating = updating
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case installed, version, checkable, updating, error
        case updateAvailable = "update_available"
    }
}
