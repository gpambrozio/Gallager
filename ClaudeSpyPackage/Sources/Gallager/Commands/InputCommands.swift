import ArgumentParser
import Foundation

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send text to focused/specified pane"
    )

    @Argument(help: "Text to send")
    var text: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["text": .string(text)]
        if let pane = options.pane ?? options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        let response = try executeRequest(method: "input.send_text", params: params, options: options)
        printResponse(response, json: options.json)
    }
}

struct SendKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-key",
        abstract: "Send a key press"
    )

    @Argument(help: "Key name: enter, tab, escape, backspace, delete, up, down, left, right, space")
    var key: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["key": .string(key)]
        if let pane = options.pane ?? options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        let response = try executeRequest(method: "input.send_key", params: params, options: options)
        printResponse(response, json: options.json)
    }
}
