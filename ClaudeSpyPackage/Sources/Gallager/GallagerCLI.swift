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
            SetTitleCommand.self,
            SetColorCommand.self,
            SetEmojiCommand.self,
            FindEmojiCommand.self,
            // Windows
            ListWindowsCommand.self,
            NewWindowCommand.self,
            SelectWindowCommand.self,
            RenameWindowCommand.self,
            CloseWindowCommand.self,
            // Panes
            ListPanesCommand.self,
            SplitPaneCommand.self,
            SelectPaneCommand.self,
            CapturePaneCommand.self,
            SetProgressCommand.self,
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
            // Layouts
            ApplyCommand.self,
            // Utility
            PingCommand.self,
            WaitReadyCommand.self,
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

    /// The pane ID for the calling shell, derived from `$TMUX_PANE`.
    ///
    /// Returns `nil` when running outside tmux. Each command decides whether
    /// to fall back to this value based on which targeting flags it actually
    /// consumes — irrelevant flags should not suppress the fallback.
    var callingPaneId: String? {
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
