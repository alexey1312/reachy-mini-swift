import Foundation
import ReachyKit

/// A robot that is not there, publishing state the way one does.
///
/// One loop advances the pose; each subscription samples it at the rate it asked
/// for. That split is what lets the two option sets this app opens coexist —
/// `.visualization` at 20 Hz and `.hearing` at 5 — without either of them
/// advancing the model twice.
public final class SimulatedRobot: RobotStateStreaming, @unchecked Sendable {
    /// The daemon's own default (`routers/state.py`), and what a stream that names
    /// no frequency gets.
    public static let defaultFrequency = 10.0

    private struct Subscriber {
        let options: StateStreamOptions
        let continuation: AsyncStream<StateStreamUpdate>.Continuation
        let interval: Double
        var elapsed: Double
    }

    private let lock = NSLock()
    private var core: SimulatedRobotCore
    private var subscribers: [UUID: Subscriber] = [:]
    private var loop: Task<Void, Never>?

    private let tick: Duration
    private let tickSeconds: Double
    private let now: @Sendable () -> Date

    /// - Parameter tick: how often the pose is integrated. Faster than any stream
    ///   samples it, so the rate a subscriber sees is its own and not a beat
    ///   pattern against this one.
    public init(
        geometry: StewartGeometry,
        tick: Duration = .milliseconds(20),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        core = SimulatedRobotCore(geometry: geometry)
        self.tick = tick
        let parts = tick.components
        tickSeconds = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
        self.now = now
    }

    deinit {
        loop?.cancel()
    }

    /// Where the robot is right now — the value a test asserts on, and what the
    /// client reports when asked for one-shot state.
    public var pose: TeleopTarget {
        lock.withLock { core.pose }
    }

    /// Command it, exactly as `ws/set_target` would.
    public func aim(at target: TeleopTarget) {
        lock.withLock { core.aim(at: target) }
    }

    /// Ends every subscription and stops integrating.
    public func stop() {
        let (task, continuations) = lock.withLock {
            let task = loop
            loop = nil
            let continuations = subscribers.values.map(\.continuation)
            subscribers.removeAll()
            return (task, continuations)
        }
        task?.cancel()
        // Outside the lock: finishing a stream runs its `onTermination`, which
        // takes the same one.
        for continuation in continuations {
            continuation.finish()
        }
    }

    public func updates(_ options: StateStreamOptions) -> AsyncStream<StateStreamUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: StateStreamUpdate.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        let interval = 1 / max(options.frequency ?? Self.defaultFrequency, 0.001)
        lock.withLock {
            subscribers[id] = Subscriber(
                options: options,
                continuation: continuation,
                interval: interval,
                // Due immediately, so a subscriber's first frame costs one tick
                // rather than a whole period.
                elapsed: interval
            )
            startLoopLocked()
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    private func remove(_ id: UUID) {
        lock.withLock {
            subscribers[id] = nil
            if subscribers.isEmpty {
                loop?.cancel()
                loop = nil
            }
        }
    }

    /// Caller holds the lock.
    private func startLoopLocked() {
        guard loop == nil else { return }
        loop = Task { [weak self, tick] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled, let self else { return }
                step()
            }
        }
    }

    private func step() {
        let due: [(StateStreamUpdate, AsyncStream<StateStreamUpdate>.Continuation)] = lock.withLock {
            core.advance(by: tickSeconds)
            let timestamp = now()
            var due: [(StateStreamUpdate, AsyncStream<StateStreamUpdate>.Continuation)] = []
            for id in subscribers.keys {
                guard var subscriber = subscribers[id] else { continue }
                subscriber.elapsed += tickSeconds
                if subscriber.elapsed >= subscriber.interval {
                    subscriber.elapsed = 0
                    let frame = core.frame(at: timestamp, options: subscriber.options)
                    due.append((StateStreamUpdate(frame: frame), subscriber.continuation))
                }
                subscribers[id] = subscriber
            }
            return due
        }
        // Yielded outside the lock: a consumer resumed here must not be able to
        // re-enter this object while it is held.
        for (update, continuation) in due {
            continuation.yield(update)
        }
    }
}
