#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation

    /// Validation error raised while parsing a `gallager apply` config.
    public struct LayoutConfigError: Error, LocalizedError, Sendable, Equatable {
        public let path: String
        public let message: String

        public var errorDescription: String? {
            path.isEmpty ? message : "\(path): \(message)"
        }

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    /// Parses a `JSONValue` (already-parsed YAML/JSON sent by the CLI) into a
    /// `LayoutConfig`. Performs strict-or-lenient validation, expands
    /// `${VAR}` references against the supplied environment, and normalizes
    /// tmuxp's polymorphic shapes (string-or-array, string-or-object panes).
    public struct LayoutConfigParser: Sendable {
        /// Top-level keys we accept. Any other key triggers a strict error or
        /// a lenient warning.
        ///
        /// `global_options`, `socket_name`, `tmux_options`, `tmux_command`
        /// are part of tmuxp's surface but Gallager owns the tmux server, so
        /// we accept-and-ignore them in both modes (with a warning).
        static let supportedTopLevelKeys: Set = [
            "session_name",
            "description",
            "start_directory",
            "environment",
            "shell_command_before",
            "before_script",
            "options",
            "suppress_history",
            "windows",
            "on_create",
            "on_apply",
            "startup_window",
            "startup_pane",
        ]

        static let acceptedButIgnoredTopLevelKeys: Set = [
            "global_options",
            "socket_name",
            "tmux_options",
            "tmux_command",
        ]

        /// Keys that are explicitly rejected because they require behavior
        /// (templating engines) that Gallager will not implement.
        static let rejectedTopLevelKeys: Set = [
            "@args",
            "@settings",
            "erb",
        ]

        static let supportedWindowKeys: Set = [
            "window_name",
            "name",
            "window_index",
            "start_directory",
            "layout",
            "focus",
            "options",
            "options_after",
            "shell_command_before",
            "panes",
        ]

        static let supportedPaneKeys: Set = [
            "shell_command",
            "start_directory",
            "focus",
            "shell",
            "enter",
            "suppress_history",
            "sleep_before",
            "sleep_after",
            "claude",
        ]

        static let supportedClaudeKeys: Set = [
            "project",
            "args",
            "model",
        ]

        static let supportedHookKeys: Set = [
            "cmd",
            "cwd",
            "env",
        ]

        public let lenient: Bool
        public let environment: [String: String]

        public init(lenient: Bool, environment: [String: String]) {
            self.lenient = lenient
            self.environment = environment
        }

        public func parse(_ value: JSONValue) throws -> LayoutConfig {
            guard case let .object(root) = value else {
                throw LayoutConfigError(path: "", message: "Expected mapping at root, got \(value.typeName)")
            }
            var warnings: [String] = []
            var ignored: [String] = []

            // Reject explicitly-banned templating constructs first; these are
            // never tolerated even under --lenient.
            for key in root.keys where Self.rejectedTopLevelKeys.contains(key) {
                throw LayoutConfigError(
                    path: key,
                    message: "Templating constructs (ERB, @args, @settings) are not supported. " +
                        "Pre-render with envsubst or a script before applying."
                )
            }

            for key in root.keys where Self.acceptedButIgnoredTopLevelKeys.contains(key) {
                ignored.append(key)
                warnings.append("Ignoring '\(key)': Gallager owns the tmux server, this option has no effect.")
            }

            for key in root.keys where !Self.supportedTopLevelKeys.contains(key)
                && !Self.acceptedButIgnoredTopLevelKeys.contains(key) {
                let msg = "Unknown top-level key '\(key)'."
                if lenient {
                    warnings.append(msg)
                } else {
                    throw LayoutConfigError(path: key, message: msg)
                }
            }

            // Required fields.
            guard let sessionNameValue = root["session_name"] else {
                throw LayoutConfigError(path: "session_name", message: "session_name is required")
            }
            guard case let .string(rawSessionName) = sessionNameValue else {
                throw LayoutConfigError(path: "session_name", message: "session_name must be a string")
            }
            let sessionName = try expand(rawSessionName, path: "session_name", warnings: &warnings)

            let description = try optionalExpandedString(root["description"], path: "description", warnings: &warnings)
            let startDirectory = try optionalExpandedString(
                root["start_directory"],
                path: "start_directory",
                warnings: &warnings
            )
            let environmentMap = try parseEnvironment(root["environment"], warnings: &warnings)
            let shellCommandBefore = try parseStringOrArray(
                root["shell_command_before"],
                path: "shell_command_before",
                warnings: &warnings
            )
            let beforeScript = try optionalExpandedString(
                root["before_script"],
                path: "before_script",
                warnings: &warnings
            )
            let options = try parseOptionsMap(root["options"], path: "options", warnings: &warnings)
            let suppressHistory = try parseBool(root["suppress_history"], path: "suppress_history") ?? false

            let windows = try parseWindows(
                root["windows"],
                sessionSuppressHistory: suppressHistory,
                warnings: &warnings
            )
            let onCreate = try parseHooks(root["on_create"], path: "on_create", warnings: &warnings)
            let onApply = try parseHooks(root["on_apply"], path: "on_apply", warnings: &warnings)

            // tmuxinator-style aliases — promote the matching window/pane to
            // focus when set.
            var resolvedWindows = windows
            if case let .string(rawTarget) = root["startup_window"] {
                let target = try expand(rawTarget, path: "startup_window", warnings: &warnings)
                applyStartupWindow(&resolvedWindows, target: target)
            } else if case let .int(idx) = root["startup_window"] {
                if let i = resolvedWindows.firstIndex(where: { $0.index == idx }) {
                    resolvedWindows[i].focus = true
                }
            }
            if case let .int(paneIndex) = root["startup_pane"] {
                applyStartupPane(&resolvedWindows, paneIndex: paneIndex)
            }

            return LayoutConfig(
                sessionName: sessionName,
                description: description,
                startDirectory: startDirectory,
                environment: environmentMap,
                shellCommandBefore: shellCommandBefore,
                beforeScript: beforeScript,
                options: options,
                suppressHistory: suppressHistory,
                windows: resolvedWindows,
                onCreate: onCreate,
                onApply: onApply,
                ignoredKeys: ignored,
                warnings: warnings
            )
        }

        // MARK: - Sub-parsers

        private func parseEnvironment(_ value: JSONValue?, warnings: inout [String]) throws -> [String: String] {
            guard let value else { return [:] }
            guard case let .object(map) = value else {
                throw LayoutConfigError(path: "environment", message: "environment must be a mapping")
            }
            var result: [String: String] = [:]
            for (key, raw) in map {
                guard case let .string(rawValue) = raw else {
                    throw LayoutConfigError(
                        path: "environment.\(key)",
                        message: "environment values must be strings (got \(raw.typeName))"
                    )
                }
                result[key] = try expand(rawValue, path: "environment.\(key)", warnings: &warnings)
            }
            return result
        }

        private func parseOptionsMap(
            _ value: JSONValue?,
            path: String,
            warnings: inout [String]
        ) throws -> [String: String] {
            guard let value else { return [:] }
            guard case let .object(map) = value else {
                throw LayoutConfigError(path: path, message: "\(path) must be a mapping")
            }
            var result: [String: String] = [:]
            for (key, raw) in map {
                let stringValue: String?
                switch raw {
                case let .string(s):
                    stringValue = try expand(s, path: "\(path).\(key)", warnings: &warnings)
                case let .int(i): stringValue = String(i)
                case let .double(d): stringValue = String(d)
                case let .bool(b): stringValue = b ? "on" : "off"
                case .null:
                    // YAML `foo:` with no value parses as null. tmuxp leaves
                    // such keys unapplied; we follow suit so users who copy
                    // tmuxp configs aren't punished for empty entries.
                    stringValue = nil
                default:
                    throw LayoutConfigError(
                        path: "\(path).\(key)",
                        message: "tmux option values must be string/int/double/bool (got \(raw.typeName))"
                    )
                }
                if let stringValue {
                    result[key] = stringValue
                }
            }
            return result
        }

        private func parseStringOrArray(
            _ value: JSONValue?,
            path: String,
            warnings: inout [String]
        ) throws -> [String] {
            guard let value else { return [] }
            switch value {
            case let .string(s):
                return try [expand(s, path: path, warnings: &warnings)]
            case let .array(items):
                return try items.enumerated().map { idx, item in
                    guard case let .string(s) = item else {
                        throw LayoutConfigError(
                            path: "\(path)[\(idx)]",
                            message: "expected string (got \(item.typeName))"
                        )
                    }
                    return try expand(s, path: "\(path)[\(idx)]", warnings: &warnings)
                }
            case .null:
                return []
            default:
                throw LayoutConfigError(
                    path: path,
                    message: "expected string or array of strings (got \(value.typeName))"
                )
            }
        }

        private func parseWindows(
            _ value: JSONValue?,
            sessionSuppressHistory: Bool,
            warnings: inout [String]
        ) throws -> [LayoutConfig.Window] {
            guard let value else { return [] }
            guard case let .array(items) = value else {
                throw LayoutConfigError(path: "windows", message: "windows must be an array")
            }
            return try items.enumerated().map { idx, item in
                try parseWindow(item, path: "windows[\(idx)]", warnings: &warnings)
            }
        }

        private func parseWindow(
            _ value: JSONValue,
            path: String,
            warnings: inout [String]
        ) throws -> LayoutConfig.Window {
            guard case let .object(map) = value else {
                throw LayoutConfigError(path: path, message: "window must be a mapping")
            }
            for key in map.keys where !Self.supportedWindowKeys.contains(key) {
                let msg = "Unknown key '\(key)' on window"
                if lenient {
                    warnings.append("\(path): \(msg)")
                } else {
                    throw LayoutConfigError(path: "\(path).\(key)", message: msg)
                }
            }

            let name: String?
            if let rawName = map["window_name"] ?? map["name"] {
                guard case let .string(s) = rawName else {
                    throw LayoutConfigError(
                        path: "\(path).window_name",
                        message: "window_name must be a string (got \(rawName.typeName))"
                    )
                }
                name = try expand(s, path: "\(path).window_name", warnings: &warnings)
            } else {
                name = nil
            }
            let index = try parseInt(map["window_index"], path: "\(path).window_index")
            let startDir = try optionalExpandedString(
                map["start_directory"],
                path: "\(path).start_directory",
                warnings: &warnings
            )
            let layout = try optionalExpandedString(
                map["layout"],
                path: "\(path).layout",
                warnings: &warnings
            )
            let focus = try parseBool(map["focus"], path: "\(path).focus") ?? false
            let options = try parseOptionsMap(
                map["options"],
                path: "\(path).options",
                warnings: &warnings
            )
            let optionsAfter = try parseOptionsMap(
                map["options_after"],
                path: "\(path).options_after",
                warnings: &warnings
            )
            // tmuxp distinguishes options applied before/after pane creation;
            // Gallager applies them all once after the window exists, so we
            // merge the two maps (options_after wins on conflict, matching
            // tmuxp's "applied later" semantics).
            let mergedOptions = options.merging(optionsAfter) { _, after in after }
            let shellCommandBefore = try parseStringOrArray(
                map["shell_command_before"],
                path: "\(path).shell_command_before",
                warnings: &warnings
            )
            let panes = try parsePanes(map["panes"], path: "\(path).panes", warnings: &warnings)

            return LayoutConfig.Window(
                name: name,
                index: index,
                startDirectory: startDir,
                layout: layout,
                focus: focus,
                options: mergedOptions,
                shellCommandBefore: shellCommandBefore,
                panes: panes
            )
        }

        private func parsePanes(
            _ value: JSONValue?,
            path: String,
            warnings: inout [String]
        ) throws -> [LayoutConfig.Pane] {
            guard let value else { return [] }
            guard case let .array(items) = value else {
                throw LayoutConfigError(path: path, message: "panes must be an array")
            }
            return try items.enumerated().map { idx, item in
                try parsePane(item, path: "\(path)[\(idx)]", warnings: &warnings)
            }
        }

        private func parsePane(
            _ value: JSONValue,
            path: String,
            warnings: inout [String]
        ) throws -> LayoutConfig.Pane {
            switch value {
            case .null:
                // Empty pane shorthand — open with no command.
                return LayoutConfig.Pane()
            case let .string(s):
                return try LayoutConfig.Pane(
                    shellCommands: [expand(s, path: path, warnings: &warnings)]
                )
            case let .array(items):
                let commands = try items.enumerated().map { idx, item -> String in
                    guard case let .string(s) = item else {
                        throw LayoutConfigError(
                            path: "\(path)[\(idx)]",
                            message: "expected string (got \(item.typeName))"
                        )
                    }
                    return try expand(s, path: "\(path)[\(idx)]", warnings: &warnings)
                }
                return LayoutConfig.Pane(shellCommands: commands)
            case let .object(map):
                for key in map.keys where !Self.supportedPaneKeys.contains(key) {
                    let msg = "Unknown key '\(key)' on pane"
                    if lenient {
                        warnings.append("\(path): \(msg)")
                    } else {
                        throw LayoutConfigError(path: "\(path).\(key)", message: msg)
                    }
                }
                let claude = try parseClaude(map["claude"], path: "\(path).claude", warnings: &warnings)
                let shellCommands = try parseStringOrArray(
                    map["shell_command"],
                    path: "\(path).shell_command",
                    warnings: &warnings
                )
                if claude != nil, !shellCommands.isEmpty {
                    throw LayoutConfigError(
                        path: path,
                        message: "shell_command and claude are mutually exclusive"
                    )
                }
                let startDir = try optionalExpandedString(
                    map["start_directory"],
                    path: "\(path).start_directory",
                    warnings: &warnings
                )
                let focus = try parseBool(map["focus"], path: "\(path).focus") ?? false
                let shell = try optionalExpandedString(
                    map["shell"],
                    path: "\(path).shell",
                    warnings: &warnings
                )
                let enter = try parseBool(map["enter"], path: "\(path).enter") ?? true
                let suppressHistory = try parseBool(map["suppress_history"], path: "\(path).suppress_history")
                let sleepBefore = try parseDouble(map["sleep_before"], path: "\(path).sleep_before") ?? 0
                let sleepAfter = try parseDouble(map["sleep_after"], path: "\(path).sleep_after") ?? 0
                return LayoutConfig.Pane(
                    shellCommands: shellCommands,
                    startDirectory: startDir,
                    focus: focus,
                    shell: shell,
                    enter: enter,
                    suppressHistory: suppressHistory,
                    sleepBefore: sleepBefore,
                    sleepAfter: sleepAfter,
                    claude: claude
                )
            default:
                throw LayoutConfigError(
                    path: path,
                    message: "expected string, array, or mapping (got \(value.typeName))"
                )
            }
        }

        private func parseClaude(
            _ value: JSONValue?,
            path: String,
            warnings: inout [String]
        ) throws -> LayoutConfig.ClaudePane? {
            guard let value else { return nil }
            guard case let .object(map) = value else {
                throw LayoutConfigError(path: path, message: "claude must be a mapping")
            }
            for key in map.keys where !Self.supportedClaudeKeys.contains(key) {
                let msg = "Unknown key '\(key)' on claude"
                if lenient {
                    warnings.append("\(path): \(msg)")
                } else {
                    throw LayoutConfigError(path: "\(path).\(key)", message: msg)
                }
            }
            guard case let .string(rawProject) = map["project"] else {
                throw LayoutConfigError(path: "\(path).project", message: "claude.project is required and must be a string")
            }
            let project = try expand(rawProject, path: "\(path).project", warnings: &warnings)
            let args = try parseStringOrArray(map["args"], path: "\(path).args", warnings: &warnings)
            let model = try optionalExpandedString(map["model"], path: "\(path).model", warnings: &warnings)
            return LayoutConfig.ClaudePane(project: project, args: args, model: model)
        }

        private func parseHooks(
            _ value: JSONValue?,
            path: String,
            warnings: inout [String]
        ) throws -> [LayoutConfig.Hook] {
            guard let value else { return [] }
            guard case let .array(items) = value else {
                throw LayoutConfigError(path: path, message: "\(path) must be an array")
            }
            return try items.enumerated().map { idx, item in
                try parseHook(item, path: "\(path)[\(idx)]", warnings: &warnings)
            }
        }

        private func parseHook(
            _ value: JSONValue,
            path: String,
            warnings: inout [String]
        ) throws -> LayoutConfig.Hook {
            switch value {
            case let .string(s):
                return try LayoutConfig.Hook(cmd: expand(s, path: path, warnings: &warnings))
            case let .object(map):
                for key in map.keys where !Self.supportedHookKeys.contains(key) {
                    let msg = "Unknown key '\(key)' on hook"
                    if lenient {
                        warnings.append("\(path): \(msg)")
                    } else {
                        throw LayoutConfigError(path: "\(path).\(key)", message: msg)
                    }
                }
                guard case let .string(rawCmd) = map["cmd"] else {
                    throw LayoutConfigError(path: "\(path).cmd", message: "hook cmd is required and must be a string")
                }
                let cmd = try expand(rawCmd, path: "\(path).cmd", warnings: &warnings)
                let cwd = try optionalExpandedString(map["cwd"], path: "\(path).cwd", warnings: &warnings)
                let envMap: [String: String]
                if let envValue = map["env"] {
                    guard case let .object(rawEnv) = envValue else {
                        throw LayoutConfigError(path: "\(path).env", message: "env must be a mapping")
                    }
                    var collected: [String: String] = [:]
                    for (k, v) in rawEnv {
                        guard case let .string(rawV) = v else {
                            throw LayoutConfigError(
                                path: "\(path).env.\(k)",
                                message: "env values must be strings (got \(v.typeName))"
                            )
                        }
                        collected[k] = try expand(rawV, path: "\(path).env.\(k)", warnings: &warnings)
                    }
                    envMap = collected
                } else {
                    envMap = [:]
                }
                return LayoutConfig.Hook(cmd: cmd, cwd: cwd, env: envMap)
            default:
                throw LayoutConfigError(
                    path: path,
                    message: "hook entries must be string or {cmd, cwd, env} object (got \(value.typeName))"
                )
            }
        }

        // MARK: - Primitive helpers

        private func optionalExpandedString(
            _ value: JSONValue?,
            path: String,
            warnings: inout [String]
        ) throws -> String? {
            guard let value else { return nil }
            if case .null = value { return nil }
            guard case let .string(s) = value else {
                throw LayoutConfigError(path: path, message: "expected string (got \(value.typeName))")
            }
            return try expand(s, path: path, warnings: &warnings)
        }

        private func parseBool(_ value: JSONValue?, path: String) throws -> Bool? {
            guard let value else { return nil }
            switch value {
            case let .bool(b): return b
            case .null: return nil
            default:
                throw LayoutConfigError(path: path, message: "expected boolean (got \(value.typeName))")
            }
        }

        private func parseInt(_ value: JSONValue?, path: String) throws -> Int? {
            guard let value else { return nil }
            switch value {
            case let .int(i): return i
            case .null: return nil
            default:
                throw LayoutConfigError(path: path, message: "expected integer (got \(value.typeName))")
            }
        }

        private func parseDouble(_ value: JSONValue?, path: String) throws -> Double? {
            guard let value else { return nil }
            switch value {
            case let .int(i): return Double(i)
            case let .double(d): return d
            case .null: return nil
            default:
                throw LayoutConfigError(path: path, message: "expected number (got \(value.typeName))")
            }
        }

        private func expand(
            _ raw: String,
            path: String,
            warnings: inout [String]
        ) throws -> String {
            let expander = LayoutVariableExpander(environment: environment)
            var undefined: [LayoutVariableExpander.UndefinedReference] = []
            let result = expander.expand(raw, undefined: &undefined)
            for ref in undefined {
                let msg = "Undefined variable '\(ref.name)' expanded to empty string"
                if lenient {
                    warnings.append("\(path): \(msg)")
                } else {
                    throw LayoutConfigError(path: path, message: msg)
                }
            }
            return result
        }

        // MARK: - Startup aliases (tmuxinator)

        private func applyStartupWindow(_ windows: inout [LayoutConfig.Window], target: String) {
            // Match by name first; fall back to numeric index. Only the first
            // match flips, matching tmuxinator's last-write-wins semantics.
            if let i = windows.firstIndex(where: { $0.name == target }) {
                windows[i].focus = true
            } else if
                let idx = Int(target),
                let i = windows.firstIndex(where: { $0.index == idx }) {
                windows[i].focus = true
            }
        }

        private func applyStartupPane(_ windows: inout [LayoutConfig.Window], paneIndex: Int) {
            guard let windowIndex = windows.firstIndex(where: { $0.focus }) ?? windows.indices.first else {
                return
            }
            guard paneIndex >= 0, paneIndex < windows[windowIndex].panes.count else { return }
            windows[windowIndex].panes[paneIndex].focus = true
        }
    }

    // MARK: - JSONValue diagnostics

    extension JSONValue {
        var typeName: String {
            switch self {
            case .string: "string"
            case .int: "int"
            case .double: "double"
            case .bool: "bool"
            case .null: "null"
            case .array: "array"
            case .object: "object"
            }
        }
    }
#endif
