import Dependencies
import DependenciesMacros
import Foundation

/// A dependency for reading and writing user preferences via UserDefaults.
///
/// This service wraps UserDefaults access so it can be controlled in tests and previews.
/// Use `@Dependency(PreferencesService.self)` to access it.
@DependencyClient
public struct PreferencesService: Sendable {
    // MARK: - String

    /// Returns the string value for the given key, or nil if not set.
    public var string: @Sendable (_ forKey: String) -> String? = { _ in nil }

    /// Sets a string value for the given key.
    public var setString: @Sendable (_ value: String?, _ forKey: String) -> Void

    // MARK: - Bool

    /// Returns the boolean value for the given key.
    /// Returns nil if the key doesn't exist (as opposed to UserDefaults.bool which returns false).
    public var optionalBool: @Sendable (_ forKey: String) -> Bool? = { _ in nil }

    /// Sets a boolean value for the given key.
    public var setBool: @Sendable (_ value: Bool, _ forKey: String) -> Void

    // MARK: - Int

    /// Returns the integer value for the given key, or nil if not set.
    public var optionalInt: @Sendable (_ forKey: String) -> Int? = { _ in nil }

    /// Sets an integer value for the given key.
    public var setInt: @Sendable (_ value: Int, _ forKey: String) -> Void

    // MARK: - Double

    /// Returns the double value for the given key, or nil if not set.
    public var optionalDouble: @Sendable (_ forKey: String) -> Double? = { _ in nil }

    /// Sets a double value for the given key.
    public var setDouble: @Sendable (_ value: Double, _ forKey: String) -> Void

    // MARK: - Data

    /// Returns the data value for the given key, or nil if not set.
    public var data: @Sendable (_ forKey: String) -> Data? = { _ in nil }

    /// Sets a data value for the given key.
    public var setData: @Sendable (_ value: Data?, _ forKey: String) -> Void
}

// MARK: - In-Memory Implementation

public extension PreferencesService {
    /// Creates a `PreferencesService` backed by an in-memory dictionary.
    ///
    /// Use this for E2E tests where the app must not write to real UserDefaults.
    static func inMemory() -> PreferencesService {
        let store = InMemoryStore()

        return PreferencesService(
            string: { key in
                store.get(key) as? String
            },
            setString: { value, key in
                store.set(value, forKey: key)
            },
            optionalBool: { key in
                store.get(key) as? Bool
            },
            setBool: { value, key in
                store.set(value, forKey: key)
            },
            optionalInt: { key in
                store.get(key) as? Int
            },
            setInt: { value, key in
                store.set(value, forKey: key)
            },
            optionalDouble: { key in
                store.get(key) as? Double
            },
            setDouble: { value, key in
                store.set(value, forKey: key)
            },
            data: { key in
                store.get(key) as? Data
            },
            setData: { value, key in
                store.set(value, forKey: key)
            }
        )
    }
}

/// Thread-safe in-memory key-value store for `PreferencesService.inMemory()`.
final private class InMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    func get(_ key: String) -> Any? {
        lock.withLock { storage[key] }
    }

    func set(_ value: Any?, forKey key: String) {
        lock.withLock { storage[key] = value }
    }
}

// MARK: - DependencyKey

extension PreferencesService: DependencyKey {
    public static var previewValue: PreferencesService {
        .inMemory()
    }

    public static var liveValue: PreferencesService {
        // Use nonisolated(unsafe) because UserDefaults.standard is thread-safe
        // but not marked Sendable
        nonisolated(unsafe) let defaults = UserDefaults.standard

        return PreferencesService(
            string: { key in
                defaults.string(forKey: key)
            },
            setString: { value, key in
                defaults.set(value, forKey: key)
            },
            optionalBool: { key in
                defaults.object(forKey: key) as? Bool
            },
            setBool: { value, key in
                defaults.set(value, forKey: key)
            },
            optionalInt: { key in
                defaults.object(forKey: key) as? Int
            },
            setInt: { value, key in
                defaults.set(value, forKey: key)
            },
            optionalDouble: { key in
                defaults.object(forKey: key) as? Double
            },
            setDouble: { value, key in
                defaults.set(value, forKey: key)
            },
            data: { key in
                defaults.data(forKey: key)
            },
            setData: { value, key in
                defaults.set(value, forKey: key)
            }
        )
    }
}
