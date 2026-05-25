#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import CodexPluginCore

    @Suite("CodexSettings")
    struct CodexSettingsTests {
        // MARK: - Defaults

        @Test("Default init values match the bundled JSON schema defaults")
        func defaultsMatchSchema() {
            let s = CodexSettings()
            #expect(s.commandPath == "codex")
            #expect(s.autoRun == true)
            #expect(s.logLevel == .info)
        }

        // MARK: - JSON round-trip

        @Test("Default-init round-trip via JSONValue preserves values")
        func defaultRoundTripViaJSONValue() throws {
            let s = CodexSettings()
            let encoded = try s.encodedJSON()
            let decoded = try CodexSettings.decode(from: encoded)
            #expect(decoded == s)
        }

        @Test("Custom values round-trip via JSONValue")
        func customRoundTripViaJSONValue() throws {
            let s = CodexSettings(
                commandPath: "/opt/custom/codex",
                autoRun: false,
                logLevel: .debug
            )
            let encoded = try s.encodedJSON()
            let decoded = try CodexSettings.decode(from: encoded)
            #expect(decoded == s)
        }

        @Test("Custom values round-trip via JSONEncoder/Decoder")
        func customRoundTripViaCodable() throws {
            let s = CodexSettings(
                commandPath: "/opt/custom/codex",
                autoRun: false,
                logLevel: .warn
            )
            let data = try JSONEncoder().encode(s)
            let decoded = try JSONDecoder().decode(CodexSettings.self, from: data)
            #expect(decoded == s)
        }

        // MARK: - Wire format

        @Test("Encoded JSON uses snake_case keys")
        func encodingUsesSnakeCase() throws {
            let s = CodexSettings(
                commandPath: "/foo/codex",
                autoRun: false,
                logLevel: .error
            )
            let data = try JSONEncoder().encode(s)
            let str = String(data: data, encoding: .utf8) ?? ""
            #expect(str.contains("\"command_path\""))
            #expect(str.contains("\"auto_run\""))
            #expect(str.contains("\"log_level\""))
            // Round-trip verifies the un-escaped value survives (JSONEncoder
            // escapes forward slashes in the raw bytes).
            let decoded = try JSONDecoder().decode(CodexSettings.self, from: data)
            #expect(decoded.commandPath == "/foo/codex")
        }

        @Test("Decoding accepts the snake_case wire shape produced by the JSON file")
        func decodesSnakeCase() throws {
            let json = #"""
            {
              "command_path": "/usr/local/bin/codex",
              "auto_run": false,
              "log_level": "debug"
            }
            """#
            let decoded = try JSONDecoder().decode(CodexSettings.self, from: Data(json.utf8))
            #expect(decoded.commandPath == "/usr/local/bin/codex")
            #expect(decoded.autoRun == false)
            #expect(decoded.logLevel == .debug)
        }

        // MARK: - Missing keys → defaults

        @Test("Missing keys fall back to defaults")
        func missingKeysFallBackToDefaults() throws {
            let json = "{}"
            let decoded = try JSONDecoder().decode(CodexSettings.self, from: Data(json.utf8))
            #expect(decoded == CodexSettings())
        }

        @Test("Partial JSON merges with defaults")
        func partialJSON() throws {
            let json = #"{ "command_path": "/opt/codex" }"#
            let decoded = try JSONDecoder().decode(CodexSettings.self, from: Data(json.utf8))
            #expect(decoded.commandPath == "/opt/codex")
            #expect(decoded.autoRun == true)
            #expect(decoded.logLevel == .info)
        }

        @Test("JSONValue.object with missing keys decodes to defaults")
        func jsonValueObjectMissingKeys() throws {
            let json = JSONValue.object([:])
            let decoded = try CodexSettings.decode(from: json)
            #expect(decoded == CodexSettings())
        }

        @Test("JSONValue.object with custom values decodes")
        func jsonValueObjectCustom() throws {
            let json = JSONValue.object([
                "command_path": .string("/custom/codex"),
                "auto_run": .bool(false),
                "log_level": .string("warn"),
            ])
            let decoded = try CodexSettings.decode(from: json)
            #expect(decoded.commandPath == "/custom/codex")
            #expect(decoded.autoRun == false)
            #expect(decoded.logLevel == .warn)
        }

        // MARK: - Validation

        @Test("Default settings validate cleanly")
        func defaultsValidate() {
            let s = CodexSettings()
            #expect(s.validate() == nil)
        }

        @Test("Empty commandPath fails validation")
        func emptyCommandPathFails() {
            let s = CodexSettings(commandPath: "")
            #expect(s.validate() == .emptyCommandPath)
        }

        @Test("Whitespace-only commandPath fails validation")
        func whitespaceCommandPathFails() {
            let s = CodexSettings(commandPath: "   \t  ")
            #expect(s.validate() == .emptyCommandPath)
        }

        // MARK: - LogLevel

        @Test("LogLevel raw values match the bundled JSON schema option values")
        func logLevelRawValues() {
            #expect(CodexSettings.LogLevel.debug.rawValue == "debug")
            #expect(CodexSettings.LogLevel.info.rawValue == "info")
            #expect(CodexSettings.LogLevel.warn.rawValue == "warn")
            #expect(CodexSettings.LogLevel.error.rawValue == "error")
            #expect(CodexSettings.LogLevel.allCases.count == 4)
        }
    }
#endif
