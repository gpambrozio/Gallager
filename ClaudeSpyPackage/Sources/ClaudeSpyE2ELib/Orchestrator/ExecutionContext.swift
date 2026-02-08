import Foundation

/// Stores variables during scenario execution for passing data between steps
final public class ExecutionContext: @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() { }

    /// Store a value
    public func set(_ key: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    /// Retrieve a value
    public func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    /// Resolve variable references in a string (e.g., "${pairingCode}" → actual value)
    public func resolve(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var result = text
        for (key, value) in storage {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }

    /// Clear all stored values
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
