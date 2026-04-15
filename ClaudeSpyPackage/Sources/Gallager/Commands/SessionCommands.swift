import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct ListSessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-sessions",
        abstract: "List all tmux sessions"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "session.list", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(sessions) = result["sessions"] {
            for session in sessions {
                if
                    case let .object(obj) = session,
                    case let .string(name) = obj["name"],
                    case let .int(windowCount) = obj["window_count"] {
                    let attached = obj["is_attached"]?.boolValue == true ? " (attached)" : ""
                    print("\(name)\t\(windowCount) windows\(attached)")
                }
            }
        }
    }
}

struct NewSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new-session",
        abstract: "Create a new session"
    )

    @Option(name: .long, help: "Session name")
    var name: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let name { params["name"] = .string(name) }
        let response = try executeRequest(method: "session.create", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(id) = result["id"] {
            print("Created session: \(id)")
        }
    }
}

struct SelectSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-session",
        abstract: "Switch to a session"
    )

    @Argument(help: "Session ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "session.select",
            params: ["session_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}

struct CurrentSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "current-session",
        abstract: "Show active session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "session.current", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(name) = result["name"] {
            print(name)
        }
    }
}

struct CloseSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-session",
        abstract: "Close a session"
    )

    @Argument(help: "Session ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "session.close",
            params: ["session_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}
