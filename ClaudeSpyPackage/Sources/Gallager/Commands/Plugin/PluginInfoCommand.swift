import ArgumentParser
import Foundation

/// `gallager plugin info <id> [--json]` — full info for a single plugin.
///
/// Surfaces manifest fields (display name, publisher, capabilities),
/// install/state paths, log file location, and the running bit. JSON
/// output is the raw RPC envelope so scripts can route through `jq`.
struct PluginInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show full info for one plugin"
    )

    @Argument(help: "Plugin id (e.g. claude-code, codex-cli)")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "plugin.info",
            params: ["id": .string(id)],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
            return
        }
        guard let result = response.result else {
            print("No info available for plugin '\(id)'.")
            return
        }
        // Print a tidy human-readable summary. Fields that the manifest
        // didn't expose appear as `(unknown)` rather than being silently
        // dropped — debugging an unfamiliar plugin is the primary use case
        // for this verb.
        func string(_ key: String, default fallback: String = "(unknown)") -> String {
            if case let .string(v) = result[key] { return v }
            return fallback
        }
        func bool(_ key: String) -> Bool {
            if case let .bool(v) = result[key] { return v }
            return false
        }
        func int(_ key: String) -> Int {
            if case let .int(v) = result[key] { return v }
            return 0
        }

        print("ID:               \(string("id"))")
        if case let .string(name) = result["display_name"] {
            print("Name:             \(name)")
        }
        if case let .string(publisher) = result["publisher"] {
            print("Publisher:        \(publisher)")
        }
        print("Version:          \(string("version"))")
        print("Source:           \(string("source"))")
        print("Enabled:          \(bool("enabled"))")
        print("Running:          \(bool("running"))")
        if case let .string(installDir) = result["install_dir"] {
            print("Install dir:      \(installDir)")
        }
        print("State dir:        \(string("state_dir"))")
        print("State dir size:   \(int("state_dir_size_bytes")) bytes")
        print("Log file:         \(string("log_file"))")

        if case let .array(processNames) = result["process_names"], !processNames.isEmpty {
            let names = processNames.compactMap(\.stringValue).joined(separator: ", ")
            print("Process names:    \(names)")
        }
        if case let .object(caps) = result["capabilities"], !caps.isEmpty {
            print("Capabilities:")
            for key in caps.keys.sorted() {
                let value = caps[key].map { describe($0) } ?? "(nil)"
                print("  \(key): \(value)")
            }
        }
    }

    /// Stringifies a single JSON value for the capabilities table.
    /// Strings/bools/numbers are printed verbatim; nested arrays/objects
    /// fall back to their JSON encoding so we don't lose information.
    private func describe(_ value: JSONValue) -> String {
        switch value {
        case let .string(v): return v
        case let .bool(v): return String(v)
        case let .int(v): return String(v)
        case let .double(v): return String(v)
        case .null: return "null"
        default:
            if
                let data = try? JSONEncoder().encode(value),
                let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "(unencodable)"
        }
    }
}
