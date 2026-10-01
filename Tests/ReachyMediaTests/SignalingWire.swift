import Foundation
import ReachyKit
@preconcurrency import WebRTC

/// What the daemon's signalling server does between the two peers: carries the
/// answer and each side's candidates to the other. A test that wants an answer lost
/// simply has no wire for that attempt.
@MainActor
final class SignalingWire {
    private let signaling: ScriptedSignaling
    private let robot: LoopbackRobot
    private var carriedFromSession = 0
    private var carriedFromRobot = 0
    private var pump: Task<Void, Never>?

    init(signaling: ScriptedSignaling, robot: LoopbackRobot) {
        self.signaling = signaling
        self.robot = robot
    }

    /// From now on, and only from now on: an answer an earlier attempt sent belongs to
    /// an earlier robot, and this one would refuse it.
    func connect() async {
        carriedFromSession = await signaling.sent.count
        pump = Task { [weak self] in
            while !Task.isCancelled {
                await self?.carry()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func cut() {
        pump?.cancel()
        pump = nil
    }

    /// One pass in each direction: everything said since the last pass.
    private func carry() async {
        let sent = await signaling.sent
        for message in sent.dropFirst(carriedFromSession) {
            switch message {
            case let .answer(sdp):
                try? await robot.accept(answer: sdp)
            case let .candidate(sdp, index, mid):
                await robot.add(candidate: sdp, sdpMLineIndex: index, sdpMid: mid)
            case .disconnect:
                break
            }
        }
        carriedFromSession = sent.count

        let gathered = robot.candidates
        for candidate in gathered.dropFirst(carriedFromRobot) {
            await signaling.deliver(.remoteCandidate(
                sessionID: "session",
                candidate: candidate.sdp,
                sdpMLineIndex: candidate.sdpMLineIndex,
                sdpMid: candidate.sdpMid
            ))
        }
        carriedFromRobot = gathered.count
    }
}
