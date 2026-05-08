import ArgumentParser
import Foundation

struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Send a desktop notification"
    )

    @Option(name: .long, help: "Notification title")
    var title: String

    @Option(name: .long, help: "Notification body")
    var body: String

    @Flag(name: .long, help: "Also push to paired iOS devices via the relay server")
    var push = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [
            "title": .string(title),
            "body": .string(body),
        ]
        if let tmuxPane = ProcessInfo.processInfo.environment["TMUX_PANE"] {
            params["pane_id"] = .string(tmuxPane)
        }
        if push {
            params["push"] = .bool(true)
        }
        let response = try executeRequest(method: "notification.create", params: params, options: options)
        printResponse(response, json: options.json)
    }
}
