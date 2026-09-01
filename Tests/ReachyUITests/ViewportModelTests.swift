import ReachyKit
import ReachyMedia
import ReachySimulator
@testable import ReachyUI
import Testing

@MainActor
@Suite("Viewport model")
struct ViewportModelTests {
    private let address = RobotAddress(host: "127.0.0.1")

    private var lan: ViewportModel.Source {
        .lan(address)
    }

    /// The simulator serves its own geometry and publishes its own state stream, so
    /// the source carries the object itself rather than an address.
    private func simulated() throws -> ViewportModel.Source {
        try .simulated(#require(SimulatedRobotClient(tick: .seconds(30))))
    }

    /// Attaching alone starts nothing — the viewport has to be on screen first.
    @Test("nothing runs until the viewport is active")
    func inactiveStartsNothing() {
        let model = ViewportModel()
        model.attach(to: lan)
        #expect(model.sceneModel == nil)
        #expect(model.cameraSession == nil)
        model.detach()
    }

    @Test("re-attaching to the same address keeps the loaded scene")
    func attachIsIdempotent() throws {
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: lan)
        let scene = try #require(model.sceneModel)

        model.attach(to: lan)
        #expect(model.sceneModel === scene)

        model.attach(to: .lan(RobotAddress(host: "127.0.0.2")))
        #expect(model.sceneModel !== scene)
        model.detach()
    }

    /// **The point of the whole track, in one assertion.** A simulated session has
    /// no address, so before the seam it could not have a moving 3D model however
    /// completely it answered everything else.
    @Test("a simulated source draws a scene and lands on it")
    func simulatedSourceDrawsAScene() throws {
        let model = ViewportModel()
        let source = try simulated()
        model.setActive(true)

        model.attach(to: source)

        #expect(model.offersScene)
        // Landed on the model rather than the camera: there is nothing to point one
        // at, and an empty pane would be a worse first frame.
        #expect(model.content == .scene)
        #expect(model.sceneModel != nil)
        #expect(model.cameraSession == nil)
        // No address, so no second socket for the direction-of-arrival badge —
        // which is right: there are no microphones either.
        #expect(model.hearing == nil)
        model.detach()
    }

    @Test("switching to the camera keeps the scene in memory")
    func switchingKeepsScene() throws {
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: lan)
        let scene = try #require(model.sceneModel)

        model.setContent(.camera)
        #expect(model.cameraSession != nil)
        // Paused, not discarded: coming back must not re-download the geometry.
        #expect(model.sceneModel === scene)

        model.setContent(.scene)
        #expect(model.sceneModel === scene)
        // The peer connection is the expensive thing, and it does not survive.
        #expect(model.cameraSession == nil)
        model.detach()
    }

    @Test("leaving the viewport drops the camera and keeps the scene")
    func suspendDropsCameraOnly() throws {
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: lan)
        model.setContent(.camera)
        let scene = try #require(model.sceneModel)

        model.setActive(false)
        #expect(model.cameraSession == nil)
        #expect(model.sceneModel === scene)

        model.setActive(true)
        #expect(model.cameraSession != nil)
        #expect(model.sceneModel === scene)
        model.detach()
    }

    @Test("detach is idempotent and clears both engines")
    func detachIsIdempotent() {
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: lan)
        model.detach()
        model.detach()
        #expect(model.sceneModel == nil)
        #expect(model.cameraSession == nil)
    }

    // MARK: A borrowed camera

    /// The riskiest thing in the whole change. Over the relay this camera is the
    /// peer connection the robot's *commands* ride on, so the battery-saving
    /// teardown that is correct for a camera we dialled would disconnect the robot.
    ///
    /// `CameraSession.stop()` returns the phase to `.connecting`, so a session
    /// still reading `.streaming` afterwards is proof nothing stopped it.
    @Test("suspending does not stop a borrowed camera")
    func suspendKeepsABorrowedCamera() {
        let camera = CameraSession.preview(.streaming)
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: .remote(camera, connection: .preview()))

        model.setActive(false)

        #expect(camera.phase == .streaming)
    }

    /// Same for leaving the robot screen altogether: the session outlives the
    /// viewport, and `RemoteRobotLink` is what ends it.
    @Test("detaching does not stop a borrowed camera")
    func detachKeepsABorrowedCamera() {
        let camera = CameraSession.preview(.streaming)
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: .remote(camera, connection: .preview()))

        model.detach()

        #expect(camera.phase == .streaming)
        #expect(model.cameraSession == nil)
    }

    /// A borrowed camera is adopted rather than built, so it is on screen from the
    /// first frame instead of renegotiating a connection that is already up.
    @Test("a remote source shows the camera it was handed")
    func adoptsTheBorrowedCamera() {
        let camera = CameraSession.preview(.streaming)
        let model = ViewportModel()
        model.setActive(true)

        model.attach(to: .remote(camera, connection: .preview()))

        #expect(model.cameraSession === camera)
        #expect(model.content == .camera)
    }

    /// The URDF and the STL meshes are HTTP-only, so there is no 3D model to switch
    /// to — and the switcher must not offer one.
    /// The relay used to have no scene at all, because the description and the
    /// meshes are HTTP routes it cannot reach. The app carries them for the
    /// simulator, so it carries them here — the switcher offers both contents and
    /// lands on the camera, which is what a call is for.
    @Test("a remote source offers the scene out of the app's own bundle")
    func remoteOffersTheBundledScene() {
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: .remote(.preview(.streaming), connection: .preview()))

        #expect(model.offersScene)
        #expect(model.content == .camera)

        model.setContent(.scene)

        #expect(model.content == .scene)
        #expect(model.sceneModel != nil)
    }

    /// The pad over the 3D model is the simulator's alone. Every other source's
    /// scene mirrors the state stream, and a joystick there would drive a picture
    /// the camera — one segment away — would not agree with.
    @Test("only a simulated source carries a joystick over its scene")
    func onlyTheSimulatorDrivesItsScene() throws {
        let model = ViewportModel()
        model.setActive(true)

        #expect(!model.offersSceneTeleop)

        model.attach(to: lan)
        #expect(!model.offersSceneTeleop)

        model.attach(to: .remote(.preview(.streaming), connection: .preview()))
        #expect(!model.offersSceneTeleop)

        try model.attach(to: simulated())
        #expect(model.offersSceneTeleop)

        model.detach()
        #expect(!model.offersSceneTeleop)
    }

    @Test("a local source offers the scene and names no reason not to")
    func localOffersTheScene() {
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: lan)

        #expect(model.offersScene)
        model.detach()
    }

    /// Swapping a borrowed camera for a dialled one must not stop the borrowed one
    /// on the way out.
    @Test("moving from a remote source to a local one leaves the borrowed camera running")
    func handsBackTheBorrowedCamera() {
        let camera = CameraSession.preview(.streaming)
        let model = ViewportModel()
        model.setActive(true)
        model.attach(to: .remote(camera, connection: .preview()))

        model.attach(to: lan)

        #expect(camera.phase == .streaming)
        #expect(model.offersScene)
        model.detach()
    }
}
