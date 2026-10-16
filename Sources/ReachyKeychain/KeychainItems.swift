import Foundation
import os
import Security

/// The generic-password items of one Keychain service, one item for each account.
///
/// On iOS this is the only keychain there is. On macOS a signed build uses the data
/// protection keychain, limited to the app's own access group, so the widget
/// extension cannot read these items. Before this type, the macOS app wrote to the
/// file-based login keychain. A read that finds nothing moves the old item across
/// once: it writes the copy first and deletes the old item only after the write
/// succeeds. A failed move keeps the old item and returns its data, so nobody is
/// signed out and no saved password or pinned host key is lost.
///
/// A macOS process with no application identifier cannot use the data protection
/// keychain: `SecItem` answers `errSecMissingEntitlement` (-34018). That is every
/// `swift test` run and every unsigned build (`mise run build:app`), so those keep
/// the file-based keychain, as before.
public struct KeychainItems: Sendable {
    private static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "Keychain")

    private let service: String
    private let current: any KeychainBackend
    /// The keychain that earlier builds wrote to, when it is not `current`.
    private let legacy: (any KeychainBackend)?
    private let failure: @Sendable (OSStatus) -> any Error

    /// - Parameter failure: Makes the caller's own error from a Keychain status.
    public init(service: String, failure: @escaping @Sendable (OSStatus) -> any Error) {
        #if os(macOS)
            if let accessGroup = SigningEntitlements.applicationIdentifier {
                self.init(
                    service: service,
                    current: SecItemKeychain.dataProtection(accessGroup: accessGroup),
                    legacy: SecItemKeychain.platformDefault,
                    failure: failure
                )
                return
            }
        #endif
        self.init(service: service, current: SecItemKeychain.platformDefault, legacy: nil, failure: failure)
    }

    /// The seam for tests: any two backends, with no Keychain behind them.
    package init(
        service: String,
        current: any KeychainBackend,
        legacy: (any KeychainBackend)?,
        failure: @escaping @Sendable (OSStatus) -> any Error
    ) {
        self.service = service
        self.current = current
        self.legacy = legacy
        self.failure = failure
    }

    /// The item's data, or nil when there is no item in either keychain.
    public func read(account: String) throws -> Data? {
        try mapped {
            if let data = try current.read(service: service, account: account) {
                return data
            }
            guard let legacy, let data = try legacy.read(service: service, account: account) else {
                return nil
            }
            move(data, account: account, from: legacy)
            return data
        }
    }

    /// Replaces the item's data, or adds the item.
    public func write(_ data: Data, account: String) throws {
        try mapped {
            try current.write(data, service: service, account: account)
            // An old copy is now stale. A failure here costs nothing: reads find the new
            // item first, and `delete` removes both.
            guard let legacy else { return }
            do {
                try legacy.delete(service: service, account: account)
            } catch {
                Self.log.error("Could not delete the old item after a write: \(Self.status(of: error))")
            }
        }
    }

    /// Removes the item from both keychains. No item is not an error.
    ///
    /// An old item that stays behind comes back on the next read, because the read
    /// moves it across — a sign-out that does not stick. So both deletes run, also
    /// when the first one fails, and the first failure is the error. The callers
    /// sign out with `try?`, so removing every copy possible is what counts.
    public func delete(account: String) throws {
        try mapped {
            var failure: (any Error)?
            do {
                try current.delete(service: service, account: account)
            } catch {
                failure = error
            }
            do {
                try legacy?.delete(service: service, account: account)
            } catch {
                failure = failure ?? error
            }
            if let failure {
                throw failure
            }
        }
    }

    private func move(_ data: Data, account: String, from legacy: any KeychainBackend) {
        do {
            try current.write(data, service: service, account: account)
        } catch {
            // Keep the old item. The next read tries the move again.
            Self.log.error("Could not move an item out of the file-based keychain: \(Self.status(of: error))")
            return
        }
        do {
            try legacy.delete(service: service, account: account)
        } catch {
            Self.log.error("Moved an item, but could not delete the old one: \(Self.status(of: error))")
        }
    }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as KeychainFailure {
            throw failure(error.status)
        }
    }

    private static func status(of error: any Error) -> OSStatus {
        (error as? KeychainFailure)?.status ?? errSecInternalError
    }
}

/// One keychain implementation.
package protocol KeychainBackend: Sendable {
    /// The item's data, or nil when there is no item.
    func read(service: String, account: String) throws -> Data?
    /// Replaces the item's data, or adds the item.
    func write(_ data: Data, service: String, account: String) throws
    /// Removes the item. No item is not an error.
    func delete(service: String, account: String) throws
}

/// A `SecItem` status other than success.
package struct KeychainFailure: Error, Equatable {
    package let status: OSStatus

    package init(_ status: OSStatus) {
        self.status = status
    }
}
