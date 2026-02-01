#if os(macOS)
    import ClaudeSpyCommon
    import Foundation
    import Logging

    /// Manages the Claude Code plugin detection and installation.
    ///
    /// Checks if the claude-spy plugin is installed, provides installation
    /// commands, and can execute installation programmatically.
    @Observable
    @MainActor
    final public class PluginService {
        // MARK: - Installation State

        /// Current state of the plugin installation
        public enum State: Equatable, Sendable {
            case unknown
            case checking
            case installed(version: String)
            case notInstalled
            case installing
            case installationFailed(String)
        }

        // MARK: - Properties

        private let logger = Logger(label: "com.claudespy.plugin")
        private let fileManager = FileManager.default
        private let processRunner = ProcessRunner()

        /// Current plugin state
        public private(set) var state: State = .unknown

        /// Path to the bundled plugin (in app Resources)
        public var bundledPluginPath: URL? {
            Bundle.main.resourceURL?.appendingPathComponent("plugin")
        }

        /// Installation output for display
        public private(set) var installationOutput = ""

        // MARK: - Claude Plugin Paths

        private var claudePluginsPath: URL {
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("plugins")
        }

        private var installedPluginsPath: URL {
            claudePluginsPath.appendingPathComponent("installed_plugins.json")
        }

        private var knownMarketplacesPath: URL {
            claudePluginsPath.appendingPathComponent("known_marketplaces.json")
        }

        // MARK: - Initialization

        public init() { }

        // MARK: - Public API

        /// Check if the plugin is installed (async to avoid blocking main thread)
        public func checkInstallation() async {
            state = .checking
            logger.debug("Checking plugin installation status")

            // Capture paths as Sendable strings before detached task
            let pluginsPath = installedPluginsPath.path

            // Perform file I/O in background
            let result = await Task.detached {
                let fm = FileManager.default
                guard fm.fileExists(atPath: pluginsPath) else {
                    return State.notInstalled
                }

                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: pluginsPath))
                    guard
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let plugins = json["plugins"] as? [String: Any]
                    else {
                        return State.notInstalled
                    }

                    // Look for claude-spy plugin (key format: "claude-spy@ClaudeSpy")
                    for key in plugins.keys where key.hasPrefix("claude-spy@") {
                        guard
                            let installations = plugins[key] as? [[String: Any]],
                            let firstInstall = installations.first,
                            let version = firstInstall["version"] as? String
                        else {
                            continue
                        }

                        return State.installed(version: version)
                    }

                    return State.notInstalled
                } catch {
                    return State.notInstalled
                }
            }.value

            // Log result on main actor
            switch result {
            case let .installed(version):
                logger.info("Plugin found: claude-spy v\(version)")
            case .notInstalled:
                logger.info("Plugin not installed")
            default:
                break
            }

            state = result
        }

        /// Check if the ClaudeSpy marketplace is registered (async to avoid blocking main thread)
        public func isMarketplaceRegistered() async -> Bool {
            // Capture path as Sendable string before detached task
            let marketplacesPath = knownMarketplacesPath.path

            let result = await Task.detached {
                let fm = FileManager.default
                guard fm.fileExists(atPath: marketplacesPath) else {
                    return false
                }

                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: marketplacesPath))
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return false
                    }

                    return json["ClaudeSpy"] != nil
                } catch {
                    return false
                }
            }.value

            if !result {
                logger.debug("ClaudeSpy marketplace not registered")
            }

            return result
        }

        /// Install the plugin programmatically
        public func installPlugin() async {
            guard let bundledPath = bundledPluginPath else {
                state = .installationFailed("Bundled plugin not found in app resources")
                return
            }

            state = .installing
            installationOutput = ""

            logger.info("Starting plugin installation from: \(bundledPath.path)")

            do {
                // Step 1: Add marketplace (if not already registered)
                if await !isMarketplaceRegistered() {
                    appendOutput("Adding ClaudeSpy marketplace...")
                    try await runClaudeCommand(
                        arguments: ["plugins", "add-marketplace", bundledPath.path],
                        description: "add marketplace"
                    )
                    appendOutput("Marketplace added successfully.\n")
                } else {
                    appendOutput("Marketplace already registered.\n")
                }

                // Step 2: Install the plugin with --user scope
                appendOutput("Installing claude-spy plugin...")
                try await runClaudeCommand(
                    arguments: ["plugins", "install", "claude-spy", "--user"],
                    description: "install plugin"
                )
                appendOutput("Plugin installed successfully.\n")

                // Verify installation
                await checkInstallation()

                if case .installed = state {
                    logger.info("Plugin installation completed successfully")
                } else {
                    state = .installationFailed("Plugin installation could not be verified")
                }
            } catch let error as PluginError {
                state = .installationFailed(error.localizedDescription)
                logger.error("Plugin installation failed: \(error)")
            } catch {
                state = .installationFailed(error.localizedDescription)
                logger.error("Plugin installation failed: \(error)")
            }
        }

        /// Get manual installation instructions
        public var manualInstructions: String {
            guard let bundledPath = bundledPluginPath else {
                return """
                # Plugin Not Available

                The bundled plugin was not found in the app resources.
                This indicates a corrupted installation.

                Please download the latest version of ClaudeSpy from:
                https://github.com/gpambrozio/ClaudeSpy/releases
                """
            }

            return """
            # Manual Plugin Installation

            Run these commands in your terminal:

            1. Add the marketplace:
               claude plugins add-marketplace "\(bundledPath.path)"

            2. Install the plugin:
               claude plugins install claude-spy --user
            """
        }

        // MARK: - Private Methods

        private func appendOutput(_ text: String) {
            installationOutput += text + "\n"
        }

        private func runClaudeCommand(arguments: [String], description: String) async throws {
            guard let executablePath = ClaudePathDetector.detectPath() else {
                throw PluginError.claudeNotFound(attemptedPaths: ClaudePathDetector.commonPaths)
            }
            logger.debug("Found claude at: \(executablePath)")

            logger.debug("Running claude command: \(arguments.joined(separator: " "))")

            // Use ProcessRunner for non-blocking async execution
            let result = try await processRunner.run(
                executable: executablePath,
                arguments: arguments
            )

            let output = result.stdoutString
            if !output.isEmpty {
                appendOutput(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if !result.isSuccess {
                let errorOutput = result.stderrString
                let fullError = errorOutput.isEmpty
                    ? "Command failed with exit code \(result.exitCode)"
                    : errorOutput
                appendOutput("Error: \(fullError.trimmingCharacters(in: .whitespacesAndNewlines))")
                throw PluginError.commandFailed(
                    description: description,
                    exitCode: result.exitCode,
                    error: fullError
                )
            }
        }
    }

    // MARK: - Errors

    enum PluginError: LocalizedError {
        case claudeNotFound(attemptedPaths: [String])
        case commandFailed(description: String, exitCode: Int32, error: String)
        case bundledPluginNotFound

        var errorDescription: String? {
            switch self {
            case let .claudeNotFound(paths):
                let pathList = paths.joined(separator: ", ")
                return "Claude CLI not found. Checked: \(pathList). Please ensure Claude Code is installed."
            case let .commandFailed(description, exitCode, error):
                return "Failed to \(description) (exit code \(exitCode)): \(error)"
            case .bundledPluginNotFound:
                return "Bundled plugin not found in app resources."
            }
        }
    }
#endif
