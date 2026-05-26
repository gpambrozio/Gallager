import ArgumentParser
import Foundation

/// `gallager plugin update [<id>] [--apply]` — check for plugin updates.
///
/// v1: no auto-update mechanism. The app always returns an empty list, so
/// the CLI prints "No updates available." regardless of flags. `--apply`
/// is parsed for forward compatibility; v2 will wire it through to the
/// manager's installer.
struct PluginUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for plugin updates (v1 stub — always reports none)"
    )

    @Argument(help: "Plugin id (omit to check every plugin)")
    var id: String?

    @Flag(name: .long, help: "Apply available updates (v1: no-op — auto-update lands in v2)")
    var apply = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let id { params["id"] = .string(id) }
        if apply { params["apply"] = .bool(true) }
        let response = try executeRequest(
            method: "plugin.update",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
            return
        }
        guard let updates = PluginCommandHelpers.arrayField("updates", from: response) else {
            print("No updates available.")
            return
        }
        if updates.isEmpty {
            print("No updates available.")
            return
        }
        for update in updates {
            guard
                case let .object(obj) = update,
                case let .string(updateId) = obj["id"],
                case let .string(current) = obj["current_version"],
                case let .string(latest) = obj["latest_version"]
            else { continue }
            print("\(updateId)\t\(current) → \(latest)")
        }
    }
}
