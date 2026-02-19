#if os(macOS)
    import Dependencies
    import DependenciesMacros
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

    /// A dependency for managing the app's login item status using SMAppService.
    ///
    /// This service wraps SMAppService access so it can be controlled in tests.
    /// Use `@Dependency(LoginItemService.self)` to access it.
    @DependencyClient
    public struct LoginItemService: Sendable {
        /// Whether the app is currently registered as a login item
        public var isEnabled: @Sendable () -> Bool = { false }

        /// Enables or disables the app as a login item.
        public var setEnabled: @Sendable (_ enabled: Bool) throws -> Void
    }

    // MARK: - DependencyKey

    extension LoginItemService: DependencyKey {
        public static var previewValue: LoginItemService {
            LoginItemService(
                isEnabled: { false },
                setEnabled: { _ in }
            )
        }

        public static var liveValue: LoginItemService {
            LoginItemService(
                isEnabled: {
                    SMAppService.mainApp.status == .enabled
                },
                setEnabled: { enabled in
                    if enabled {
                        do {
                            try SMAppService.mainApp.register()
                        } catch {
                            throw LoginItemError.registrationFailed(error)
                        }
                    } else {
                        do {
                            try SMAppService.mainApp.unregister()
                        } catch {
                            throw LoginItemError.unregistrationFailed(error)
                        }
                    }
                }
            )
        }
    }
#endif
