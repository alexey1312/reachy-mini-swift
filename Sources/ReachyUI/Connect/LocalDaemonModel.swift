import Foundation
import Observation
import ReachyKit

/// Whether a daemon is serving on this very machine.
///
/// A Lite robot and a simulator are the same daemon as a Wireless robot's, started
/// on the reader's own computer instead of on the robot — `--serialport` for one,
/// `--sim` for the other. So neither needs a transport of its own: loopback is the
/// whole difference, and this model is the one question worth asking about it.
///
/// It is not a `KnownRobotsModel` entry. A stored robot is keyed by the identity a
/// handshake established (project rule 4), and a daemon that has not been talked to
/// yet has none — the address is the only thing there is to know.
@MainActor
@Observable
final class LocalDaemonModel {
    /// Reusing the robot list's vocabulary rather than inventing a second one: the
    /// row renders through `KnownRobotStatusLabel`, and two spellings of "answering"
    /// on one screen is one more than a reader can be asked to hold.
    typealias Status = KnownRobotsModel.Status

    /// Loopback at the daemon's own default port.
    ///
    /// The same candidate `CandidateSweep.enqueueInitialCandidates()` already seeds
    /// on macOS and in the Simulator, and it is right in both for the same reason:
    /// a simulated daemon runs on this Mac and advertises no Bonjour a simulator can
    /// see, while loopback reaches the host either way.
    ///
    /// A daemon on another port is what the Manual segment is for. Probing a range
    /// would be a port scan of the reader's own machine to save one field.
    static let loopback = RobotAddress(host: "127.0.0.1")

    private(set) var status: Status = .checking

    /// The address the row connects to, which is the address that was probed. Not
    /// `private`: the section must not reach for the static default, or an injected
    /// model would report one daemon and dial another.
    let address: RobotAddress
    private let interval: Duration
    private let probe: @Sendable (RobotAddress) async -> Bool
    private var pollTask: Task<Void, Never>?

    init(
        address: RobotAddress = LocalDaemonModel.loopback,
        interval: Duration = .seconds(10),
        probe: @escaping @Sendable (RobotAddress) async -> Bool = { await RobotReachability.probe($0) }
    ) {
        self.address = address
        self.interval = interval
        self.probe = probe
    }

    func start() {
        guard pollTask == nil else { return }
        // Implicit `self`, as `KnownRobotsModel.start()` has: `Task.init` marks its
        // operation `@_implicitSelfCapture`, so the loop can assign `status` without
        // a capture list. Probe first and sleep after — the opposite order would
        // leave the row spinning for a full interval before saying anything.
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                let isServing = await probe(address)
                guard !Task.isCancelled else { return }
                status = isServing ? .reachable : .unreachable
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        // Deliberately *not* reset to `.checking`. The section stays mounted for the
        // life of the gate, so blanking the answer on the way past would put a
        // spinner back under a reader who had already been told there is nothing
        // there — and the next probe is ten seconds away.
    }

    #if DEBUG
        /// A model parked in one state, with no polling task.
        ///
        /// Previews are captured on their first frame, so the probe must never run.
        static func preview(_ status: Status) -> LocalDaemonModel {
            let model = LocalDaemonModel(interval: .seconds(3600)) { _ in false }
            model.status = status
            return model
        }
    #endif
}
