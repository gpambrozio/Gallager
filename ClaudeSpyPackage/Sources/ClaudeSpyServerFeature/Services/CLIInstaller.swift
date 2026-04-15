#if os(macOS)
    import AppKit
    import Foundation
    import Logging

    /// Manages installation of the `gallager` CLI symlink in `/usr/local/bin`.
    public enum CLIInstaller {
        private static let logger = Logger(label: "com.claudespy.cliinstaller")
        private static let symlinkPath = "/usr/local/bin/gallager"

        /// Whether the CLI symlink is already installed and points to the current binary.
        public static var isInstalled: Bool {
            let fm = FileManager.default
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) else {
                return false
            }
            guard let currentCLIPath = cliBinaryPath else { return false }
            return destination == currentCLIPath
        }

        /// Path to the GallagerCLI binary inside the running app bundle.
        public static var cliBinaryPath: String? {
            Bundle.main.url(forAuxiliaryExecutable: "GallagerCLI")?.path
        }

        /// Install the CLI symlink at `/usr/local/bin/gallager`.
        ///
        /// Uses AppleScript to request admin privileges for creating the symlink.
        @MainActor
        public static func install() -> Bool {
            guard let cliPath = cliBinaryPath else {
                logger.error("GallagerCLI binary not found in app bundle")
                return false
            }

            // Use osascript with administrator privileges to create the symlink
            let script = """
            do shell script \
            "mkdir -p /usr/local/bin && ln -sf '\(cliPath)' '\(symlinkPath)'" \
            with administrator privileges
            """

            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)

            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                logger.error("Failed to install CLI: \(message)")
                return false
            }

            logger.info("CLI installed at \(symlinkPath) -> \(cliPath)")
            return true
        }

        /// Remove the CLI symlink.
        @MainActor
        public static func uninstall() -> Bool {
            let script = """
            do shell script \
            "rm -f '\(symlinkPath)'" \
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

            logger.info("CLI uninstalled from \(symlinkPath)")
            return true
        }
    }
#endif
