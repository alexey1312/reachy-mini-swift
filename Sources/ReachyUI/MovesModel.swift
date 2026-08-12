import Foundation
import Observation
import ReachyDesign
import ReachyKit
import ReachyWidgetUI

@MainActor
@Observable
final class MovesModel {
    /// The libraries live in `ReachyWidgetUI` because `MoveEntityQuery` needs them
    /// too, and an extension cannot link this target. One declaration, two readers
    /// — the move `AppArtwork` made before it.
    typealias Library = MoveLibrary

    static let libraries = MoveLibrary.all

    var selection = 0 {
        didSet {
            guard Self.libraries.indices.contains(selection) else { return }
            let dataset = selectedLibrary.dataset
            if movesByDataset[dataset] == nil {
                // `.task(id:)` will retry this uncached library. Mark it pending now so
                // the frame drawn for the picker change cannot say "No moves" first.
                attemptedDatasets.remove(dataset)
            }
        }
    }

    private(set) var startingMove = false
    /// Why the last library fetch, playback or stop refused.
    ///
    /// Owned here rather than read off the session: a move that would not play is
    /// this screen's news, and `RobotSession.robotError` is for the robot's
    /// connection and power alone. `RobotSession.message(for:)` is what fills it,
    /// so a cancelled fetch — the user leaving the tab — says nothing at all.
    private(set) var lastError: String?
    /// Keyed by dataset rather than held as one array: `selection` changes a frame before
    /// `.task(id:)` gets to run, so a shared array leaves the previous library's rows under
    /// the newly selected tab for as long as the fetch takes.
    private var movesByDataset: [String: [String]] = [:]
    private var loadingDataset: String?
    /// An absent result starts as loading, but after a failed request it must become
    /// an actionable error instead of an infinite spinner. A later visit still retries.
    private var attemptedDatasets: Set<String> = []
    /// Libraries that came off disk and the robot has not confirmed yet. The
    /// per-dataset twin of `AppStoreModel.catalogueIsWarmed`, and it has to be per
    /// dataset because the user may open one library and never the others.
    private var warmedDatasets: Set<String> = []
    private var loadID: UUID?

    /// Seeded from what `RobotSession.warmCatalogues` read off disk during the
    /// handshake — before the connect gate lifted and before this model existed.
    /// `.task` runs after the first frame, so a model that read the cache itself
    /// would still draw one spinner.
    ///
    /// `nil` is the session-less form every test and preview builds.
    init(session: RobotSession? = nil) {
        guard let session else { return }
        for library in Self.libraries {
            guard let cached = session.cachedMoves(in: library.dataset) else { continue }
            movesByDataset[library.dataset] = cached
            attemptedDatasets.insert(library.dataset)
            warmedDatasets.insert(library.dataset)
        }
    }

    var selectedLibrary: Library {
        Self.libraries[selection]
    }

    /// Derived from `selection`, so the rows can never belong to another library.
    var moves: [String] {
        movesByDataset[selectedLibrary.dataset] ?? []
    }

    var loading: Bool {
        loadingDataset == selectedLibrary.dataset
    }

    /// Unlike `loading`, this only replaces an empty content area. A refresh of rows
    /// already on screen is deliberately non-blocking.
    var isContentLoading: Bool {
        movesByDataset[selectedLibrary.dataset] == nil
            && (loading || !attemptedDatasets.contains(selectedLibrary.dataset))
    }

    /// Whether a row may be tapped.
    ///
    /// Lives here rather than in the view because it is a rule about the robot,
    /// not about layout, and because every phase in it was found the same way: the
    /// daemon's `_try_start_move` refuses a play without saying so and hands back
    /// a fresh UUID, so a row left live over a busy robot puts a dance on screen
    /// that never started. Browsing the library stays available throughout —
    /// only playing needs the robot.
    ///
    /// Playing is deliberately *not* in the list: picking another move while one
    /// runs is how you change dance, and `playMove` clears the floor first.
    func rowsAreEnabled(_ session: RobotSession) -> Bool {
        !startingMove && !session.isStoppingMove && !session.isRecentring && session.isAwake
    }

    /// Fetches the selected library, and over warmed rows does it silently — the
    /// reasoning is `AppStoreModel.load`'s, down to which slot may be written.
    func load(session: RobotSession, refresh: Bool = false) async {
        let dataset = selectedLibrary.dataset
        let silent = warmedDatasets.contains(dataset) && !refresh
        // A library fetched earlier this session is already on screen; entering the loading
        // state for it would only replace those rows with a spinner and put them back.
        // A warmed one is the exception: it is on screen and still owed a fetch.
        if !refresh, !silent, movesByDataset[dataset] != nil {
            return
        }
        let requestID = UUID()
        loadID = requestID
        loadingDataset = dataset
        defer {
            if loadID == requestID {
                loadingDataset = nil
            }
        }
        do {
            // Forced over a warmed library for `AppStoreModel.load`'s reason: the
            // session holds the same index, so without it the robot is never asked.
            let loaded = try await session.moves(in: dataset, refresh: refresh || silent)
            guard !Task.isCancelled, loadID == requestID else { return }
            movesByDataset[dataset] = loaded
            attemptedDatasets.insert(dataset)
            warmedDatasets.remove(dataset)
            if !silent {
                lastError = nil
            }
        } catch {
            guard !Task.isCancelled, loadID == requestID else { return }
            attemptedDatasets.insert(dataset)
            // `movesByDataset` is deliberately left alone. An absent key means "never
            // fetched", so the next visit to the tab retries, and a failed refresh leaves
            // the rows already on screen in place rather than clearing them over one bad
            // round trip. A stored `[]` is then a library the daemon really answered as
            // empty, which is not worth retrying. Only the reason is recorded — and a
            // silent revalidation records nothing at all, keeping `warmedDatasets` so
            // the next visit tries again.
            if !silent {
                report(error)
            }
        }
    }

    func play(_ move: String, session: RobotSession) async {
        startingMove = true
        defer { startingMove = false }
        do {
            try await session.playMove(dataset: selectedLibrary.dataset, move: move)
            lastError = nil
        } catch {
            report(error)
        }
    }

    /// The two daemon tasks are stopped in parallel and both are seen through, so
    /// `stopMove` answers with a list rather than throwing one of them. Joined the
    /// way the session used to join it, now on the side that owns the screen.
    func stop(session: RobotSession) async {
        let failures = await session.stopMove()
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// `nil` is a cancelled call — the user left the tab — and leaves whatever is
    /// on screen standing rather than replacing it with the word "cancelled".
    private func report(_ error: any Error) {
        lastError = RobotSession.message(for: error) ?? lastError
    }

    static func displayName(_ move: String) -> String {
        MoveLibrary.displayName(move)
    }
}

#if DEBUG
    extension MovesModel {
        /// Lives here rather than in `Previews/`: `moves` and `loading` are `private(set)`, which
        /// `@testable` does not reach from another module.
        static func preview(
            moves: [String] = MovesModel.previewMoves,
            selection: Int = 0,
            loading: Bool = false,
            startingMove: Bool = false,
            error: String? = nil
        ) -> MovesModel {
            let model = MovesModel()
            model.selection = selection
            if loading {
                model.loadingDataset = model.selectedLibrary.dataset
                if !moves.isEmpty {
                    model.movesByDataset[model.selectedLibrary.dataset] = moves
                    model.attemptedDatasets.insert(model.selectedLibrary.dataset)
                }
            } else {
                model.movesByDataset[model.selectedLibrary.dataset] = moves
                model.attemptedDatasets.insert(model.selectedLibrary.dataset)
            }
            model.startingMove = startingMove
            model.lastError = error
            // A preview is the state it was handed, never a debt to a robot.
            model.warmedDatasets = []
            return model
        }

        static let previewMoves = [
            "happy_dance", "head_shake", "look_around", "nod_yes", "sad_slump", "wave_hello",
        ]
    }
#endif
