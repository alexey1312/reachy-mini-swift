import Foundation

/// Answers "is a daemon serving this address right now" for robots the app already knows.
///
/// Deliberately not a handshake: this runs on a timer for every stored robot and only has to
/// tell a robot that is on the air from one that is not. `hardware-id` is the cheapest route
/// that proves it is a Reachy daemon answering rather than any HTTP server.
public enum RobotReachability {
    public static func probe(
        _ address: RobotAddress,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> Bool {
        guard let url = address.httpURL(path: "/api/daemon/hardware-id") else { return false }
        var request = URLRequest.toDaemon(url)
        request.timeoutInterval = timeout

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200 ..< 300).contains(http.statusCode)
    }
}
