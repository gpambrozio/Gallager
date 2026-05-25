import Foundation

// MARK: - PluginSettingsSchema

/// JSON schema describing the per-plugin settings form (Spec §17.3).
///
/// The Mac renders a SwiftUI form from this schema; saved values land at
/// `~/.gallager/state/plugins/<id>/settings.json` and reach the sidecar via
/// `apply_settings`. iOS does NOT render this UI — settings are Mac-only.
///
/// Wire-format requirement: decoding MUST use a `JSONDecoder` with
/// `keyDecodingStrategy = .convertFromSnakeCase`. Schemas are read-only on
/// the Mac side; this type still conforms to `Codable` (round-trip via the
/// strategy) for test ergonomics.
public struct PluginSettingsSchema: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sections: [Section]

    public init(schemaVersion: Int, sections: [Section]) {
        self.schemaVersion = schemaVersion
        self.sections = sections
    }

    // MARK: - Section

    /// One titled group of fields rendered as a SwiftUI `Section`.
    public struct Section: Codable, Sendable, Equatable {
        public let title: String
        public let fields: [Field]

        public init(title: String, fields: [Field]) {
            self.title = title
            self.fields = fields
        }
    }

    // MARK: - Field

    /// Closed set of supported field types. Discriminator key is `type`,
    /// matching the same flat-with-tag shape as `AppAction` in
    /// `ClaudeSpyNetworking`.
    public enum Field: Codable, Sendable, Equatable {
        case string(StringField)
        case boolean(BooleanField)
        case int(IntField)
        case picker(PickerField)
        case filePath(FilePathField)

        // Discriminator. Field-specific keys (`id`, `label`, ...) live flat
        // alongside `type` per Spec §17.3.
        private enum TypeKey: String, CodingKey {
            case type
        }

        private enum FieldType: String, Codable {
            case string
            case boolean
            case int
            case picker
            case filePath = "file_path"
        }

        public init(from decoder: Decoder) throws {
            let typeContainer = try decoder.container(keyedBy: TypeKey.self)
            let type = try typeContainer.decode(FieldType.self, forKey: .type)
            switch type {
            case .string:
                self = try .string(StringField(from: decoder))
            case .boolean:
                self = try .boolean(BooleanField(from: decoder))
            case .int:
                self = try .int(IntField(from: decoder))
            case .picker:
                self = try .picker(PickerField(from: decoder))
            case .filePath:
                self = try .filePath(FilePathField(from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var typeContainer = encoder.container(keyedBy: TypeKey.self)
            switch self {
            case let .string(field):
                try typeContainer.encode(FieldType.string, forKey: .type)
                try field.encode(to: encoder)
            case let .boolean(field):
                try typeContainer.encode(FieldType.boolean, forKey: .type)
                try field.encode(to: encoder)
            case let .int(field):
                try typeContainer.encode(FieldType.int, forKey: .type)
                try field.encode(to: encoder)
            case let .picker(field):
                try typeContainer.encode(FieldType.picker, forKey: .type)
                try field.encode(to: encoder)
            case let .filePath(field):
                try typeContainer.encode(FieldType.filePath, forKey: .type)
                try field.encode(to: encoder)
            }
        }
    }

    // MARK: - StringField

    /// A single-line text input. Stored value: `String`.
    public struct StringField: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let `default`: String?
        public let placeholder: String?
        public let help: String?

        public init(
            id: String,
            label: String,
            default: String?,
            placeholder: String?,
            help: String?
        ) {
            self.id = id
            self.label = label
            self.default = `default`
            self.placeholder = placeholder
            self.help = help
        }
    }

    // MARK: - BooleanField

    /// A toggle. Stored value: `Bool`.
    public struct BooleanField: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let `default`: Bool?

        public init(id: String, label: String, default: Bool?) {
            self.id = id
            self.label = label
            self.default = `default`
        }
    }

    // MARK: - IntField

    /// A `Stepper` (with optional inline `TextField` for direct entry).
    /// Stored value: `Int`.
    public struct IntField: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let `default`: Int?
        public let min: Int?
        public let max: Int?
        public let step: Int?
        public let help: String?

        public init(
            id: String,
            label: String,
            default: Int?,
            min: Int?,
            max: Int?,
            step: Int?,
            help: String?
        ) {
            self.id = id
            self.label = label
            self.default = `default`
            self.min = min
            self.max = max
            self.step = step
            self.help = help
        }
    }

    // MARK: - PickerField

    /// A picker. Stored value: the chosen option's `value` (a `String`).
    public struct PickerField: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let `default`: String?
        public let options: [Option]
        public let help: String?

        public init(
            id: String,
            label: String,
            default: String?,
            options: [Option],
            help: String?
        ) {
            self.id = id
            self.label = label
            self.default = `default`
            self.options = options
            self.help = help
        }

        public struct Option: Codable, Sendable, Equatable {
            public let value: String
            public let label: String

            public init(value: String, label: String) {
                self.value = value
                self.label = label
            }
        }
    }

    // MARK: - FilePathField

    /// A path picker. macOS uses `NSOpenPanel`; iOS doesn't render this
    /// field type. Stored value: `String` (absolute path).
    public struct FilePathField: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let `default`: String?
        public let mustExist: Bool
        public let directoriesOnly: Bool
        public let help: String?

        public init(
            id: String,
            label: String,
            default: String?,
            mustExist: Bool,
            directoriesOnly: Bool,
            help: String?
        ) {
            self.id = id
            self.label = label
            self.default = `default`
            self.mustExist = mustExist
            self.directoriesOnly = directoriesOnly
            self.help = help
        }
    }
}
