import ClaudeSpyNetworking
import Foundation

public enum FramingError: Error, Equatable {
    case malformedHeader
    case bodyTooLarge(Int)
    case missingContentLength
}

public enum StdioFramer {
    static let maxHeaderBytes = 16 * 1_024
    static let maxBodyBytes = 32 * 1_024 * 1_024

    public static func encode(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}

/// Incremental, allocation-bounded decoder for `Content-Length`-framed JSON.
/// Not thread-safe; the transport actor owns one and feeds it inline.
public struct FrameDecoder {
    private var buffer = Data()
    private var expectedBody: Int? // set once a header is parsed; nil while reading a header
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    public init() { }

    /// Append `chunk`; return every complete body it completes, in order.
    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []
        while true {
            if let need = expectedBody {
                guard buffer.count >= need else { break }
                bodies.append(buffer.prefix(need))
                buffer.removeFirst(need)
                expectedBody = nil
                continue
            }
            guard let range = buffer.range(of: Self.headerTerminator) else {
                if buffer.count > StdioFramer.maxHeaderBytes { throw FramingError.malformedHeader }
                break
            }
            let header = buffer[buffer.startIndex..<range.lowerBound]
            if header.count > StdioFramer.maxHeaderBytes { throw FramingError.malformedHeader }
            guard let length = Self.contentLength(header) else { throw FramingError.missingContentLength }
            if length > StdioFramer.maxBodyBytes { throw FramingError.bodyTooLarge(length) }
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            expectedBody = length
        }
        return bodies
    }

    private static func contentLength(_ header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard
                parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

public struct RPCError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: "method_not_found", message: "Unknown method: \(method)")
    }
}

public struct RPCMessage: Codable, Sendable, Equatable {
    public var id: String?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?

    public init(
        id: String? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: RPCError? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public static func request(id: String, method: String, params: JSONValue?) -> RPCMessage {
        RPCMessage(id: id, method: method, params: params)
    }

    public static func notification(method: String, params: JSONValue?) -> RPCMessage {
        RPCMessage(method: method, params: params)
    }

    public static func response(id: String, result: JSONValue?) -> RPCMessage {
        RPCMessage(id: id, result: result ?? .object([:]))
    }

    public static func failure(id: String, error: RPCError) -> RPCMessage {
        RPCMessage(id: id, error: error)
    }

    public var isResponse: Bool {
        id != nil && method == nil
    }

    public var isRequest: Bool {
        id != nil && method != nil
    }

    public var isNotification: Bool {
        id == nil && method != nil
    }
}

/// App→Sidecar method names (each `PluginCore` method, serialized).
public enum SidecarRPC {
    public static let initialize = "initialize"
    public static let translateEvent = "translate_event" // handleIngress
    public static let deliverResponse = "deliver_response"
    public static let refreshProjects = "refresh_projects"
    public static let commandForLaunch = "command_for_launch"
    public static let install = "install"
    public static let uninstall = "uninstall"
    public static let installStatus = "install_status"
    public static let applySettings = "apply_settings"
    public static let shutdown = "shutdown"
    public static let detectPane = "detect_pane" // optional capability
}

/// Sidecar→App message names (each `PluginHost` method, serialized).
public enum HostRPC {
    public static let setProjects = "set_projects" // notification
    public static let emitEvent = "emit_event" // notification
    public static let sendText = "send_text" // notification
    public static let sendKeys = "send_keys" // notification
    public static let log = "log" // notification
    public static let agentPanes = "agent_panes" // REQUEST (returns [String])
    public static let promptUser = "prompt_user" // optional capability (notification)
}

/// `PluginEnv` minus the non-serializable `host`, with `settings` as nested JSON.
public struct PluginEnvWire: Codable, Sendable, Equatable {
    public var pluginRoot: String
    public var stateDir: String
    public var appVersion: String
    public var settings: JSONValue // the parsed settings.json (or .object([:]) when empty)
    public var marketplaceSource: String
    public var otlpReceiverEndpoint: String?

    public init(_ env: PluginEnv) throws {
        self.pluginRoot = env.pluginRoot.path
        self.stateDir = env.stateDir.path
        self.appVersion = env.appVersion
        self.marketplaceSource = env.marketplaceSource.path
        self.otlpReceiverEndpoint = env.otlpReceiverEndpoint?.absoluteString
        if env.settings.isEmpty {
            self.settings = .object([:])
        } else {
            self.settings = try JSONDecoder().decode(JSONValue.self, from: env.settings)
        }
    }

    /// Re-encode the embedded settings object back to canonical JSON bytes.
    public func settingsData() -> Data {
        (try? JSONEncoder().encode(settings)) ?? Data()
    }
}
