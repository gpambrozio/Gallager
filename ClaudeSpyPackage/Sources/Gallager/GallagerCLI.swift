import ArgumentParser
import ClaudeSpyNetworking
import Foundation

@main
struct GallagerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gallager",
        abstract: "Control Gallager from the command line",
        subcommands: [
            // Sessions
            ListSessionsCommand.self,
            NewSessionCommand.self,
            SelectSessionCommand.self,
            CurrentSessionCommand.self,
            CloseSessionCommand.self,
            // Windows
            ListWindowsCommand.self,
            NewWindowCommand.self,
            SelectWindowCommand.self,
            CloseWindowCommand.self,
            // Panes
            ListPanesCommand.self,
            SplitPaneCommand.self,
            SelectPaneCommand.self,
            // Input
            SendCommand.self,
            SendKeyCommand.self,
            // Notifications
            NotifyCommand.self,
            // Editor
            EditCommand.self,
            // Utility
            PingCommand.self,
            CapabilitiesCommand.self,
            IdentifyCommand.self,
        ]
    )
}

/// Global options shared across all commands.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Custom socket path")
    var socket: String?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Target specific pane")
    var pane: String?

    @Option(name: .long, help: "Target specific session")
    var session: String?

    @Option(name: .long, help: "Target specific window")
    var window: String?
}

/// Helper to send a request and handle common error reporting.
func executeRequest(
    method: String,
    params: [String: JSONValue] = [:],
    options: GlobalOptions
) throws -> JSONRPCResponse {
    let request = JSONRPCRequest(
        id: UUID().uuidString,
        method: method,
        params: params
    )
    let response = try SocketClient.send(request, socketPath: options.socket)
    if !response.ok, let error = response.error {
        throw ValidationError("Error: \(error.message)")
    }
    return response
}

/// Prints a response as JSON or as formatted text.
func printResponse(_ response: JSONRPCResponse, json: Bool) {
    if json {
        if
            let data = try? JSONEncoder().encode(response),
            let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    } else if let result = response.result {
        if
            let data = try? JSONEncoder().encode(result),
            let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
