import ArgumentParser
import Foundation

// MARK: - plugin (parent verb group, spec §14)

/// `gallager plugin <subcommand>` — inspect and drive the in-process plugin
/// runtime (spec §14). All state lives in the running Gallager app; these verbs
/// are thin JSON-RPC clients over the existing Unix socket.
struct PluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Inspect and manage Gallager plugins",
        subcommands: [
            PluginListCommand.self,
            PluginInfoCommand.self,
            PluginEnableCommand.self,
            PluginDisableCommand.self,
            PluginLogsCommand.self,
            PluginCallCommand.self,
            PluginInstallCommand.self,
            PluginRemoveCommand.self,
            PluginUpdateCommand.self,
        ]
    )
}

// MARK: - Shared error reporting

/// Sends a request and returns the response. On a JSON-RPC error, prints
/// `Error: <message>` to stderr and exits 1 (spec §14: unknown id / failures go
/// to stderr with a non-zero exit). Connection/transport errors propagate as
/// the usual `CLIError` (also stderr + non-zero via ArgumentParser).
private func pluginRequest(
    method: String,
    params: [String: JSONValue] = [:],
    options: GlobalOptions
) throws -> JSONRPCResponse {
    let request = JSONRPCRequest(id: UUID().uuidString, method: method, params: params)
    let response = try SocketClient.send(request, socketPath: options.socket)
    if !response.ok, let error = response.error {
        FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
        throw ExitCode.failure
    }
    return response
}

// MARK: - plugin list

struct PluginListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all plugins (id, version, enabled, source)"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try pluginRequest(method: "plugin.list", options: options)
        if options.json {
            printResponse(response, json: true)
            return
        }
        guard
            let result = response.result,
            case let .array(plugins) = result["plugins"]
        else {
            return
        }
        for plugin in plugins {
            guard case let .object(obj) = plugin else { continue }
            let id = obj["id"]?.stringValue ?? "?"
            let version = obj["version"]?.stringValue ?? ""
            let enabled = obj["enabled"]?.boolValue == true ? "enabled" : "disabled"
            let source = obj["source"]?.stringValue ?? ""
            print("\(id)\t\(version)\t\(enabled)\t\(source)")
        }
    }
}

// MARK: - plugin info

struct PluginInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show a plugin's manifest, state, and log path"
    )

    @Argument(help: "Plugin id (e.g. claude-code, codex)")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try pluginRequest(
            method: "plugin.info",
            params: ["id": .string(id)],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
            return
        }
        guard let result = response.result else { return }
        let version = result["version"]?.stringValue ?? ""
        let enabled = result["enabled"]?.boolValue == true ? "enabled" : "disabled"
        print("id:            \(result["id"]?.stringValue ?? id)")
        print("version:       \(version)")
        print("state:         \(enabled)")
        if case let .string(failure) = result["failedInit"] {
            print("failed-init:   \(failure)")
        }
        print("source:        \(result["source"]?.stringValue ?? "")")
        print("log:           \(result["logPath"]?.stringValue ?? "")")
        if let bytes = result["stateDirBytes"]?.intValue {
            print("state-dir:     \(bytes) bytes")
        }
    }
}

// MARK: - plugin enable / disable

struct PluginEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a plugin (construct + initialize its core)"
    )

    @Argument(help: "Plugin id to enable")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try pluginRequest(
            method: "plugin.enable",
            params: ["id": .string(id)],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else {
            let enabled = response.result?["enabled"]?.boolValue == true
            print(enabled ? "Enabled \(id)" : "Plugin \(id) failed to initialize")
        }
    }
}

struct PluginDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a plugin (shut down its core; files are kept)"
    )

    @Argument(help: "Plugin id to disable")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try pluginRequest(
            method: "plugin.disable",
            params: ["id": .string(id)],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else {
            print("Disabled \(id)")
        }
    }
}

// MARK: - plugin logs

struct PluginLogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print (or follow) a plugin's log file"
    )

    @Argument(help: "Plugin id whose logs to print")
    var id: String

    @Flag(name: .shortAndLong, help: "Follow the log file, printing new lines as they arrive")
    var follow = false

    @Option(name: .long, help: "Print only the last N lines")
    var lines: Int?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["id": .string(id)]
        if let lines {
            params["lines"] = .int(lines)
        }
        let response = try pluginRequest(method: "plugin.logs", params: params, options: options)

        if options.json {
            // Emit the single JSON-RPC envelope and stop. `-f` is intentionally
            // ignored in `--json` mode: tailing would append bare (non-JSON) log
            // lines after the envelope and break the machine-readable contract.
            printResponse(response, json: true)
            if follow {
                FileHandle.standardError.write(
                    Data("note: --follow is ignored with --json (tailing would corrupt the JSON stream)\n".utf8)
                )
            }
            return
        }

        let initial = extractLines(from: response)
        for line in initial {
            print(line)
        }
        if follow {
            followLoop(printedSoFar: initial.count)
        }
    }

    /// Poll `plugin.logs` and print lines that appeared after the first
    /// `printedSoFar` lines. Mirrors `wait-ready`'s `Thread.sleep` polling; the
    /// server has no push channel, so follow is client-side tailing. Runs until
    /// interrupted (Ctrl-C).
    private func followLoop(printedSoFar: Int) {
        var seen = printedSoFar
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            guard
                let response = try? pluginRequest(
                    method: "plugin.logs",
                    params: ["id": .string(id)],
                    options: options
                )
            else {
                continue
            }
            let all = extractLines(from: response)
            // The log file rotates at 5 MB; if it shrank we reset and reprint
            // from the start of the new (rotated) file rather than miss lines.
            if all.count < seen {
                seen = 0
            }
            if all.count > seen {
                for line in all[seen...] {
                    print(line)
                }
                seen = all.count
            }
        }
    }

    /// Pull the `lines` string array out of a `plugin.logs` response.
    private func extractLines(from response: JSONRPCResponse) -> [String] {
        guard
            let result = response.result,
            case let .array(values) = result["lines"]
        else {
            return []
        }
        return values.compactMap(\.stringValue)
    }
}

// MARK: - plugin call

struct PluginCallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "call",
        abstract: "Dispatch a debugging method into a plugin's in-process core",
        discussion: """
        Methods: enable, disable, refreshProjects, installStatus, install, uninstall.
        Optionally pass a JSON argument string as the third positional.
        """
    )

    @Argument(help: "Plugin id")
    var id: String

    @Argument(help: "Method name (e.g. refreshProjects, installStatus, install, uninstall)")
    var method: String

    @Argument(help: "Optional JSON argument string")
    var json: String?

    @Option(
        name: .customLong("config-root"),
        help: "Config root (CLAUDE_CONFIG_DIR / CODEX_HOME) to scope install/uninstall/installStatus to."
    )
    var configRoot: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [
            "id": .string(id),
            "method": .string(method),
        ]
        if let json {
            params["json"] = .string(json)
        }
        if let configRoot {
            params["configRoot"] = .string(configRoot)
        }
        let response = try pluginRequest(method: "plugin.call", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result {
            let ok = result["ok"]?.boolValue == true
            let detail = result["result"]?.stringValue ?? ""
            print("\(method): \(ok ? "ok" : "failed")\(detail.isEmpty ? "" : " (\(detail))")")
        }
    }
}

// MARK: - plugin install

struct PluginInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a sidecar plugin from an HTTPS manifest URL or a local .zip",
        discussion: """
        Installs a plugin either from a remote manifest URL (must use https://) or
        from a local .zip bundle via --zip (plugin.json + executable at the archive
        root). The plugin's trust details (display name, publisher, version, source,
        and — for URL installs — bundle URL + SHA-256) are printed before
        installation; you are asked to confirm unless --yes is passed.

        Examples:
          gallager plugin install https://example.com/plugin.json
          gallager plugin install --zip ./my-agent.zip
        """
    )

    @Argument(help: "HTTPS URL of the plugin's plugin.json manifest")
    var url: String?

    @Option(name: .long, help: "Path to a local .zip bundle to install instead of a URL")
    var zip: String?

    @Flag(name: .long, help: "Skip the trust confirmation prompt and install immediately")
    var yes = false

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        guard (url != nil) != (zip != nil) else {
            throw ValidationError("Provide exactly one of <url> or --zip <path>")
        }
    }

    func run() throws {
        // Resolve the install source into the JSON-RPC params + a label for output.
        let baseParams: [String: JSONValue]
        let sourceLabel: String
        if let zip {
            // Resolve to an absolute path: the app process has a different working
            // directory, so a relative path would not resolve on its side.
            let expanded = (zip as NSString).expandingTildeInPath
            let absolute = (expanded as NSString).isAbsolutePath
                ? expanded
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expanded).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: absolute) else {
                FileHandle.standardError.write(Data("Error: No such file: \(absolute)\n".utf8))
                throw ExitCode.failure
            }
            baseParams = ["path": .string(absolute)]
            sourceLabel = absolute
        } else if let url {
            // Enforce HTTPS on the client side (server validates too).
            guard url.hasPrefix("https://") else {
                FileHandle.standardError.write(Data("Error: URL must use https:// (got: \(url))\n".utf8))
                throw ExitCode.failure
            }
            baseParams = ["url": .string(url)]
            sourceLabel = url
        } else {
            // validate() guarantees exactly one source; defensive.
            throw ExitCode.failure
        }

        // First call: trustConfirmed = false → get trust details.
        var trustParams = baseParams
        trustParams["trustConfirmed"] = .bool(false)
        let trustResponse = try pluginRequest(
            method: "plugin.install",
            params: trustParams,
            options: options
        )

        if options.json {
            printResponse(trustResponse, json: true)
            return
        }

        guard let result = trustResponse.result else {
            throw ExitCode.failure
        }

        let status = result["status"]?.stringValue ?? ""

        if status == "installed" {
            // Already installed (shouldn't happen on first call, but handle gracefully).
            print("Installed: \(result["id"]?.stringValue ?? sourceLabel)")
            return
        }

        guard
            status == "needs_trust",
            case let .object(trust) = result["trust"] else {
            FileHandle.standardError.write(Data("Error: Unexpected response from server\n".utf8))
            throw ExitCode.failure
        }

        // Print trust details.
        print("Plugin details:")
        print("  Display name : \(trust["displayName"]?.stringValue ?? "(unknown)")")
        if let publisher = trust["publisher"]?.stringValue {
            print("  Publisher    : \(publisher)")
        }
        print("  Version      : \(trust["version"]?.stringValue ?? "(unknown)")")
        print("  Source       : \(trust["sourceURL"]?.stringValue ?? sourceLabel)")
        if let bundleURL = trust["bundleURL"]?.stringValue {
            print("  Bundle URL   : \(bundleURL)")
        }
        if let sha256 = trust["bundleSHA256"]?.stringValue {
            print("  SHA-256      : \(sha256)")
        }
        if let sizeBytes = trust["bundleSizeBytes"]?.intValue {
            let kb = sizeBytes / 1_024
            print("  Bundle size  : \(kb > 0 ? "\(kb) KB" : "\(sizeBytes) bytes")")
        }
        print("")
        print("WARNING: Only install plugins from sources you trust.")

        if !yes {
            print("Install this plugin? [y/N] ", terminator: "")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                print("Aborted.")
                throw ExitCode.failure
            }
        }

        // Second call: trustConfirmed = true → actually install.
        var confirmParams = baseParams
        confirmParams["trustConfirmed"] = .bool(true)
        let installResponse = try pluginRequest(
            method: "plugin.install",
            params: confirmParams,
            options: options
        )

        if options.json {
            printResponse(installResponse, json: true)
            return
        }

        guard
            let installResult = installResponse.result,
            installResult["status"]?.stringValue == "installed" else {
            throw ExitCode.failure
        }
        print("Installed: \(installResult["id"]?.stringValue ?? sourceLabel)")
    }
}

// MARK: - plugin remove

struct PluginRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an installed plugin",
        discussion: """
        Removes a URL-installed or folder-drop plugin. Bundled plugins (claude-code,
        codex) cannot be removed. By default the plugin's state directory is kept;
        pass --delete-state to remove it as well.
        """
    )

    @Argument(help: "Plugin id to remove")
    var id: String

    @Flag(
        name: .customLong("keep-state"),
        help: "Keep the plugin's state directory after removal (default)"
    )
    var keepState = false

    @Flag(
        name: .customLong("delete-state"),
        help: "Also delete the plugin's state directory"
    )
    var deleteState = false

    @OptionGroup var options: GlobalOptions

    func validate() throws {
        if keepState && deleteState {
            throw ValidationError("--keep-state and --delete-state are mutually exclusive")
        }
    }

    func run() throws {
        // Default: keep state unless --delete-state is explicitly passed.
        let shouldDeleteState = deleteState && !keepState
        let response = try pluginRequest(
            method: "plugin.remove",
            params: ["id": .string(id), "deleteState": .bool(shouldDeleteState)],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
            return
        }
        if response.ok {
            print("Removed \(id)\(shouldDeleteState ? " (state deleted)" : " (state kept)")")
        }
        // Non-ok responses are already handled by pluginRequest (prints + throws ExitCode.failure).
    }
}

// MARK: - plugin update

struct PluginUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for (or apply) plugin updates",
        discussion: """
        Without --apply, lists which URL-installed plugins have newer versions
        available. With --apply, downloads and installs them. Omit <id> to check
        all URL-installed plugins.
        """
    )

    @Argument(help: "Plugin id to check/update (default: all)")
    var id: String?

    @Flag(name: .long, help: "Download and install available updates")
    var apply = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["apply": .bool(apply)]
        if let id {
            params["id"] = .string(id)
        }
        let response = try pluginRequest(method: "plugin.update", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
            return
        }
        guard let result = response.result else { return }
        guard case let .array(updates) = result["updates"] else { return }
        if updates.isEmpty {
            print(id.map { "Plugin '\($0)' is up to date." } ?? "All plugins are up to date.")
            return
        }
        for update in updates {
            guard case let .object(obj) = update else { continue }
            let pluginId = obj["id"]?.stringValue ?? "?"
            let current = obj["currentVersion"]?.stringValue ?? "?"
            let newer = obj["newVersion"]?.stringValue ?? "?"
            if apply {
                let applied = obj["applied"]?.boolValue == true
                let note = obj["note"]?.stringValue
                if applied {
                    print("Updated \(pluginId): \(current) → \(newer)")
                } else if let note {
                    print("Skipped \(pluginId): \(note)")
                } else {
                    print("Failed to update \(pluginId)")
                }
            } else {
                let changed = obj["sourceChanged"]?.boolValue == true ? " (source changed)" : ""
                print("Update available: \(pluginId) \(current) → \(newer)\(changed)")
            }
        }
    }
}
