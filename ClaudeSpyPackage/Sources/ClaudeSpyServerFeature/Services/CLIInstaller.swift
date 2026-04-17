#if os(macOS)
    import AppKit
    import Foundation
    import Logging

    /// Manages installation of the `gallager` CLI wrapper in `/usr/local/bin`.
    ///
    /// Installs a shell script that locates the Gallager app bundle and invokes
    /// the embedded GallagerCLI binary. This approach (used by VS Code, Sublime, etc.)
    /// avoids dynamic framework loading issues that occur with direct symlinks.
    public enum CLIInstaller {
        private static let logger = Logger(label: "com.claudespy.cliinstaller")
        private static let installPath = "/usr/local/bin/gallager"
        private static let bundleID = "br.eng.gustavo.ClaudeSpyServer"

        /// Whether the CLI wrapper is installed.
        public static var isInstalled: Bool {
            FileManager.default.isExecutableFile(atPath: installPath)
        }

        /// Install the CLI wrapper script at `/usr/local/bin/gallager`.
        ///
        /// Embeds the current app bundle path directly in the script.
        /// Uses AppleScript to request admin privileges.
        @MainActor
        public static func install() -> Bool {
            guard let appPath = Bundle.main.bundlePath as String? else {
                logger.error("Could not determine app bundle path")
                return false
            }

            let escapedAppPath = appPath.replacingOccurrences(of: "'", with: "'\\''")
            let wrapperScript = """
            #!/bin/bash
            # Gallager CLI — installed by Gallager.app
            # Re-run "Install Command Line Tool..." if you move the app.

            CLI='\(escapedAppPath)/Contents/MacOS/GallagerCLI'
            if [ ! -x "$CLI" ]; then
                echo "Error: GallagerCLI not found at $CLI" >&2
                echo "The app may have moved. Re-run Install Command Line Tool from the Gallager menu." >&2
                exit 1
            fi

            exec "$CLI" "$@"
            """

            // Write the script to a temp file, then move it with admin privileges
            let tempPath = NSTemporaryDirectory() + "gallager-cli-install.sh"
            do {
                try wrapperScript.write(toFile: tempPath, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Failed to write wrapper script: \(error)")
                return false
            }

            let script = """
            do shell script \
            "mkdir -p /usr/local/bin && cp '\(tempPath)' '\(installPath)' && chmod +x '\(installPath)'" \
            with administrator privileges
            """

            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)

            // Clean up temp file
            try? FileManager.default.removeItem(atPath: tempPath)

            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                logger.error("Failed to install CLI: \(message)")
                return false
            }

            logger.info("CLI wrapper installed at \(installPath)")
            return true
        }

        /// Remove the CLI wrapper.
        @MainActor
        public static func uninstall() -> Bool {
            let script = """
            do shell script \
            "rm -f '\(installPath)'" \
            with administrator privileges
            """

            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)

            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                logger.error("Failed to uninstall CLI: \(message)")
                return false
            }

            logger.info("CLI wrapper removed from \(installPath)")
            return true
        }
    }
#endif
