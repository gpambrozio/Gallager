import ArgumentParser
import Foundation

struct ListPanesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-panes",
        abstract: "List panes in current window"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let window = options.window {
            params["window_id"] = .string(window)
        } else if let pane = options.pane ?? options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
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

    @Option(name: .long, help: "Working directory for the new pane (defaults to $HOME)")
    var path: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["direction": .string(direction)]
        if let pane = options.pane ?? options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        if let path { params["path"] = .string(path) }
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

struct CapturePaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-pane",
        abstract: "Print recent pane output as plain text",
        discussion: """
        Surfaces `tmux capture-pane -p` for scripts that want to read pane content
        (grep a build log, assert on a test output, wait for a specific line).
        Without --pane, defaults to the calling pane via $TMUX_PANE.
        """
    )

    @Flag(name: .long, help: "Include the entire scrollback history, not just the visible region")
    var scrollback = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let pane = options.pane ?? options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        if scrollback {
            params["scrollback"] = .bool(true)
        }
        let response = try executeRequest(method: "pane.capture", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(content) = result["content"] {
            // Print without an extra trailing newline — tmux's capture-pane
            // already includes one per visible row.
            print(content, terminator: "")
        }
    }
}
