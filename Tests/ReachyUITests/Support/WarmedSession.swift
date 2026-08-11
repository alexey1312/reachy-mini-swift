import Foundation
import ReachyKit
import Testing

/// A pair of sessions over one throwaway catalogue cache: the first fills the
/// disk the way a real visit to the Apps or Moves tab does, the second is what a
/// cold start gets.
///
/// Built through the public seam rather than by writing into the session, so what
/// these tests exercise is the path production takes — `RobotSession.init`'s
/// `catalogues`, the write on the way out of `appCatalogue`/`moves`, and
/// `warmCatalogues` on the way back in.
/// `@MainActor` rather than isolation-inheriting, unlike its `ReachyKit` sibling:
/// `RobotSession` is main-actor isolated and every suite here already is too, and
/// a global function cannot carry both a global actor and an `isolated` parameter.
@MainActor
func withWarmedSession<T>(
    client: any RobotAPIClient,
    fill: (RobotSession) async throws -> Void,
    body: (RobotSession) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReachyUITests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = RobotCatalogueCache(root: root)
    // A table of its own, for the reason `AppSessionStores` has one: connecting
    // writes a snapshot, disconnecting clears it, and the defaults these two
    // stores fall back to are the App Group's — one table shared by every suite
    // `--parallel` is running at the same time.
    let defaults = try #require(UserDefaults(suiteName: "ReachyUITests.\(UUID().uuidString)"))
    let stores = (
        snapshots: RobotSnapshotStore(defaults: defaults),
        apps: RobotAppsCacheStore(defaults: defaults)
    )

    let first = RobotSession(snapshots: stores.snapshots, appsCache: stores.apps, catalogues: cache) { _ in client }
    #expect(await first.connect(to: .init(host: "127.0.0.1")))
    try await fill(first)
    first.disconnect()

    let warmed = RobotSession(snapshots: stores.snapshots, appsCache: stores.apps, catalogues: cache) { _ in client }
    #expect(await warmed.connect(to: .init(host: "127.0.0.1")))
    defer { warmed.disconnect() }
    return try await body(warmed)
}
