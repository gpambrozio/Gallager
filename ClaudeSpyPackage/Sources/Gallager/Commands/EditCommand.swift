import ArgumentParser
import Foundation

struct EditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Open file in prompt editor (blocks until done)"
    )

    @Argument(help: "File path to edit")
    var file: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        guard let paneId = ProcessInfo.processInfo.environment["TMUX_PANE"], !paneId.isEmpty else {
            throw ValidationError("TMUX_PANE not set")
        }

        let request = JSONRPCRequest(
            id: UUID().uuidString,
            method: "editor.open",
            params: [
                "pane_id": .string(paneId),
                "file_path": .string(file),
            ]
        )

        // This blocks until the user finishes editing in the app
        _ = try SocketClient.sendAndWait(request, socketPath: options.socket)
    }
}
