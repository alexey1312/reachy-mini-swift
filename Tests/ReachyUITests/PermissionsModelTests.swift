import Foundation
@testable import ReachyKit
@testable import ReachyUI
import Testing

/// Counts what each probe was asked, because the rule this screen has to keep is a
/// negative one: opening it must not raise a prompt.
private final class ProbeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ name: String) {
        lock.withLock { counts[name, default: 0] += 1 }
    }

    func count(_ name: String) -> Int {
        lock.withLock { counts[name] ?? 0 }
    }
}

@MainActor
@Suite("PermissionsModel")
struct PermissionsModelTests {
    private static func model(
        spy: ProbeSpy,
        bluetooth: PermissionState = .undetermined,
        microphone: PermissionState = .undetermined,
        promptedMicrophone: PermissionState = .granted,
        probedNetwork: PermissionState = .granted,
        notifications: PermissionState = .undetermined,
        promptedNotifications: PermissionState = .granted,
        availability: BLEAvailability = .ready
    ) -> PermissionsModel {
        PermissionsModel(
            readBluetooth: {
                spy.record("readBluetooth")
                return bluetooth
            },
            readMicrophone: {
                spy.record("readMicrophone")
                return microphone
            },
            promptBluetooth: {
                spy.record("promptBluetooth")
                return availability
            },
            promptMicrophone: {
                spy.record("promptMicrophone")
                return promptedMicrophone
            },
            probeLocalNetwork: {
                spy.record("probeLocalNetwork")
                return probedNetwork
            },
            readNotifications: {
                spy.record("readNotifications")
                return notifications
            },
            promptNotifications: {
                spy.record("promptNotifications")
                return promptedNotifications
            }
        )
    }

    /// Asserted over `allCases` rather than against a literal triple: the claim is
    /// that *no* row starts with an answer, and pinning the count as well only makes
    /// this fail when a row is added for unrelated reasons.
    @Test("everything starts unknown, so no row claims an answer nobody has given")
    func startsUndetermined() {
        let model = PermissionsModel()
        let answered = PermissionKind.allCases.map { model[$0] }.filter { $0 != .undetermined }
        #expect(answered.isEmpty)
        #expect(PermissionKind.allCases.isEmpty == false)
    }

    @Test("a refresh reads the two non-prompting sources and never touches the probes")
    func refreshDoesNotPrompt() {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy, bluetooth: .granted, microphone: .denied)
        model.refresh()

        #expect(model[.bluetooth] == .granted)
        #expect(model[.microphone] == .denied)
        // The whole point. Starting a browser *is* the local-network prompt, and
        // building a central *is* the Bluetooth one, so a screen appearing must reach
        // neither.
        #expect(spy.count("probeLocalNetwork") == 0)
        #expect(spy.count("promptBluetooth") == 0)
        #expect(spy.count("promptMicrophone") == 0)
        // And the local network is left exactly as it was rather than guessed at.
        #expect(model[.localNetwork] == .undetermined)
    }

    /// The synchronous half must stay synchronous, and it must not reach the one
    /// source that is async — otherwise the notification row would be read on a path
    /// that cannot await it, and somebody would make `refresh()` async to fix that.
    @Test("a plain refresh does not read the notification status at all")
    func refreshLeavesNotificationsAlone() {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy)
        model.refresh()

        #expect(spy.count("readNotifications") == 0)
        #expect(model[.notifications] == .undetermined)
    }

    @Test("refreshing notifications reads the status once and prompts for nothing")
    func refreshNotificationsDoesNotPrompt() async {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy, notifications: .denied)
        await model.refreshNotifications()

        #expect(model[.notifications] == .denied)
        #expect(spy.count("readNotifications") == 1)
        #expect(spy.count("promptNotifications") == 0)
        // The negative that matters most: the async refresh must not drag the two
        // genuinely prompting probes in with it.
        #expect(spy.count("probeLocalNetwork") == 0)
        #expect(spy.count("promptBluetooth") == 0)
    }

    @Test("asking for notifications goes through the prompting path and reports the answer")
    func requestNotificationsPrompts() async {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy, promptedNotifications: .denied)
        await model.requestNotifications()

        #expect(spy.count("promptNotifications") == 1)
        #expect(model[.notifications] == .denied)
    }

    @Test("a live LAN session settles the local network without asking anything")
    func lanSessionProvesTheGrant() {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy)
        model.noteLocalNetworkProvenByConnection()

        #expect(model[.localNetwork] == .granted)
        #expect(spy.count("probeLocalNetwork") == 0)
    }

    @Test("checking the local network runs the probe once and stores what it found")
    func checkLocalNetwork() async {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy, probedNetwork: .denied)
        await model.checkLocalNetwork()

        #expect(spy.count("probeLocalNetwork") == 1)
        #expect(model[.localNetwork] == .denied)
        #expect(model.busy == nil)
    }

    @Test("a restricted microphone is stored as restricted, not as a refusal")
    func restrictedMicrophoneKeepsItsName() async {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy, promptedMicrophone: .restricted)
        await model.requestMicrophone()

        // The distinction the request is written around: a restricted device also
        // answers "no", and calling that denied would send someone to a Settings
        // toggle they are not allowed to move.
        #expect(model[.microphone] == .restricted)
        #expect(model[.microphone].isBlocking)
    }

    @Test("prompting for Bluetooth also learns the radio state authorization cannot report")
    func bluetoothPromptLearnsAvailability() async {
        let spy = ProbeSpy()
        let model = Self.model(spy: spy, bluetooth: .granted, availability: .poweredOff)
        await model.requestBluetooth()

        #expect(spy.count("promptBluetooth") == 1)
        #expect(model[.bluetooth] == .granted)
        // Granted and unusable at the same time — the pair `CBManagerAuthorization`
        // alone can never express.
        #expect(model.bluetoothAvailability == .poweredOff)
    }

    @Test("the radio is unknown until something asks, so a fresh model claims nothing about it")
    func availabilityStartsUnknown() {
        #expect(PermissionsModel().bluetoothAvailability == nil)
    }
}

@Suite("PermissionKind")
struct PermissionKindTests {
    @Test("only a blocking state is coloured")
    func tones() {
        // Mapped outside the macro: `#expect` and a trailing closure argue, and
        // swiftformat rewriting one into a key path is what breaks the expansion.
        let kinds = PermissionKind.allCases
        let denied = kinds.map { $0.tone(.denied) }.filter { $0 != .failed }
        let restricted = kinds.map { $0.tone(.restricted) }.filter { $0 != .failed }
        let granted = kinds.map { $0.tone(.granted) }.filter { $0 != .idle }
        let undetermined = kinds.map { $0.tone(.undetermined) }.filter { $0 != .idle }
        #expect(denied.isEmpty)
        #expect(restricted.isEmpty)
        #expect(granted.isEmpty)
        #expect(undetermined.isEmpty)
    }

    @Test("every kind has a caption for every state")
    func captionsAreComplete() {
        let empty = PermissionKind.allCases
            .flatMap { kind in PermissionState.allCases.map { kind.caption($0) } }
            .filter(\.isEmpty)
        #expect(empty.isEmpty)
    }

    @Test("the local network says unknown where the others say not asked")
    func undeterminedReadsDifferently() {
        // It has no status API, so "undetermined" there also covers a granted
        // permission on a Wi-Fi with no robot on it. "Not asked yet" would be a lie.
        #expect(PermissionKind.localNetwork.caption(.undetermined) != PermissionKind.bluetooth.caption(.undetermined))
        #expect(PermissionKind.bluetooth.caption(.undetermined) == PermissionKind.microphone.caption(.undetermined))
    }

    @Test("each kind deep-links to its own privacy pane")
    func panes() {
        #expect(PermissionKind.bluetooth.pane == .bluetooth)
        #expect(PermissionKind.localNetwork.pane == .localNetwork)
        #expect(PermissionKind.microphone.pane == .microphone)
    }
}
