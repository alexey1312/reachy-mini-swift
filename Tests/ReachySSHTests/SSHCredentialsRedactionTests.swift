import Foundation
@testable import ReachySSH
import Testing

@Suite("Printed SSH credentials are redacted")
struct SSHCredentialsRedactionTests {
    private let credentials = SSHCredentials(host: "10.0.0.7", username: "pollen", password: "root-secret")

    @Test("no way of printing credentials shows the password")
    func printsNoPassword() {
        var dumped = ""
        dump(credentials, to: &dumped)

        for printed in [String(describing: credentials), String(reflecting: credentials), "\(credentials)", dumped] {
            #expect(!printed.contains("root-secret"))
            #expect(printed.contains("pollen"))
        }
    }
}
