#if os(macOS)
    import Foundation
    import ServiceManagement

    /// Error types for login item operations
    public enum LoginItemError: LocalizedError {
        case registrationFailed(Error)
        case unregistrationFailed(Error)

        public var errorDescription: String? {
            switch self {
            case let .registrationFailed(error):
                "Failed to enable launch at login: \(error.localizedDescription)"
            case let .unregistrationFailed(error):
                "Failed to disable launch at login: \(error.localizedDescription)"
            }
        }
    }

    /// Utility for managing the app's login item status using SMAppService.
    ///
    /// This is a stateless utility that interacts with the system's login item management.
    /// The login item appears in System Settings → General → Login Items.
    @MainActor
    public enum LoginItemService {
        /// Whether the app is currently registered as a login item
        public static var isEnabled: Bool {
            SMAppService.mainApp.status == .enabled
        }

        /// Current status of the login item
        public static var status: SMAppService.Status {
            SMAppService.mainApp.status
        }

        /// Enables or disables the app as a login item.
        ///
        /// - Parameter enabled: Whether to enable (register) or disable (unregister) the login item.
        /// - Throws: `LoginItemError` if the operation fails.
        public static func setEnabled(_ enabled: Bool) throws {
            if enabled {
                try register()
            } else {
                try unregister()
            }
        }

        /// Registers the app as a login item.
        ///
        /// After registration, the app will automatically launch when the user logs in.
        /// - Throws: `LoginItemError.registrationFailed` if registration fails.
        public static func register() throws {
            do {
                try SMAppService.mainApp.register()
            } catch {
                throw LoginItemError.registrationFailed(error)
            }
        }

        /// Unregisters the app from login items.
        ///
        /// After unregistration, the app will no longer launch automatically at login.
        /// - Throws: `LoginItemError.unregistrationFailed` if unregistration fails.
        public static func unregister() throws {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                throw LoginItemError.unregistrationFailed(error)
            }
        }
    }
#endif
