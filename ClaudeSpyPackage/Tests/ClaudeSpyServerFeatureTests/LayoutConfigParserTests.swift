#if os(macOS)
    import ClaudeSpyNetworking
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Required fields

    @Test
    func parsesMinimalConfig() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("workers"),
        ])
        let config = try parser.parse(value)
        #expect(config.sessionName == "workers")
        #expect(config.windows.isEmpty)
    }

    @Test
    func failsWhenSessionNameMissing() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([:])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    @Test
    func failsWhenSessionNameNotString() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object(["session_name": .int(42)])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    @Test
    func failsWhenRootIsNotObject() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .array([])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    // MARK: - Strict / lenient

    @Test
    func strictModeRejectsUnknownTopLevelKey() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "made_up_key": .string("hi"),
        ])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    @Test
    func lenientModeDemotesUnknownKeysToWarnings() throws {
        let parser = LayoutConfigParser(lenient: true, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "made_up_key": .string("hi"),
        ])
        let config = try parser.parse(value)
        #expect(config.warnings.contains(where: { $0.contains("made_up_key") }))
    }

    @Test
    func acceptedButIgnoredKeysWarnInBothModes() throws {
        let strictParser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "global_options": .object([:]),
            "socket_name": .string("/tmp/x"),
        ])
        let config = try strictParser.parse(value)
        #expect(config.ignoredKeys.contains("global_options"))
        #expect(config.ignoredKeys.contains("socket_name"))
        #expect(config.warnings.contains(where: { $0.contains("global_options") }))
    }

    @Test
    func rejectsERBTemplateKeys() {
        let parser = LayoutConfigParser(lenient: true, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "@args": .object([:]),
        ])
        // ERB / @args are explicitly rejected even under lenient mode — they
        // require behavior we will not implement.
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    // MARK: - Variable expansion

    @Test
    func expandsVariablesInSessionName() throws {
        let parser = LayoutConfigParser(lenient: false, environment: ["BRANCH": "feature-x"])
        let value: JSONValue = .object([
            "session_name": .string("review-${BRANCH}"),
        ])
        let config = try parser.parse(value)
        #expect(config.sessionName == "review-feature-x")
    }

    @Test
    func strictModeRejectsUndefinedVariables() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("review-${MISSING}"),
        ])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    @Test
    func lenientModeDemotesUndefinedVariablesToWarnings() throws {
        let parser = LayoutConfigParser(lenient: true, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("review-${MISSING}"),
        ])
        let config = try parser.parse(value)
        #expect(config.sessionName == "review-")
        #expect(config.warnings.contains(where: { $0.contains("MISSING") }))
    }

    // MARK: - Windows

    @Test
    func windowAcceptsBothWindowNameAndNameAlias() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object(["window_name": .string("editor")]),
                .object(["name": .string("server")]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.windows.count == 2)
        #expect(config.windows[0].name == "editor")
        // `name:` is treated as an alias for `window_name:` so users coming from
        // tmuxinator configs aren't forced to rename keys.
        #expect(config.windows[1].name == "server")
    }

    @Test
    func windowRejectsUnknownKeyInStrictMode() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object(["window_name": .string("editor"), "weird": .string("x")]),
            ]),
        ])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    @Test
    func mergesWindowOptionsAndOptionsAfter() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object([
                    "window_name": .string("editor"),
                    "options": .object(["main-pane-height": .int(20)]),
                    "options_after": .object(["main-pane-height": .int(30)]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        // `options_after` wins on conflict because tmuxp applies it later in the
        // build pipeline.
        #expect(config.windows[0].options["main-pane-height"] == "30")
    }

    // MARK: - Panes

    @Test
    func paneAsBareStringBecomesShellCommand() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object([
                    "window_name": .string("editor"),
                    "panes": .array([.string("vim .")]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.windows[0].panes.first?.shellCommands == ["vim ."])
    }

    @Test
    func paneAsArrayBecomesMultipleShellCommands() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object([
                    "window_name": .string("editor"),
                    "panes": .array([.array([.string("cmd1"), .string("cmd2")])]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.windows[0].panes.first?.shellCommands == ["cmd1", "cmd2"])
    }

    @Test
    func paneAsObjectAcceptsAllFields() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object([
                    "window_name": .string("editor"),
                    "panes": .array([
                        .object([
                            "shell_command": .string("vim ."),
                            "start_directory": .string("./api"),
                            "focus": .bool(true),
                            "shell": .string("/bin/fish"),
                            "enter": .bool(false),
                            "suppress_history": .bool(true),
                            "sleep_before": .double(0.5),
                            "sleep_after": .int(1),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        let pane = config.windows[0].panes[0]
        #expect(pane.shellCommands == ["vim ."])
        #expect(pane.startDirectory == "./api")
        #expect(pane.focus == true)
        #expect(pane.shell == "/bin/fish")
        #expect(pane.enter == false)
        #expect(pane.suppressHistory == true)
        #expect(pane.sleepBefore == 0.5)
        #expect(pane.sleepAfter == 1)
    }

    @Test
    func paneEnterDefaultsToTrue() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object([
                    "panes": .array([.object([:])]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.windows[0].panes[0].enter == true)
    }

    @Test
    func claudePaneShorthand() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object([
                    "panes": .array([
                        .object([
                            "claude": .object([
                                "project": .string("~/code/foo"),
                                "args": .array([.string("--resume")]),
                                "model": .string("claude-sonnet-4-6"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        let claude = config.windows[0].panes[0].claude
        #expect(claude?.project == "~/code/foo")
        #expect(claude?.args == ["--resume"])
        #expect(claude?.model == "claude-sonnet-4-6")
    }

    @Test
    func claudeAndShellCommandAreMutuallyExclusive() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object([
                    "panes": .array([
                        .object([
                            "shell_command": .string("vim"),
                            "claude": .object(["project": .string("~/foo")]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    // MARK: - Hooks

    @Test
    func parsesStringHooks() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "on_create": .array([.string("echo bootstrap")]),
            "on_apply": .array([.string("notify-send 'ready'")]),
        ])
        let config = try parser.parse(value)
        #expect(config.onCreate.count == 1)
        #expect(config.onCreate[0].cmd == "echo bootstrap")
        #expect(config.onApply[0].cmd == "notify-send 'ready'")
    }

    @Test
    func parsesObjectHookWithCwdAndEnv() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "on_create": .array([
                .object([
                    "cmd": .string("./bootstrap.sh"),
                    "cwd": .string("/tmp"),
                    "env": .object(["X": .string("1")]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.onCreate[0].cmd == "./bootstrap.sh")
        #expect(config.onCreate[0].cwd == "/tmp")
        #expect(config.onCreate[0].env == ["X": "1"])
    }

    // MARK: - tmuxp parity examples

    @Test
    func tmuxpDjangoExampleParses() throws {
        // Cribbed from the Motivation section in the spec — should round-trip
        // without modification or warnings under strict mode.
        let parser = LayoutConfigParser(
            lenient: false,
            environment: ["HOME": "/Users/me"]
        )
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "start_directory": .string("./"),
            "shell_command_before": .array([.string("source .venv/bin/activate")]),
            "environment": .object([
                "DJANGO_SETTINGS_MODULE": .string("config.settings.local"),
            ]),
            "windows": .array([
                .object([
                    "window_name": .string("editor"),
                    "focus": .bool(true),
                    "panes": .array([.string("vim")]),
                ]),
                .object([
                    "window_name": .string("server"),
                    "panes": .array([.string("./manage.py runserver")]),
                ]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.sessionName == "dev")
        #expect(config.startDirectory == "./")
        #expect(config.environment == ["DJANGO_SETTINGS_MODULE": "config.settings.local"])
        #expect(config.shellCommandBefore == ["source .venv/bin/activate"])
        #expect(config.windows[0].focus == true)
        #expect(config.windows[0].panes[0].shellCommands == ["vim"])
        #expect(config.windows[1].panes[0].shellCommands == ["./manage.py runserver"])
        #expect(config.warnings.isEmpty)
    }

    @Test
    func parsesSparseWindowIndexes() throws {
        // Spec §4.3: "sparse indexes are honored, not compacted." The parser
        // round-trips the explicit indexes; the driver is responsible for
        // creating windows at those indexes.
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "windows": .array([
                .object(["window_name": .string("main"), "window_index": .int(0)]),
                .object(["window_name": .string("logs"), "window_index": .int(5)]),
                .object(["window_name": .string("scratch")]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.windows[0].index == 0)
        #expect(config.windows[1].index == 5)
        #expect(config.windows[2].index == nil)
    }

    // MARK: - Color

    @Test
    func parsesCanonicalColor() throws {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "color": .string("blue"),
        ])
        let config = try parser.parse(value)
        #expect(config.color == .blue)
    }

    @Test
    func parsesColorAlias() throws {
        // Aliases like "violet"/"magenta" mirror the CLI/API parser so YAML
        // configs ported from notes don't fail on a synonym.
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "color": .string("violet"),
        ])
        let config = try parser.parse(value)
        #expect(config.color == .purple)
    }

    @Test
    func emptyColorClears() throws {
        // `color: ""` mirrors `set-color ""`/`set-color none`: the field is
        // present but explicitly empty, which means "no color".
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "color": .string(""),
        ])
        let config = try parser.parse(value)
        #expect(config.color == nil)
    }

    @Test
    func strictModeRejectsUnknownColor() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "color": .string("chartreuse"),
        ])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    @Test
    func lenientModeDemotesUnknownColorToWarning() throws {
        let parser = LayoutConfigParser(lenient: true, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "color": .string("chartreuse"),
        ])
        let config = try parser.parse(value)
        #expect(config.color == nil)
        #expect(config.warnings.contains(where: { $0.contains("chartreuse") }))
    }

    @Test
    func colorMustBeString() {
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "color": .int(42),
        ])
        #expect(throws: LayoutConfigError.self) {
            _ = try parser.parse(value)
        }
    }

    @Test
    func startupWindowAliasFlipsFocus() throws {
        // tmuxinator's `startup_window` should flip the matching window's focus.
        let parser = LayoutConfigParser(lenient: false, environment: [:])
        let value: JSONValue = .object([
            "session_name": .string("dev"),
            "startup_window": .string("server"),
            "windows": .array([
                .object(["window_name": .string("editor")]),
                .object(["window_name": .string("server")]),
            ]),
        ])
        let config = try parser.parse(value)
        #expect(config.windows[0].focus == false)
        #expect(config.windows[1].focus == true)
    }
#endif
