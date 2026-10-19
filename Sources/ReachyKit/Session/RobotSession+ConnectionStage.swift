import Foundation

public extension RobotSession {
    /// The steps a connection walks through, in order — the stepper's row model.
    enum ConnectionStage: Int, CaseIterable, Equatable, Sendable {
        case connect
        case compatibility
        case backend
    }

    enum StageOutcome: Equatable, Sendable {
        case pending, active, done, attention, failed
    }
}

/// Projects the connection phase onto the stepper's rows.
///
/// Kept here rather than in the view so the mapping is testable as a plain
/// table, and so progress is monotonic by construction: the outcome is derived
/// from the phase every time instead of being accumulated, which is what forces
/// upstream to carry a high-water mark.
public extension RobotSession.ConnectionPhase {
    func outcome(for stage: RobotSession.ConnectionStage) -> RobotSession.StageOutcome {
        switch self {
        case .idle: .pending
        case .connected, .unreachable: .done
        case let .connecting(step): step.outcome(for: stage)
        }
    }
}

private extension RobotSession.ConnectionStep {
    /// Which stage the attempt is standing on, and how that one row reads. Every
    /// earlier stage is finished by definition — the attempt could not have got
    /// here otherwise — and every later one has not been tried.
    var position: (stage: RobotSession.ConnectionStage, outcome: RobotSession.StageOutcome) {
        switch self {
        case .handshaking: (.connect, .active)
        case .checkingBackend: (.backend, .active)
        case .needsDaemonUpdate: (.compatibility, .attention)
        case .backendUnavailable: (.backend, .attention)
        case let .failed(stage, _): (stage, .failed)
        }
    }

    func outcome(for stage: RobotSession.ConnectionStage) -> RobotSession.StageOutcome {
        let current = position
        guard stage != current.stage else { return current.outcome }
        return stage.rawValue < current.stage.rawValue ? .done : .pending
    }
}
