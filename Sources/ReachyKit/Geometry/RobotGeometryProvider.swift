import Foundation

/// A robot description plus every mesh it draws.
public struct RobotGeometry: Sendable {
    public let urdf: URDFDocument
    public let digest: String
    public let meshes: [String: STLMesh]

    public init(urdf: URDFDocument, digest: String, meshes: [String: STLMesh]) {
        self.urdf = urdf
        self.digest = digest
        self.meshes = meshes
    }
}

public enum GeometryLoadProgress: Sendable, Equatable {
    case fetchingDescription
    case downloadingMeshes(completed: Int, total: Int)
    case ready(RobotGeometry)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.fetchingDescription, .fetchingDescription):
            true
        case let (.downloadingMeshes(a, b), .downloadingMeshes(c, d)):
            a == c && b == d
        case let (.ready(lhs), .ready(rhs)):
            lhs.digest == rhs.digest
        default:
            false
        }
    }
}

/// Fetches the robot's own geometry and keeps a copy on disk.
///
/// Nothing is bundled with the app: the description comes from the machine in
/// front of the user, so a hardware revision or a differently coloured shell is
/// drawn correctly without shipping anyone else's assets.
public actor RobotGeometryProvider {
    private let client: any RobotGeometryClient
    private let cache: GeometryCache
    /// The robot's Wi-Fi is the slow link here; a handful of parallel requests
    /// saturates it without starving the state stream sharing the connection.
    private let concurrentDownloads = 4

    public init(client: any RobotGeometryClient, cache: GeometryCache = .default) {
        self.client = client
        self.cache = cache
    }

    public func load() -> AsyncThrowingStream<GeometryLoadProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(reporting: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        reporting continuation: AsyncThrowingStream<GeometryLoadProgress, any Error>.Continuation
    ) async throws {
        continuation.yield(.fetchingDescription)
        let xml = try await client.urdf()
        let digest = GeometryCache.digest(of: xml)
        let document = try URDFParser.parse(xml)
        try cache.store(urdf: xml, digest: digest)

        let wanted = document.visualMeshFilenames.sorted()
        var meshes: [String: STLMesh] = [:]
        var completed = 0
        continuation.yield(.downloadingMeshes(completed: 0, total: wanted.count))

        for chunk in wanted.chunked(into: concurrentDownloads) {
            try Task.checkCancellation()
            let loaded = try await withThrowingTaskGroup(of: (String, STLMesh).self) { group in
                for name in chunk {
                    group.addTask { try await (name, self.mesh(named: name, digest: digest)) }
                }
                var result: [String: STLMesh] = [:]
                for try await (name, mesh) in group {
                    result[name] = mesh
                }
                return result
            }
            meshes.merge(loaded) { _, new in new }
            completed += chunk.count
            continuation.yield(.downloadingMeshes(completed: completed, total: wanted.count))
        }

        try cache.finalize(digest: digest, meshes: wanted)
        cache.removeEntries(keeping: digest)
        continuation.yield(.ready(RobotGeometry(urdf: document, digest: digest, meshes: meshes)))
    }

    private func mesh(named name: String, digest: String) async throws -> STLMesh {
        if let cached = cache.storedMesh(digest: digest, named: name),
           let mesh = try? STLDecoder.decode(cached)
        {
            return mesh
        }
        let data = try await client.stlAsset(named: name)
        let mesh = try STLDecoder.decode(data)
        // Only cache what decoded: a corrupt download must not become a permanent
        // cache entry that fails identically on every launch.
        try? cache.store(mesh: data, digest: digest, named: name)
        return mesh
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
