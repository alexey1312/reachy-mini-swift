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
        /// The robot answered, and said no.
        case refused(String)
        /// The link went away before any answer arrived, which is also what a
        /// success looks like from here. Neither outcome is known.
        case uncertain(ssid: String)
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
        // The screen's `.task` and the "Scan again" button can both reach this. Two
        // overlapping sweeps let the first one's `defer` clear `isScanning` while
        // the second is still running, which re-enables a button over a live scan.
        guard !isScanning else { return }
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
            // Held no longer than the call that needed it. Only here: clearing it
            // on the way to `.refused` empties the field behind "Try again", and
            // the usual reason for a refusal is the code rather than the password.
            password = ""
        } catch {
            phase = Self.outcome(of: error, ssid: ssid)
        }
    }

    /// What a failed join means, which is three different things.
    ///
    /// `RobotSession.message(for:)` answers nil for an abandoned call, and that
    /// means *leave the screen alone* — overriding it with `??` turned "we learned
    /// nothing" into a red refusal panel under a footer blaming the code. A dropped
    /// link is its own outcome for the same reason: this screen's success takes the
    /// link down, so a lost connection is as likely to be a join that worked.
    private static func outcome(of error: any Error, ssid: String) -> Phase {
        guard let message = RobotSession.message(for: error) else { return .editing }
        guard !RobotSession.isLinkLoss(error) else { return .uncertain(ssid: ssid) }
        return .refused(message)
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
