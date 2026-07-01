import Foundation

/// A JSON value that can be used in JSON-RPC params and results.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(v): try container.encode(v)
        case let .int(v): try container.encode(v)
        case let .double(v): try container.encode(v)
        case let .bool(v): try container.encode(v)
        case .null: try container.encodeNil()
        case let .array(v): try container.encode(v)
        case let .object(v): try container.encode(v)
        }
    }

    /// Convenience accessor for string values.
    public var stringValue: String? {
        if case let .string(v) = self { return v }
        return nil
    }

    /// Convenience accessor for bool values.
    public var boolValue: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }

    /// Convenience accessor for int values.
    public var intValue: Int? {
        if case let .int(v) = self { return v }
        return nil
    }

    /// Convenience accessor for object values.
    public var objectValue: [String: JSONValue]? {
        if case let .object(v) = self { return v }
        return nil
    }

    /// Encode any `Encodable` to a `JSONValue` (JSONEncoder → decode to JSONValue).
    public init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode this `JSONValue` as a typed `Decodable` (re-encode → JSONDecoder).
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

/// A JSON-RPC request sent from the CLI to the socket server.
public struct JSONRPCRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: [String: JSONValue]

    public init(id: String, method: String, params: [String: JSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Error detail in a JSON-RPC error response.
public struct JSONRPCError: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A JSON-RPC response sent from the socket server to the CLI.
public struct JSONRPCResponse: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: [String: JSONValue]?
    public let error: JSONRPCError?

    public init(id: String, result: [String: JSONValue]) {
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: String, error: JSONRPCError) {
        self.id = id
        self.ok = false
        self.result = nil
        self.error = error
    }

    /// Convenience for simple success with no data.
    public static func ok(id: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: ["ok": .bool(true)])
    }

    /// Convenience for not-found errors.
    public static func notFound(id: String, _ message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "not_found", message: message))
    }

    /// Convenience for invalid-params errors.
    public static func invalidParams(id: String, _ message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "invalid_params", message: message))
    }

    /// Convenience for method-not-found errors.
    public static func methodNotFound(id: String, _ method: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "method_not_found", message: "Unknown method: \(method)"))
    }

    /// Convenience for internal errors.
    public static func internalError(id: String, _ message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "internal_error", message: message))
    }
}
