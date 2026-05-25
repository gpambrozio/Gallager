#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import SwiftUI
    import Testing
    @testable import ClaudeSpyPluginRuntime

    @Suite("SchemaFormBuilder")
    struct SchemaFormBuilderTests {
        // MARK: - Fixtures

        /// Mirror of the bundled `claude-code/ui/settings.json` schema —
        /// covers `string`, `boolean`, `picker`, and includes an `int`
        /// + `file_path` to exercise the remaining renderers.
        private func sampleSchema() -> PluginSettingsSchema {
            PluginSettingsSchema(
                schemaVersion: 1,
                sections: [
                    .init(
                        title: "Command",
                        fields: [
                            .string(.init(
                                id: "command_path",
                                label: "CLI command",
                                default: "claude",
                                placeholder: "claude",
                                help: "Absolute path or $PATH-discoverable name."
                            )),
                            .filePath(.init(
                                id: "config_dir",
                                label: "Config dir",
                                default: nil,
                                mustExist: true,
                                directoriesOnly: true,
                                help: nil
                            )),
                        ]
                    ),
                    .init(
                        title: "Behavior",
                        fields: [
                            .boolean(.init(
                                id: "auto_run",
                                label: "Auto-launch on project open",
                                default: true
                            )),
                            .int(.init(
                                id: "max_concurrent",
                                label: "Max concurrent sessions",
                                default: 3,
                                min: 1,
                                max: 10,
                                step: 1,
                                help: nil
                            )),
                            .picker(.init(
                                id: "log_level",
                                label: "Log level",
                                default: "info",
                                options: [
                                    .init(value: "debug", label: "Debug"),
                                    .init(value: "info", label: "Info"),
                                    .init(value: "warn", label: "Warning"),
                                    .init(value: "error", label: "Error"),
                                ],
                                help: nil
                            )),
                        ]
                    ),
                ]
            )
        }

        // MARK: - Field id extraction

        @Test("fieldIDs walks every section in source order")
        func fieldIDsInSourceOrder() {
            let schema = sampleSchema()
            let ids = SchemaFormDefaults.fieldIDs(for: schema)
            #expect(ids == [
                "command_path",
                "config_dir",
                "auto_run",
                "max_concurrent",
                "log_level",
            ])
        }

        // MARK: - Defaults from schema

        @Test("initialValues seeds the dictionary with each field's declared default")
        func initialValuesUsesDeclaredDefaults() {
            let schema = sampleSchema()
            let values = SchemaFormDefaults.initialValues(for: schema)

            #expect(values["command_path"] == .string("claude"))
            #expect(values["auto_run"] == .bool(true))
            #expect(values["max_concurrent"] == .int(3))
            #expect(values["log_level"] == .string("info"))
            // No default on the file path → empty string fallback.
            #expect(values["config_dir"] == .string(""))
        }

        @Test("initialValues falls back to type-appropriate values when default is omitted")
        func initialValuesFallsBackOnMissingDefault() {
            let schema = PluginSettingsSchema(
                schemaVersion: 1,
                sections: [
                    .init(title: "S", fields: [
                        .string(.init(id: "a", label: "A", default: nil, placeholder: nil, help: nil)),
                        .boolean(.init(id: "b", label: "B", default: nil)),
                        .int(.init(id: "c", label: "C", default: nil, min: nil, max: nil, step: nil, help: nil)),
                        .picker(.init(
                            id: "d",
                            label: "D",
                            default: nil,
                            options: [.init(value: "first", label: "F"), .init(value: "second", label: "S")],
                            help: nil
                        )),
                        .int(.init(id: "e", label: "E", default: nil, min: 5, max: 10, step: 1, help: nil)),
                    ]),
                ]
            )

            let values = SchemaFormDefaults.initialValues(for: schema)
            #expect(values["a"] == .string(""))
            #expect(values["b"] == .bool(false))
            #expect(values["c"] == .int(0))
            // First picker option used as fallback.
            #expect(values["d"] == .string("first"))
            // Int with min but no default uses the min as fallback.
            #expect(values["e"] == .int(5))
        }

        // MARK: - Merge keeps existing user values

        @Test("merge preserves existing values and fills missing keys from defaults")
        func mergePreservesExistingValues() {
            let schema = sampleSchema()
            let existing: [String: JSONValue] = [
                "command_path": .string("/opt/claude"),
                "log_level": .string("debug"),
                // No `auto_run`, `max_concurrent`, or `config_dir` —
                // these come from the schema defaults.
            ]

            let merged = SchemaFormDefaults.merge(schema: schema, with: existing)
            #expect(merged["command_path"] == .string("/opt/claude"))
            #expect(merged["log_level"] == .string("debug"))
            #expect(merged["auto_run"] == .bool(true))
            #expect(merged["max_concurrent"] == .int(3))
            #expect(merged["config_dir"] == .string(""))
        }

        // MARK: - JSONValue accessors

        @Test("JSONValue accessors round-trip the three primitive types")
        func jsonValueAccessors() {
            // Sanity-check that the `JSONValue` accessors the form
            // bindings rely on actually return values.
            #expect(JSONValue.string("hello").stringValue == "hello")
            #expect(JSONValue.bool(true).boolValue == true)
            #expect(JSONValue.int(42).intValue == 42)
            // Mismatched types yield nil so the binding falls back to the
            // declared default.
            #expect(JSONValue.string("not a bool").boolValue == nil)
            #expect(JSONValue.bool(true).intValue == nil)
        }

        // MARK: - View instantiation smoke test

        @Test("SchemaFormView can be instantiated for every field type without crashing")
        @MainActor
        func instantiateView() {
            let schema = sampleSchema()
            var values = SchemaFormDefaults.initialValues(for: schema)
            let binding = Binding(get: { values }, set: { values = $0 })
            let view = SchemaFormView(
                values: binding,
                schema: schema,
                onSubmit: { _ in }
            )
            // Reading `.body` proves the view tree builds successfully —
            // every field type returns a non-nil renderer.
            _ = view.body
        }
    }
#endif
