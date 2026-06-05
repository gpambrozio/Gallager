import ArgumentParser
import Foundation
import Yams

struct ApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Build a tmux session from a declarative YAML/JSON layout file",
        discussion: """
        Materializes a session, its windows, panes, working directories, and
        startup commands from a single declarative file. Idempotent by default
        — re-applying selects an existing session instead of duplicating it.

        File format is a strict superset of tmuxp's YAML schema. Pass `-` to
        read from stdin.

        Examples:
          gallager apply workers.yml
          gallager apply ./.gallager.yaml --rebuild
          envsubst < layout.tmpl.yaml | gallager apply -
        """
    )

    @Argument(help: "Layout file path, directory, or '-' for stdin")
    var file: String

    @Flag(name: .long, help: "Close existing session first, then build a fresh one")
    var rebuild = false

    @Flag(name: .long, help: "Do not switch to the session after building")
    var detach = false

    @Flag(name: .long, help: "Parse, validate, and print planned actions; do not touch tmux")
    var dryRun = false

    @Flag(name: .long, help: "Demote unknown-key validation errors to stderr warnings")
    var lenient = false

    @Flag(name: .long, help: "Fail with exit 3 if the session already exists")
    var requireCreate = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let configValue: JSONValue
        let configPath: String?
        do {
            (configValue, configPath) = try loadConfig(from: file)
        } catch {
            // File-not-found, encoding, YAML parse errors are all "config
            // can't be applied" failures — spec §3 maps these to exit 2.
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            throw ExitCode(2)
        }
        var params: [String: JSONValue] = [
            "config": configValue,
            "rebuild": .bool(rebuild),
            "detach": .bool(detach),
            "dry_run": .bool(dryRun),
            "lenient": .bool(lenient),
            "require_create": .bool(requireCreate),
        ]
        if let configPath {
            params["config_path"] = .string(configPath)
        }
        // Bypass executeRequest's generic error handling so we can distinguish
        // validation errors (exit 2) and `--require-create` collisions (exit 3)
        // from generic failures (exit 1) per spec §3.
        let request = JSONRPCRequest(
            id: UUID().uuidString,
            method: "layout.apply",
            params: params
        )
        let response = try SocketClient.send(request, socketPath: options.socket)
        if !response.ok, let error = response.error {
            FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
            switch error.code {
            case "validation_error": throw ExitCode(2)
            case "session_exists": throw ExitCode(3)
            default: throw ExitCode.failure
            }
        }
        printApplyResult(response)
    }

    // MARK: - File loading

    /// Loads YAML/JSON from a file path, directory, or stdin (`-`). Returns the
    /// parsed value along with the absolute config path (so the daemon can
    /// resolve relative `start_directory` against the file's directory).
    private func loadConfig(from arg: String) throws -> (JSONValue, String?) {
        if arg == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return try (parseYAMLOrJSON(text), nil)
        }
        let resolved = try resolveFilePath(arg)
        let absolute = (resolved as NSString).standardizingPath
        let text = try String(contentsOf: URL(fileURLWithPath: absolute), encoding: .utf8)
        return try (parseYAMLOrJSON(text), absolute)
    }

    private func resolveFilePath(_ arg: String) throws -> String {
        let expanded = (arg as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ValidationError("File not found: \(arg)")
        }
        if isDirectory.boolValue {
            // Directory lookup order — first match wins. Mirrors tmuxp's own
            // resolution so projects with both files behave predictably.
            let candidates = [
                ".gallager.yaml",
                ".gallager.yml",
                ".tmuxp.yaml",
                ".tmuxp.yml",
            ]
            for candidate in candidates {
                let path = url.appendingPathComponent(candidate).path
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
            throw ValidationError(
                "Directory '\(arg)' does not contain any of: \(candidates.joined(separator: ", "))"
            )
        }
        return url.path
    }

    private func parseYAMLOrJSON(_ text: String) throws -> JSONValue {
        // Yams handles both YAML and JSON (JSON is a strict subset). Using
        // it for both lets users mix formats without us caring.
        let yaml = try Yams.load(yaml: text)
        return jsonValue(from: yaml as Any)
    }

    /// Recursively converts the dynamic-typed tree returned by Yams into our
    /// Sendable `JSONValue`. Yams returns Dictionary<AnyHashable, Any> for
    /// mappings; we coerce keys to Strings (rejecting non-string keys) so the
    /// daemon-side parser can rely on a uniform shape.
    private func jsonValue(from any: Any) -> JSONValue {
        switch any {
        case let dict as [AnyHashable: Any]:
            var result: [String: JSONValue] = [:]
            for (key, value) in dict {
                let keyString: String
                if let s = key as? String {
                    keyString = s
                } else {
                    keyString = String(describing: key)
                }
                result[keyString] = jsonValue(from: value)
            }
            return .object(result)
        case let array as [Any]:
            return .array(array.map(jsonValue))
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case Optional<Any>.none,
             is NSNull:
            return .null
        default:
            // Fallback: stringify anything we don't recognize. Yams shouldn't
            // ever produce these, but keep the path total to avoid crashes.
            return .string(String(describing: any))
        }
    }

    // MARK: - Output

    private func printApplyResult(_ response: JSONRPCResponse) {
        if options.json {
            printResponse(response, json: true)
            return
        }
        guard let result = response.result else { return }
        if case let .array(warnings) = result["warnings"] {
            for case let .string(msg) in warnings {
                FileHandle.standardError.write(Data("warning: \(msg)\n".utf8))
            }
        }
        if dryRun, case let .array(planned) = result["planned_actions"] {
            for case let .string(action) in planned {
                print(action)
            }
            return
        }
        if case let .string(name) = result["session_name"] {
            let created = result["created"]?.boolValue ?? false
            print(created ? "Created session: \(name)" : "Selected existing session: \(name)")
        }
    }
}
