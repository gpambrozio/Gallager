#if os(macOS)
    import SwiftUI

    // MARK: - PluginManager environment key

    /// SwiftUI environment plumbing for `PluginManager` so views nested
    /// under Settings can drill into per-plugin pages without an explicit
    /// init-time hand-off.
    ///
    /// Optional because the app injects the manager lazily — settings
    /// pages must still render when the manager hasn't booted yet (e.g.
    /// the first launch of a freshly-installed app, or the preview
    /// canvas), in which case views should show an empty / disabled
    /// state rather than crashing.
    ///
    /// The conformance itself is `@MainActor` so that
    /// `defaultValue` (which references a `@MainActor`-isolated type)
    /// can be a `@MainActor`-isolated static. The EnvironmentKey
    /// machinery only reads `defaultValue` on the MainActor for
    /// MainActor-isolated values, so this is sound under Swift 6.
    private struct PluginManagerKey: @MainActor EnvironmentKey {
        @MainActor
        static let defaultValue: PluginManager? = nil
    }

    public extension EnvironmentValues {
        /// The coding-agent plugin runtime. `nil` until
        /// `AppCoordinator.setupPluginManager()` finishes; setters must be
        /// MainActor-isolated to satisfy `PluginManager`'s `@MainActor`
        /// constraint.
        @MainActor
        var pluginManager: PluginManager? {
            get { self[PluginManagerKey.self] }
            set { self[PluginManagerKey.self] = newValue }
        }
    }
#endif
