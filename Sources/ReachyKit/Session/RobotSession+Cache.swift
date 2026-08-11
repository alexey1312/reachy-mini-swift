import Foundation

/// What survives the app being unloaded: the app catalogue and the recorded-move
/// index, read back before the first screen that wants them exists.
///
/// A file of its own for the reason `RobotSession+Apps` and `RobotSession+Moves`
/// are — `RobotSession` is at SwiftLint's length limit.
extension RobotSession {
    /// The catalogues this session can show without asking the robot anything.
    ///
    /// Synchronous on purpose: a screen's first frame cannot `await`, which is the
    /// whole point of warming these before `.connected`.
    public var cachedAppCatalogue: [RobotApp]? {
        appCatalogueCache
    }

    public func cachedMoves(in dataset: String) -> [String]? {
        moveCache[dataset]
    }

    /// Fills the in-memory catalogues from disk, during the handshake and before
    /// the gate comes down.
    ///
    /// Here rather than in `finishConnected` because that one is synchronous — and
    /// here rather than in the screens because a `.task` runs *after* the first
    /// frame, so a model reading disk itself would still show a spinner for one
    /// pass. One file read against `readinessTimeout`'s eight seconds.
    func warmCatalogues(for identity: RobotIdentity, attemptID: UUID) async {
        guard let catalogues else { return }
        let robotID = identity.deduplicationKey
        async let apps = catalogues.record(RobotAppCatalogueRecord.self, for: robotID)
        async let moves = catalogues.record(RobotMoveIndexRecord.self, for: robotID)
        let (catalogue, index) = await (apps, moves)
        // An attempt that was superseded while the disk answered may not write into
        // the session — the same guard every other awaited step in `settle` takes.
        guard isAttemptLive(attemptID) else { return }
        if let catalogue, appCatalogueCache == nil {
            appCatalogueCache = catalogue.apps
        }
        if let index, moveCache.isEmpty {
            moveCache = index.movesByDataset
        }
        Task { await catalogues.evict(keeping: robotID) }
    }

    /// Rides the call the app was already making, so it costs the robot nothing —
    /// the same arrangement `recordInstalled` has with the widget's cache.
    ///
    /// **Awaited rather than spawned**, and this is the difference between a cache
    /// and a lottery: an install invalidates the record through `forget`, and two
    /// detached `Task`s against one actor have no order between them, so a
    /// revalidation still in flight could land its pre-install list *after* the
    /// deletion meant to remove it. Awaiting puts every store call in the order the
    /// session made them. It costs a suspension, not a block — the encode happens
    /// on the actor, and the main actor is free while it does.
    func persistCatalogue(_ apps: [RobotApp]) async {
        // An empty list is what a daemon mid-restart reports. Keep the last
        // identity-bound answer until a real one replaces it, exactly as
        // `recordInstalled` does.
        guard !apps.isEmpty, let catalogues, let robotID = connectedRobotID else { return }
        await catalogues.write(RobotAppCatalogueRecord(robotID: robotID, apps: apps))
    }

    /// Writes every library listed so far, not the one just fetched: the record is
    /// one file, and a partial rewrite would drop the libraries the user has not
    /// visited this session.
    func persistMoveIndex() async {
        guard !moveCache.isEmpty, let catalogues, let robotID = connectedRobotID else { return }
        await catalogues.write(RobotMoveIndexRecord(robotID: robotID, movesByDataset: moveCache))
    }

    /// Deletes the stored catalogue rather than letting it age out.
    ///
    /// "The robot's app list as of the moment it started changing" is not old, it
    /// is **wrong** — `source_kind` is what the job is in the middle of moving. A
    /// force-quit mid-install would otherwise warm a catalogue offering Install for
    /// something already there. The cost is one Hugging Face round trip on the next
    /// connection, which is what happens today anyway.
    ///
    /// Not called on disconnect, unlike `RobotSnapshotStore.clear` and for the
    /// reason written over `RobotAppsCacheStore.clear`: a cache that dies when a
    /// robot is let go does not survive a cold start, which is the only thing it is
    /// for.
    func forgetPersistedCatalogue() async {
        guard let catalogues, let robotID = connectedRobotID else { return }
        await catalogues.remove(.apps, for: robotID)
    }

    /// The identity behind the current phase, or `nil` while there is none.
    ///
    /// One copy: `RobotSession+Apps` and `RobotSession+Moves` each had a private
    /// version of this, which is the same thought written twice.
    var connectedIdentity: RobotIdentity? {
        switch phase {
        case let .connected(identity), let .unreachable(identity): identity
        case .idle, .connecting: nil
        }
    }

    var connectedRobotID: String? {
        connectedIdentity?.deduplicationKey
    }
}
