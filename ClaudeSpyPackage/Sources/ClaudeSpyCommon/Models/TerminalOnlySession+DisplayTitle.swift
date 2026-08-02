import ClaudeSpyNetworking
import Foundation

public extension TerminalOnlySession {
    /// The menu-row label for a terminal-only session: the user's session
    /// description when one is set, else "Terminal: <folder>" with the
    /// representative pane's working directory abbreviated to `~` against
    /// `homeDirectory` (pass a remote host's pushed home so `~` means the
    /// host's home; `nil` abbreviates against the local home), else the tmux
    /// session name when no path has been reported.
    func displayTitle(homeDirectory: String?) -> String {
        if let customDescription, !customDescription.isEmpty {
            return customDescription
        }
        if let currentPath, !currentPath.isEmpty {
            return "Terminal: \(currentPath.abbreviatedPath(home: homeDirectory))"
        }
        return sessionName
    }
}
