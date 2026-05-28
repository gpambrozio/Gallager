import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import SwiftUI

/// Sends the user's answer (or dismissal) for an outstanding
/// `AgentResponseRequest` back to the Mac via the existing command channel.
///
/// Each open response form holds a reference to one of these and calls
/// `submit(...)` on the user's submit action, or `dismiss(...)` on cancel.
/// The form itself never builds wire envelopes or agent-specific keystrokes —
/// it just produces a structured `AgentResponse` and hands it to the submitter.
///
/// `@MainActor` because the response views invoke this from SwiftUI button
/// handlers; `AnyObject` so it can be held by reference. `@MainActor` already
/// implies `Sendable` for class types, so no explicit conformance is needed.
@MainActor
public protocol AgentResponseSubmitter: AnyObject {
    /// User answered the request. Wraps `response` in an
    /// `AgentResponseSubmission` envelope and writes it on the host socket.
    func submit(
        hostID: String,
        sessionID: String,
        pluginID: String,
        requestID: String,
        response: AgentResponse
    ) async

    /// User dismissed the form without answering. Clears the matching entry in
    /// `SessionStore.responseRequests` so the UI stops presenting it.
    ///
    /// We deliberately don't ship a wire message for dismiss in this iteration:
    /// the contract is that the Mac is the one driving form lifecycle (see
    /// `agent_response_request` with `request == nil` for the cancel path).
    /// Local dismissal is purely a UI affordance — the open ask remains
    /// outstanding on the agent side until something else resolves it.
    func dismiss(requestID: String) async
}

// MARK: - Default Implementation

/// Default `AgentResponseSubmitter` that wraps the existing
/// `ViewerConnectionManager` socket. iOS holds a single instance keyed off the
/// connection manager and the local session store.
@MainActor
final public class DefaultAgentResponseSubmitter: AgentResponseSubmitter {
    private let connectionManager: ViewerConnectionManager
    private let sessionStore: SessionStore

    public init(connectionManager: ViewerConnectionManager, sessionStore: SessionStore) {
        self.connectionManager = connectionManager
        self.sessionStore = sessionStore
    }

    public func submit(
        hostID: String,
        sessionID: String,
        pluginID: String,
        requestID: String,
        response: AgentResponse
    ) async {
        // Intentionally do NOT clear the local presentation here. The
        // response views show a brief "Reply submitted" confirmation once
        // `submit` returns, and an optimistic dismiss would tear that view
        // down before it can render. The Mac sends an `agent_response_request`
        // with `request == nil` once it accepts the submission, which is the
        // authoritative signal that dismisses the form.
        let submission = AgentResponseSubmission(
            sessionId: sessionID,
            pluginId: pluginID,
            requestId: requestID,
            response: response
        )
        await connectionManager.sendAgentResponseSubmission(submission, hostId: hostID)
    }

    public func dismiss(requestID: String) async {
        sessionStore.dismissResponseRequest(requestID: requestID)
    }
}

// MARK: - SwiftUI Environment

/// Environment key carrying the active `AgentResponseSubmitter`. iOS sets it
/// at the root of the connected view hierarchy so any response form can submit
/// without threading the submitter through every initializer.
///
/// `EnvironmentKey.defaultValue` is a non-isolated static requirement, so the
/// key's default has to be plain `nil` — `AgentResponseSubmitter` is
/// `@MainActor`, but a nil optional doesn't touch any state. The reading side
/// (`@Environment(\.agentResponseSubmitter)`) already runs on the main actor
/// in views, so the value is consumed safely.
private struct AgentResponseSubmitterKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (any AgentResponseSubmitter)? = nil
}

public extension EnvironmentValues {
    /// The active `AgentResponseSubmitter`, if iOS has wired one up. Forms
    /// downstream of `ContentView` get a non-nil value.
    var agentResponseSubmitter: (any AgentResponseSubmitter)? {
        get { self[AgentResponseSubmitterKey.self] }
        set { self[AgentResponseSubmitterKey.self] = newValue }
    }
}

public extension View {
    /// Injects an `AgentResponseSubmitter` into the environment.
    func agentResponseSubmitter(_ submitter: any AgentResponseSubmitter) -> some View {
        environment(\.agentResponseSubmitter, submitter)
    }
}
