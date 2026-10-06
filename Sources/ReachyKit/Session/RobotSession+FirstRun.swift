import Foundation
import OSLog

/// What outlives a connection in the first run's gate (#169).
public struct FirstRunServices {
    /// Opens a LAN robot's own WebRTC data channel — the one on its signaling port,
    /// the same peer its camera uses — and answers it once it is open, or `nil` if it
    /// did not open in time.
    ///
    /// **A closure the UI supplies, because only the UI can build one**: the peer
    /// connection is `ReachyMedia`, which `ReachyKit` does not link. `nil` leaves the
    /// LAN without a first run at all, which is what every test and preview that does
    /// not ask for one gets.
    public var openLANChannel: (@MainActor (RobotAddress) async -> (any FirstWakeUpClient)?)?
    /// This device's own record, for a robot whose channel does not open.
    public var records: FirstRunRecordStore

    public init(
        openLANChannel: (@MainActor (RobotAddress) async -> (any FirstWakeUpClient)?)? = nil,
        records: FirstRunRecordStore = FirstRunRecordStore()
    ) {
        self.openLANChannel = openLANChannel
        self.records = records
    }
}

/// One connection's worth of the first run's gate.
struct FirstRunState {
    var isOffered = false
    /// The run is over on screen and its end is still on its way to the robot. The
    /// LAN link is held for this too: the write travels on its data channel.
    var isWritingFlag = false
    /// Where finishing writes the robot's flag: the relay's client, or the LAN data
    /// channel opened to read it. `nil` when the robot could not be asked, and only
    /// this device's record is written.
    var flag: (any FirstWakeUpClient)?
    /// The robot, for this device's record. LAN only — over the relay the flag is
    /// read on every connect and nothing local stands in for it.
    var robot: String?
    /// Captured during the handshake, before the robot is remembered: whether this
    /// device had met it before, or set it up over Bluetooth a moment ago.
    var isNewToDevice = false
}

/// A first run of this app's own, gated on the robot's first wake-up flag (#169).
///
/// Pollen's apps gate a first-run wizard on the robot's `first_wake_up_completed`
/// flag and keep the robot asleep until it has run. This app does the same: on a
/// connect to a robot that reads `false`, ``offersFirstRun`` holds the shell back and
/// the first run stands in for it — a sleep-position check, the wake-up itself, the
/// camera, the microphone, the speaker and a name. Finishing it or skipping it writes
/// the flag, and nothing else does: a disconnect halfway through leaves the robot
/// new, so the next connect offers it again.
///
/// **The flag lives behind `process_command` and nowhere else**, and the two
/// transports reach it differently:
///
/// - **Over the relay** the session's own client is the data channel, and the flag is
///   read on every connect.
/// - **On the LAN** there is no REST route on any daemon up to `main`, and `/ws/sdk`
///   executes commands while answering none. But the robot's media server builds the
///   same `data` channel for a peer that arrives through its own signaling port as for
///   one arriving through central, so the UI opens one for the purpose
///   (``FirstRunServices/openLANChannel``) and the flag is read exactly as the relay
///   reads it. Where that channel does not open, this device's record decides
///   (``FirstRunRecordStore``) — a robot it meets for the first time is offered the
///   run — and once a robot is settled either way the channel is never opened for it
///   again.
///
/// **This replaces the wake-time marking #157 added, rather than adding a second
/// moment.** That marked the flag after the first wake this app performed; the first
/// run wakes the robot partway through, and a mark there would end the run's claim on
/// the next connect if the owner put the phone down before the last step.
extension RobotSession {
    private nonisolated static let firstRunLog = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "FirstRun"
    )

    /// The robot reads as never woken, so the first run stands in for the shell.
    public var offersFirstRun: Bool {
        firstRun.isOffered
    }

    /// Read during the connect, before the gate comes down, so the shell is never
    /// drawn for a moment before the first run replaces it.
    ///
    /// A failed read offers nothing over the relay — a robot that cannot answer is not
    /// shown a setup it may long since have had — and is never reported: `robotError`
    /// is the robot's connection and power alone (`RobotSessionErrorOwnershipTests`).
    ///
    /// **An attempt that ends during a read writes nothing.** Opening the LAN channel
    /// takes up to eight seconds and the read up to a reply budget more, and a
    /// disconnect in that time resets `firstRun`. A stale attempt that went on would
    /// read the reset state as a robot this device has met, and settle a new robot
    /// that never saw its first run.
    func readFirstRun(using client: any RobotAPIClient, identity: RobotIdentity, attemptID: UUID) async {
        let isNewToDevice = firstRun.isNewToDevice
        firstRun = FirstRunState(isNewToDevice: isNewToDevice)
        switch link {
        case .remote:
            // A 1.9.x daemon on the relay has no such command and would hold the gate
            // for the whole reply budget saying so.
            guard !predatesRelayCommands, let flag = client as? any FirstWakeUpClient,
                  let completed = await completed(asking: flag), isAttemptLive(attemptID), !completed
            else { return }
            offer(writingTo: flag)
        case let .lan(address):
            await readFirstRunOverLAN(
                address: address,
                robot: identity.deduplicationKey,
                isNewToDevice: isNewToDevice,
                attemptID: attemptID
            )
        case .none, .simulated:
            return
        }
    }

    /// The robot's own flag where its channel opens, this device's record where it
    /// does not — and a robot settled either way is never asked again.
    private func readFirstRunOverLAN(
        address: RobotAddress,
        robot: String,
        isNewToDevice: Bool,
        attemptID: UUID
    ) async {
        guard let open = firstRunServices.openLANChannel else { return }
        let records = firstRunServices.records
        let recorded = records.state(for: robot)
        guard recorded != .settled else { return }
        firstRun.robot = robot
        // The command arrived with 1.10.0; an older daemon is not worth a peer
        // connection, and its record decides.
        if !predatesRelayCommands, let flag = await open(address) {
            let completed = await completed(asking: flag)
            guard isAttemptLive(attemptID) else { return }
            if let completed {
                guard !completed else {
                    records.record(.settled, for: robot)
                    return
                }
                offer(writingTo: flag)
                return
            }
        }
        guard isAttemptLive(attemptID) else { return }
        guard recorded == .pending || isNewToDevice else {
            // Met before and never offered: set up already, as far as this device can
            // tell, and not worth a channel that did not open on every connect.
            records.record(.settled, for: robot)
            return
        }
        offer(writingTo: nil)
    }

    private func completed(asking flag: any FirstWakeUpClient) async -> Bool? {
        do {
            return try await flag.firstWakeUpCompleted()
        } catch {
            _ = Self.message(for: error)
            return nil
        }
    }

    /// Pending in this device's record too, so a run abandoned halfway is offered
    /// again even if the next connect cannot reach the robot's flag.
    private func offer(writingTo flag: (any FirstWakeUpClient)?) {
        firstRun.isOffered = true
        firstRun.flag = flag
        if let robot = firstRun.robot {
            firstRunServices.records.record(.pending, for: robot)
        }
    }

    /// Whether the end of the first run is still on its way to the robot.
    ///
    /// The shell is already on screen by then. On the LAN the write travels on the
    /// data channel the root opened for the run, so the root holds that channel
    /// open until this is false (`RootFirstRunLink`).
    public var isWritingFirstRunFlag: Bool {
        firstRun.isWritingFlag
    }

    /// The first run is over, finished or skipped: the shell takes its place at once
    /// and the robot is told it has met its owner.
    ///
    /// The offer is withdrawn **before** the write, not after it: a channel that has
    /// gone quiet would otherwise hold the owner on the last screen for a whole reply
    /// budget over bookkeeping they never see. ``isWritingFirstRunFlag`` covers the
    /// write instead, so the LAN channel it travels on stays open until it returns.
    ///
    /// This device records the robot as settled only once the robot confirms. A write
    /// that fails is logged and leaves the robot reading new, here and on the robot,
    /// which is the honest outcome — the next connect offers the run again, and
    /// skipping it costs one tap. Without a channel there is nothing to confirm, and
    /// the record is all there is.
    public func finishFirstRun() async {
        guard firstRun.isOffered else { return }
        firstRun.isOffered = false
        let robot = firstRun.robot
        guard let flag = firstRun.flag else {
            settleRecord(for: robot)
            return
        }
        let attemptID = connectionAttemptID
        firstRun.isWritingFlag = true
        defer {
            // A disconnect has already cleared it, and a new connection owns it now.
            if connectionAttemptID == attemptID {
                firstRun.isWritingFlag = false
            }
        }
        do {
            guard try await flag.setFirstWakeUpCompleted(true) else {
                Self.firstRunLog.error("the robot could not store its first wake-up")
                return
            }
            settleRecord(for: robot)
        } catch {
            _ = Self.message(for: error)
        }
    }

    private func settleRecord(for robot: String?) {
        guard let robot else { return }
        firstRunServices.records.record(.settled, for: robot)
    }
}
