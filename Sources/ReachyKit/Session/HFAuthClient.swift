import Foundation

/// Taking the robot's token away, which is the one part of its Hugging Face
/// account a relayed session can reach.
///
/// Split out of ``HFAuthClient`` because the data channel carries this command and
/// none of the others: the robot cannot be *asked* about its account over the
/// relay, and it cannot be given a token there either. It can be told to drop the
/// one it has — and the relay is exactly where an owner who is nowhere near the
/// robot needs that.
///
/// **The robot goes offline and stays there.** Its token is what registers it with
/// central, so dropping it ends this session and every future one until somebody
/// re-provisions the robot over Bluetooth or through the page it serves itself.
public protocol RobotUnlinkClient: Sendable {
    func deleteHFToken() async throws
}

public extension RobotUnlinkClient {
    func deleteHFToken() async throws {
        throw URLError(.unsupportedURL)
    }
}

/// The robot's own Hugging Face account: the token it stores, the relay that
/// token buys it, and central's robot list proxied through it.
///
/// The daemon's OAuth routes (`/api/hf-auth/oauth/*`) are deliberately absent.
/// They exist for a browser pointed at the robot, and they redirect back to
/// `reachy-mini.local` — a flow this app has no use for, because it signs in
/// natively and hands the robot a token it already holds.
public protocol HFAuthClient: RobotUnlinkClient {
    func hfAuthStatus() async throws -> HFAuthStatus
    /// Stores the token on the robot. The daemon validates it against the Hub
    /// first and answers 400 if the Hub refuses it. Returns the account name it
    /// resolved to.
    @discardableResult
    func saveHFToken(_ token: String) async throws -> String?
    func relayStatus() async throws -> RelayStatus
    /// Asks the relay to reconnect. Check `didStart` before waiting on anything.
    @discardableResult
    func refreshRelay() async throws -> RelayRefresh
    /// Central's robot list, fetched by the robot with its own token.
    func centralRobotStatus() async throws -> CentralRobotStatusProxy
}

/// Defaults keep test doubles focused on the behaviour they exercise.
public extension HFAuthClient {
    func hfAuthStatus() async throws -> HFAuthStatus {
        throw URLError(.unsupportedURL)
    }

    @discardableResult
    func saveHFToken(_: String) async throws -> String? {
        throw URLError(.unsupportedURL)
    }

    func relayStatus() async throws -> RelayStatus {
        throw URLError(.unsupportedURL)
    }

    @discardableResult
    func refreshRelay() async throws -> RelayRefresh {
        throw URLError(.unsupportedURL)
    }

    func centralRobotStatus() async throws -> CentralRobotStatusProxy {
        throw URLError(.unsupportedURL)
    }
}
