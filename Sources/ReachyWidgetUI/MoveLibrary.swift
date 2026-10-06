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

    /// Recordings this app does not offer, by dataset.
    ///
    /// Both carry bursts of frames that share one timestamp — 574 in Thriller and
    /// 838 in We Will Rock You. The daemon's `RecordedMove.evaluate` sets alpha to
    /// 0 between two equal timestamps, so the head snaps across a burst instead of
    /// easing through it: up to 27.5° in 10 ms. Their twins without "official" in
    /// the name hold one or two such bursts and stay in the library.
    static let withheld: [String: Set<String>] = [
        "Anne-Charlotte/music": [
            "michael-jackson-thriller-official-video-shortene",
            "queen-we-will-rock-you-official",
        ],
    ]

    /// The moves a person is offered out of what the robot listed, in its order.
    ///
    /// Every list a person picks from goes through this: the Moves screen, the
    /// Shortcuts and widget pickers, Siri's match and the Spotlight index. A saved
    /// shortcut still resolves by its identifier, which names the move outright.
    public static func offered(_ moves: [String], in dataset: String) -> [String] {
        guard let withheld = withheld[dataset] else { return moves }
        return moves.filter { !withheld.contains($0) }
    }

    /// The only title a move has. The daemon answers with file stems —
    /// `happy_dance`, `sad2` — and there is no metadata behind them anywhere.
    public static func displayName(_ move: String) -> String {
        let words = move.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
