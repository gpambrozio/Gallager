import Dependencies
import DependenciesMacros
import Foundation

/// Plugin-system on-disk paths, exposed as a dependency so tests can redirect
/// the entire layout at a temp directory.
///
/// Mirrors the layout defined in the plugin-system spec (§4):
///
/// ```
/// ~/.gallager/
///   registry.json                          ← canonical installed-plugin list
///   plugins/<id>/                          ← user-installed plugins
///   state/plugins/<id>/                    ← per-plugin private state
///     ingress.sock
///     settings.json
///     logs/
/// Gallager.app/Contents/Resources/plugins/ ← bundled plugins (read-only)
/// ```
///
/// The `--gallager-state-root` launch arg overrides the default root by
/// re-binding the dependency to `.live(rootOverride: ...)` (see Task 22).
@DependencyClient
public struct PluginRootLayout: Sendable {
    /// Path to `~/.gallager/registry.json`.
    public var registryURL: @Sendable () -> URL = {
        reportIssue("PluginRootLayout.registryURL is unimplemented")
        return URL(fileURLWithPath: "/dev/null")
    }

    /// Directory of bundled plugins shipped inside the .app
    /// (`Gallager.app/Contents/Resources/plugins`).
    public var bundledPluginsDir: @Sendable () -> URL = {
        reportIssue("PluginRootLayout.bundledPluginsDir is unimplemented")
        return URL(fileURLWithPath: "/dev/null")
    }

    /// Directory of user-installed plugins (`~/.gallager/plugins`).
    public var userPluginsDir: @Sendable () -> URL = {
        reportIssue("PluginRootLayout.userPluginsDir is unimplemented")
        return URL(fileURLWithPath: "/dev/null")
    }

    /// State directory for one plugin (`~/.gallager/state/plugins/<id>/`).
    public var stateDir: @Sendable (_ pluginID: String) -> URL = { _ in
        reportIssue("PluginRootLayout.stateDir is unimplemented")
        return URL(fileURLWithPath: "/dev/null")
    }

    /// Unix-domain socket that one plugin's sidecar listens on for ingress
    /// frames (`~/.gallager/state/plugins/<id>/ingress.sock`).
    public var ingressSocketURL: @Sendable (_ pluginID: String) -> URL = { _ in
        reportIssue("PluginRootLayout.ingressSocketURL is unimplemented")
        return URL(fileURLWithPath: "/dev/null")
    }

    /// User-editable settings file for one plugin
    /// (`~/.gallager/state/plugins/<id>/settings.json`).
    public var settingsURL: @Sendable (_ pluginID: String) -> URL = { _ in
        reportIssue("PluginRootLayout.settingsURL is unimplemented")
        return URL(fileURLWithPath: "/dev/null")
    }

    /// Per-plugin log directory (`~/.gallager/state/plugins/<id>/logs/`).
    public var logsDir: @Sendable (_ pluginID: String) -> URL = { _ in
        reportIssue("PluginRootLayout.logsDir is unimplemented")
        return URL(fileURLWithPath: "/dev/null")
    }
}

extension PluginRootLayout: TestDependencyKey {
    /// Tests get the auto-generated unimplemented value, which calls
    /// `reportIssue` on any closure access — forcing tests to override the
    /// dependency before exercising code that needs filesystem paths.
    public static let testValue: Self = PluginRootLayout()
}

extension PluginRootLayout: DependencyKey {
    /// Production layout rooted at `~/.gallager`, with bundled plugins under
    /// `Gallager.app/Contents/Resources/plugins`.
    public static var liveValue: Self {
        .live(rootOverride: nil, bundledOverride: nil)
    }

    /// Build a layout rooted at a custom path.
    ///
    /// - Parameters:
    ///   - rootOverride: If non-nil, use this directory in place of
    ///     `~/.gallager`. Tests pass a temp directory; the
    ///     `--gallager-state-root` launch arg passes a per-E2E-scenario root.
    ///   - bundledOverride: If non-nil, use this directory in place of
    ///     `Bundle.main.resourceURL/plugins`. Tests pass a fixture directory;
    ///     production passes nil and falls back to the bundle's resources.
    public static func live(rootOverride: URL?, bundledOverride: URL?) -> Self {
        let root = rootOverride ?? URL(
            fileURLWithPath: NSString(string: "~/.gallager").expandingTildeInPath,
            isDirectory: true
        )
        // Fall back to a `/tmp` path rather than crashing if `Bundle.main`
        // has no resource directory (e.g. when the runtime is loaded by a
        // CLI tool with no resource bundle). The fallback is unusable in
        // practice — bundled-plugin loading just yields an empty list —
        // but it avoids a startup crash in odd environments.
        let bundledDir = bundledOverride
            ?? Bundle.main.resourceURL?.appendingPathComponent("plugins", isDirectory: true)
            ?? URL(fileURLWithPath: "/tmp/gallager-bundled-fallback", isDirectory: true)

        return PluginRootLayout(
            registryURL: { root.appendingPathComponent("registry.json") },
            bundledPluginsDir: { bundledDir },
            userPluginsDir: { root.appendingPathComponent("plugins", isDirectory: true) },
            stateDir: { id in
                root.appendingPathComponent("state/plugins/\(id)", isDirectory: true)
            },
            ingressSocketURL: { id in
                root.appendingPathComponent("state/plugins/\(id)/ingress.sock")
            },
            settingsURL: { id in
                root.appendingPathComponent("state/plugins/\(id)/settings.json")
            },
            logsDir: { id in
                root.appendingPathComponent("state/plugins/\(id)/logs", isDirectory: true)
            }
        )
    }
}

public extension DependencyValues {
    /// On-disk paths for the plugin runtime.
    var pluginRootLayout: PluginRootLayout {
        get { self[PluginRootLayout.self] }
        set { self[PluginRootLayout.self] = newValue }
    }
}
