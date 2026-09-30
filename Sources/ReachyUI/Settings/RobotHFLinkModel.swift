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
    /// The three device-code calls, as one seam: a test scripts the robot's side of
    /// the sign-in, and the approval that happens in a browser is its to decide.
    struct DeviceCode {
        var start: @MainActor (RobotSession) async throws -> RobotDeviceLogin
        var status: @MainActor (RobotSession, RobotDeviceLogin) async throws -> RobotDeviceLoginStatus
        var cancel: @MainActor (RobotSession, RobotDeviceLogin) async -> Void
        /// The wait between two readings. A seam so a test does not sit out the
        /// robot's five-second interval.
        var pause: @Sendable (Duration) async throws -> Void

        static var live: DeviceCode {
            DeviceCode(
                start: { try await $0.startRobotDeviceLogin() },
                status: { try await $0.robotDeviceLoginStatus($1) },
                cancel: { await $0.cancelRobotDeviceLogin($1) },
                pause: { try await Task.sleep(for: $0) }
            )
        }
    }

    private(set) var robotAccount: HFAuthStatus?
    private(set) var relay: RelayStatus?
    private(set) var linkError: String?
    private(set) var isLinking = false
    /// The code the robot is waiting on, while it waits. Its presence is what puts
    /// the code on the card instead of the Link button.
    private(set) var deviceLogin: RobotDeviceLogin?

    private let accountCall: Account
    private let relayCall: Relay
    private let linkCall: Link
    private let unlinkCall: Unlink
    private let deviceCode: DeviceCode
    private var deviceLoginTask: Task<Void, Never>?

    init(
        account: @escaping Account = { try await $0.robotHFAccount(refresh: $1) },
        relay: @escaping Relay = { try await $0.relayStatus() },
        link: @escaping Link = { try await $0.linkRobot(token: $1) },
        unlink: @escaping Unlink = { try await $0.unlinkRobot() },
        deviceCode: DeviceCode = .live
    ) {
        accountCall = account
        relayCall = relay
        linkCall = link
        unlinkCall = unlink
        self.deviceCode = deviceCode
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

    /// Starts the device-code sign-in and keeps it running after the button's own
    /// task is gone — the approval happens in a browser, and the card has to still be
    /// listening when the person comes back from it.
    func beginDeviceLogin(session: RobotSession, open: @escaping @MainActor (URL) -> Void) {
        deviceLoginTask?.cancel()
        deviceLoginTask = Task { await linkWithDeviceCode(session: session, open: open) }
    }

    /// Stops listening and tells the robot to stop polling the Hub.
    func cancelDeviceLogin() {
        deviceLoginTask?.cancel()
    }

    /// The robot signs itself in: it asks the Hub for a code, the person approves
    /// that code in a browser, and this reads the robot's progress until it holds a
    /// token or the code runs out. Nothing here ever sees a token.
    ///
    /// Read at the robot's own interval, which is the pace it polls the Hub at —
    /// asking it more often learns nothing sooner.
    func linkWithDeviceCode(session: RobotSession, open: @MainActor (URL) -> Void) async {
        isLinking = true
        linkError = nil
        defer {
            isLinking = false
            deviceLogin = nil
        }
        let login: RobotDeviceLogin
        do {
            login = try await deviceCode.start(session)
        } catch {
            linkError.recordDaemonFailure(error)
            return
        }
        deviceLogin = login
        open(login.approvalURL)
        let deadline = ContinuousClock.now.advanced(by: login.expiresIn)
        while ContinuousClock.now < deadline {
            do {
                try await deviceCode.pause(login.interval)
            } catch {
                // Cancelled — by the person, or by the card going away. The robot
                // would otherwise go on polling the Hub for a code nobody will enter.
                await deviceCode.cancel(session, login)
                return
            }
            let status: RobotDeviceLoginStatus
            do {
                status = try await deviceCode.status(session, login)
            } catch {
                linkError.recordDaemonFailure(error)
                return
            }
            guard status.isFinished else { continue }
            await finishDeviceLogin(status, session: session)
            return
        }
        linkError = Self.expiredText
    }

    private func finishDeviceLogin(_ status: RobotDeviceLoginStatus, session: RobotSession) async {
        switch status {
        case .authorized:
            // The daemon starts the relay itself on the reading that said
            // `authorized`, so there is no refresh to ask for — only a state to read.
            robotAccount = try? await accountCall(session, true)
            relay = try? await relayCall(session)
        case .expired:
            linkError = Self.expiredText
        case let .failed(message):
            // Runtime text from the Hub by way of the robot, which is what keeps
            // this slot a String (rule 9).
            linkError = message ?? String(localized: .reachy("Hugging Face did not sign the robot in."))
        case .cancelled, .pending, .unknown:
            break
        }
    }

    private static var expiredText: String {
        String(localized: .reachy("The code expired before it was approved. Link the robot again."))
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
            linkError: String? = nil,
            deviceLogin: RobotDeviceLogin? = nil
        ) -> RobotHFLinkModel {
            let model = RobotHFLinkModel()
            model.robotAccount = robotAccount
            model.relay = relay
            model.linkError = linkError
            model.deviceLogin = deviceLogin
            model.isLinking = deviceLogin != nil
            return model
        }
    }
#endif
