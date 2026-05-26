import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

// MARK: - Sink protocols
//
// Downstream Mac-side code implements these in Task 15 (the app coordinator
// wiring). We declare them here so the runtime can be exercised by unit tests
// — and reasoned about in isolation — without dragging in the app target.

/// Receives session-status updates emitted by plugins. The app sink updates
/// the per-pane `working`/`needsAttention` indicators.
///
/// `tmuxPane` is the tmux pane id the sidecar harvested from `TMUX_PANE`
/// for this event (when known). The Mac uses it to bootstrap a fresh
/// `AgentSession` for non-bundled plugins (and bundled plugins running in
/// stubbed-out E2E panes) whose process-name detection didn't fire.
public protocol PluginSessionStatusSink: AnyObject, Sendable {
    func updateStatus(
        pluginID: String,
        sessionID: String,
        tmuxPane: String?,
        working: Bool?,
        attention: Bool
    ) async
}

/// Receives Mac notifications (banner + iOS push fan-out) emitted by plugins.
public protocol PluginNotificationSink: AnyObject, Sendable {
    func deliverNotification(
        pluginID: String,
        sessionID: String?,
        tmuxPane: String?,
        title: String,
        body: String
    ) async
}

/// Receives iOS-bound response requests (and dismissals).
public protocol PluginResponseRequestSink: AnyObject, Sendable {
    func deliverRequest(
        pluginID: String,
        sessionID: String,
        tmuxPane: String?,
        requestID: String,
        request: AgentResponseRequest,
        isAutoApprovable: Bool
    ) async

    func dismissRequest(
        pluginID: String,
        sessionID: String,
        requestID: String
    ) async
}

/// Receives discrete app-side actions emitted by plugins (open-file
/// suggestions, dismiss-suggestion, close-pane-on-end, ...).
public protocol PluginAppActionSink: AnyObject, Sendable {
    func handle(pluginID: String, sessionID: String?, tmuxPane: String?, action: AppAction) async
}

/// Receives sidecar-driven pane writes (text + keys). The downstream sink
/// translates the simplified `PluginTmuxKey` set into the app's existing
/// `TmuxKey` enum used by `TmuxControlClient`.
public protocol PluginAgentDriverSink: AnyObject, Sendable {
    /// Called when the sidecar emits a `send_text` notification — write
    /// `text` to the pane backing `sessionID` (verbatim, no special key
    /// handling).
    func sendText(
        pluginID: String,
        sessionID: String,
        text: String
    ) async

    /// Called when the sidecar emits a `send_keys` notification — drive the
    /// pane backing `sessionID` with the supplied key sequence.
    func sendKeys(
        pluginID: String,
        sessionID: String,
        keys: [PluginTmuxKey]
    ) async
}

// MARK: - Yolo provider

/// Async lookup for whether a given pane has yolo mode enabled. Implemented
/// by the app-side pane-state store; the dispatcher consults it to decide
/// whether to auto-approve flagged permissions (Spec §17.1).
public protocol YoloModeProvider: AnyObject, Sendable {
    func isYolo(forSessionID sessionID: String) async -> Bool
}

// MARK: - PluginTmuxKey
//
// `PluginTmuxKey` lives in `GallagerPluginProtocol` so plugin-core packages
// can depend on it without pulling in the Mac runtime. `ClaudeSpyPluginRuntime`
// re-exports it via its `import GallagerPluginProtocol` at the top of this
// file; downstream code that already does `import ClaudeSpyPluginRuntime` keeps
// seeing the type.
