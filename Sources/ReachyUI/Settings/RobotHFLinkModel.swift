import Foundation
import Observation
import ReachyKit

/// Whether this robot holds a copy of the account's token, and the two ways to
/// change that.
///
/// A model rather than `@State` on the card, because linking is not one call: the
/// robot is told, then asked what it now holds, and the relay is only worth reading
/// back when a reconnect actually started. Unlinking is the same shape and matters
/// more — it is the path that takes a token away from a robot, and it was reachable
/// from a recorded image and nothing else.
///
/// This is the robot's custody of the token. `HFSignInModel` holds this app's own.
@MainActor
@Observable
final class RobotHFLinkModel {
    typealias Account = @MainActor (RobotSession, Bool) async throws -> HFAuthStatus
    typealias Relay = @MainActor (RobotSession) async throws -> RelayStatus
    typealias Link = @MainActor (RobotSession, String) async throws -> RelayRefresh
    typealias Unlink = @MainActor (RobotSession) async throws -> Void

    private(set) var robotAccount: HFAuthStatus?
    private(set) var relay: RelayStatus?
    private(set) var linkError: String?
    private(set) var isLinking = false

    private let accountCall: Account
    private let relayCall: Relay
    private let linkCall: Link
    private let unlinkCall: Unlink

    init(
        account: @escaping Account = { try await $0.robotHFAccount(refresh: $1) },
        relay: @escaping Relay = { try await $0.relayStatus() },
        link: @escaping Link = { try await $0.linkRobot(token: $1) },
        unlink: @escaping Unlink = { try await $0.unlinkRobot() }
    ) {
        accountCall = account
        relayCall = relay
        linkCall = link
        unlinkCall = unlink
    }

    var isLinked: Bool {
        robotAccount?.isLoggedIn == true
    }

    var accountText: String {
        guard let robotAccount else { return "…" }
        if robotAccount.isLoggedIn {
            return robotAccount.username.map { String(localized: .reachy("Linked to \($0)")) }
                ?? String(localized: .reachy("Linked"))
        }
        return String(localized: .reachy("Not linked"))
    }

    var relayCaption: String? {
        guard let relay else { return nil }
        return switch relay.state {
        case .connected: String(localized: .reachy("Online"))
        case .connecting, .reconnecting: String(localized: .reachy("Connecting…"))
        case .waitingForToken: String(localized: .reachy("Waiting for a token"))
        case .stopped: String(localized: .reachy("Off"))
        case .unavailable: relay.message ?? String(localized: .reachy("Not available on this robot"))
        case .error: relay.message ?? String(localized: .reachy("Error"))
        // The daemon's own word for a state this app does not know — runtime
        // text, which is what keeps this slot a String (rule 9).
        case let .unknown(state): state
        }
    }

    /// Both readings are `try?`: a robot that cannot answer either one is not a
    /// failure to report on a card the user opened to read something else.
    func load(session: RobotSession) async {
        robotAccount = try? await accountCall(session, false)
        relay = try? await relayCall(session)
    }

    /// The token comes from this app's account, which is the caller's to hold.
    func link(session: RobotSession, token: String?) async {
        guard let token else {
            linkError = String(localized: .reachy("This app has no valid token to share. Sign in again."))
            return
        }
        isLinking = true
        linkError = nil
        defer { isLinking = false }
        do {
            let refresh = try await linkCall(session, token)
            robotAccount = try? await accountCall(session, true)
            // `skipped` means no reconnect was started, so waiting for the relay to
            // change state would wait forever — the daemon's own docstring calls
            // that trap out by name.
            relay = refresh.didStart ? try? await relayCall(session) : relay
        } catch {
            linkError.recordDaemonFailure(error)
        }
    }

    func unlink(session: RobotSession) async {
        isLinking = true
        linkError = nil
        defer { isLinking = false }
        do {
            try await unlinkCall(session)
            robotAccount = try? await accountCall(session, true)
            relay = try? await relayCall(session)
        } catch {
            linkError.recordDaemonFailure(error)
        }
    }
}

#if DEBUG
    extension RobotHFLinkModel {
        static func preview(
            robotAccount: HFAuthStatus? = nil,
            relay: RelayStatus? = nil,
            linkError: String? = nil
        ) -> RobotHFLinkModel {
            let model = RobotHFLinkModel()
            model.robotAccount = robotAccount
            model.relay = relay
            model.linkError = linkError
            return model
        }
    }
#endif
