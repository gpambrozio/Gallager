import ClaudeSpyNetworking
import Foundation

// MARK: - JSONRPCMessage

/// Top-level JSON-RPC 2.0 message. Disambiguates between request, response,
/// and notification by peeking at which keys are present:
///
/// - `id` + `method` → request
/// - `method` (no `id`) → notification
/// - `id` + (`result` or `error`) → response
///
/// We deliberately keep these as distinct types so call sites can pattern-
/// match on the case without re-decoding. Coexists with the older
/// `JSONRPCRequest`/`JSONRPCResponse` in `ClaudeSpyNetworking`, which use a
/// simpler shape for the in-app socket protocol.
public enum JSONRPCMessage: Codable, Sendable, Equatable {
    case request(JSONRPCRequest)
    case response(JSONRPCResponse)
    case notification(JSONRPCNotification)

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasID = container.contains(.id)
        let hasMethod = container.contains(.method)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)

        if hasMethod, hasID {
            self = try .request(JSONRPCRequest(from: decoder))
        } else if hasMethod {
            self = try .notification(JSONRPCNotification(from: decoder))
        } else if hasID, hasResult || hasError {
            self = try .response(JSONRPCResponse(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not a recognized JSON-RPC message shape"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .request(request):
            try request.encode(to: encoder)
        case let .response(response):
            try response.encode(to: encoder)
        case let .notification(notification):
            try notification.encode(to: encoder)
        }
    }
}

// MARK: - JSONRPCRequest

/// A JSON-RPC 2.0 request: an `id` to correlate the response, a `method`
/// name, and optional `params`. Distinct from `ClaudeSpyNetworking`'s
/// in-app `JSONRPCRequest` (which uses a string id and a `[String: JSONValue]`
/// params dictionary).
public struct JSONRPCRequest: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let method: String
    public let params: JSONValue?

    public init(jsonrpc: String = "2.0", id: JSONRPCID, method: String, params: JSONValue? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

// MARK: - JSONRPCNotification

/// A JSON-RPC 2.0 notification: like a request, but no `id` — no response
/// is expected. Used in the sidecar protocol for fire-and-forget callbacks
/// (`set_projects`, `log`, status updates).
public struct JSONRPCNotification: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(jsonrpc: String = "2.0", method: String, params: JSONValue? = nil) {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
    }
}

// MARK: - JSONRPCResponse

/// A JSON-RPC 2.0 response. Carries either a `result` or an `error` — never
/// both. The `id` matches the originating request's `id`.
public struct JSONRPCResponse: Codable, Sendable, Equatable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(
        jsonrpc: String = "2.0",
        id: JSONRPCID,
        result: JSONValue? = nil,
        error: JSONRPCError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

// MARK: - JSONRPCError

/// A JSON-RPC 2.0 error payload. Code is numeric per the spec; the in-app
/// `ClaudeSpyNetworking.JSONRPCError` uses string codes for the unrelated
/// gallager socket protocol.
public struct JSONRPCError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - JSONRPCID

/// A JSON-RPC 2.0 message id. Per the spec the id can be a number, a string,
/// or null. We model only the number and string variants because gallager
/// never emits null ids; ids are always present and never spoofable.
public enum JSONRPCID: Codable, Sendable, Hashable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .number(int)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "JSON-RPC id must be int or string"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(n): try container.encode(n)
        case let .string(s): try container.encode(s)
        }
    }
}
