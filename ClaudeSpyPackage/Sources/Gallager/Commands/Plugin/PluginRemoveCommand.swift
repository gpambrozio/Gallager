import ArgumentParser
import Foundation

/// `gallager plugin remove <id> [--keep-state | --delete-state]` —
/// uninstall a plugin.
///
/// Bundled plugins refuse uninstall by design (Spec §17.4 / §10.3); the
/// app surfaces the error via JSON-RPC and the CLI re-throws it.
struct PluginRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Uninstall a plugin (URL-installed only)"
    )

    @Argument(help: "Plugin id")
    var id: String

    /// `--keep-state` and `--delete-state` are mutually exclusive flags.
    /// Argument Parser doesn't have an Either-flag helper, so we expose
    /// two `@Flag`s and validate in `run()`.
    @Flag(name: .long, help: "Keep the plugin's state directory (logs, settings).")
    var keepState = false

    @Flag(name: .long, help: "Also delete the plugin's state directory.")
    var deleteState = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        if keepState, deleteState {
            throw ValidationError("--keep-state and --delete-state are mutually exclusive")
        }
        // v1: the app currently always tears down the state dir on
        // uninstall. `--keep-state` is parsed for forward compatibility
        // but not yet honored; v2 will route the flag into the manager.
        let params: [String: JSONValue] = [
            "id": .string(id),
            "delete_state": .bool(deleteState || !keepState),
        ]
        let response = try executeRequest(
            method: "plugin.remove",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            print("Removed plugin \(id).")
        }
    }
}
