import Foundation
import ReachyKeychain

/// A keychain in memory, for tests of `KeychainItems` and the stores built on it.
///
/// It can refuse one kind of call with a given status, which is how a test makes the
/// data protection keychain refuse a write (`errSecMissingEntitlement`) or the
/// file-based keychain refuse a delete.
public final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    public enum Call: Hashable, Sendable {
        case read, write, delete
    }

    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var items: [Key: Data] = [:]
    private var refusals: [Call: OSStatus] = [:]
    private var counts: [Call: Int] = [:]

    public init() {}

    /// Puts an item in place without counting a call, as an earlier build would have.
    public func seed(_ data: Data, service: String, account: String) {
        lock.withLock { items[Key(service: service, account: account)] = data }
    }

    /// The item's data, without counting a call.
    public func data(service: String, account: String) -> Data? {
        lock.withLock { items[Key(service: service, account: account)] }
    }

    /// Makes every later call of this kind fail with `status`. Nil allows it again.
    public func refuse(_ call: Call, with status: OSStatus?) {
        lock.withLock { refusals[call] = status }
    }

    /// How many calls of this kind arrived, refused ones included.
    public func count(of call: Call) -> Int {
        lock.withLock { counts[call, default: 0] }
    }

    public func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            try arrive(.read)
            return items[Key(service: service, account: account)]
        }
    }

    public func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            try arrive(.write)
            items[Key(service: service, account: account)] = data
        }
    }

    public func delete(service: String, account: String) throws {
        try lock.withLock {
            try arrive(.delete)
            items[Key(service: service, account: account)] = nil
        }
    }

    /// Call with the lock held.
    private func arrive(_ call: Call) throws {
        counts[call, default: 0] += 1
        if let status = refusals[call] {
            throw KeychainFailure(status)
        }
    }
}
