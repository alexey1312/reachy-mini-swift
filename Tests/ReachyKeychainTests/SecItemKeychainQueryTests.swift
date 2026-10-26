import Foundation
@testable import ReachyKeychain
import Security
import Testing

@Suite("Keychain query routing")
struct SecItemKeychainQueryTests {
    #if os(macOS)
        @Test("legacy cleanup cannot reach the protected keychain")
        func legacyQueryExcludesProtectedItems() {
            let query = SecItemKeychain.platformDefault.base(service: "test-service", account: "test-robot")

            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
            #expect(query[kSecAttrAccessGroup as String] == nil)
        }
    #endif

    @Test("a protected query selects the app's access group")
    func protectedQueryUsesOnlyItsGroup() {
        let group = "TESTTEAM.com.example.app"
        let query = SecItemKeychain.dataProtection(accessGroup: group).base(
            service: "test-service",
            account: "test-robot"
        )

        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrAccessGroup as String] as? String == group)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "test-service")
        #expect(query[kSecAttrAccount as String] as? String == "test-robot")
    }
}
