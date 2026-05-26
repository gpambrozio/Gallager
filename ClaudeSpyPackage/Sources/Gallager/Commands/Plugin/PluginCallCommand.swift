import ArgumentParser
import Foundation

/// `gallager plugin call <id> <method> [<json>]` — fire a raw RPC at a
/// sidecar for debugging.
///
/// JSON params are taken from the trailing argument or stdin (when no
/// argument is given). The result is printed verbatim.
///
/// Bypasses the manager's normal flow — useful for poking developer-only
/// methods that aren't wired into the regular event pipeline.
struct PluginCallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "call",
        abstract: "Send a raw JSON-RPC to a plugin's sidecar (debug)",
        discussion: """
        JSON params come from the optional trailing argument or, when
        omitted, stdin. The sidecar's response result is printed to stdout
        as JSON.

        Examples:
          gallager plugin call claude-code _test_push_set_projects
          gallager plugin call claude-code translate_event '{"context":{}}'
          echo '{"context":{}}' | gallager plugin call claude-code translate_event
        """
    )

    @Argument(help: "Plugin id")
    var id: String

    @Argument(help: "JSON-RPC method name")
    var method: String

    @Argument(help: "JSON-encoded params object (defaults to stdin)")
    var paramsJSON: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        // Resolve params: trailing arg first, then stdin, else empty.
        let rawParams: String?
        if let paramsJSON, !paramsJSON.isEmpty {
            rawParams = paramsJSON
        } else if !isStdinTTY() {
            let stdin = FileHandle.standardInput.availableData
            if let str = String(data: stdin, encoding: .utf8), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawParams = str
            } else {
                rawParams = nil
            }
        } else {
            rawParams = nil
        }

        let parsedParams: JSONValue?
        if let rawParams {
            let data = Data(rawParams.utf8)
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw ValidationError("Failed to parse params as JSON: \(rawParams)")
            }
            parsedParams = value
        } else {
            parsedParams = nil
        }

        var params: [String: JSONValue] = [
            "id": .string(id),
            "method": .string(method),
        ]
        if let parsedParams { params["params"] = parsedParams }
        let response = try executeRequest(method: "plugin.call", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
            return
        }
        // Default output: just the result payload (unwrapped from the
        // outer `{ "result": … }` envelope) so the caller can pipe it
        // straight into `jq` without an extra `.result`.
        if let result = response.result, let value = result["result"] {
            if
                let data = try? JSONEncoder().encode(value),
                let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        }
    }

    private func isStdinTTY() -> Bool {
        isatty(fileno(stdin)) != 0
    }
}
