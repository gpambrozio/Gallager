import Foundation

/// In-memory implementation of ``UserDefaultsStorable`` for testing.
///
/// Stores all values in a dictionary instead of persisting to disk.
/// Thread-safe via `NSLock`.
///
/// - Warning: **TESTING ONLY** — Values are lost when the process terminates.
final public class InMemoryDefaults: UserDefaultsStorable, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    public init() { }

    // MARK: - UserDefaultsStorable

    public func string(forKey defaultName: String) -> String? {
        lock.withLock { store[defaultName] as? String }
    }

    public func integer(forKey defaultName: String) -> Int {
        lock.withLock { store[defaultName] as? Int ?? 0 }
    }

    public func double(forKey defaultName: String) -> Double {
        lock.withLock { store[defaultName] as? Double ?? 0 }
    }

    public func bool(forKey defaultName: String) -> Bool {
        lock.withLock { store[defaultName] as? Bool ?? false }
    }

    public func data(forKey defaultName: String) -> Data? {
        lock.withLock { store[defaultName] as? Data }
    }

    public func object(forKey defaultName: String) -> Any? {
        lock.withLock { store[defaultName] }
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock {
            if let value {
                store[defaultName] = value
            } else {
                _ = store.removeValue(forKey: defaultName)
            }
        }
    }

    public func removeObject(forKey defaultName: String) {
        lock.withLock { _ = store.removeValue(forKey: defaultName) }
    }
}
