import ArgumentParser
import Foundation

/// `gallager plugin disable <id>` — shut down a plugin's sidecar without
/// uninstalling it.
///
/// The plugin's files stay on disk; re-running `gallager plugin enable
/// <id>` brings it back. Idempotent.
struct PluginDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a plugin (shuts down its sidecar)"
    )

    @Argument(help: "Plugin id")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "plugin.disable",
            params: ["id": .string(id)],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            print("Disabled plugin \(id).")
        }
    }
}
