import ArgumentParser
import Foundation

struct ListWindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-windows",
        abstract: "List windows in current/specified session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let session = options.session {
            params["session_id"] = .string(session)
        } else if let pane = options.pane ?? options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
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

    @Option(name: .long, help: "Working directory for the new window (defaults to $HOME)")
    var path: String?

    @Option(name: .long, help: "tmux window name (tab label). Defaults to auto-generated 'terminal N'.")
    var name: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let session = options.session {
            params["session_id"] = .string(session)
        } else if let pane = options.pane ?? options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        if let path { params["path"] = .string(path) }
        if let name { params["name"] = .string(name) }
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

struct RenameWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename-window",
        abstract: "Rename a window's tab label",
        discussion: """
        Sets the tmux window name (the tab label). Always targets a specific
        window — there is no `--session` or `--pane` form, since renaming a
        single tab is the only operation that makes sense at this scope. To
        change a session-wide title shown in the sidebar, use `gallager
        set-title` instead.
        """
    )

    @Argument(help: "Window ID (session:index)")
    var id: String

    @Argument(help: "New window name")
    var name: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "window.set_name",
            params: [
                "window_id": .string(id),
                "name": .string(name),
            ],
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            print("Renamed window \(id) to \(name).")
        }
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
