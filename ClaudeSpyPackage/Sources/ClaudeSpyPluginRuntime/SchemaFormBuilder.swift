#if os(macOS)
    import AppKit
    import ClaudeSpyNetworking
    import GallagerPluginProtocol
    import SwiftUI

    // MARK: - SchemaFormView

    /// SwiftUI form rendered from a `PluginSettingsSchema` (Spec §17.3).
    ///
    /// The form owns no model of its own — values are stored in a binding
    /// keyed by field id. The parent (`PluginSettingsView`) seeds the
    /// dictionary from the plugin's saved settings.json, owns the binding,
    /// and forwards `onSubmit` to `PluginManager.applySettings(...)`.
    ///
    /// Validation strategy: trivial UI-side checks (numeric range, file
    /// existence when `mustExist`) live in the field renderers themselves.
    /// Semantic validation (e.g. "does this binary launch?") is delegated
    /// to the sidecar — `applySettings` returns an error that this view
    /// surfaces via `validationError`.
    public struct SchemaFormView: View {
        // MARK: - Inputs

        @Binding public var values: [String: JSONValue]
        public let schema: PluginSettingsSchema
        public let onSubmit: ([String: JSONValue]) async throws -> Void
        public let validationError: String?

        // MARK: - Local state

        @State private var isSubmitting = false
        @State private var localError: String?

        public init(
            values: Binding<[String: JSONValue]>,
            schema: PluginSettingsSchema,
            onSubmit: @escaping ([String: JSONValue]) async throws -> Void,
            validationError: String? = nil
        ) {
            self._values = values
            self.schema = schema
            self.onSubmit = onSubmit
            self.validationError = validationError
        }

        // MARK: - Body

        public var body: some View {
            Group {
                ForEach(Array(schema.sections.enumerated()), id: \.offset) { _, section in
                    Section(section.title) {
                        ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                            fieldView(for: field)
                        }
                    }
                }

                if let displayError = localError ?? validationError {
                    Section {
                        Label(displayError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Save") {
                            Task { await save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSubmitting)
                    }
                }
            }
        }

        // MARK: - Submission

        private func save() async {
            isSubmitting = true
            defer { isSubmitting = false }
            localError = nil
            do {
                try await onSubmit(values)
            } catch {
                localError = error.localizedDescription
            }
        }

        // MARK: - Field rendering

        @ViewBuilder
        private func fieldView(for field: PluginSettingsSchema.Field) -> some View {
            switch field {
            case let .string(stringField):
                stringFieldView(stringField)
            case let .boolean(booleanField):
                booleanFieldView(booleanField)
            case let .int(intField):
                intFieldView(intField)
            case let .picker(pickerField):
                pickerFieldView(pickerField)
            case let .filePath(filePathField):
                filePathFieldView(filePathField)
            }
        }

        @ViewBuilder
        private func stringFieldView(_ field: PluginSettingsSchema.StringField) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    field.label,
                    text: stringBinding(for: field.id, default: field.default ?? ""),
                    prompt: field.placeholder.map(Text.init)
                )
                if let help = field.help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        @ViewBuilder
        private func booleanFieldView(_ field: PluginSettingsSchema.BooleanField) -> some View {
            Toggle(
                field.label,
                isOn: boolBinding(for: field.id, default: field.default ?? false)
            )
        }

        @ViewBuilder
        private func intFieldView(_ field: PluginSettingsSchema.IntField) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                let value = intBinding(
                    for: field.id,
                    default: field.default ?? (field.min ?? 0)
                )
                Stepper(
                    "\(field.label): \(value.wrappedValue)",
                    value: value,
                    in: (field.min ?? Int.min)...(field.max ?? Int.max),
                    step: field.step ?? 1
                )
                if let help = field.help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        @ViewBuilder
        private func pickerFieldView(_ field: PluginSettingsSchema.PickerField) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                let style: PickerStyleChoice = field.options.count <= 4 ? .segmented : .menu
                let binding = stringBinding(
                    for: field.id,
                    default: field.default ?? field.options.first?.value ?? ""
                )
                pickerWithStyle(field: field, binding: binding, style: style)
                if let help = field.help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // SwiftUI's `.pickerStyle(...)` modifier produces a different type
        // per case, so we hand-roll a tiny switch instead of `if/else`-ing
        // a single Picker — the type-erased generic just for branching
        // would erase the segmented appearance.
        @ViewBuilder
        private func pickerWithStyle(
            field: PluginSettingsSchema.PickerField,
            binding: Binding<String>,
            style: PickerStyleChoice
        ) -> some View {
            switch style {
            case .segmented:
                Picker(field.label, selection: binding) {
                    ForEach(field.options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
            case .menu:
                Picker(field.label, selection: binding) {
                    ForEach(field.options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }
        }

        @ViewBuilder
        private func filePathFieldView(_ field: PluginSettingsSchema.FilePathField) -> some View {
            let path = stringBinding(for: field.id, default: field.default ?? "").wrappedValue
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(field.label)
                    Spacer()
                    Button("Browse…") {
                        if let chosen = openPathPanel(for: field) {
                            values[field.id] = .string(chosen)
                        }
                    }
                }
                if !path.isEmpty {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let help = field.help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        @MainActor
        private func openPathPanel(for field: PluginSettingsSchema.FilePathField) -> String? {
            let panel = NSOpenPanel()
            panel.canChooseFiles = !field.directoriesOnly
            panel.canChooseDirectories = field.directoriesOnly
            panel.allowsMultipleSelection = false
            panel.message = "Select \(field.label)"
            // `mustExist` is implicit in NSOpenPanel — it only ever returns
            // paths that exist at the time the user clicks Open.
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return url.path
        }

        // MARK: - JSONValue <-> binding helpers

        /// Pull-or-default helper for a string-shaped field. Writes back to
        /// the parent's binding through a custom getter/setter.
        private func stringBinding(for key: String, default fallback: String) -> Binding<String> {
            Binding<String>(
                get: { values[key]?.stringValue ?? fallback },
                set: { values[key] = .string($0) }
            )
        }

        private func boolBinding(for key: String, default fallback: Bool) -> Binding<Bool> {
            Binding<Bool>(
                get: { values[key]?.boolValue ?? fallback },
                set: { values[key] = .bool($0) }
            )
        }

        private func intBinding(for key: String, default fallback: Int) -> Binding<Int> {
            Binding<Int>(
                get: { values[key]?.intValue ?? fallback },
                set: { values[key] = .int($0) }
            )
        }
    }

    // MARK: - PickerStyleChoice

    /// Branching helper for the segmented-vs-menu picker style decision.
    /// Spec §17.3 mandates segmented when there are 4 or fewer options.
    private enum PickerStyleChoice {
        case segmented
        case menu
    }

    // MARK: - SchemaFormDefaults

    /// Static helpers exposed for tests + the per-plugin Settings page so
    /// that the same default-resolution logic that powers the form is
    /// reusable outside the SwiftUI view body.
    public enum SchemaFormDefaults {
        /// Default values for every field in `schema`, expressed as
        /// `JSONValue`s. Fields whose default is omitted in the schema use
        /// a type-appropriate fallback (`""` for strings, `false` for
        /// booleans, `0` for ints, the first picker option, an empty path).
        public static func initialValues(
            for schema: PluginSettingsSchema
        ) -> [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            for section in schema.sections {
                for field in section.fields {
                    out[fieldID(for: field)] = defaultValue(for: field)
                }
            }
            return out
        }

        /// Merge `existing` into the schema's defaults so a partially-
        /// populated settings.json fills in only the missing keys. Order
        /// matters: existing values win over defaults.
        public static func merge(
            schema: PluginSettingsSchema,
            with existing: [String: JSONValue]
        ) -> [String: JSONValue] {
            var values = initialValues(for: schema)
            for (key, value) in existing {
                values[key] = value
            }
            return values
        }

        /// Flat list of every field id declared by `schema`, in source
        /// order. Useful for tests asserting that field renderers covered
        /// every entry.
        public static func fieldIDs(for schema: PluginSettingsSchema) -> [String] {
            schema.sections.flatMap { section in
                section.fields.map(fieldID(for:))
            }
        }

        // MARK: - Internal

        static func fieldID(for field: PluginSettingsSchema.Field) -> String {
            switch field {
            case let .string(f): f.id
            case let .boolean(f): f.id
            case let .int(f): f.id
            case let .picker(f): f.id
            case let .filePath(f): f.id
            }
        }

        static func defaultValue(for field: PluginSettingsSchema.Field) -> JSONValue {
            switch field {
            case let .string(f):
                return .string(f.default ?? "")
            case let .boolean(f):
                return .bool(f.default ?? false)
            case let .int(f):
                return .int(f.default ?? (f.min ?? 0))
            case let .picker(f):
                return .string(f.default ?? f.options.first?.value ?? "")
            case let .filePath(f):
                return .string(f.default ?? "")
            }
        }
    }
#endif
