import ArgumentParser
import Foundation

/// Parent command for the `gallager plugin <verb>` family (Spec §17.4).
///
/// All subcommands talk to the running Gallager app over the existing
/// Unix-socket JSON-RPC channel — no separate plugin transport.
struct PluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage Gallager plugins",
        subcommands: [
            PluginListCommand.self,
            PluginInfoCommand.self,
            PluginInstallCommand.self,
            PluginRemoveCommand.self,
            PluginEnableCommand.self,
            PluginDisableCommand.self,
            PluginUpdateCommand.self,
            PluginCallCommand.self,
            PluginLogsCommand.self,
        ]
    )
}

// MARK: - Shared helpers

enum PluginCommandHelpers {
    /// Pulls a top-level `{ "plugins": [ ... ] }` shape (or one of its
    /// siblings) out of a JSON-RPC response. Subcommands use this so they
    /// don't all have to hand-roll the same enum-pattern dance.
    static func arrayField(_ key: String, from response: JSONRPCResponse) -> [JSONValue]? {
        guard
            let result = response.result,
            case let .array(items) = result[key]
        else { return nil }
        return items
    }

    /// Read a single-line response field. Used for things like `content`
    /// (logs) where the result is a single string.
    static func stringField(_ key: String, from response: JSONRPCResponse) -> String? {
        guard
            let result = response.result,
            case let .string(value) = result[key]
        else { return nil }
        return value
    }
}
