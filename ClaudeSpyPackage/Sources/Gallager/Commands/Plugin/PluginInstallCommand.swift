import ArgumentParser
import Foundation

/// `gallager plugin install <url> [--yes]` — install a plugin from a
/// manifest URL.
///
/// v1 behavior:
/// - Without `--yes`: prints the manifest URL and prompts on stdin. Any
///   answer that doesn't start with `y` aborts (exit 1).
/// - With `--yes`: skips the prompt and goes straight to install.
///
/// v2 will replace the bare prompt with the trust UI / signature
/// verification described in Spec §16. The CLI contract — `--yes` to skip
/// confirmation — is forward-compatible with that change.
struct PluginInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a plugin from a manifest URL",
        discussion: """
        Fetches the manifest at <url>, verifies the bundle SHA-256, and
        unpacks the plugin into ~/.gallager/plugins/<id>/.

        v1 only supports https:// manifests. The CLI prompts for confirmation
        on stdin; pass --yes to skip the prompt (e.g. for scripts).

        TODO(v2): replace the prompt with the trust UI / signature
        verification flow described in Spec §16.
        """
    )

    @Argument(help: "HTTPS URL of the plugin manifest")
    var url: String

    @Flag(name: .long, help: "Skip the y/n confirmation prompt")
    var yes = false

    @OptionGroup var options: GlobalOptions

    func run() throws {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
            throw ValidationError("Manifest URL must be an https:// URL: \(url)")
        }

        if !yes {
            // Best-effort confirmation: if stdin isn't a TTY (script
            // pipeline), the user is expected to pass `--yes`. We still
            // try to read so noninteractive callers without `--yes`
            // fail loudly rather than silently installing.
            print("About to install plugin from:")
            print("  \(url)")
            print("Continue? [y/N] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                FileHandle.standardError.write(Data("Install cancelled.\n".utf8))
                throw ExitCode.failure
            }
        }

        let params: [String: JSONValue] = [
            "manifest_url": .string(url),
            "yes": .bool(yes),
        ]
        let response = try executeRequest(
            method: "plugin.install",
            params: params,
            options: options
        )
        if options.json {
            printResponse(response, json: true)
        } else if response.ok {
            print("Installed plugin from \(url).")
        }
    }
}
