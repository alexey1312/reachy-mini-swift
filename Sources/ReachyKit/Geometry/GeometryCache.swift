import CryptoKit
import Foundation

/// On-disk store for one robot's URDF and meshes.
///
/// Entries are keyed by a digest of the URDF text rather than by robot identity
/// or daemon version. A hardware id is null on the simulator, and the daemon
/// version does not change when the description does — but the digest changes
/// exactly when the geometry does, so staleness cannot happen.
///
/// Everything here is recoverable from the robot, which is why it lives in
/// `Caches` and may be evicted by the system at any time.
public struct GeometryCache: Sendable {
    private let root: URL
    /// `FileManager` is not `Sendable`, so it is reached for per call rather than
    /// stored — `.default` is documented as safe to use from any thread.
    private var fileManager: FileManager {
        .default
    }

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: GeometryCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return GeometryCache(root: caches.appendingPathComponent("ReachyMini/geometry", isDirectory: true))
    }

    public static func digest(of urdf: String) -> String {
        SHA256.hash(data: Data(urdf.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Layout

    private func directory(for digest: String) -> URL {
        root.appendingPathComponent(digest, isDirectory: true)
    }

    private func urdfURL(for digest: String) -> URL {
        directory(for: digest).appendingPathComponent("robot.urdf")
    }

    private func meshURL(for digest: String, mesh: String) -> URL {
        directory(for: digest)
            .appendingPathComponent("meshes", isDirectory: true)
            .appendingPathComponent(mesh)
    }

    /// Written last, so its presence means the entry is complete. Without it a
    /// download interrupted halfway would look like a usable cache.
    private func manifestURL(for digest: String) -> URL {
        directory(for: digest).appendingPathComponent("manifest.json")
    }

    // MARK: - Reading

    public func isComplete(digest: String) -> Bool {
        fileManager.fileExists(atPath: manifestURL(for: digest).path)
    }

    public func storedURDF(digest: String) -> String? {
        try? String(contentsOf: urdfURL(for: digest), encoding: .utf8)
    }

    public func storedMesh(digest: String, named mesh: String) -> Data? {
        guard Self.isSafeMeshName(mesh) else { return nil }
        return try? Data(contentsOf: meshURL(for: digest, mesh: mesh))
    }

    // MARK: - Writing

    public func store(urdf: String, digest: String) throws {
        try fileManager.createDirectory(
            at: directory(for: digest).appendingPathComponent("meshes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write(Data(urdf.utf8), to: urdfURL(for: digest))
    }

    public func store(mesh: Data, digest: String, named name: String) throws {
        guard Self.isSafeMeshName(name) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try write(mesh, to: meshURL(for: digest, mesh: name))
    }

    /// Mesh names come out of the robot-served URDF, and the daemon is
    /// unauthenticated plaintext on the LAN — "the robot" is whoever answered
    /// first. A name carrying a path separator or `..` would escape the cache
    /// directory on write, so it is refused rather than resolved.
    static func isSafeMeshName(_ name: String) -> Bool {
        !name.isEmpty && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    public func finalize(digest: String, meshes: [String]) throws {
        try write(JSONEncoder().encode(meshes.sorted()), to: manifestURL(for: digest))
    }

    /// Replaces atomically: a partial file left by a cancelled download would
    /// otherwise survive restarts and decode into garbage.
    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Drops every entry other than the one in use.
    public func removeEntries(keeping digest: String) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent != digest {
            try? fileManager.removeItem(at: entry)
        }
    }
}
