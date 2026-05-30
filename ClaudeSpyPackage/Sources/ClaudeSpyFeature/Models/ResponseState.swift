import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation

/// Manages the state of a response to an `AgentResponseRequest` (permission,
/// prompt, plan, …). Shared between the terminal detail views. Responses are
/// persisted to `SessionStore` (keyed by `requestID`) so they survive navigation.
@MainActor
@Observable
final public class ResponseState {
    /// The open request this state is responding to.
    public let request: AgentResponseRequest

    /// Plugin that emitted the request (carried back on submission).
    public let pluginID: String

    /// Stable request id correlating the submission to the request.
    public let requestID: String

    /// Whether a response is currently being submitted.
    public var isSending = false

    /// Whether the stop hook summary section is expanded (used by StopResponseView).
    public var isSummaryExpanded = false

    /// Reference to the session store for persistence
    private weak var sessionStore: SessionStore?

    /// Flag to prevent didSet from persisting during initialization
    private var isInitialized = false

    /// The user's response feedback, if they've responded.
    /// Setting this persists the response to `SessionStore` (iOS only).
    public var response: ResponseType? {
        didSet {
            guard isInitialized else { return }
            #if os(iOS)
                sessionStore?.setResponse(response, forRequestID: requestID)
            #endif
        }
    }

    public init(
        request: AgentResponseRequest,
        pluginID: String,
        requestID: String,
        sessionStore: SessionStore? = nil
    ) {
        self.request = request
        self.pluginID = pluginID
        self.requestID = requestID
        self.sessionStore = sessionStore
        // Restore any existing response from the store.
        // isInitialized is false, so didSet won't trigger @Observable mutations.
        #if os(iOS)
            self.response = sessionStore?.response(forRequestID: requestID)
        #endif
        self.isInitialized = true
    }
}
