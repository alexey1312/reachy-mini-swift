import Foundation
import ReachyKit
import RealityKit

/// Drives the 3D robot: fetches its geometry, then mirrors the live state stream.
///
/// Read-only by construction — nothing here ever sends the robot a command.
@MainActor
@Observable
public final class RobotSceneModel {
    public enum Phase: Equatable {
        case idle
        case fetchingDescription
        case downloadingMeshes(completed: Int, total: Int)
        case buildingScene
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Updated at a couple of hertz, not per frame: a text label does not justify
    /// twenty SwiftUI invalidations a second.
    public private(set) var lastFrameAt: Date?
    public private(set) var streamDiagnostics = StateStreamDiagnostics()

    /// Stable across view updates, so `RealityView` never rebuilds its content.
    public let container = Entity()
    /// Owned here rather than by the view so a SwiftUI redraw cannot reset the
    /// angle the user just dragged to.
    public let camera = OrbitCamera()

    /// The head is also placed straight from the daemon's pose. The linkage
    /// algorithm points each rod correctly but never enforces its length, so
    /// driving the head directly keeps it exactly where the robot says it is.
    public var placesHeadDirectly = true
    /// Off shows the raw tree with every wrist at zero — useful for seeing what
    /// the solver is contributing.
    public var solvesPassiveJoints = true

    private let address: RobotAddress
    private let client: any RobotAPIClient
    private let cache: GeometryCache
    private var graph: RobotSceneGraph?
    private var solver: PassiveJointSolver?
    private var geometryTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var lastPublishedFrameAt: Date?

    public init(address: RobotAddress, client: any RobotAPIClient, cache: GeometryCache = .default) {
        self.address = address
        self.client = client
        self.cache = cache
        container.addChild(RobotSceneLighting.makeRig())
    }

    public func start() {
        guard geometryTask == nil else { return }
        geometryTask = Task { [weak self] in
            await self?.loadGeometry()
        }
    }

    public func stop() {
        geometryTask?.cancel()
        streamTask?.cancel()
        geometryTask = nil
        streamTask = nil
    }

    /// Drops the state stream but keeps the downloaded geometry, the entity tree
    /// and the camera angle. `stop()` would clear `geometryTask`, and `start()`
    /// guards on it being nil, so the pair would re-download and re-frame — the
    /// user would lose the angle they just dragged to every time they left the
    /// viewer or backgrounded the app.
    public func pauseStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// No-op until the scene is built: streaming into an empty tree is pointless,
    /// and `build(_:)` starts the stream itself once there is something to move.
    public func resumeStream() {
        guard phase == .ready else { return }
        startStreaming()
    }

    private func loadGeometry() async {
        let provider = RobotGeometryProvider(client: client, cache: cache)
        do {
            for try await step in await provider.load() {
                switch step {
                case .fetchingDescription:
                    phase = .fetchingDescription
                case let .downloadingMeshes(completed, total):
                    phase = .downloadingMeshes(completed: completed, total: total)
                case let .ready(geometry):
                    await build(geometry)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(Self.describe(error))
            // A failed load must not pin `geometryTask` for good: `start()`
            // guards on it, so leaving it set made the failure terminal — no
            // way back short of discarding the whole model.
            geometryTask = nil
        }
    }

    private func build(_ geometry: RobotGeometry) async {
        phase = .buildingScene
        let meshes = await MeshResourceFactory.makeAll(geometry.meshes)
        guard !Task.isCancelled else { return }
        // Derived from the description that was just downloaded, so the linkage is
        // solved — and the head placed — with this robot's dimensions rather than
        // assumed ones. Both consumers share the one derivation, so the rods cannot
        // point at a height the head is not drawn at.
        let stewart = StewartGeometry(urdf: geometry.urdf)
        solver = stewart.map(PassiveJointSolver.init)
        let graph = RobotSceneGraph(urdf: geometry.urdf, meshes: meshes, geometry: stewart)
        // A rebuild replaces the robot rather than stacking a second one on the
        // same container (the lighting rig stays — it is added once, in init).
        self.graph?.root.removeFromParent()
        self.graph = graph
        container.addChild(graph.root)
        // Framing has to wait for the meshes: before they exist the model has no
        // extent, and a camera aimed at an empty point ends up inside the robot.
        camera.frame(graph.visualBounds)
        phase = .ready
        startStreaming()
    }

    private func startStreaming() {
        guard streamTask == nil else { return }
        var configuration = StateStreamClient.Configuration()
        configuration.options = .visualization
        guard let client = try? StateStreamClient(address: address, configuration: configuration) else {
            phase = .failed("Could not open the state stream")
            return
        }
        streamTask = Task { [weak self] in
            for await update in client.updates() {
                guard let self else { break }
                consume(update)
            }
        }
    }

    /// Writes straight into the entity tree. Deliberately not routed through
    /// SwiftUI: at 20 Hz that would invalidate the view on every frame.
    private func consume(_ update: StateStreamUpdate) {
        guard let frame = update.frame else { return }
        graph?.apply(RobotJointState.resolve(frame, solver: solvesPassiveJoints ? solver : nil))
        if placesHeadDirectly {
            graph?.applyHeadPose(frame.headPose?.transform)
        }
        let now = Date()
        if lastPublishedFrameAt.map({ now.timeIntervalSince($0) > 0.5 }) ?? true {
            lastPublishedFrameAt = now
            lastFrameAt = now
            streamDiagnostics = update.diagnostics
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

#if DEBUG
    public extension RobotSceneModel {
        /// A model parked in one phase, with no geometry download and no state stream.
        ///
        /// `phase` and `lastFrameAt` are `private(set)`, so this has to live in the same file.
        /// Constructing the model is inert on its own — `start()` is what reaches the robot.
        static func preview(_ phase: Phase, lastFrameAt: Date? = nil) -> RobotSceneModel {
            let model = RobotSceneModel(
                address: RobotAddress(host: "192.168.1.42"),
                client: PreviewRobotClient()
            )
            model.phase = phase
            model.lastFrameAt = lastFrameAt
            return model
        }
    }
#endif
