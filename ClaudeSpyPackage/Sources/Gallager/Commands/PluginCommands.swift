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
            printResponse(response, json: true)
            // `--json -f` would interleave repeated JSON envelopes; the follow
            // loop below only runs for human output.
            if follow { followLoop(printedSoFar: extractLines(from: response).count) }
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
