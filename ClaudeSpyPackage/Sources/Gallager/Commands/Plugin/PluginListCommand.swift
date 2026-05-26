import ArgumentParser
import Foundation

/// `gallager plugin list [--json]` — print every installed plugin.
///
/// Default output is one line per plugin, tab-separated:
/// `<id> <version> <enabled> <source>`. Matches the existing CLI's
/// tabular convention so output piped through `awk`/`cut` keeps working.
struct PluginListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed plugins"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "plugin.list", options: options)
        if options.json {
            printResponse(response, json: true)
            return
        }
        guard let plugins = PluginCommandHelpers.arrayField("plugins", from: response) else {
            print("No plugins installed.")
            return
        }
        if plugins.isEmpty {
            print("No plugins installed.")
            return
        }
        // Tabular: id<TAB>version<TAB>enabled<TAB>source. Avoids alignment
        // tricks so the format stays cheap to parse with cut/awk.
        for plugin in plugins {
            guard
                case let .object(obj) = plugin,
                case let .string(id) = obj["id"],
                case let .string(version) = obj["version"],
                case let .bool(enabled) = obj["enabled"],
                case let .string(source) = obj["source"]
            else { continue }
            print("\(id)\t\(version)\t\(enabled ? "enabled" : "disabled")\t\(source)")
        }
    }
}
