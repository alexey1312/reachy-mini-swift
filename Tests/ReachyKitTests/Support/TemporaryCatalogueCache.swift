import Foundation
@testable import ReachyKit

/// A catalogue cache on a directory of its own, removed afterwards.
///
/// Injected the way `RobotAppsCacheStore` is given a `UserDefaults` suite, and for
/// a stronger version of the same reason: `--parallel` runs suites concurrently,
/// and a file system is one table every one of them shares.
func withTemporaryCatalogueCache<T>(
    _ body: (RobotCatalogueCache) async throws -> T
) async rethrows -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RobotCatalogueCacheTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(RobotCatalogueCache(root: root))
}
