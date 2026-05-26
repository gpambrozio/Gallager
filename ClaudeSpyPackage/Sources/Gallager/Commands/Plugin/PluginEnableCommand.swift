import ArgumentParser
import Foundation

/// `gallager plugin enable <id>` — re-enable a previously-disabled plugin.
///
/// Spawns its sidecar and reloads the presentation bundle. Idempotent — a
/// no-op when the plugin is already enabled.
struct PluginEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a plugin (spawns its sidecar)"
    )

    @Argument(help: "Plugin id")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "plugin.enable",
            params: ["id": .string(id)],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            print("Enabled plugin \(id).")
        }
    }
}
