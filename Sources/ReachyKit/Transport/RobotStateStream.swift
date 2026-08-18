import Foundation

/// Where a live robot's state comes from.
///
/// The one thing in the client that never went through a seam. Everything else a
/// session does — the handshake, the geometry, the commands — funnels through a
/// `RobotAPIClient` the caller supplies, which is how the Hugging Face relay works
/// at all (`RemoteRobotConnection`). The state stream did not: both consumers built
/// a `StateStreamClient` from a `RobotAddress` themselves, so a session without an
/// address could not have a moving 3D model no matter what it answered to
/// everything else.
///
/// Options are a parameter rather than a property because the two consumers ask for
/// genuinely different frames — `.visualization` at 10 Hz with the geometry,
/// `.hearing` at 5 Hz with two fields — and a supplier that had to be configured
/// before it was handed over would have to be handed over twice.
public protocol RobotStateStreaming: Sendable {
    func updates(_ options: StateStreamOptions) -> AsyncStream<StateStreamUpdate>
}

/// The live stream, over the robot's own network.
///
/// One socket per call, because that is what the daemon offers: the option set
/// travels in the URL's query, so two consumers wanting different fields are two
/// subscriptions and always were.
///
/// Deliberately not configurable. `StateStreamClient.Configuration` carries the
/// reconnect backoff too, and exposing it here would mean holding a value whose
/// `options` half `updates(_:)` overwrites — a settable field that does nothing,
/// which is worse than the parameter nobody has yet asked for.
public struct RobotStateStream: RobotStateStreaming {
    private let address: RobotAddress
    private let session: URLSession

    /// Throws on an address no URL can be built from, so the failure lands where a
    /// caller can report it — `ViewportModel` already treats "a transport could not
    /// be constructed" as a setup error rather than as a robot that went quiet.
    /// Validated against the bare path, which is enough: query items are appended
    /// from the options and cannot make a good address bad.
    public init(address: RobotAddress, session: URLSession = .shared) throws {
        _ = try StateStreamClient(address: address, session: session)
        self.address = address
        self.session = session
    }

    public func updates(_ options: StateStreamOptions) -> AsyncStream<StateStreamUpdate> {
        var configuration = StateStreamClient.Configuration()
        configuration.options = options
        guard let client = try? StateStreamClient(
            address: address,
            configuration: configuration,
            session: session
        ) else {
            // Unreachable: `init` built the same URL from the same address, and the
            // options only add query items. Finishing rather than trapping, because
            // a stream that ends is the case every consumer already handles.
            return AsyncStream { $0.finish() }
        }
        return client.updates()
    }
}
