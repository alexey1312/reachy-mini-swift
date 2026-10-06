import Foundation
import Observation
import ReachyKit
import ReachyMedia
import SwiftUI

/// The robot's own data channel on the LAN, held for as long as the first run needs
/// it (#169).
///
/// The first wake-up flag is answered by `process_command` alone, which on the LAN
/// is reachable through one door: a WebRTC peer arriving through the robot's own
/// signaling port, whose `data` channel the media server builds exactly as it does
/// for a peer from central. So the session asks this to open one during the connect
/// (`RobotSession.firstRunServices.openLANChannel`), reads the flag over it, and —
/// when the robot turns out to be new — the first run keeps it for its camera step
/// and for the write at the end. The root closes it the moment it is no longer
/// owed (`RootFirstRunLink`).
///
/// **Bounded at eight seconds, because the connect gate waits on it.** That wait is
/// paid once per robot per device: a robot settled either way — by its flag or by
/// this device's record — is never opened a channel for again.
@MainActor
@Observable
final class FirstRunLANLink {
    static let openingDeadline: Duration = .seconds(8)

    private(set) var link: RemoteRobotLink?
    @ObservationIgnored private var address: RobotAddress?

    /// The robot's flag client once its channel is open, or `nil` if it did not open in
    /// time — no media server, a network that blocks the peer, or a robot that is not
    /// there. A channel already open to the same robot is reused, which is what the
    /// connect stepper's Start backend path asks for when it re-runs readiness.
    func open(_ address: RobotAddress) async -> (any FirstWakeUpClient)? {
        if let link, self.address == address, link.camera.dataChannel.isOpen {
            return link.client
        }
        close()
        guard let link = try? RemoteRobotLink(address: address) else { return nil }
        self.link = link
        self.address = address
        link.start()
        guard await link.waitUntilOpen(within: Self.openingDeadline), self.link === link else {
            if self.link === link {
                close()
            }
            return nil
        }
        return link.client
    }

    func close() {
        link?.stop()
        link = nil
        address = nil
    }
}

/// The latest motor-by-motor pose and heard voice off the LAN's state socket, one
/// frame per ask — the first run's `readPose` on a robot reached by address.
///
/// The socket rather than the data channel, which the relay has to poll: on the LAN
/// the daemon pushes this at five frames a second for nothing. Its frame decodes no
/// `doa` of its own — the generated half carries it (`StateStreamUpdate.hearing`) —
/// so the two are joined here into the frame the checks read.
@MainActor
final class FirstRunStateReader {
    /// How long one ask waits for a frame newer than the last it answered. A robot
    /// whose socket has gone quiet then reads as a failed frame, which is what the
    /// checks count before they give up.
    static let frameTimeout: Duration = .seconds(2)

    private let stream: any RobotStateStreaming
    private let frameTimeout: Duration
    private var task: Task<Void, Never>?
    private var latest: RobotStateFrame?
    private var received = 0
    private var answered = 0

    init(stream: any RobotStateStreaming, frameTimeout: Duration = FirstRunStateReader.frameTimeout) {
        self.stream = stream
        self.frameTimeout = frameTimeout
    }

    deinit {
        task?.cancel()
    }

    static var options: StateStreamOptions {
        var options = StateStreamOptions()
        options.frequency = 5
        options.headJoints = true
        options.antennaPositions = true
        options.directionOfArrival = true
        options.headPose = false
        options.bodyYaw = false
        options.passiveJoints = false
        return options
    }

    func next() async throws -> RobotStateFrame? {
        start()
        let deadline = ContinuousClock.now + frameTimeout
        while received == answered {
            guard ContinuousClock.now < deadline else { throw ReachyKitError.notConnected }
            try await Task.sleep(for: .milliseconds(50))
        }
        answered = received
        return latest
    }

    private func start() {
        guard task == nil else { return }
        let updates = stream.updates(Self.options)
        task = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                latest = RobotStateFrame(
                    headJoints: update.frame?.headJoints,
                    antennas: update.frame?.antennas,
                    directionOfArrival: update.hearing
                )
                received += 1
            }
        }
    }
}

/// Closes the LAN channel once nothing is owed it: held while a connect may still be
/// reading the flag over it, while the first run that reading found is on screen, and
/// while the end of that run is on its way to the robot over it.
struct RootFirstRunLink: ViewModifier {
    let session: RobotSession
    let lan: FirstRunLANLink

    func body(content: Content) -> some View {
        content.onChange(of: holdsLink) { _, holds in
            guard !holds else { return }
            lan.close()
        }
    }

    private var holdsLink: Bool {
        // The offer goes before the write does, so the screen does not wait on the
        // robot. Closing on the offer alone cut the channel under the write.
        if session.offersFirstRun || session.isWritingFirstRunFlag {
            return true
        }
        switch session.phase {
        case .connecting(.handshaking), .connecting(.checkingBackend): return true
        default: return false
        }
    }
}
