import Foundation
@testable import ReachyKit

/// A catalogue cache on a directory of its own, removed afterwards.
///
/// Injected the way `RobotAppsCacheStore` is given a `UserDefaults` suite, and for
/// a stronger version of the same reason: `--parallel` runs suites concurrently,
/// and a file system is one table every one of them shares.
///
/// `isolation` is what lets a `@MainActor` suite hand in a closure that touches
/// its session: without it the body is a main-actor-isolated value crossing into
/// a nonisolated function, which Swift 6 refuses as a sending risk.
func withTemporaryCatalogueCache<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (RobotCatalogueCache) async throws -> T
) async rethrows -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RobotCatalogueCacheTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(RobotCatalogueCache(root: root))
}
