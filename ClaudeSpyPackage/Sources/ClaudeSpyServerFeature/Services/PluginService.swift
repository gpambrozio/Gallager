#if os(macOS)
    import ClaudeSpyCommon
    import Dependencies
    import Foundation
    import Logging

    /// Manages the Claude Code plugin detection and installation.
    ///
    /// Checks if the gallager plugin is installed, provides installation
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

        @ObservationIgnored
        @Dependency(ProcessRunner.self) private var processRunner

        @ObservationIgnored
        @Dependency(ClaudePathDetector.self) private var claudePathDetector

        /// Current plugin state
        public private(set) var state: State = .unknown

        /// Path to the bundled plugin (in app Resources)
        public var bundledPluginPath: URL? {
            Bundle.main.resourceURL?.appendingPathComponent("plugin")
        }

        /// Installation output for display
        public private(set) var installationOutput = ""

        /// Detailed diagnostic for the most recent failed installation attempt.
        ///
        /// Populated whenever `state` transitions to `.installationFailed`, and cleared
        /// when a new attempt starts or a previous attempt succeeds. UI code uses this
        /// to offer a "Show Details" popover with a copy-to-clipboard report.
        public private(set) var lastFailure: PluginInstallationFailure?

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

                    // Look for gallager plugin (key format: "gallager@Gallager")
                    for key in plugins.keys where key.hasPrefix("gallager@") {
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
                logger.info("Plugin found: gallager v\(version)")
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
                recordFailure(
                    summary: "Bundled plugin not found in app resources",
                    failedStep: "Locate bundled plugin",
                    claudePath: nil,
                    command: nil,
                    exitCode: nil,
                    stdout: nil,
                    stderr: nil,
                    underlyingError: nil
                )
                return
            }

            state = .installing
            installationOutput = ""
            lastFailure = nil

            logger.info("Starting plugin installation from: \(bundledPath.path)")

            do {
                // Step 1: Add marketplace (if not already registered)
                if await !isMarketplaceRegistered() {
                    appendOutput("Adding ClaudeSpy marketplace...")
                    try await runClaudeCommand(
                        step: "add marketplace",
                        arguments: ["plugin", "marketplace", "add", bundledPath.path]
                    )
                    appendOutput("Marketplace added successfully.\n")
                } else {
                    appendOutput("Marketplace already registered.\n")
                }

                // Step 2: Install the plugin with user scope
                appendOutput("Installing gallager plugin...")
                try await runClaudeCommand(
                    step: "install plugin",
                    arguments: ["plugin", "install", "gallager", "--scope", "user"]
                )
                appendOutput("Plugin installed successfully.\n")

                // Verify installation
                await checkInstallation()

                if case .installed = state {
                    logger.info("Plugin installation completed successfully")
                    lastFailure = nil
                } else {
                    recordFailure(
                        summary: "Plugin installation could not be verified",
                        failedStep: "Verify installation",
                        claudePath: claudePathDetector.detectPath(),
                        command: nil,
                        exitCode: nil,
                        stdout: nil,
                        stderr: nil,
                        underlyingError: "After running the install commands, the gallager plugin did not appear in ~/.claude/plugins/installed_plugins.json."
                    )
                }
            } catch let error as PluginError {
                logger.error("Plugin installation failed: \(error)")
                recordFailure(from: error)
            } catch {
                logger.error("Plugin installation failed: \(error)")
                recordFailure(
                    summary: error.localizedDescription,
                    failedStep: "Run installation command",
                    claudePath: claudePathDetector.detectPath(),
                    command: nil,
                    exitCode: nil,
                    stdout: nil,
                    stderr: nil,
                    underlyingError: String(describing: error)
                )
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
               claude plugin marketplace add "\(bundledPath.path)"

            2. Install the plugin:
               claude plugin install gallager --scope user
            """
        }

        // MARK: - Private Methods

        private func appendOutput(_ text: String) {
            installationOutput += text + "\n"
        }

        private func runClaudeCommand(step: String, arguments: [String]) async throws {
            guard let executablePath = claudePathDetector.detectPath() else {
                throw PluginError.claudeNotFound(attemptedPaths: ClaudePathDetector.commonPaths)
            }
            logger.debug("Found claude at: \(executablePath)")
            logger.debug("Running claude command: \(arguments.joined(separator: " "))")

            let result: ProcessResult
            do {
                result = try await processRunner.run(
                    executable: executablePath,
                    arguments: arguments,
                    environment: nil,
                    timeout: nil
                )
            } catch {
                throw PluginError.processRunFailed(
                    step: step,
                    executable: executablePath,
                    arguments: arguments,
                    underlyingError: String(describing: error)
                )
            }

            let stdout = result.stdoutString
            let stderr = result.stderrString

            let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedStdout.isEmpty {
                appendOutput(trimmedStdout)
            }

            if !result.isSuccess {
                let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let errorMessage = trimmedStderr.isEmpty
                    ? "Command failed with exit code \(result.exitCode)"
                    : trimmedStderr
                appendOutput("Error: \(errorMessage)")
                throw PluginError.commandFailed(
                    step: step,
                    executable: executablePath,
                    arguments: arguments,
                    exitCode: result.exitCode,
                    stdout: stdout,
                    stderr: stderr
                )
            }
        }

        // MARK: - Failure Recording

        private func recordFailure(
            summary: String,
            failedStep: String,
            claudePath: String?,
            command: (executable: String, arguments: [String])?,
            exitCode: Int32?,
            stdout: String?,
            stderr: String?,
            underlyingError: String?
        ) {
            let commandLine = command.map { Self.formatCommandLine(executable: $0.executable, arguments: $0.arguments) }
            let failure = PluginInstallationFailure(
                summary: summary,
                failedStep: failedStep,
                commandLine: commandLine,
                exitCode: exitCode,
                stdout: stdout.flatMap { $0.isEmpty ? nil : $0 },
                stderr: stderr.flatMap { $0.isEmpty ? nil : $0 },
                installationLog: installationOutput,
                claudePath: claudePath,
                bundledPluginPath: bundledPluginPath?.path,
                underlyingError: underlyingError,
                appVersion: Self.currentAppVersion,
                osVersion: Self.currentOSVersion,
                timestamp: Date()
            )
            lastFailure = failure
            state = .installationFailed(summary)
        }

        private func recordFailure(from error: PluginError) {
            switch error {
            case let .claudeNotFound(paths):
                let searched = "Searched common paths:\n" + paths.map { "  • \($0)" }.joined(separator: "\n")
                recordFailure(
                    summary: "Claude CLI not found",
                    failedStep: "Locate claude CLI",
                    claudePath: nil,
                    command: nil,
                    exitCode: nil,
                    stdout: nil,
                    stderr: searched,
                    underlyingError: nil
                )
            case let .commandFailed(step, executable, arguments, exitCode, stdout, stderr):
                recordFailure(
                    summary: error.localizedDescription ?? "Command failed",
                    failedStep: step,
                    claudePath: executable,
                    command: (executable, arguments),
                    exitCode: exitCode,
                    stdout: stdout,
                    stderr: stderr,
                    underlyingError: nil
                )
            case let .processRunFailed(step, executable, arguments, underlying):
                recordFailure(
                    summary: error.localizedDescription ?? "Failed to launch command",
                    failedStep: step,
                    claudePath: executable,
                    command: (executable, arguments),
                    exitCode: nil,
                    stdout: nil,
                    stderr: nil,
                    underlyingError: underlying
                )
            case .bundledPluginNotFound:
                recordFailure(
                    summary: "Bundled plugin not found in app resources",
                    failedStep: "Locate bundled plugin",
                    claudePath: nil,
                    command: nil,
                    exitCode: nil,
                    stdout: nil,
                    stderr: nil,
                    underlyingError: nil
                )
            }
        }

        // MARK: - Environment Helpers

        private static var currentAppVersion: String {
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = info?["CFBundleVersion"] as? String ?? "unknown"
            return "\(version) (\(build))"
        }

        private static var currentOSVersion: String {
            let osVer = ProcessInfo.processInfo.operatingSystemVersion
            return "macOS \(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        }

        private static func formatCommandLine(executable: String, arguments: [String]) -> String {
            let quoted = arguments.map { argument -> String in
                if argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) {
                    let escaped = argument.replacingOccurrences(of: "\"", with: "\\\"")
                    return "\"\(escaped)\""
                }
                return argument
            }
            return ([executable] + quoted).joined(separator: " ")
        }
    }

    // MARK: - Failure Diagnostic

    /// Structured diagnostic data for a failed plugin installation attempt.
    ///
    /// Captures everything useful for troubleshooting and sharing with a developer:
    /// the failed step, the command that was run, its exit code and output streams,
    /// the accumulated installation log, and environment info (app version, OS, etc.).
    ///
    /// Use `report` to get a formatted, copy-paste-friendly representation.
    public struct PluginInstallationFailure: Sendable, Equatable {
        public let summary: String
        public let failedStep: String
        public let commandLine: String?
        public let exitCode: Int32?
        public let stdout: String?
        public let stderr: String?
        public let installationLog: String
        public let claudePath: String?
        public let bundledPluginPath: String?
        public let underlyingError: String?
        public let appVersion: String
        public let osVersion: String
        public let timestamp: Date

        /// Human-readable, multi-section diagnostic report suitable for clipboard sharing.
        public var report: String {
            var lines: [String] = []
            lines.append("Gallager Plugin Installation Failure")
            lines.append(String(repeating: "=", count: 40))

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            lines.append("Time:        \(formatter.string(from: timestamp))")
            lines.append("App version: \(appVersion)")
            lines.append("OS version:  \(osVersion)")
            lines.append("")

            lines.append("Failed step: \(failedStep)")
            lines.append("Summary:     \(summary)")
            lines.append("")

            lines.append("Claude CLI path:     \(claudePath ?? "(not found)")")
            if let bundledPluginPath {
                lines.append("Bundled plugin path: \(bundledPluginPath)")
            } else {
                lines.append("Bundled plugin path: (not found)")
            }
            lines.append("")

            if let commandLine {
                lines.append("Command:")
                lines.append("  \(commandLine)")
            }
            if let exitCode {
                lines.append("Exit code: \(exitCode)")
            }
            if let underlyingError {
                lines.append("Underlying error: \(underlyingError)")
            }
            if commandLine != nil || exitCode != nil || underlyingError != nil {
                lines.append("")
            }

            if let stdout, !stdout.isEmpty {
                lines.append("--- stdout ---")
                lines.append(stdout)
                lines.append("")
            }

            if let stderr, !stderr.isEmpty {
                lines.append("--- stderr ---")
                lines.append(stderr)
                lines.append("")
            }

            let trimmedLog = installationLog.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLog.isEmpty {
                lines.append("--- Installation log ---")
                lines.append(trimmedLog)
            }

            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Errors

    enum PluginError: LocalizedError {
        case claudeNotFound(attemptedPaths: [String])
        case commandFailed(
            step: String,
            executable: String,
            arguments: [String],
            exitCode: Int32,
            stdout: String,
            stderr: String
        )
        case processRunFailed(
            step: String,
            executable: String,
            arguments: [String],
            underlyingError: String
        )
        case bundledPluginNotFound

        var errorDescription: String? {
            switch self {
            case let .claudeNotFound(paths):
                let pathList = paths.joined(separator: ", ")
                return "Claude CLI not found. Checked: \(pathList). Please ensure Claude Code is installed."
            case let .commandFailed(step, _, _, exitCode, _, stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "Failed to \(step) (exit code \(exitCode))"
                }
                return "Failed to \(step) (exit code \(exitCode)): \(trimmed)"
            case let .processRunFailed(step, _, _, underlying):
                return "Failed to launch command for \(step): \(underlying)"
            case .bundledPluginNotFound:
                return "Bundled plugin not found in app resources."
            }
        }
    }
#endif
