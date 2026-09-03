import ReachyDesign
import ReachyKit
import SwiftUI

/// The one opt-in for job notifications.
///
/// Built on `AppearanceSection`'s shape: the defaults suite is injectable, because a
/// preview reading the real `KnownRobots.defaults` would render whatever the machine
/// happens to hold rather than the state the preview is about.
///
/// **Off until the reader turns it on**, and turning it on is what raises the system
/// prompt. An app that has never asked must not behave as though it had, and there is
/// no honest way to show a toggle that is on while the system would refuse to deliver.
struct NotificationsSection: View {
    @AppStorage(JobNotificationSettings.key) private var isOn = false
    @State private var authorization: PermissionState
    @Environment(\.reachyPreviewMode) private var previewMode
    @Environment(\.scenePhase) private var scenePhase

    private let read: @Sendable () async -> PermissionState
    private let ask: @Sendable () async -> PermissionState

    /// The two probes resolve to `nil` and are filled in here rather than in the
    /// signature, for the reason `PermissionsModel.init` records: a default argument
    /// is evaluated in a nonisolated context.
    init(
        defaults: UserDefaults = KnownRobots.defaults,
        authorization: PermissionState = .undetermined,
        read: (@Sendable () async -> PermissionState)? = nil,
        ask: (@Sendable () async -> PermissionState)? = nil
    ) {
        _isOn = AppStorage(wrappedValue: false, JobNotificationSettings.key, store: defaults)
        _authorization = State(initialValue: authorization)
        self.read = read ?? { await NotificationPermission.current }
        self.ask = ask ?? { await NotificationPermission.request() }
    }

    /// Only worth saying where the reader has asked for something the system is
    /// refusing. A refusal while the switch is off is not news.
    private var isBlocked: Bool {
        isOn && authorization.isBlocking
    }

    var body: some View {
        Section {
            Toggle(.reachy("Tell me when a job finishes"), isOn: $isOn)
                .onChange(of: isOn) { _, turnedOn in
                    guard turnedOn else { return }
                    Task { await requestPermission() }
                }
            if isBlocked {
                PrivacySettingsButton(pane: .notifications)
            }
        } header: {
            Text(.reachy("Notifications"))
        } footer: {
            footer
        }
        // Keyed on the scene phase, not a bare `.task`. A bare one runs on appear and
        // never again, and the trip this row's own Open Settings button starts —
        // background, change the permission, come back — leaves the Form mounted, so
        // the answer on screen would stay whatever it was before the reader changed it.
        .task(id: scenePhase) { await appeared() }
    }

    /// A `VStack` rather than two `Text`s, because a `Section` handed a bare pair
    /// renders only the first — the trap `SystemUpdateCard` already records.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(.reachy("A finished install or robot update is announced. A job the robot never answered is not."))
            // The sentence this whole feature can most easily lie about. Nothing here
            // survives the app being unloaded, and the copy has to say so.
            Text(.reachy("Announced while the app is still running in the background, not after it has been closed."))
            if isBlocked {
                Text(.reachy("Notifications are switched off in Settings."))
                    .foregroundStyle(Tone.danger.style)
            }
        }
    }

    /// Reads the status without asking for it, so a reader coming back from Settings
    /// sees the truth. The switch is deliberately **not** flipped off here: silently
    /// rewriting a setting the reader chose is worse than saying why it is not
    /// working, which is what `isBlocked` puts on screen.
    ///
    /// Only on activation: the other phases cannot have changed the answer, and
    /// re-reading on the way out would spend a cross-process call on nothing.
    private func appeared() async {
        guard !previewMode, scenePhase == .active else { return }
        authorization = await read()
    }

    /// The prompt, and the one place the switch is moved on the app's own initiative:
    /// a toggle left on after a refusal would claim a delivery that cannot happen.
    private func requestPermission() async {
        guard !previewMode else { return }
        let answer = await ask()
        authorization = answer
        if answer != .granted {
            isOn = false
        }
    }
}

#if DEBUG
    extension NotificationsSection {
        /// A suite nothing else reads, so a preview can show the switch both on and
        /// off — the same trick `AppearanceSection.preview` plays, under a key neither
        /// of them touches.
        static func preview(on: Bool, authorization: PermissionState = .granted) -> NotificationsSection {
            let defaults = UserDefaults(suiteName: "ReachyUI.previews") ?? .standard
            defaults.set(on, forKey: JobNotificationSettings.key)
            return NotificationsSection(
                defaults: defaults,
                authorization: authorization,
                read: { authorization },
                ask: { authorization }
            )
        }
    }
#endif
