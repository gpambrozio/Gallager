import ArgumentParser
import GallagerAPI
import Foundation

struct ListWindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-windows",
        abstract: "List windows in current/specified session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let session = options.session { params["session_id"] = .string(session) }
        let response = try executeRequest(method: "window.list", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(windows) = result["windows"] {
            for window in windows {
                if
                    case let .object(obj) = window,
                    case let .string(id) = obj["id"],
                    case let .string(name) = obj["name"],
                    case let .int(paneCount) = obj["pane_count"] {
                    let active = obj["is_active"]?.boolValue == true ? " *" : ""
                    print("\(id)\t\(name)\t\(paneCount) panes\(active)")
                }
            }
        }
    }
}

struct NewWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new-window",
        abstract: "Create window in current/specified session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let session = options.session { params["session_id"] = .string(session) }
        let response = try executeRequest(method: "window.create", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(id) = result["id"] {
            print("Created window: \(id)")
        }
    }
}

struct SelectWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-window",
        abstract: "Switch to a window"
    )

    @Argument(help: "Window ID (session:index)")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "window.select",
            params: ["window_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}

struct CloseWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-window",
        abstract: "Close a window"
    )

    @Argument(help: "Window ID (session:index)")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "window.close",
            params: ["window_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}
