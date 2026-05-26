import ArgumentParser
import Foundation

/// `gallager plugin logs <id> [-f] [--lines N]` — print the trailing
/// lines from a plugin's sidecar log file.
///
/// `-f` tails: re-runs the RPC every `pollInterval` seconds and prints
/// any newly-appended lines. There's no incremental tail RPC today —
/// we poll the file via the existing route and dedupe locally.
struct PluginLogsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print a plugin's sidecar log"
    )

    @Argument(help: "Plugin id")
    var id: String

    @Flag(name: .shortAndLong, help: "Follow the log — keep printing new lines")
    var follow = false

    @Option(name: .long, help: "Number of trailing lines to print (default: 256)")
    var lines = 256

    @OptionGroup var options: GlobalOptions

    /// How often to poll the file when `-f` is set. 1s is a compromise
    /// between snappy follow-mode and not hammering the socket.
    private static let pollInterval: TimeInterval = 1

    func run() throws {
        // First shot: print whatever's there.
        let initial = try fetchLogs(lineCount: lines)
        if !initial.isEmpty {
            print(initial)
        }

        guard follow else { return }

        // Follow mode: poll, diff, print any new tail. Track the last
        // emitted line so we can skip everything we've already shown.
        // Lines are content-keyed because plugin logs don't carry
        // monotonic offsets — this is correct as long as no two adjacent
        // lines are byte-identical, which is the common case for a
        // structured logger.
        var seenSuffix = initial
        while true {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            let current: String
            do {
                current = try fetchLogs(lineCount: lines)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                continue
            }
            guard current != seenSuffix else { continue }
            // Common-suffix dedupe: if the cached `seenSuffix` is a
            // suffix of the new fetch, print only the new portion.
            if current.hasSuffix(seenSuffix), !seenSuffix.isEmpty {
                let extra = String(current.dropLast(seenSuffix.count))
                if !extra.isEmpty {
                    print(extra, terminator: "")
                }
            } else if current.count > seenSuffix.count {
                // The cached suffix scrolled out of the trailing window.
                // Print the whole new fetch so we don't lose anything.
                print(current)
            }
            seenSuffix = current
        }
    }

    private func fetchLogs(lineCount: Int) throws -> String {
        let response = try executeRequest(
            method: "plugin.logs",
            params: [
                "id": .string(id),
                "lines": .int(lineCount),
            ],
            options: options
        )
        if options.json {
            // In JSON mode we just print the raw envelope per follow
            // tick. Plays poorly with `-f`, but matches the rest of the
            // CLI's behavior under --json.
            printResponse(response, json: true)
            return ""
        }
        return PluginCommandHelpers.stringField("content", from: response) ?? ""
    }
}
