#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeCodePluginCore

    @Suite("ClaudeCodeSettings")
    struct ClaudeCodeSettingsTests {
        // MARK: - Defaults

        @Test("Default init values match the bundled JSON schema defaults")
        func defaultsMatchSchema() {
            let s = ClaudeCodeSettings()
            #expect(s.commandPath == "claude")
            #expect(s.autoRun == true)
            #expect(s.logLevel == .info)
        }

        // MARK: - JSON round-trip

        @Test("Default-init round-trip via JSONValue preserves values")
        func defaultRoundTripViaJSONValue() throws {
            let s = ClaudeCodeSettings()
            let encoded = try s.encodedJSON()
            let decoded = try ClaudeCodeSettings.decode(from: encoded)
            #expect(decoded == s)
        }

        @Test("Custom values round-trip via JSONValue")
        func customRoundTripViaJSONValue() throws {
            let s = ClaudeCodeSettings(
                commandPath: "/opt/custom/claude",
                autoRun: false,
                logLevel: .debug
            )
            let encoded = try s.encodedJSON()
            let decoded = try ClaudeCodeSettings.decode(from: encoded)
            #expect(decoded == s)
        }

        @Test("Custom values round-trip via JSONEncoder/Decoder")
        func customRoundTripViaCodable() throws {
            let s = ClaudeCodeSettings(
                commandPath: "/opt/custom/claude",
                autoRun: false,
                logLevel: .warn
            )
            let data = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(ClaudeCodeSettings.self, from: data)
            #expect(decoded == s)
        }

        // MARK: - Wire format

        @Test("Encoded JSON uses snake_case keys")
        func encodingUsesSnakeCase() throws {
            let s = ClaudeCodeSettings(
                commandPath: "/foo/claude",
                autoRun: false,
                logLevel: .error
            )
            let data = try JSONEncoder().encode(s)
            let str = String(data: data, encoding: .utf8) ?? ""
            #expect(str.contains("\"command_path\""))
            #expect(str.contains("\"auto_run\""))
            #expect(str.contains("\"log_level\""))
            // JSONEncoder escapes forward slashes by default — assert the
            // un-escaped value survives a round-trip rather than checking
            // the raw bytes.
            let decoded = try JSONDecoder().decode(ClaudeCodeSettings.self, from: data)
            #expect(decoded.commandPath == "/foo/claude")
        }

        @Test("Decoding accepts the snake_case wire shape produced by the JSON file")
        func decodesSnakeCase() throws {
            let json = #"""
            {
              "command_path": "/usr/local/bin/claude",
              "auto_run": false,
              "log_level": "debug"
            }
            """#
            let decoded = try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data(json.utf8))
            #expect(decoded.commandPath == "/usr/local/bin/claude")
            #expect(decoded.autoRun == false)
            #expect(decoded.logLevel == .debug)
        }

        // MARK: - Missing keys → defaults

        @Test("Missing keys fall back to defaults")
        func missingKeysFallBackToDefaults() throws {
            let json = "{}"
            let decoded = try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data(json.utf8))
            #expect(decoded == ClaudeCodeSettings())
        }

        @Test("Partial JSON merges with defaults")
        func partialJSON() throws {
            let json = #"{ "command_path": "/opt/claude" }"#
            let decoded = try JSONDecoder().decode(ClaudeCodeSettings.self, from: Data(json.utf8))
            #expect(decoded.commandPath == "/opt/claude")
            #expect(decoded.autoRun == true)
            #expect(decoded.logLevel == .info)
        }

        @Test("JSONValue.object with missing keys decodes to defaults")
        func jsonValueObjectMissingKeys() throws {
            let json = JSONValue.object([:])
            let decoded = try ClaudeCodeSettings.decode(from: json)
            #expect(decoded == ClaudeCodeSettings())
        }

        @Test("JSONValue.object with custom values decodes")
        func jsonValueObjectCustom() throws {
            let json = JSONValue.object([
                "command_path": .string("/custom/claude"),
                "auto_run": .bool(false),
                "log_level": .string("warn"),
            ])
            let decoded = try ClaudeCodeSettings.decode(from: json)
            #expect(decoded.commandPath == "/custom/claude")
            #expect(decoded.autoRun == false)
            #expect(decoded.logLevel == .warn)
        }

        // MARK: - Validation

        @Test("Default settings validate cleanly")
        func defaultsValidate() {
            let s = ClaudeCodeSettings()
            #expect(s.validate() == nil)
        }

        @Test("Empty commandPath fails validation")
        func emptyCommandPathFails() {
            let s = ClaudeCodeSettings(commandPath: "")
            #expect(s.validate() == .emptyCommandPath)
        }

        @Test("Whitespace-only commandPath fails validation")
        func whitespaceCommandPathFails() {
            let s = ClaudeCodeSettings(commandPath: "   \t  ")
            #expect(s.validate() == .emptyCommandPath)
        }

        // MARK: - LogLevel

        @Test("LogLevel raw values match the bundled JSON schema option values")
        func logLevelRawValues() {
            #expect(ClaudeCodeSettings.LogLevel.debug.rawValue == "debug")
            #expect(ClaudeCodeSettings.LogLevel.info.rawValue == "info")
            #expect(ClaudeCodeSettings.LogLevel.warn.rawValue == "warn")
            #expect(ClaudeCodeSettings.LogLevel.error.rawValue == "error")
            #expect(ClaudeCodeSettings.LogLevel.allCases.count == 4)
        }
    }
#endif
