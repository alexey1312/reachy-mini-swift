/// The usage descriptions ("purpose strings") the system shows when it asks for a permission.
///
/// App Review refused 0.7.4 under guideline 5.1.1(ii): a purpose string must say how the app
/// uses the data and give one specific example. Every string here has that shape. The same
/// texts had passed review for 0.7.2 and 0.7.3, so a pass says nothing about the next reviewer.
/// The camera strings and the tvOS strings for what the TV does not use are not here: they
/// say that the app does not use the resource, and each target words that for itself.
///
/// `ReachyMini/Resources/InfoPlist.xcstrings` translates the iPhone app's strings, and its
/// English value is the text a reader actually sees, not the one here. Change both together:
/// `Scripts/check-catalogue.py` checks that every language is present, not that English matches.
public enum PurposeString {
    /// Discovery, the daemon's API and the camera. The iPhone, the Mac and Vision Pro share it,
    /// because all three run `ReachyRootView`, joystick included.
    public static let localNetwork = """
    The app uses the local network to find and control your Reachy Mini. \
    For example, the app shows the robot's camera video and sends your joystick moves to the robot.
    """

    /// The TV's own example: a game controller, not the phone's joystick.
    public static let localNetworkTV = """
    The app uses the local network to find and control your Reachy Mini. \
    For example, the app shows the robot's camera video and sends your game controller moves \
    to the robot.
    """

    /// The widget extension never shows a prompt, because an extension has no screen to ask
    /// from. App Review can still read the string.
    public static let localNetworkWidget = """
    Widgets and controls use the local network to send commands to your Reachy Mini. \
    For example, the Wake Reachy Mini control in Control Center wakes the robot.
    """

    /// Wi-Fi provisioning and the recovery console. The example is the provisioning, which
    /// encrypts the credentials (X25519, HKDF-SHA256 and AES-GCM).
    public static let bluetooth = """
    The app uses Bluetooth to set up your Reachy Mini and to repair its Wi-Fi connection. \
    For example, the app sends your Wi-Fi name and password to the robot, encrypted, \
    so that the robot can join your network.
    """

    /// The WebRTC uplink of a call: the phone's microphone to the robot's speaker.
    public static let microphone = """
    The app sends your voice to your Reachy Mini's speaker. \
    For example, you can talk to people near the robot when you are in another room.
    """

    /// Head tracking from headphones (`HeadphoneTeleop`). The last sentence answers the
    /// "Motion & Fitness" name of the permission: `CMHeadphoneMotionManager` is the only
    /// Core Motion API the app calls. A head turned left turns the robot's head left.
    public static let motion = """
    The app reads head movement from your headphones to turn your Reachy Mini's head. \
    For example, when you turn your head to the left with AirPods Pro on, \
    the robot turns its head to the left. The app does not read fitness or activity data.
    """
}
