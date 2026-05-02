import ArgumentParser
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
            SessionStateCommand.self,
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
            // Projects
            ListProjectsCommand.self,
            StartProjectCommand.self,
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

    /// The pane to operate on when no explicit targeting flag was passed.
    ///
    /// Returns the explicit `--pane` value if given. Otherwise, when none of
    /// `--pane`/`--session`/`--window` were specified, falls back to
    /// `$TMUX_PANE` so commands operate on the pane where they were invoked
    /// instead of whatever pane happens to be globally active in tmux.
    var defaultPaneId: String? {
        if let pane { return pane }
        guard session == nil, window == nil else { return nil }
        let envPane = ProcessInfo.processInfo.environment["TMUX_PANE"]
        return envPane?.isEmpty == false ? envPane : nil
    }
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
        throw CleanExit.message("Error: \(error.message)")
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
