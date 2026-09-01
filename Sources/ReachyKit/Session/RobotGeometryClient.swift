import Foundation

/// The robot's shape: its URDF and the meshes that description names.
///
/// Split off ``RobotAPIClient`` because the 3D scene reads exactly these two things
/// and nothing else, so whatever answers them need not be a robot. The relay's
/// answer is the app's own bundle, and typing that as a connection cost it four
/// stubs that could only throw — see `BundledGeometryClient`.
public protocol RobotGeometryClient: Sendable {
    func urdf() async throws -> String
    func stlAsset(named filename: String) async throws -> Data
}

public extension RobotGeometryClient {
    func urdf() async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func stlAsset(named _: String) async throws -> Data {
        throw URLError(.unsupportedURL)
    }
}
