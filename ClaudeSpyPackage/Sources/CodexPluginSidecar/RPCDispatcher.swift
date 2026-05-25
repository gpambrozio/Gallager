import Foundation
import GallagerPluginProtocol
import Logging

// `JSONValue` lives in `ClaudeSpyNetworking` while the JSON-RPC envelope
// types live in `GallagerPluginProtocol`. We narrow the import to avoid
// pulling `ClaudeSpyNetworking`'s own `JSONRPCRequest`/`JSONRPCResponse`
// (an unrelated in-app socket protocol) into scope.
import enum ClaudeSpyNetworking.JSONValue

// MARK: - RPCDispatcher

/// Routes inbound JSON-RPC requests to handler closures keyed by method
/// name. Defined here (instead of inside the `JSONRPCConnection` that the
/// Mac runtime uses) so the sidecar can register handlers in a declarative
/// table.
///
/// The sidecar protocol's "App → Sidecar" methods (Spec §6.1) are all
/// request/response. Notifications back to the app are sent through a
/// separate write path; this dispatcher only deals with inbound traffic.
///
/// Identical to the dispatcher in `ClaudeCodePluginSidecar`. Each sidecar
/// keeps its own copy because the type is internal — sharing it would
/// require promoting it to `GallagerPluginProtocol` along with the entire
/// handler closure shape, which we'd rather defer until we have a third
/// sidecar that wants the same surface.
actor RPCDispatcher {
    /// Handler signature: takes the raw `params` value and returns the raw
    /// `result` value (or throws to surface an error to the peer).
    typealias Handler = @Sendable (_ params: JSONValue?) async throws -> JSONValue?

    private var handlers: [String: Handler] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    /// Register a handler for `method`. Re-registering overwrites — fine
    /// for the sidecar use case where the table is built once at startup.
    func register(_ method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    /// Whether a handler has been registered for `method`. Mostly used by
    /// tests; the dispatcher itself just calls `handle(_:)` and surfaces
    /// method-not-found through the wire response.
    func isRegistered(_ method: String) -> Bool {
        handlers[method] != nil
    }

    /// Look up and run the handler for `request.method`. Wraps results +
    /// errors into a `JSONRPCResponse`. Unknown methods surface as the
    /// standard `-32_601` method-not-found code (Spec §13).
    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let handler = handlers[request.method] else {
            logger.debug("rpc: unknown method \(request.method)")
            return JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: JSONRPCError(
                    code: -32_601,
                    message: "Method not found: \(request.method)"
                )
            )
        }

        do {
            let result = try await handler(request.params)
            return JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: result ?? .null,
                error: nil
            )
        } catch let rpc as RPCDispatcherError {
            return JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: rpc.asRPCError()
            )
        } catch {
            logger.warning("rpc handler \(request.method) threw: \(error)")
            return JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: JSONRPCError(
                    code: -32_603,
                    message: "Internal error: \(error)"
                )
            )
        }
    }
}

// MARK: - RPCDispatcherError

/// Errors a handler can throw to surface a structured JSON-RPC error to
/// the peer instead of the generic internal-error code.
enum RPCDispatcherError: Error, Sendable {
    /// `-32_602` — the params object was missing or malformed.
    case invalidParams(String)
    /// `-32_603` — handler-internal failure with a custom message.
    case internalError(String)
    /// Custom JSON-RPC error code + message + optional data payload.
    case custom(code: Int, message: String, data: JSONValue?)

    func asRPCError() -> JSONRPCError {
        switch self {
        case let .invalidParams(message):
            return JSONRPCError(code: -32_602, message: message)
        case let .internalError(message):
            return JSONRPCError(code: -32_603, message: message)
        case let .custom(code, message, data):
            return JSONRPCError(code: code, message: message, data: data)
        }
    }
}
