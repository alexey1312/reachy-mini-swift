import AppIntents
import CoreSpotlight
import Foundation
import ReachyDesign
import UniformTypeIdentifiers

/// What Spotlight is handed about an app and a move.
///
/// **A fourth system beside the three `ReachyUI/AGENTS.md` already names.** App
/// Shortcuts put *commands* in Spotlight, `ReachyQuickAction` fills the Home Screen
/// icon's menu, and `ReachySpotlightIndex` files two *destinations*. This files the
/// **entities themselves**, which is the one that makes searching for a dance offer
/// to play it: an indexed `AppEntity` carries its type with it, so Spotlight can
/// pair a row with the intents that take that type — `PlayMoveIntent` for a move,
/// `StartRobotAppIntent` for an app. A destination row can only ever open a tab.
///
/// `IndexedEntity` is iOS 18 / macOS 15, which is this app's floor exactly
/// (`RealityView` set it), so nothing here needs an availability guard.
///
/// The default `attributeSet` derives title and subtitle from
/// `displayRepresentation` and stops there. Both are overridden for the keywords:
/// an entry point (`dance_party`) and a display name ("Dance Party") are the two
/// spellings a person might reach for, and only one of them is the title.
extension RobotAppEntity: IndexedEntity {
    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = isInstalled
            ? String(localized: .reachy("An app installed on your Reachy Mini."))
            : String(localized: .reachy("An app for your Reachy Mini. Not installed."))
        // The entry point is in here rather than in the title because it is not a
        // name anybody chose — but `dance_party` is what the robot's own logs and
        // the daemon's status call this, so somebody who has read either will type
        // it.
        attributes.keywords = ReachyEntityKeywords.list(
            title,
            name,
            String(localized: .reachy("robot app, app, Reachy Mini"))
        )
        attributes.alternateNames = attributes.keywords
        return attributes
    }
}

extension MoveEntity: IndexedEntity {
    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.displayName = title
        // The library, so "Happy" from Emotions and "Happy" from Dances are two
        // rows a person can tell apart — the same job the subtitle does in the
        // picker. A dataset the app does not know is named as the robot spells it.
        // `MoveLibrary.title` is a `LocalizedStringResource`; a keyword list and a
        // description are both `String`, so it is resolved once here.
        let library = MoveLibrary.named(dataset).map { String(localized: $0.title) } ?? dataset
        attributes.contentDescription = String(localized: .reachy("A move from \(library)."))
        // `move` is the file stem (`happy_dance`); `title` is the spoken form. Both,
        // for the reason `MoveEntityQuery.entities(matching:)` matches on the second.
        attributes.keywords = ReachyEntityKeywords.list(
            title,
            move,
            library,
            String(localized: .reachy("move, dance, animation, Reachy Mini"))
        )
        attributes.alternateNames = attributes.keywords
        return attributes
    }
}

/// One place that turns names into search terms, because both entities want the
/// same treatment and a second copy would drift.
enum ReachyEntityKeywords {
    /// Every word a reader might reach for, deduplicated case-insensitively while
    /// keeping the order — the same rule `ReachySpotlightIndex.keywords(appName:)`
    /// follows, and for the same reason: a one-word name must not go in twice.
    ///
    /// Each argument is split two ways: kept whole, and split on whitespace,
    /// underscores and hyphens. That is what puts `dance` in the index as a term of
    /// its own for an app called `dance_party`, which is a token no amount of
    /// prefix matching would otherwise reach.
    ///
    /// A comma-separated argument is treated as a list, so the one catalogue string
    /// each caller passes is replaced wholesale by a translator rather than
    /// translated word for word — the words somebody would type are not a
    /// translation of these words, and there are not necessarily this many of them.
    static func list(_ terms: String...) -> [String] {
        var seen = Set<String>()
        return terms
            .flatMap(split(_:))
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func split(_ term: String) -> [String] {
        let pieces = term.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let words = pieces.flatMap { piece in
            piece
                .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
                .map(String.init)
        }
        return pieces + words
    }
}
