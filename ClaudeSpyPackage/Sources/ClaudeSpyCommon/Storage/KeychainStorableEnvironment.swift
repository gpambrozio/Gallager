#if canImport(SwiftUI) && canImport(Security)
    import ClaudeSpyEncryption
    import SwiftUI

    /// Environment key for injecting a ``KeychainStorable`` implementation.
    private struct KeychainStorableKey: EnvironmentKey {
        static let defaultValue: (any KeychainStorable)? = nil
    }

    public extension EnvironmentValues {
        /// The keychain storage implementation for this view hierarchy.
        ///
        /// When nil, views should fall back to creating a real ``KeyManager``.
        var keychainStorage: (any KeychainStorable)? {
            get { self[KeychainStorableKey.self] }
            set { self[KeychainStorableKey.self] = newValue }
        }
    }

    public extension View {
        /// Sets the keychain storage implementation for this view hierarchy.
        func keychainStorage(_ storage: any KeychainStorable) -> some View {
            environment(\.keychainStorage, storage)
        }
    }
#endif
