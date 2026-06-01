import Foundation

// MARK: - Plugin wire messages (Mac ↔ iOS)

/// High-frequency session-status badge update (spec §7.2). No tool name, no
/// card — just the working/attention bits for a session, tagged by plugin.
public struct AgentSessionStatusMessage: Codable, Sendable, Equatable {
    public let pairId: String
    public let sessionId: String
    public let pluginId: String
    public let working: Bool
    public let attention: Bool
    public let timestamp: Date

    public init(
        pairId: String,
        sessionId: String,
        pluginId: String,
        working: Bool,
        attention: Bool,
        timestamp: Date
    ) {
        self.pairId = pairId
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.working = working
        self.attention = attention
        self.timestamp = timestamp
    }

    /// Returns a copy with `pairId` replaced (filled per-connection on send).
    public func withPairId(_ pairId: String) -> AgentSessionStatusMessage {
        AgentSessionStatusMessage(
            pairId: pairId,
            sessionId: sessionId,
            pluginId: pluginId,
            working: working,
            attention: attention,
            timestamp: timestamp
        )
    }
}

/// Open or retract an iOS response form. `request == nil` retracts the open form
/// with `requestId` (spec §7.2).
public struct AgentResponseRequestMessage: Codable, Sendable, Equatable {
    public let pairId: String
    public let sessionId: String
    public let pluginId: String
    public let requestId: String
    public let request: AgentResponseRequest?

    public init(
        pairId: String,
        sessionId: String,
        pluginId: String,
        requestId: String,
        request: AgentResponseRequest?
    ) {
        self.pairId = pairId
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.requestId = requestId
        self.request = request
    }

    public func withPairId(_ pairId: String) -> AgentResponseRequestMessage {
        AgentResponseRequestMessage(
            pairId: pairId,
            sessionId: sessionId,
            pluginId: pluginId,
            requestId: requestId,
            request: request
        )
    }
}

/// iOS submits a response for a request the Mac previously emitted. The Mac
/// matches `requestId` and calls `core.deliverResponse(...)` (spec §7.2).
public struct AgentResponseSubmissionMessage: Codable, Sendable, Equatable {
    public let pairId: String
    public let sessionId: String
    public let pluginId: String
    public let requestId: String
    public let response: AgentResponse

    public init(
        pairId: String,
        sessionId: String,
        pluginId: String,
        requestId: String,
        response: AgentResponse
    ) {
        self.pairId = pairId
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.requestId = requestId
        self.response = response
    }

    public func withPairId(_ pairId: String) -> AgentResponseSubmissionMessage {
        AgentResponseSubmissionMessage(
            pairId: pairId,
            sessionId: sessionId,
            pluginId: pluginId,
            requestId: requestId,
            response: response
        )
    }
}

/// The complete enabled-plugin presentation set, pushed on every viewer connect
/// and on enable/disable/upgrade. **Always the complete set** (spec §7.2/§7.3).
public struct PluginPresentationsMessage: Codable, Sendable, Equatable {
    public let pairId: String
    public let presentations: [PluginPresentation]

    public init(pairId: String, presentations: [PluginPresentation]) {
        self.pairId = pairId
        self.presentations = presentations
    }

    public func withPairId(_ pairId: String) -> PluginPresentationsMessage {
        PluginPresentationsMessage(pairId: pairId, presentations: presentations)
    }
}

/// A pre-baked notification (title/body) delivered over the live WebSocket so a
/// backgrounded-but-connected viewer can materialize a local notification. The
/// relay drops the parallel `.encryptedPush` (APNs) while the viewer is
/// WS-connected, so this is the only alert path during the backgrounded window;
/// once the socket drops, APNs takes over. `sessionId` carries the pane id.
public struct AgentNotificationMessage: Codable, Sendable, Equatable {
    public let pairId: String
    public let sessionId: String?
    public let title: String
    public let body: String
    public let timestamp: Date

    public init(
        pairId: String,
        sessionId: String?,
        title: String,
        body: String,
        timestamp: Date
    ) {
        self.pairId = pairId
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.timestamp = timestamp
    }

    public func withPairId(_ pairId: String) -> AgentNotificationMessage {
        AgentNotificationMessage(
            pairId: pairId,
            sessionId: sessionId,
            title: title,
            body: body,
            timestamp: timestamp
        )
    }
}
