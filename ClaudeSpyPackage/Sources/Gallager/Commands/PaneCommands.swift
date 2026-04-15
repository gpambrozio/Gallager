import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct ListPanesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-panes",
        abstract: "List panes in current window"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let window = options.window { params["window_id"] = .string(window) }
        let response = try executeRequest(method: "pane.list", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(panes) = result["panes"] {
            for pane in panes {
                if
                    case let .object(obj) = pane,
                    case let .string(id) = obj["id"],
                    case let .int(width) = obj["width"],
                    case let .int(height) = obj["height"] {
                    let active = obj["is_active"]?.boolValue == true ? " *" : ""
                    let cwd = obj["cwd"]?.stringValue ?? ""
                    print("\(id)\t\(width)x\(height)\t\(cwd)\(active)")
                }
            }
        }
    }
}

struct SplitPaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split-pane",
        abstract: "Split pane (left/right/up/down, default: right)"
    )

    @Argument(help: "Split direction: left, right, up, down")
    var direction = "right"

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["direction": .string(direction)]
        if let pane = options.pane { params["pane_id"] = .string(pane) }
        let response = try executeRequest(method: "pane.split", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(id) = result["id"] {
            print("Created pane: \(id)")
        }
    }
}

struct SelectPaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-pane",
        abstract: "Focus a pane"
    )

    @Argument(help: "Pane ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "pane.select",
            params: ["pane_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}
