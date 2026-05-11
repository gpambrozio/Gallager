#if os(macOS)
    import AppKit
    import Dependencies
    import DependenciesMacros
    import Foundation

    // MARK: - Editor Configuration

    /// A user-configured external editor that can be launched to open a file.
    ///
    /// `bundleIdentifier` is the preferred way to launch the editor — when set,
    /// `NSWorkspace.openApplication(at:)` is used so macOS picks up newly installed
    /// versions without the user updating their settings. `executablePath` is used
    /// when the user added a custom editor that is not registered in
    /// `LaunchServices` (rare; mostly homebrew CLI editors).
    public struct EditorConfiguration: Codable, Identifiable, Sendable, Hashable {
        public let id: UUID
        /// Display name shown in menus and the Settings list.
        public var displayName: String
        /// macOS bundle identifier (e.g. `com.microsoft.VSCode`). Either this or
        /// `executablePath` must be non-nil.
        public var bundleIdentifier: String?
        /// Filesystem path to a `.app` bundle or a CLI executable. Used as the
        /// launch target when `bundleIdentifier` is nil or the bundle ID cannot
        /// be resolved.
        public var executablePath: String?

        public init(
            id: UUID = UUID(),
            displayName: String,
            bundleIdentifier: String? = nil,
            executablePath: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.executablePath = executablePath
        }

        /// The editor's app icon resolved via Launch Services, or `nil` when
        /// neither the bundle identifier nor the executable path resolves to
        /// an installed app — in which case callers should render a generic
        /// fallback symbol.
        public var nsIcon: NSImage? {
            let workspace = NSWorkspace.shared
            if
                let bundleId = bundleIdentifier,
                let url = workspace.urlForApplication(withBundleIdentifier: bundleId) {
                return workspace.icon(forFile: url.path)
            }
            if let path = executablePath {
                return workspace.icon(forFile: path)
            }
            return nil
        }
    }

    /// A known editor we ship with the app. When the user's editor list is empty
    /// on first launch, we filter this list to the ones actually installed and
    /// pre-fill their settings.
    public struct KnownEditor: Sendable, Hashable {
        public let displayName: String
        public let bundleIdentifier: String

        public init(displayName: String, bundleIdentifier: String) {
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
        }

        /// The default catalog of editors we look for on first launch.
        public static let defaults: [KnownEditor] = [
            KnownEditor(displayName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode"),
            KnownEditor(displayName: "VSCodium", bundleIdentifier: "com.vscodium"),
            KnownEditor(displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
            KnownEditor(displayName: "Sublime Text", bundleIdentifier: "com.sublimetext.4"),
            KnownEditor(displayName: "Zed", bundleIdentifier: "dev.zed.Zed"),
            KnownEditor(displayName: "BBEdit", bundleIdentifier: "com.barebones.bbedit"),
            KnownEditor(displayName: "Nova", bundleIdentifier: "com.panic.Nova"),
            KnownEditor(displayName: "TextMate", bundleIdentifier: "com.macromates.TextMate"),
            KnownEditor(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
            KnownEditor(displayName: "AppCode", bundleIdentifier: "com.jetbrains.AppCode"),
            KnownEditor(displayName: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij"),
            KnownEditor(displayName: "PyCharm", bundleIdentifier: "com.jetbrains.pycharm"),
            KnownEditor(displayName: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm"),
        ]
    }

    // MARK: - EditorClient

    /// A dependency that lets the app discover installed editors and launch them
    /// against a file path. Wraps `NSWorkspace` so E2E tests can inject a stable
    /// list of editors and route launches through a fake script instead of opening
    /// real editor apps on the host.
    @DependencyClient
    public struct EditorClient: Sendable {
        /// Returns the subset of `KnownEditor.defaults` whose bundle identifiers
        /// resolve to an installed `.app` on the system. Used to seed the user's
        /// editor list on first launch.
        ///
        /// Async because the live implementation calls
        /// `NSWorkspace.urlForApplication(withBundleIdentifier:)` once per
        /// candidate editor — each is a synchronous Launch Services lookup that
        /// can take tens of milliseconds, which would block the MainActor when
        /// called from a SwiftUI button action or at app launch.
        public var detectInstalledKnownEditors: @Sendable () async -> [EditorConfiguration] = { [] }

        /// Launches `editor` against `filePath`. The returned `Bool` is `true`
        /// when the launch was attempted successfully — failures (missing path
        /// / app not found) return `false` so callers can surface a useful
        /// error to the user.
        public var openFile: @Sendable (
            _ editor: EditorConfiguration,
            _ filePath: String
        ) async -> Bool = { _, _ in false }
    }

    // MARK: - DependencyKey

    extension EditorClient: DependencyKey {
        public static var liveValue: EditorClient {
            EditorClient(
                detectInstalledKnownEditors: {
                    // Off the MainActor: NSWorkspace.urlForApplication runs a
                    // synchronous Launch Services query per candidate, so the
                    // 13-entry scan can stall the main thread if not hopped off.
                    await Task.detached {
                        KnownEditor.defaults.compactMap { known in
                            let workspace = NSWorkspace.shared
                            guard workspace.urlForApplication(withBundleIdentifier: known.bundleIdentifier) != nil else {
                                return nil
                            }
                            return EditorConfiguration(
                                displayName: known.displayName,
                                bundleIdentifier: known.bundleIdentifier
                            )
                        }
                    }.value
                },
                openFile: { editor, filePath in
                    let fileURL = URL(fileURLWithPath: filePath)

                    if
                        let bundleId = editor.bundleIdentifier,
                        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        do {
                            _ = try await NSWorkspace.shared.open(
                                [fileURL],
                                withApplicationAt: appURL,
                                configuration: configuration
                            )
                            return true
                        } catch {
                            return false
                        }
                    }

                    if let path = editor.executablePath {
                        let appURL = URL(fileURLWithPath: path)
                        let isApplication = (try? appURL.resourceValues(forKeys: [.isApplicationKey]).isApplication) == true
                        if path.hasSuffix(".app") || isApplication {
                            let configuration = NSWorkspace.OpenConfiguration()
                            configuration.activates = true
                            do {
                                _ = try await NSWorkspace.shared.open(
                                    [fileURL],
                                    withApplicationAt: appURL,
                                    configuration: configuration
                                )
                                return true
                            } catch {
                                return false
                            }
                        }

                        // Treat as an arbitrary executable that takes the file path as
                        // its single argument. Used for CLI editors and (in tests) for
                        // a Python script masquerading as an editor.
                        let process = Process()
                        process.executableURL = appURL
                        process.arguments = [filePath]
                        do {
                            try process.run()
                            return true
                        } catch {
                            return false
                        }
                    }

                    return false
                }
            )
        }

        public static var previewValue: EditorClient {
            EditorClient(
                detectInstalledKnownEditors: { [] },
                openFile: { _, _ in true }
            )
        }

        /// E2E factory: detection returns two stub entries — "Fake Editor" and
        /// "Fake Editor 2" — both pointing at `scriptPath`. Having more than
        /// one editor lets scenarios exercise the multi-row rendering of the
        /// "Open in Editor" submenu and the Cmd+E confirmation dialog. Both
        /// names dispatch through the same Python script, so the test can pick
        /// either and still assert against the same log file.
        ///
        /// When `logPath` is set, it's exported as `GALLAGER_FAKE_EDITOR_LOG`
        /// so the script appends every received file path to that file — the
        /// test scenario can poll it to assert the dispatch genuinely went
        /// through the editor process.
        public static func fakeScript(scriptPath: String, logPath: String?) -> EditorClient {
            let editors = [
                EditorConfiguration(displayName: "Fake Editor", executablePath: scriptPath),
                EditorConfiguration(displayName: "Fake Editor 2", executablePath: scriptPath),
            ]
            return EditorClient(
                detectInstalledKnownEditors: { editors },
                openFile: { config, filePath in
                    let path = config.executablePath ?? scriptPath
                    let process = Process()
                    if path.hasSuffix(".py") {
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        process.arguments = ["python3", path, filePath]
                    } else {
                        process.executableURL = URL(fileURLWithPath: path)
                        process.arguments = [filePath]
                    }
                    if let logPath {
                        var env = ProcessInfo.processInfo.environment
                        env["GALLAGER_FAKE_EDITOR_LOG"] = logPath
                        process.environment = env
                    }
                    do {
                        try process.run()
                    } catch {
                        return false
                    }
                    return true
                }
            )
        }
    }
#endif
