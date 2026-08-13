import Foundation
import ReachyDesign
import ReachyKit

/// What the store shows and in what order. Separate from `AppStoreModel` because
/// that file is already near SwiftLint's type and file limits.
extension AppStoreModel {
    /// Scopes are questions, not buckets: a private community Space answers both
    /// `.community` and `.private`. Partitioning them instead would hide such a
    /// Space from a reader who asked for community apps, which is the more
    /// surprising of the two ways to be wrong.
    enum Scope: Int, CaseIterable, Identifiable {
        case all
        case official
        case community
        case privateSpaces

        var id: Int {
            rawValue
        }

        var title: LocalizedStringResource {
            switch self {
            case .all: .reachy("All apps")
            case .official: .reachy("Official")
            case .community: .reachy("Community")
            case .privateSpaces: .reachy("Private")
            }
        }

        /// The same two symbols the row badges use, so the menu and the list agree
        /// about what a seal and a lock mean.
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .official: "checkmark.seal"
            case .community: "person.2"
            case .privateSpaces: "lock"
            }
        }

        func admits(_ app: RobotApp) -> Bool {
            switch self {
            case .all: true
            case .official: app.isOfficial
            case .community: !app.isOfficial
            case .privateSpaces: app.isPrivate
            }
        }
    }

    enum Sort: Int, CaseIterable, Identifiable {
        /// The daemon's own order, untouched. `list_all_available_apps` puts the
        /// curated `app-list.json` entries ahead of the rest and nothing else in
        /// the payload records that — re-sorting by default would throw away the
        /// only editorial signal the store has.
        case recommended
        case name
        case author
        case likes
        case published
        case updated

        var id: Int {
            rawValue
        }

        var title: LocalizedStringResource {
            switch self {
            case .recommended: .reachy("Recommended")
            case .name: .reachy("Name")
            case .author: .reachy("Author")
            case .likes: .reachy("Most liked")
            case .published: .reachy("Newest")
            case .updated: .reachy("Recently updated")
            }
        }

        var symbol: String {
            switch self {
            case .recommended: "sparkles"
            case .name: "textformat"
            case .author: "person"
            case .likes: "heart"
            case .published: "calendar.badge.plus"
            case .updated: "clock.arrow.circlepath"
            }
        }

        func applied(to apps: [RobotApp]) -> [RobotApp] {
            guard self != .recommended else { return apps }
            return apps.sorted { primary($0, $1) ?? Self.tieBreak($0, $1) }
        }

        /// `nil` when the two apps are equal on this sort's own key.
        private func primary(_ lhs: RobotApp, _ rhs: RobotApp) -> Bool? {
            switch self {
            case .recommended, .name:
                nil
            case .author:
                Self.ordered(lhs.author, rhs.author) { $0.localizedStandardCompare($1) == .orderedAscending }
            case .likes:
                Self.ordered(lhs.likes, rhs.likes) { $0 > $1 }
            case .published:
                Self.ordered(lhs.publishedAt, rhs.publishedAt) { $0 > $1 }
            case .updated:
                Self.ordered(lhs.updatedAt, rhs.updatedAt) { $0 > $1 }
            }
        }

        /// A missing value sorts last whichever way the key runs: an app the Hub
        /// told us nothing about is neither the newest nor the most liked. An
        /// installed app that lost its metadata is exactly that case.
        private static func ordered<T: Equatable>(_ lhs: T?, _ rhs: T?, by leads: (T, T) -> Bool) -> Bool? {
            switch (lhs, rhs) {
            case let (lhs?, rhs?): lhs == rhs ? nil : leads(lhs, rhs)
            case (nil, nil): nil
            case (_?, nil): true
            case (nil, _?): false
            }
        }

        /// `sorted(by:)` is not stable, so equal keys need a total order of their
        /// own — otherwise two apps with the same author swap places between
        /// redraws of a list nobody touched.
        private static func tieBreak(_ lhs: RobotApp, _ rhs: RobotApp) -> Bool {
            switch lhs.title.localizedStandardCompare(rhs.title) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }
}
