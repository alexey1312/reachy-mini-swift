import Foundation
import Observation
import ReachyKit

/// The robots this app has connected to before, with whether each one is answering now.
///
/// Discovery alone cannot carry this screen: mDNS does not reach every network, and a robot
/// that has dropped off the air stops advertising entirely. A stored robot therefore stays
/// listed, and the probe is what says whether it is there.
@MainActor
@Observable
final class KnownRobotsModel {
    enum Status: Equatable {
        case checking
        case reachable
        case unreachable
    }

    struct Entry: Identifiable, Equatable {
        let robot: KnownRobot
        var status: Status

        var id: String {
            robot.key
        }
    }

    private(set) var entries: [Entry] = []

    private let store: KnownRobotStore
    private let interval: Duration
    private let probe: @Sendable (RobotAddress) async -> Bool
    /// Hardware ids Bonjour is reporting right now. An advertising robot is on the network by
    /// definition, so it needs no probe to be shown as present.
    private var discovered: Set<String> = []
    private var pollTask: Task<Void, Never>?

    init(
        store: KnownRobotStore = KnownRobots.store,
        interval: Duration = .seconds(10),
        probe: @escaping @Sendable (RobotAddress) async -> Bool = { await RobotReachability.probe($0) }
    ) {
        self.store = store
        self.interval = interval
        self.probe = probe
        reload()
    }

    func start() {
        reload()
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                // The iCloud mirror has no callback into this model, so the poll re-reads
                // the store — a robot synced from another device appears within one interval.
                reload()
                await probeAll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func updateDiscovered(_ hardwareIDs: Set<String>) {
        discovered = hardwareIDs
        for index in entries.indices where discovered.contains(entries[index].robot.key) {
            entries[index].status = .reachable
        }
    }

    func forget(_ key: String) {
        store.forget(key)
        entries.removeAll { $0.robot.key == key }
    }

    private func reload() {
        let statuses = Dictionary(uniqueKeysWithValues: entries.map { ($0.robot.key, $0.status) })
        entries = store.all.map { robot in
            let status: Status = discovered.contains(robot.key) ? .reachable : statuses[robot.key] ?? .checking
            return Entry(robot: robot, status: status)
        }
    }

    #if DEBUG
        /// A model parked in a fixed state. Previews are captured on their first frame, so the
        /// probe must never run — and the store is a throwaway suite rather than `.standard`,
        /// which holds the user's real robots.
        static func preview(_ entries: [Entry]) -> KnownRobotsModel {
            let defaults = UserDefaults(suiteName: "ReachyUI.previews") ?? .standard
            let model = KnownRobotsModel(
                store: KnownRobotStore(defaults: defaults),
                interval: .seconds(3600)
            ) { _ in false }
            model.entries = entries
            return model
        }
    #endif

    private func probeAll() async {
        // Snapshot first: the probes run concurrently and `entries` can be rewritten under them.
        let targets = entries.map { ($0.robot.key, $0.robot.address) }
        await withTaskGroup(of: (String, Bool).self) { group in
            for (key, address) in targets {
                group.addTask { [probe] in await (key, probe(address)) }
            }
            for await (key, isReachable) in group {
                guard let index = entries.firstIndex(where: { $0.robot.key == key }) else { continue }
                entries[index].status = isReachable || discovered.contains(key) ? .reachable : .unreachable
            }
        }
    }
}

#if DEBUG
    extension KnownRobotsModel.Entry {
        /// On `Entry` rather than on the model: Prefire copies a preview body into a generated
        /// file, where a leading-dot call resolves against the array's element type. The same
        /// helper on `KnownRobotsModel` compiles here and fails the snapshot target.
        static func preview(
            key: String = "b68ff6bbe47f0608",
            name: String? = "reachy_mini",
            host: String = "192.168.8.188",
            status: KnownRobotsModel.Status
        ) -> Self {
            Self(
                robot: KnownRobot(
                    key: key,
                    name: name,
                    address: RobotAddress(host: host),
                    lastConnected: Date(timeIntervalSince1970: 1_770_000_000)
                ),
                status: status
            )
        }
    }
#endif
