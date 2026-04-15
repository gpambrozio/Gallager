import ArgumentParser
import Foundation

struct PingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Check if Gallager is running"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "system.ping", options: options)
        if options.json {
            printResponse(response, json: true)
        } else {
            print("pong")
        }
    }
}

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "List available API methods"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "system.capabilities", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(methods) = result["methods"] {
            for method in methods {
                if case let .string(name) = method {
                    print(name)
                }
            }
        }
    }
}

struct IdentifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identify",
        abstract: "Show current context (session/window/pane)"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        // Pass TMUX_PANE if available for context detection
        if let tmuxPane = ProcessInfo.processInfo.environment["TMUX_PANE"] {
            params["pane_id"] = .string(tmuxPane)
        }
        let response = try executeRequest(method: "system.identify", params: params, options: options)
        printResponse(response, json: options.json)
    }
}
