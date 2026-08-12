import Foundation
import ReachyDesign

/// One recorded-move dataset the robot can be asked for.
///
/// **Client-side, and there is nothing on the daemon to read it from.**
/// `move/recorded-move-datasets/list/{dataset}` lists the moves *inside* a
/// dataset; no route lists the datasets themselves, so which libraries exist is a
/// decision this app makes and Pollen publishes against.
///
/// It lives here rather than beside the Moves screen because both surfaces need
/// it now: the screen draws a picker out of it, and `MoveEntityQuery` — running in
/// an extension that cannot link `ReachyUI` — has to know which datasets to look
/// for in the cache. Same move down that `AppArtwork` made.
public struct MoveLibrary: Sendable, Equatable, Identifiable {
    public let title: LocalizedStringResource
    public let dataset: String
    /// What the Moves screen says while the library is on its way. Unused by the
    /// intents, and kept here anyway so a library is one declaration rather than
    /// two halves in two targets.
    public let loadingTitle: LocalizedStringResource

    public var id: String {
        dataset
    }

    public init(title: LocalizedStringResource, dataset: String, loadingTitle: LocalizedStringResource) {
        self.title = title
        self.dataset = dataset
        self.loadingTitle = loadingTitle
    }

    public static let all: [MoveLibrary] = [
        MoveLibrary(
            title: .reachy("Dances"),
            dataset: "pollen-robotics/reachy-mini-dances-library",
            loadingTitle: .reachy("Teaching the servos new steps…")
        ),
        MoveLibrary(
            title: .reachy("Emotions"),
            dataset: "pollen-robotics/reachy-mini-emotions-library",
            loadingTitle: .reachy("Calibrating robot feelings…")
        ),
        MoveLibrary(
            title: .reachy("Music"),
            dataset: "Anne-Charlotte/music",
            loadingTitle: .reachy("Warming up the tiny speakers…")
        ),
    ]

    public static func named(_ dataset: String) -> MoveLibrary? {
        all.first { $0.dataset == dataset }
    }

    /// The only title a move has. The daemon answers with file stems —
    /// `happy_dance`, `sad2` — and there is no metadata behind them anywhere.
    public static func displayName(_ move: String) -> String {
        move.replacingOccurrences(of: "_", with: " ")
    }
}
