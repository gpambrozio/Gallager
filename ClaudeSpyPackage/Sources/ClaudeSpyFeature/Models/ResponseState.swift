import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation

/// Manages the state of an event response (permission request, prompt, etc.)
/// This allows response state to be shared between ClaudeSessionTerminalView and LiveTerminalView.
/// Responses are persisted to SessionStore so they survive navigation.
@MainActor
@Observable
final public class ResponseState {
    /// The event this response is for
    public let event: HookEvent

    /// Whether a command is currently being sent
    public var isSending = false

    /// Reference to the session store for persistence
    private weak var sessionStore: SessionStore?

    /// Flag to prevent didSet from persisting during initialization
    private var isInitialized = false

    /// The user's response, if they've responded.
    /// Setting this persists the response to SessionStore (iOS only).
    public var response: ResponseType? {
        didSet {
            guard isInitialized else { return }
            #if os(iOS)
                sessionStore?.setResponse(response, for: event.id)
            #endif
        }
    }

    public init(event: HookEvent, sessionStore: SessionStore? = nil) {
        self.event = event
        self.sessionStore = sessionStore
        // Restore any existing response from the store.
        // isInitialized is false, so didSet won't trigger @Observable mutations.
        #if os(iOS)
            self.response = sessionStore?.response(for: event.id)
        #endif
        self.isInitialized = true
    }
}
