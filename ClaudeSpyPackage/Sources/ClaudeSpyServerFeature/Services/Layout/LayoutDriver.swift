#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Logging

    /// Drives a parsed `LayoutConfig` against the live tmux service, building
    /// (or selecting) a session top-down. Coordinates session/window/pane
    /// creation, environment + option pass-through, hooks, and focus.
    ///
    /// Idempotency: when the named session already exists, the driver runs
    /// `on_apply` hooks and selects it without re-creating panes. Pass
    /// `rebuild: true` to close-then-create instead.
    public struct LayoutDriver: Sendable {
        public struct Result: Sendable {
            public let sessionName: String
            /// `true` when this run cold-started the session; `false` when it
            /// reattached to an existing one.
            public let created: Bool
            /// Warnings surfaced during apply (parser warnings + runtime gaps
            /// like missing window names).
            public let warnings: [String]
            /// Planned actions, populated only when `dryRun: true`. Each entry
            /// is one human-readable line describing a step the driver would
            /// have taken.
            public let plannedActions: [String]

            public init(
                sessionName: String,
                created: Bool,
                warnings: [String] = [],
                plannedActions: [String] = []
            ) {
                self.sessionName = sessionName
                self.created = created
                self.warnings = warnings
                self.plannedActions = plannedActions
            }
        }

        public enum DriverError: Error, LocalizedError, Sendable {
            case alreadyExists(name: String)
            case beforeScriptFailed(exitCode: Int32, stderr: String)
            case hookFailed(cmd: String, exitCode: Int32, stderr: String)
            case invalidPath(path: String, message: String)

            public var errorDescription: String? {
                switch self {
                case let .alreadyExists(name):
                    "Session '\(name)' already exists (--require-create)."
                case let .beforeScriptFailed(code, stderr):
                    "before_script exited with code \(code): \(stderr)"
                case let .hookFailed(cmd, code, stderr):
                    "Hook '\(cmd)' exited with code \(code): \(stderr)"
                case let .invalidPath(path, message):
                    "Invalid path '\(path)': \(message)"
                }
            }
        }

        public typealias TmuxAccessor = @Sendable () async -> TmuxService
        /// Applies a session-scoped description (or clears it when nil) through
        /// the same MirrorWindowManager path the CLI's `set-title` uses.
        public typealias DescriptionApplier = @Sendable (
            _ description: String?,
            _ sessionName: String
        ) async -> Void
        /// Applies a session-scoped color (or clears it when nil) through the
        /// same MirrorWindowManager path the CLI's `set-color` uses.
        public typealias ColorApplier = @Sendable (
            _ color: SessionColor?,
            _ sessionName: String
        ) async -> Void
        /// Applies a per-pane progress override through the same
        /// MirrorWindowManager path the CLI's `set-progress` uses. Treated as
        /// a no-op when the pane isn't yet tracked (the apply driver makes
        /// sure paneStates is refreshed first).
        public typealias ProgressApplier = @Sendable (
            _ progress: TerminalProgressState?,
            _ paneId: String
        ) async -> Void

        let tmuxAccessor: TmuxAccessor
        let descriptionApplier: DescriptionApplier
        let colorApplier: ColorApplier
        let progressApplier: ProgressApplier
        let processRunner: ProcessRunner
        let logger: Logger

        public init(
            tmuxAccessor: @escaping TmuxAccessor,
            descriptionApplier: @escaping DescriptionApplier,
            colorApplier: @escaping ColorApplier,
            progressApplier: @escaping ProgressApplier,
            processRunner: ProcessRunner = .liveValue,
            logger: Logger = Logger(label: "com.claudespy.layoutdriver")
        ) {
            self.tmuxAccessor = tmuxAccessor
            self.descriptionApplier = descriptionApplier
            self.colorApplier = colorApplier
            self.progressApplier = progressApplier
            self.processRunner = processRunner
            self.logger = logger
        }

        // MARK: - Apply

        public func apply(
            _ config: LayoutConfig,
            rebuild: Bool = false,
            detach: Bool = false,
            dryRun: Bool = false,
            requireCreate: Bool = false,
            configDirectory: String? = nil,
            shellEnvironment: [String: String] = ProcessInfo.processInfo.environment,
            claudeCommandPath: String = "claude"
        ) async throws -> Result {
            let tmux = await tmuxAccessor()
            var planned: [String] = []
            var warnings = config.warnings

            let exists = await tmux.sessionExists(named: config.sessionName)

            // Dry-run never throws on the require-create collision — the spec
            // promises dry-run has no side effects, and exiting non-zero would
            // be a side effect from a pure planning request. Surface the
            // would-be failure via the planned actions instead.
            if exists, requireCreate {
                if dryRun {
                    planned.append("--require-create would fail: session '\(config.sessionName)' already exists")
                    return Result(
                        sessionName: config.sessionName,
                        created: false,
                        warnings: warnings,
                        plannedActions: planned
                    )
                }
                throw DriverError.alreadyExists(name: config.sessionName)
            }

            if exists, !rebuild {
                planned.append("session '\(config.sessionName)' exists — re-applying description/color, running on_apply hooks, selecting")
                if !dryRun {
                    // Re-apply description + color on warm-attach so editing
                    // the YAML and re-running `gallager apply` updates the
                    // sidebar without forcing the user into `--rebuild`.
                    // Environment + tmux options are intentionally left
                    // alone — they only affect new shells, and re-running
                    // them on every apply would be a quiet way to surprise
                    // users with state from a config they thought they had
                    // already shipped.
                    if let description = config.description, !description.isEmpty {
                        await descriptionApplier(description, config.sessionName)
                    }
                    // Always push the configured color (including nil → clear)
                    // so removing `color:` from the YAML and re-applying
                    // actually clears the dot rather than silently leaving
                    // the previous choice in place.
                    await colorApplier(config.color, config.sessionName)
                }
                try await runHooks(
                    config.onApply,
                    scope: "on_apply",
                    planned: &planned,
                    dryRun: dryRun,
                    shellEnvironment: shellEnvironment
                )
                if !dryRun, !detach {
                    // Trailing `:` resolves to the session's current window
                    // unambiguously. `:!` (last/previous window) fails with
                    // "can't find window: !" when the session has no window
                    // history yet — i.e. a single-window session that's never
                    // been switched away from — which made warm-attach apply
                    // exit non-zero.
                    try await tmux.selectWindow("\(config.sessionName):")
                }
                return Result(
                    sessionName: config.sessionName,
                    created: false,
                    warnings: warnings,
                    plannedActions: planned
                )
            }

            if exists, rebuild {
                planned.append("--rebuild: closing existing session '\(config.sessionName)'")
                if !dryRun {
                    try await tmux.killSession(config.sessionName)
                }
            }

            // Cold-start path. before_script runs first so a failed bootstrap
            // can fail fast — no half-created session left behind.
            if let script = config.beforeScript, !script.isEmpty {
                planned.append("before_script: \(script)")
                if !dryRun {
                    let result = try await runShellCommand(
                        script,
                        cwd: nil,
                        env: [:],
                        shellEnvironment: shellEnvironment
                    )
                    if !result.isSuccess {
                        throw DriverError.beforeScriptFailed(
                            exitCode: result.exitCode,
                            stderr: result.stderrString
                        )
                    }
                }
            }

            let sessionDir = resolvedDirectory(
                start: config.startDirectory,
                fallbacks: [],
                configDirectory: configDirectory,
                shellEnvironment: shellEnvironment
            )
            planned.append(
                "session.create name=\(config.sessionName) path=\(sessionDir ?? "$HOME")"
            )
            let createdName: String
            if dryRun {
                createdName = config.sessionName
            } else {
                let (name, _) = try await tmux.createSession(
                    baseName: config.sessionName,
                    width: 200,
                    height: 50,
                    workingDirectory: sessionDir
                )
                createdName = name
                if name != config.sessionName {
                    // createSession uniquifies on collision; under apply we
                    // already proved the name was free. Still, surface drift
                    // so the user notices the rename.
                    warnings.append("Session created as '\(name)' (requested '\(config.sessionName)')")
                }
            }

            // Apply session-level environment, options, description.
            for (key, value) in config.environment {
                planned.append("session.set_env \(key)=\(value)")
                if !dryRun {
                    try await tmux.setSessionEnvironment(
                        sessionName: createdName,
                        name: key,
                        value: value
                    )
                }
            }
            for (key, value) in config.options {
                planned.append("session.set_option \(key)=\(value)")
                if !dryRun {
                    try await tmux.setOption(
                        target: createdName,
                        name: key,
                        value: value,
                        scope: .session
                    )
                }
            }
            if let description = config.description, !description.isEmpty {
                planned.append("session.set_title \(description)")
                if !dryRun {
                    await descriptionApplier(description, createdName)
                }
            }
            if let color = config.color {
                planned.append("session.set_color \(color.rawValue)")
                if !dryRun {
                    await colorApplier(color, createdName)
                }
            }

            // Walk windows top-down. Window 0 is the bootstrap from
            // createSession; we rename + repopulate it in place to avoid a
            // visible "two windows then collapse" flicker.
            for (windowIndex, window) in config.windows.enumerated() {
                try await applyWindow(
                    window,
                    windowIndex: windowIndex,
                    sessionName: createdName,
                    sessionConfig: config,
                    dryRun: dryRun,
                    planned: &planned,
                    warnings: &warnings,
                    configDirectory: configDirectory,
                    shellEnvironment: shellEnvironment,
                    claudeCommandPath: claudeCommandPath,
                    tmux: tmux
                )
            }

            // on_create hooks fire after the session is fully built; tmuxp's
            // before_script counts as on_create[0] but ran earlier so failures
            // could short-circuit before any tmux state was touched.
            try await runHooks(
                config.onCreate,
                scope: "on_create",
                planned: &planned,
                dryRun: dryRun,
                shellEnvironment: shellEnvironment
            )
            try await runHooks(
                config.onApply,
                scope: "on_apply",
                planned: &planned,
                dryRun: dryRun,
                shellEnvironment: shellEnvironment
            )

            // Focus the requested pane/window before the final select so the
            // session lands on the user's intended view.
            if
                let focusWindow = config.windows.first(where: { $0.focus }),
                let target = focusWindow.tmuxTarget(sessionName: createdName, fallbackIndex: nil) {
                planned.append("window.select \(target)")
                if !dryRun {
                    try? await tmux.selectWindow(target)
                }
            }

            if !detach {
                planned.append("session.select \(createdName)")
                if !dryRun {
                    // See above: `:!` fails on freshly built sessions
                    // (no previous-window history). Trailing `:` resolves to
                    // the session's current window unambiguously.
                    try await tmux.selectWindow("\(createdName):")
                }
            }

            return Result(
                sessionName: createdName,
                created: true,
                warnings: warnings,
                plannedActions: planned
            )
        }

        // MARK: - Window + pane

        private func applyWindow(
            _ window: LayoutConfig.Window,
            windowIndex: Int,
            sessionName: String,
            sessionConfig: LayoutConfig,
            dryRun: Bool,
            planned: inout [String],
            warnings: inout [String],
            configDirectory: String?,
            shellEnvironment: [String: String],
            claudeCommandPath: String,
            tmux: TmuxService
        ) async throws {
            let windowDir = resolvedDirectory(
                start: window.startDirectory,
                fallbacks: [sessionConfig.startDirectory],
                configDirectory: configDirectory,
                shellEnvironment: shellEnvironment
            )
            let windowName = window.name

            let firstPaneId: String
            let actualIndex: Int
            if windowIndex == 0 {
                // Bootstrap window already exists at index 0 from createSession.
                planned.append("window[0]: rename '\(windowName ?? "<auto>")' (in place)")
                actualIndex = 0
                if !dryRun, let windowName, !windowName.isEmpty {
                    try? await tmux.renameWindow(target: "\(sessionName):0", name: windowName)
                }
                if !dryRun {
                    let panes = await tmux.refreshPanes()
                    let bootstrap = panes.first { $0.sessionName == sessionName && $0.windowIndex == 0 }
                    firstPaneId = bootstrap?.paneId ?? "%0"
                } else {
                    firstPaneId = "%dryrun-w0p0"
                }
            } else {
                planned.append(
                    "window.create name=\(windowName ?? "<auto>") index=\(window.index.map(String.init) ?? "<next>") path=\(windowDir ?? "$HOME")"
                )
                if dryRun {
                    // In dry-run honor the requested index so the planned
                    // actions reflect what tmux would actually pick. Without
                    // an explicit index, fall through to the loop counter as
                    // an approximation.
                    actualIndex = window.index ?? windowIndex
                    firstPaneId = "%dryrun-w\(actualIndex)p0"
                } else {
                    let newPaneId = try await tmux.newWindow(
                        sessionName: sessionName,
                        workingDirectory: windowDir,
                        windowName: windowName,
                        windowIndex: window.index
                    )
                    firstPaneId = newPaneId
                    let panes = await tmux.refreshPanes()
                    actualIndex = panes
                        .first(where: { $0.paneId == newPaneId })?
                        .windowIndex ?? window.index ?? windowIndex
                }
            }

            if let layout = window.layout, !layout.isEmpty {
                planned.append("window[\(actualIndex)].select_layout \(layout)")
                // Layout is applied after panes exist — defer until the end of
                // this window.
            }

            for (key, value) in window.options {
                planned.append("window[\(actualIndex)].set_option \(key)=\(value)")
                if !dryRun {
                    try await tmux.setOption(
                        target: "\(sessionName):\(actualIndex)",
                        name: key,
                        value: value,
                        scope: .window
                    )
                }
            }

            // Build pane list. The first pane already exists; later panes are
            // splits off the previously-created one.
            var paneIds: [String] = [firstPaneId]
            for paneOffset in 1..<window.panes.count {
                let pane = window.panes[paneOffset]
                let paneDir = resolvedDirectory(
                    start: pane.startDirectory,
                    fallbacks: [window.startDirectory, sessionConfig.startDirectory],
                    configDirectory: configDirectory,
                    shellEnvironment: shellEnvironment
                )
                planned.append(
                    "pane.split (window[\(actualIndex)]) path=\(paneDir ?? "$HOME")"
                )
                if dryRun {
                    paneIds.append("%dryrun-w\(actualIndex)p\(paneOffset)")
                } else {
                    let newId = try await tmux.splitPane(
                        paneIds[0], // Splits off the first pane so the next layout
                        // call can re-arrange them; tmux preset layouts ignore
                        // which split came from which parent anyway.
                        horizontal: true,
                        workingDirectory: paneDir,
                        shellCommand: pane.shell
                    )
                    paneIds.append(newId)
                }
            }

            // Apply layout once all panes exist so tmux can size the window
            // proportionally.
            if let layout = window.layout, !layout.isEmpty, !dryRun {
                try? await tmux.selectLayout(target: "\(sessionName):\(actualIndex)", layout: layout)
            }

            // Send shell_command_before + per-pane shell + shell_command lines.
            for (paneOffset, pane) in window.panes.enumerated() {
                let paneId = paneIds[paneOffset]
                if pane.sleepBefore > 0 {
                    planned.append("sleep \(pane.sleepBefore)s before pane[\(paneOffset)] commands")
                    if !dryRun {
                        try? await Task.sleep(for: .seconds(pane.sleepBefore))
                    }
                }

                // The first pane of every window is bootstrapped with the
                // user's default shell (by createSession or newWindow). For
                // split-off panes we already passed `shell:` to splitPane so
                // the new process is the requested shell. The bootstrap pane
                // needs an explicit `exec <shell>` to swap.
                if paneOffset == 0, let shell = pane.shell, !shell.isEmpty {
                    planned.append("pane[\(paneOffset)] exec \(shell)")
                    if !dryRun {
                        try await tmux.sendKeys(paneId, keys: "exec \(shell)", literal: true)
                        try await tmux.sendKeys(paneId, keys: "Enter")
                    }
                }

                let suppress = pane.suppressHistory ?? sessionConfig.suppressHistory
                let prefix = sessionConfig.shellCommandBefore + window.shellCommandBefore

                // Prefix commands always send Enter — these are bootstrap
                // shell commands (env setup, source ...) that would stall
                // the shell mid-line if held back. Only the pane's own
                // commands respect `pane.enter`, so a user can pre-fill a
                // command line with `enter: false` without breaking the
                // session-/window-level prep.
                for command in prefix {
                    let payload = suppress ? " \(command)" : command
                    planned.append("pane[\(paneOffset)] send: \(payload)")
                    if !dryRun {
                        if !payload.isEmpty {
                            try await tmux.sendKeys(paneId, keys: payload, literal: true)
                        }
                        try await tmux.sendKeys(paneId, keys: "Enter")
                    }
                }

                let lines = pane.commandLines(claudeCommandPath: claudeCommandPath)
                for command in lines {
                    let payload = suppress ? " \(command)" : command
                    planned.append("pane[\(paneOffset)] send: \(payload)")
                    if !dryRun {
                        if !payload.isEmpty {
                            try await tmux.sendKeys(paneId, keys: payload, literal: true)
                        }
                        if pane.enter {
                            try await tmux.sendKeys(paneId, keys: "Enter")
                        }
                    }
                }

                if pane.sleepAfter > 0 {
                    planned.append("sleep \(pane.sleepAfter)s after pane[\(paneOffset)] commands")
                    if !dryRun {
                        try? await Task.sleep(for: .seconds(pane.sleepAfter))
                    }
                }

                // Apply the optional initial progress bar declared in the
                // YAML. Sent through the same `MirrorWindowManager` path
                // the OSC 9;4 reader (and the runtime CLI) uses, so a
                // re-applied layout can set the bar even if the pane was
                // already running and the bar can later be overridden by
                // any new OSC sequence the pane emits.
                if let progress = pane.progress {
                    planned.append("pane[\(paneOffset)] set_progress \(progress.accessibilityValueString)")
                    if !dryRun {
                        await progressApplier(progress, paneId)
                    }
                }
            }

            // Per-pane focus: do this after layout so the requested pane wins.
            if let focusOffset = window.panes.firstIndex(where: { $0.focus }) {
                let target = paneIds[focusOffset]
                planned.append("pane.select \(target)")
                if !dryRun {
                    try? await tmux.selectPane(target)
                }
            }
        }

        // MARK: - Hooks

        private func runHooks(
            _ hooks: [LayoutConfig.Hook],
            scope: String,
            planned: inout [String],
            dryRun: Bool,
            shellEnvironment: [String: String]
        ) async throws {
            for hook in hooks {
                planned.append("\(scope): \(hook.cmd)")
                if !dryRun {
                    let result = try await runShellCommand(
                        hook.cmd,
                        cwd: hook.cwd,
                        env: hook.env,
                        shellEnvironment: shellEnvironment
                    )
                    if !result.isSuccess {
                        throw DriverError.hookFailed(
                            cmd: hook.cmd,
                            exitCode: result.exitCode,
                            stderr: result.stderrString
                        )
                    }
                }
            }
        }

        private func runShellCommand(
            _ cmd: String,
            cwd: String?,
            env: [String: String],
            shellEnvironment: [String: String]
        ) async throws -> ProcessResult {
            // `-l` gives the user's full login profile (PATH, aliases via
            // sourced files, etc.) so hooks behave like shell commands the
            // user would type. `-c` reads the next argv as the command body.
            var arguments = ["-lc", cmd]
            if let cwd, !cwd.isEmpty {
                let resolved = expandUserPath(cwd, shellEnvironment: shellEnvironment)
                // `cd <dir> && <cmd>` is the cheapest cross-platform way to
                // run with a custom cwd through `sh -lc`. Process.workingDirectoryURL
                // would also work but adds another error surface.
                arguments = ["-lc", "cd \(shellQuote(resolved)) && \(cmd)"]
            }
            // ProcessRunner merges `env` over ProcessInfo.environment, so
            // hook-supplied keys win without losing the rest of the user
            // environment.
            let merged = env.isEmpty ? nil : env
            return try await processRunner.run(
                "/bin/sh",
                arguments,
                merged,
                nil
            )
        }

        // MARK: - Path resolution

        /// Resolves a directory string per spec §7. The first non-nil value
        /// from [start, fallbacks…, configDirectory, $HOME] becomes the cwd.
        /// `~` and `$VAR` get expanded; relative paths are resolved against
        /// the next fallback in the list.
        private func resolvedDirectory(
            start: String?,
            fallbacks: [String?],
            configDirectory: String?,
            shellEnvironment: [String: String]
        ) -> String? {
            let candidates: [String?] = [start] + fallbacks
            for candidate in candidates {
                guard let candidate, !candidate.isEmpty else { continue }
                let expanded = expandUserPath(candidate, shellEnvironment: shellEnvironment)
                if (expanded as NSString).isAbsolutePath {
                    return expanded
                }
                // Relative — resolve against the next defined scope (deeper
                // fallbacks already tried by the loop's progression on the
                // outer call site).
                let base = nextBaseFor(
                    candidate: candidate,
                    fallbacks: fallbacks,
                    configDirectory: configDirectory,
                    shellEnvironment: shellEnvironment
                )
                let baseUrl = URL(fileURLWithPath: base)
                return baseUrl.appendingPathComponent(expanded).standardizedFileURL.path
            }
            return configDirectory.map { expandUserPath($0, shellEnvironment: shellEnvironment) }
        }

        private func nextBaseFor(
            candidate: String,
            fallbacks: [String?],
            configDirectory: String?,
            shellEnvironment: [String: String]
        ) -> String {
            for fallback in fallbacks {
                guard let fallback, !fallback.isEmpty else { continue }
                let expanded = expandUserPath(fallback, shellEnvironment: shellEnvironment)
                if (expanded as NSString).isAbsolutePath {
                    return expanded
                }
            }
            if let configDirectory, !configDirectory.isEmpty {
                return expandUserPath(configDirectory, shellEnvironment: shellEnvironment)
            }
            return shellEnvironment["HOME"] ?? NSHomeDirectory()
        }

        private func expandUserPath(_ path: String, shellEnvironment: [String: String]) -> String {
            var result = path
            if result.hasPrefix("~/") {
                let home = shellEnvironment["HOME"] ?? NSHomeDirectory()
                result = home + String(result.dropFirst(1))
            } else if result == "~" {
                result = shellEnvironment["HOME"] ?? NSHomeDirectory()
            }
            // Variable expansion already happened in the parser (§7.1);
            // anything still containing `$` here is a literal the user wrote
            // intentionally (or escaped via `\$`).
            return result
        }

        private func shellQuote(_ s: String) -> String {
            // Single-quote everything and escape embedded single quotes by
            // closing the quote, inserting `'\''`, and reopening.
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    // MARK: - Window/Pane helpers

    extension LayoutConfig.Window {
        func tmuxTarget(sessionName: String, fallbackIndex: Int?) -> String? {
            if let index { return "\(sessionName):\(index)" }
            if let name { return "\(sessionName):\(name)" }
            if let fallbackIndex { return "\(sessionName):\(fallbackIndex)" }
            return nil
        }
    }

    extension LayoutConfig.Pane {
        /// Returns the command line(s) that should be sent into this pane.
        /// `claude:` shorthand expands here so the driver can treat all panes
        /// uniformly during the send loop.
        func commandLines(claudeCommandPath: String) -> [String] {
            if let claude {
                var parts: [String] = [shellQuoteWord(claudeCommandPath)]
                if let model = claude.model {
                    parts.append("--model")
                    parts.append(shellQuoteWord(model))
                }
                parts.append(contentsOf: claude.args.map(shellQuoteWord))
                return [parts.joined(separator: " ")]
            }
            return shellCommands
        }

        private func shellQuoteWord(_ s: String) -> String {
            if s.range(of: "[^A-Za-z0-9_./:=-]", options: .regularExpression) == nil {
                return s
            }
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
#endif
