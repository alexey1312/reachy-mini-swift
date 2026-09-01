import Foundation
import Observation
import ReachyKit

/// What the robot is on, what it remembers, and the two ways to take a network away.
///
/// A model rather than `@State` on the card, because every one of these calls has a
/// second step the view cannot show: `forget` is only half done until the status is
/// read back, and a failure anywhere lands in the same slot the load failure uses.
/// `WiFiJoinModel` owns the other half of this screen and this owns the rest.
@MainActor
@Observable
final class WiFiSettingsModel {
    typealias Status = @MainActor (RobotSession) async throws -> WiFiStatus
    typealias LastError = @MainActor (RobotSession) async throws -> String?
    typealias Forget = @MainActor (RobotSession, String) async throws -> Void
    typealias ForgetAll = @MainActor (RobotSession) async throws -> Void
    typealias ResetError = @MainActor (RobotSession) async throws -> Void

    private(set) var status: WiFiStatus?
    /// Why the robot's own last attempt failed — the robot's memory, not this run's.
    private(set) var joinError: String?
    private(set) var loadFailure: String?
    private(set) var busy = false

    private let statusCall: Status
    private let lastErrorCall: LastError
    private let forgetCall: Forget
    private let forgetAllCall: ForgetAll
    private let resetErrorCall: ResetError

    init(
        status: @escaping Status = { try await $0.wifiStatus() },
        lastError: @escaping LastError = { try await $0.lastWiFiError() },
        forget: @escaping Forget = { try await $0.forgetWiFi(ssid: $1) },
        forgetAll: @escaping ForgetAll = { try await $0.forgetAllWiFi() },
        resetError: @escaping ResetError = { try await $0.resetWiFiError() }
    ) {
        statusCall = status
        lastErrorCall = lastError
        forgetCall = forget
        forgetAllCall = forgetAll
        resetErrorCall = resetError
    }

    var modeText: String {
        switch status?.mode {
        case .wlan: String(localized: .reachy("On a network"))
        case .hotspot: String(localized: .reachy("Its own hotspot"))
        case .disconnected: String(localized: .reachy("Not connected"))
        case .busy: "Working…"
        case nil: status == nil ? "—" : "Unknown"
        }
    }

    /// The robot's own hotspot cannot be forgotten, so a single saved network is not
    /// worth a second button beside the row that already forgets it.
    var offersForgetAll: Bool {
        (status?.known?.count ?? 0) > 1
    }

    func load(session: RobotSession) async {
        do {
            status = try await statusCall(session)
            joinError = try await lastErrorCall(session)
            loadFailure = nil
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }

    func forget(_ ssid: String, session: RobotSession) async {
        busy = true
        defer { busy = false }
        do {
            try await forgetCall(session, ssid)
            await load(session: session)
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }

    /// `/wifi/forget_all` rather than a loop over the rows: the robot does it in one
    /// `nmcli` operation, and the per-network route answers 409 while another one
    /// runs, so a loop would race itself.
    func forgetAll(session: RobotSession) async {
        busy = true
        defer { busy = false }
        do {
            try await forgetAllCall(session)
            await load(session: session)
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }

    func clearError(session: RobotSession) async {
        do {
            try await resetErrorCall(session)
            joinError = nil
        } catch {
            loadFailure.recordDaemonFailure(error)
        }
    }
}

#if DEBUG
    extension WiFiSettingsModel {
        static func preview(
            status: WiFiStatus? = nil,
            joinError: String? = nil,
            loadFailure: String? = nil
        ) -> WiFiSettingsModel {
            let model = WiFiSettingsModel()
            model.status = status
            model.joinError = joinError
            model.loadFailure = loadFailure
            return model
        }
    }
#endif
