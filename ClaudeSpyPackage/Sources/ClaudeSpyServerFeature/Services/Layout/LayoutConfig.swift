#if os(macOS)
    import Foundation

    /// Declarative description of a tmux session built by `gallager apply`.
    ///
    /// The shape is a strict superset of [tmuxp](https://tmuxp.git-pull.com)'s YAML
    /// schema with a small set of Gallager-only extensions (`description`,
    /// `claude:` pane shorthand, `on_create:`/`on_apply:` hooks).
    public struct LayoutConfig: Sendable, Equatable {
        public var sessionName: String
        public var description: String?
        public var startDirectory: String?
        public var environment: [String: String]
        public var shellCommandBefore: [String]
        public var beforeScript: String?
        public var options: [String: String]
        public var suppressHistory: Bool
        public var windows: [Window]
        public var onCreate: [Hook]
        public var onApply: [Hook]
        /// Keys that the parser accepted but does not act on. Recorded so the
        /// daemon can surface them via `--dry-run` and as warnings to the user.
        public var ignoredKeys: [String]
        /// Validation issues that were demoted to warnings under `--lenient`.
        /// Empty in strict mode (those would have thrown instead).
        public var warnings: [String]

        public init(
            sessionName: String,
            description: String? = nil,
            startDirectory: String? = nil,
            environment: [String: String] = [:],
            shellCommandBefore: [String] = [],
            beforeScript: String? = nil,
            options: [String: String] = [:],
            suppressHistory: Bool = false,
            windows: [Window] = [],
            onCreate: [Hook] = [],
            onApply: [Hook] = [],
            ignoredKeys: [String] = [],
            warnings: [String] = []
        ) {
            self.sessionName = sessionName
            self.description = description
            self.startDirectory = startDirectory
            self.environment = environment
            self.shellCommandBefore = shellCommandBefore
            self.beforeScript = beforeScript
            self.options = options
            self.suppressHistory = suppressHistory
            self.windows = windows
            self.onCreate = onCreate
            self.onApply = onApply
            self.ignoredKeys = ignoredKeys
            self.warnings = warnings
        }

        public struct Window: Sendable, Equatable {
            public var name: String?
            public var index: Int?
            public var startDirectory: String?
            public var layout: String?
            public var focus: Bool
            public var options: [String: String]
            public var shellCommandBefore: [String]
            public var panes: [Pane]

            public init(
                name: String? = nil,
                index: Int? = nil,
                startDirectory: String? = nil,
                layout: String? = nil,
                focus: Bool = false,
                options: [String: String] = [:],
                shellCommandBefore: [String] = [],
                panes: [Pane] = []
            ) {
                self.name = name
                self.index = index
                self.startDirectory = startDirectory
                self.layout = layout
                self.focus = focus
                self.options = options
                self.shellCommandBefore = shellCommandBefore
                self.panes = panes
            }
        }

        public struct Pane: Sendable, Equatable {
            public var shellCommands: [String]
            public var startDirectory: String?
            public var focus: Bool
            public var shell: String?
            public var enter: Bool
            public var suppressHistory: Bool?
            public var sleepBefore: Double
            public var sleepAfter: Double
            public var claude: ClaudePane?

            public init(
                shellCommands: [String] = [],
                startDirectory: String? = nil,
                focus: Bool = false,
                shell: String? = nil,
                enter: Bool = true,
                suppressHistory: Bool? = nil,
                sleepBefore: Double = 0,
                sleepAfter: Double = 0,
                claude: ClaudePane? = nil
            ) {
                self.shellCommands = shellCommands
                self.startDirectory = startDirectory
                self.focus = focus
                self.shell = shell
                self.enter = enter
                self.suppressHistory = suppressHistory
                self.sleepBefore = sleepBefore
                self.sleepAfter = sleepAfter
                self.claude = claude
            }
        }

        public struct ClaudePane: Sendable, Equatable {
            public var project: String
            public var args: [String]
            public var model: String?

            public init(project: String, args: [String] = [], model: String? = nil) {
                self.project = project
                self.args = args
                self.model = model
            }
        }

        public struct Hook: Sendable, Equatable {
            public var cmd: String
            public var cwd: String?
            public var env: [String: String]

            public init(cmd: String, cwd: String? = nil, env: [String: String] = [:]) {
                self.cmd = cmd
                self.cwd = cwd
                self.env = env
            }
        }
    }
#endif
