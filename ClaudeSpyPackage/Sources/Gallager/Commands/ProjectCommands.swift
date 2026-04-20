import ArgumentParser
import Foundation

struct ListProjectsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-projects",
        abstract: "List all Claude Code projects discovered on the host"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "project.list", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .array(projects) = result["projects"] {
            for project in projects {
                if
                    case let .object(obj) = project,
                    case let .string(name) = obj["name"],
                    case let .string(path) = obj["path"] {
                    print("\(name)\t\(path)")
                } else {
                    let warning = "warning: skipping project entry missing 'name' or 'path'\n"
                    FileHandle.standardError.write(Data(warning.utf8))
                }
            }
        }
    }
}

struct StartProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start-project",
        abstract: "Start a new tmux session for a Claude project and run claude in it"
    )

    @Argument(help: "Project path (the directory to open Claude in)")
    var path: String

    @Argument(parsing: .captureForPassthrough, help: "Optional arguments appended to the claude command")
    var extraArgs: [String] = []

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let expandedPath = (path as NSString).expandingTildeInPath
        var params: [String: JSONValue] = ["path": .string(expandedPath)]
        if !extraArgs.isEmpty {
            params["args"] = .array(extraArgs.map { .string($0) })
        }
        let response = try executeRequest(method: "project.start", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if
            let result = response.result,
            case let .string(id) = result["id"] {
            print("Started session: \(id)")
        }
    }
}
