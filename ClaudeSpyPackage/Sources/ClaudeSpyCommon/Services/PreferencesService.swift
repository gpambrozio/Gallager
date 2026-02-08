#if canImport(UIKit) || canImport(AppKit)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// A dependency for reading and writing user preferences (UserDefaults).
    ///
    /// Provides a testable and previewable interface over `UserDefaults`,
    /// allowing features to read/write preferences without directly coupling
    /// to the `UserDefaults` singleton.
    ///
    /// ## Usage
    ///
    /// Access via `@Dependency`:
    /// ```swift
    /// @Dependency(\.preferencesService) var preferences
    /// let name = preferences.string("fontName")
    /// preferences.setString("SF Mono", "fontName")
    /// ```
    @DependencyClient
    public struct PreferencesService: Sendable {
        // MARK: - Read Operations

        /// Returns the string value for the given key, or nil if not set.
        public var string: @Sendable (_ forKey: String) -> String? = { _ in nil }

        /// Returns the boolean value for the given key.
        public var bool: @Sendable (_ forKey: String) -> Bool = { _ in false }

        /// Returns the integer value for the given key.
        public var integer: @Sendable (_ forKey: String) -> Int = { _ in 0 }

        /// Returns the double value for the given key.
        public var double: @Sendable (_ forKey: String) -> Double = { _ in 0 }

        /// Returns the data value for the given key, or nil if not set.
        public var data: @Sendable (_ forKey: String) -> Data? = { _ in nil }

        /// Returns the object value for the given key, or nil if not set.
        public var object: @Sendable (_ forKey: String) -> Any? = { _ in nil }

        // MARK: - Write Operations

        /// Sets a string value for the given key.
        public var setString: @Sendable (_ value: String, _ forKey: String) -> Void

        /// Sets a boolean value for the given key.
        public var setBool: @Sendable (_ value: Bool, _ forKey: String) -> Void

        /// Sets an integer value for the given key.
        public var setInteger: @Sendable (_ value: Int, _ forKey: String) -> Void

        /// Sets a double value for the given key.
        public var setDouble: @Sendable (_ value: Double, _ forKey: String) -> Void

        /// Sets a data value for the given key.
        public var setData: @Sendable (_ value: Data, _ forKey: String) -> Void

        /// Sets any value for the given key.
        public var setObject: @Sendable (_ value: Any?, _ forKey: String) -> Void

        // MARK: - Delete

        /// Removes the value for the given key.
        public var removeObject: @Sendable (_ forKey: String) -> Void
    }

    // MARK: - DependencyKey Conformance

    extension PreferencesService: DependencyKey {
        public static var liveValue: PreferencesService {
            // UserDefaults.standard is thread-safe but not marked Sendable
            nonisolated(unsafe) let defaults = UserDefaults.standard
            return PreferencesService(
                string: { defaults.string(forKey: $0) },
                bool: { defaults.bool(forKey: $0) },
                integer: { defaults.integer(forKey: $0) },
                double: { defaults.double(forKey: $0) },
                data: { defaults.data(forKey: $0) },
                object: { defaults.object(forKey: $0) },
                setString: { defaults.set($0, forKey: $1) },
                setBool: { defaults.set($0, forKey: $1) },
                setInteger: { defaults.set($0, forKey: $1) },
                setDouble: { defaults.set($0, forKey: $1) },
                setData: { defaults.set($0, forKey: $1) },
                setObject: { defaults.set($0, forKey: $1) },
                removeObject: { defaults.removeObject(forKey: $0) }
            )
        }
    }

    // MARK: - DependencyValues Registration

    extension DependencyValues {
        public var preferencesService: PreferencesService {
            get { self[PreferencesService.self] }
            set { self[PreferencesService.self] = newValue }
        }
    }
#endif
