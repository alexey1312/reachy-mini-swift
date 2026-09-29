import Foundation
import ReachyDesign
import ReachyKit

/// What the robot screen says about a daemon it cannot vouch for.
///
/// `DaemonCompatibility` used to carry its own English sentence with both versions
/// interpolated into it, which put it out of the catalogue's reach twice over:
/// `ReachyKit` links no catalogue, and a key that interpolates is one the catalogue
/// deliberately leaves out. So the sentence is a plain key and the version stands
/// beside it as a value. Only the tested one: the robot's own is already on the
/// screen as "Software version".
enum DaemonCompatibilityCaption {
    struct Warning {
        let message: LocalizedStringResource
        /// Shown beside the message where there is a comparison to make.
        let testedVersion: String?
    }

    /// Nil where there is nothing to warn about — and for an unsupported daemon,
    /// which never reaches the robot screen: the session halts on it and the update
    /// screen explains it instead.
    static func warning(for compatibility: DaemonCompatibility?) -> Warning? {
        switch compatibility {
        case nil, .supported, .unsupported:
            nil
        case let .untestedNewer(_, tested):
            Warning(
                message: .reachy(
                    "This robot's software is newer than this app was tested with. Some features may not work."
                ),
                testedVersion: tested
            )
        case .unknown:
            Warning(
                message: .reachy(
                    "This robot didn't report a software version this app can read. Some features may not work."
                ),
                testedVersion: nil
            )
        }
    }
}
