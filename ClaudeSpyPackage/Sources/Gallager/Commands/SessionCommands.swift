import ArgumentParser
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

    @Option(name: .long, help: "Working directory for the new session (defaults to $HOME)")
    var path: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let name { params["name"] = .string(name) }
        if let path { params["path"] = .string(path) }
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

struct SessionStateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-state",
        abstract: "Override the displayed state of a tmux session in the sidebar",
        discussion: """
        Sets a synthetic state on the session's pane (or every pane in a target
        session). The override stays in place until cleared explicitly or until
        a Claude hook event for the same pane changes the underlying state.

        States: working, idle, waiting, clear
        Aliases: "waiting-for-input", "attention" (waiting); "none" (clear).
        """
    )

    @Argument(help: "State to apply: working, idle, waiting, or clear")
    var state: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["state": .string(state)]
        if let pane = options.pane {
            params["pane_id"] = .string(pane)
        } else if let session = options.session {
            params["session_id"] = .string(session)
        } else if let pane = options.callingPaneId {
            params["pane_id"] = .string(pane)
        }
        let response = try executeRequest(
            method: "session.set_state",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .int(applied) = result["applied_to"] {
            let canonical = Self.canonicalState(for: state)
            if applied == 0 {
                print("No matching panes found.")
            } else if canonical == "clear" {
                print("Cleared state on \(applied) pane(s).")
            } else {
                print("Set state '\(canonical)' on \(applied) pane(s).")
            }
        }
    }

    /// Maps the user-supplied state argument (and supported aliases) to the
    /// canonical name used in the sidebar so the success message stays in sync
    /// regardless of which alias or casing the caller typed.
    private static func canonicalState(for raw: String) -> String {
        switch raw.lowercased() {
        case "clear",
             "none":
            return "clear"
        case "working":
            return "working"
        case "idle":
            return "idle"
        case "waiting",
             "waiting-for-input",
             "attention":
            return "waiting"
        default:
            return raw.lowercased()
        }
    }
}
