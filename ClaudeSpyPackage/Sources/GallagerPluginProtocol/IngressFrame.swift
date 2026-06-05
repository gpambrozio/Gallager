import Foundation

// MARK: - IngressFrame

/// One self-identifying frame read from the app-owned ingress socket (spec §8).
///
/// Wire format on the socket:
/// ```
/// 4-byte big-endian UInt32 length + JSON body
/// body = { "plugin_id": "<id>", "context": { <env vars> }, "payload": <raw event> }
/// ```
/// The app reads the frame, routes by `pluginID` to the owning core's
/// `handleIngress`, and dispatches the returned event. The `payload` is the raw
/// host-agent event bytes (the core decodes them); `context` is the env snapshot
/// the bridge harvested (`TMUX_PANE` always present; agent-specific keys read via
/// per-core extensions).
public struct IngressFrame: Sendable, Equatable {
    public let pluginID: String
    public let context: [String: String]
    /// Raw host-agent event bytes (decoded by the owning core).
    public let payload: Data

    public init(pluginID: String, context: [String: String], payload: Data) {
        self.pluginID = pluginID
        self.context = context
        self.payload = payload
    }

    /// `TMUX_PANE` from the harvested context, if present (pane identity — §8.1).
    public var tmuxPane: String? {
        context["TMUX_PANE"]
    }
}

// MARK: - Frame codec

/// Errors decoding a length-prefixed ingress frame.
public enum IngressFrameError: Error, Sendable, Equatable {
    case malformedJSON
    case missingPluginID
}

public extension IngressFrame {
    /// Keys for the JSON frame body. `payload` is kept as raw bytes (re-encoded
    /// verbatim) so cores receive the exact host-agent event.
    private enum BodyKeys: String {
        case pluginID = "plugin_id"
        case context
        case payload
    }

    /// Decode a frame from the JSON **body** bytes (length prefix already stripped).
    static func decode(body: Data) throws -> IngressFrame {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            throw IngressFrameError.malformedJSON
        }
        guard let pluginID = object[BodyKeys.pluginID.rawValue] as? String, !pluginID.isEmpty else {
            throw IngressFrameError.missingPluginID
        }
        // Keep only the string-valued entries: a single non-string value would
        // make an `as? [String: String]` cast fail wholesale, dropping the whole
        // dict (including TMUX_PANE) and mis-routing the frame.
        var context: [String: String] = [:]
        if let rawContext = object[BodyKeys.context.rawValue] as? [String: Any] {
            for (key, value) in rawContext {
                if let string = value as? String { context[key] = string }
            }
        }

        // Preserve the raw payload bytes by re-serializing the sub-object. The
        // payload may be any JSON value (object/array/scalar).
        let payloadData: Data
        if let payloadValue = object[BodyKeys.payload.rawValue] {
            payloadData = (try? JSONSerialization.data(
                withJSONObject: payloadValue,
                options: [.fragmentsAllowed]
            )) ?? Data()
        } else {
            payloadData = Data()
        }

        return IngressFrame(pluginID: pluginID, context: context, payload: payloadData)
    }

    /// Encode this frame's JSON body bytes (without the length prefix). Used by
    /// the test driver and the language-agnostic bridge contract.
    func encodeBody() throws -> Data {
        var object: [String: Any] = [
            BodyKeys.pluginID.rawValue: pluginID,
            BodyKeys.context.rawValue: context,
        ]
        if
            !payload.isEmpty,
            let payloadValue = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) {
            object[BodyKeys.payload.rawValue] = payloadValue
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The full on-socket frame: 4-byte big-endian length prefix + JSON body.
    func encodeFrame() throws -> Data {
        let body = try encodeBody()
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }
}
