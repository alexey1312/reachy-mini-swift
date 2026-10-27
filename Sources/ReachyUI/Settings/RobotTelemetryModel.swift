import Foundation
import Observation
import ReachyKit

/// The robot's "Share anonymous usage data" switch, read and written (daemon 1.13.0).
///
/// The section draws nothing until a read has answered, which is what Pollen's apps
/// do: a robot without the setting, and one whose answer never came, both show no
/// switch rather than a guess. A write moves the switch at once and puts it back
/// when the robot refuses, so a refused write never looks like a saved one.
@MainActor
@Observable
final class RobotTelemetryModel {
    typealias Read = @MainActor (RobotSession) async throws -> RobotTelemetry?
    typealias Write = @MainActor (RobotSession, Bool) async throws -> RobotTelemetry

    private(set) var status: RobotTelemetry?
    private(set) var isSaving = false
    private(set) var lastError: String?
    private var hasRead = false
    private let read: Read
    private let write: Write

    init(
        read: @escaping Read = { try await $0.robotTelemetry() },
        write: @escaping Write = { try await $0.setRobotTelemetry(enabled: $1) }
    ) {
        self.read = read
        self.write = write
    }

    /// Once per screen. A failure leaves the section hidden and is tried again the
    /// next time Settings opens; it is logged through the one filter.
    func load(session: RobotSession) async {
        guard !hasRead else { return }
        do {
            status = try await read(session)
            hasRead = true
        } catch {
            _ = RobotSession.message(for: error)
        }
    }

    /// One write at a time: a second tap while one is out could take the first
    /// reply and show the wrong state.
    func setSharing(_ isOn: Bool, session: RobotSession) async {
        guard let before = status, !before.isDisabledByEnvironment, !isSaving, before.isEnabled != isOn else { return }
        isSaving = true
        defer { isSaving = false }
        status?.isEnabled = isOn
        do {
            status = try await write(session, isOn)
            lastError = nil
        } catch {
            status = before
            lastError.recordDaemonFailure(error)
        }
    }
}

#if DEBUG
    extension RobotTelemetryModel {
        static func preview(
            _ status: RobotTelemetry = RobotTelemetry(isEnabled: true, isDisabledByEnvironment: false),
            lastError: String? = nil
        ) -> RobotTelemetryModel {
            let model = RobotTelemetryModel()
            model.status = status
            model.hasRead = true
            model.lastError = lastError
            return model
        }
    }
#endif
