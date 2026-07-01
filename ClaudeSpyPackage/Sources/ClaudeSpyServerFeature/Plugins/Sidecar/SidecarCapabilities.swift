#if os(macOS)
    import Foundation

    // MARK: - rich_pane_detection types (spec §Task-17)

    /// Facts about a tmux pane sent to the sidecar's `detect_pane` RPC.
    /// Named `SidecarPaneInfo` to avoid ambiguity with the tmux `PaneInfo` model.
    /// Kept modest — only what a rich detector needs beyond process names.
    public struct SidecarPaneInfo: Codable, Sendable, Equatable {
        /// Tmux pane ID (e.g. `"%4"`).
        public let paneID: String
        /// Process base-names currently running in the pane.
        public let processNames: [String]
        /// The foreground command string (may be nil when unavailable).
        public let command: String?
        /// Current working directory of the pane's shell, if tmux reports it.
        public let cwd: String?

        public init(paneID: String, processNames: [String], command: String? = nil, cwd: String? = nil) {
            self.paneID = paneID
            self.processNames = processNames
            self.command = command
            self.cwd = cwd
        }
    }

    /// Result from a sidecar's `detect_pane` RPC.
    public struct SidecarPaneMatch: Codable, Sendable, Equatable {
        /// Whether this pane belongs to the plugin's agent.
        public let matches: Bool
        /// The project path the agent is working on, if the sidecar can infer it.
        public let projectPath: String?
        /// The session ID the agent reported, if available.
        public let sessionID: String?

        public init(matches: Bool, projectPath: String? = nil, sessionID: String? = nil) {
            self.matches = matches
            self.projectPath = projectPath
            self.sessionID = sessionID
        }
    }

    // MARK: - modal_prompts types (spec §Task-17)

    /// Payload carried by an inbound `prompt_user` notification from the sidecar.
    /// The coordinator surfaces this as a Mac modal (the callback hook deferred to Task-17 coordinator).
    public struct PromptUserRequest: Codable, Sendable, Equatable {
        /// Short title for the dialog.
        public let title: String
        /// Optional descriptive body.
        public let message: String?

        public init(title: String, message: String? = nil) {
            self.title = title
            self.message = message
        }
    }
#endif
