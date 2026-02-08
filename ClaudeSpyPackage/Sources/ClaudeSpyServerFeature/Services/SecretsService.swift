#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Security

    /// A dependency for securely storing and retrieving secrets from the Keychain.
    ///
    /// Provides a testable and previewable interface over the macOS Keychain,
    /// allowing features to manage sensitive data like API keys and credentials
    /// without directly coupling to `Security` framework APIs.
    ///
    /// ## Usage
    ///
    /// Access via `@Dependency`:
    /// ```swift
    /// @Dependency(\.secretsService) var secrets
    /// try secrets.store("my-secret".data(using: .utf8)!, "api-key", "com.app.service")
    /// let data = try secrets.load("api-key", "com.app.service")
    /// ```
    @DependencyClient
    public struct SecretsService: Sendable {
        /// Stores data in the Keychain for the given account and service.
        ///
        /// If an item with the same account and service already exists, it will be updated.
        /// - Parameters:
        ///   - data: The data to store
        ///   - account: The account identifier for the Keychain item
        ///   - service: The service identifier for the Keychain item
        ///   - accessGroup: Optional Keychain access group for sharing between apps/extensions
        public var store: @Sendable (
            _ data: Data,
            _ account: String,
            _ service: String,
            _ accessGroup: String?
        ) throws -> Void

        /// Loads data from the Keychain for the given account and service.
        ///
        /// - Parameters:
        ///   - account: The account identifier for the Keychain item
        ///   - service: The service identifier for the Keychain item
        ///   - accessGroup: Optional Keychain access group for sharing between apps/extensions
        /// - Returns: The stored data, or nil if not found
        public var load: @Sendable (
            _ account: String,
            _ service: String,
            _ accessGroup: String?
        ) throws -> Data?

        /// Deletes the Keychain item for the given account and service.
        ///
        /// - Parameters:
        ///   - account: The account identifier for the Keychain item
        ///   - service: The service identifier for the Keychain item
        ///   - accessGroup: Optional Keychain access group for sharing between apps/extensions
        public var delete: @Sendable (
            _ account: String,
            _ service: String,
            _ accessGroup: String?
        ) throws -> Void

        /// Checks whether a Keychain item exists for the given account and service.
        ///
        /// - Parameters:
        ///   - account: The account identifier for the Keychain item
        ///   - service: The service identifier for the Keychain item
        ///   - accessGroup: Optional Keychain access group for sharing between apps/extensions
        /// - Returns: True if an item exists, false otherwise
        public var contains: @Sendable (
            _ account: String,
            _ service: String,
            _ accessGroup: String?
        ) -> Bool = { _, _, _ in false }
    }

    // MARK: - Keychain Error

    /// Errors that can occur during Keychain operations.
    public enum SecretsServiceError: Error, LocalizedError {
        case storeFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .storeFailed(status):
                "Failed to store item in Keychain (status: \(status))"
            case let .loadFailed(status):
                "Failed to load item from Keychain (status: \(status))"
            case let .deleteFailed(status):
                "Failed to delete item from Keychain (status: \(status))"
            }
        }
    }

    // MARK: - DependencyKey Conformance

    extension SecretsService: DependencyKey {
        public static var liveValue: SecretsService {
            SecretsService(
                store: { data, account, service, accessGroup in
                    // Delete existing item first
                    let deleteQuery = baseQuery(account: account, service: service, accessGroup: accessGroup)
                    SecItemDelete(deleteQuery as CFDictionary)

                    // Add new item
                    var addQuery = deleteQuery
                    addQuery[kSecValueData as String] = data
                    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

                    let status = SecItemAdd(addQuery as CFDictionary, nil)
                    guard status == errSecSuccess else {
                        throw SecretsServiceError.storeFailed(status)
                    }
                },
                load: { account, service, accessGroup in
                    var query = baseQuery(account: account, service: service, accessGroup: accessGroup)
                    query[kSecReturnData as String] = true
                    query[kSecMatchLimit as String] = kSecMatchLimitOne

                    var result: AnyObject?
                    let status = SecItemCopyMatching(query as CFDictionary, &result)

                    if status == errSecItemNotFound {
                        return nil
                    }

                    guard status == errSecSuccess, let data = result as? Data else {
                        throw SecretsServiceError.loadFailed(status)
                    }

                    return data
                },
                delete: { account, service, accessGroup in
                    let query = baseQuery(account: account, service: service, accessGroup: accessGroup)
                    let status = SecItemDelete(query as CFDictionary)
                    if status != errSecSuccess && status != errSecItemNotFound {
                        throw SecretsServiceError.deleteFailed(status)
                    }
                },
                contains: { account, service, accessGroup in
                    var query = baseQuery(account: account, service: service, accessGroup: accessGroup)
                    query[kSecReturnData as String] = false
                    let status = SecItemCopyMatching(query as CFDictionary, nil)
                    return status == errSecSuccess
                }
            )
        }

        private static func baseQuery(
            account: String,
            service: String,
            accessGroup: String?
        ) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: service,
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            return query
        }
    }

    // MARK: - DependencyValues Registration

    extension DependencyValues {
        public var secretsService: SecretsService {
            get { self[SecretsService.self] }
            set { self[SecretsService.self] = newValue }
        }
    }
#endif
