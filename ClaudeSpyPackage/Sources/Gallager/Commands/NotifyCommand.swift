import ArgumentParser
import ClaudeSpyNetworking
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

    @Option(name: .long, help: "Notification subtitle")
    var subtitle: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [
            "title": .string(title),
            "body": .string(body),
        ]
        if let subtitle { params["subtitle"] = .string(subtitle) }
        if let tmuxPane = ProcessInfo.processInfo.environment["TMUX_PANE"] {
            params["pane_id"] = .string(tmuxPane)
        }
        let response = try executeRequest(method: "notification.create", params: params, options: options)
        printResponse(response, json: options.json)
    }
}
