#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Provides this Mac's advertised display name (its system `ComputerName`).
    ///
    /// The iOS/Mac viewer renders this name in its Sessions header, unpair
    /// dialog, and version-mismatch text. Because `ComputerName` varies per
    /// machine (a CI box might report "Managed's Virtual Machine" instead of
    /// "MacMini"), E2E scenarios override this client via the `--e2e-device-name`
    /// launch argument so screenshot baselines stay portable across machines.
    @DependencyClient
    public struct DeviceNameClient: Sendable {
        /// The name to advertise to the relay server and paired devices.
        public var current: @Sendable () -> String = { "Mac" }
    }

    extension DeviceNameClient: DependencyKey {
        public static let liveValue = DeviceNameClient(
            current: { Host.current().localizedName ?? "Mac" }
        )
    }
#endif
