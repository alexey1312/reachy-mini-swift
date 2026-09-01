import Foundation
import Observation
import ReachyKit

/// Moves the robot to another network from settings, over the connection it is on.
///
/// **Success ends the session, and that is not a failure to report.** The robot
/// answers before it reconfigures its interface, so an accepted password is the last
/// thing this connection carries. The screen says so and hands back to discovery
/// rather than polling a link that is going away — over Bluetooth the robot can be
/// asked how the join went, and here it cannot.
@MainActor
@Observable
final class WiFiJoinModel {
    enum Phase: Equatable {
        case editing
        case sending
        /// Accepted. The robot is switching networks and this link is going with it.
        case sent(ssid: String)
        case refused(String)
    }

    typealias Scan = @MainActor (RobotSession) async throws -> [String]
    typealias Join = @MainActor (RobotSession, String, String, String) async throws -> Void

    private(set) var phase: Phase = .editing
    private(set) var networks: [String] = []
    private(set) var isScanning = false
    private(set) var scanFailure: String?

    /// Nil means "Other network…", and that is a first-class choice rather than a
    /// fallback: a scan is one sweep of one radio, and a network that stayed quiet
    /// through it is still there to be typed.
    var selected: String?
    var manualSSID = ""
    var password = ""
    /// The code printed on the robot's base. The robot throttles wrong ones globally,
    /// so this screen counts nothing and says so instead.
    var code = ""

    private let scanCall: Scan
    private let joinCall: Join

    init(
        scan: @escaping Scan = { try await $0.scanWiFiNetworks() },
        join: @escaping Join = { try await $0.joinWiFi(ssid: $1, password: $2, pin: $3) }
    ) {
        scanCall = scan
        joinCall = join
    }

    var ssid: String {
        selected ?? manualSSID.trimmingCharacters(in: .whitespaces)
    }

    /// The password is not required: an open network has none, and the robot decides
    /// whether the one it was given works.
    var canSend: Bool {
        phase == .editing && !ssid.isEmpty && !code.isEmpty
    }

    func scan(session: RobotSession) async {
        isScanning = true
        defer { isScanning = false }
        do {
            networks = try await scanCall(session)
            scanFailure = nil
            // A name that vanished between sweeps must not stay selected under a
            // picker that no longer lists it.
            if let selected, !networks.contains(selected) {
                self.selected = nil
                manualSSID = selected
            }
        } catch {
            scanFailure.recordDaemonFailure(error)
        }
    }

    func send(session: RobotSession) async {
        guard canSend else { return }
        let ssid = ssid
        phase = .sending
        do {
            try await joinCall(session, ssid, password, code)
            phase = .sent(ssid: ssid)
        } catch {
            phase = .refused(RobotSession.message(for: error) ?? String(
                localized: .reachy("The robot refused the network.")
            ))
        }
        // Held no longer than the call that needed it.
        password = ""
    }

    func editAgain() {
        phase = .editing
    }
}

#if DEBUG
    extension WiFiJoinModel {
        static func preview(
            phase: Phase = .editing,
            networks: [String] = [],
            selected: String? = nil,
            manualSSID: String = "",
            code: String = "",
            scanning: Bool = false,
            scanFailure: String? = nil
        ) -> WiFiJoinModel {
            let model = WiFiJoinModel(scan: { _ in networks }, join: { _, _, _, _ in })
            model.phase = phase
            model.networks = networks
            model.selected = selected
            model.manualSSID = manualSSID
            model.code = code
            model.isScanning = scanning
            model.scanFailure = scanFailure
            return model
        }
    }
#endif
