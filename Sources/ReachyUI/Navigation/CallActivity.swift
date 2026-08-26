import Foundation
#if os(iOS)
    import Intents
#endif

/// The sixth entry-point system, beside App Shortcuts, `ReachyQuickAction`,
/// `ReachySpotlightIndex`, `ReachyEntityIndex` and `ReachyHandoff` — and the
/// only one the *Phone app* drives. Each call started through
/// `RobotCallController` donates an `INStartCallIntent`, which is what gives a
/// Recents row its redial and Siri its suggestion; tapping that row relaunches
/// this app with the intent wrapped in an `NSUserActivity`, and
/// `RootCallLifecycle` turns it back into a `CallRequestInbox` entry.
///
/// `#if os(iOS)` is a platform fork, not a version gate: LiveCommunicationKit —
/// the framework whose Recents these donations serve — is macOS-unavailable
/// outright, so there is nothing on macOS for a donation to feed.
public enum CallActivity {
    /// The class name of `INStartCallIntent`, which is the activity type the
    /// system delivers a Recents redial under. Copied, never retyped — it is
    /// declared a second time in `Apps/Project.swift`'s `NSUserActivityTypes`,
    /// and `CallProjectLockstepTests` holds the pair together.
    public static let activityType = "INStartCallIntent"

    #if os(iOS)
        /// Donates "the user called this robot", so Recents and Siri can offer
        /// it back. The handle's value is the robot's `deduplicationKey` (rule
        /// 4: identity, never an address); the display name is what the
        /// Recents row shows.
        static func donate(robotID: String, robotName: String?) {
            let handle = INPersonHandle(value: robotID, type: .unknown)
            let person = INPerson(
                personHandle: handle,
                nameComponents: nil,
                displayName: robotName,
                image: nil,
                contactIdentifier: nil,
                customIdentifier: robotID
            )
            let intent = INStartCallIntent(
                callRecordFilter: nil,
                callRecordToCallBack: nil,
                audioRoute: .unknown,
                destinationType: .normal,
                contacts: [person],
                callCapability: .videoCall
            )
            INInteraction(intent: intent, response: nil).donate(completion: nil)
        }

        /// The robot a Recents redial names, out of the relaunch activity —
        /// `nil` for an activity that is not a start-call intent at all.
        static func robotID(from activity: NSUserActivity) -> String? {
            guard let intent = activity.interaction?.intent as? INStartCallIntent else { return nil }
            let person = intent.contacts?.first
            return person?.customIdentifier ?? person?.personHandle?.value
        }
    #else
        static func donate(robotID: String, robotName: String?) {}

        static func robotID(from activity: NSUserActivity) -> String? {
            nil
        }
    #endif
}
