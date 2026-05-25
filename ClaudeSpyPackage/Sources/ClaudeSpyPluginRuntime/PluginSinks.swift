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
public protocol PluginSessionStatusSink: AnyObject, Sendable {
    func updateStatus(
        pluginID: String,
        sessionID: String,
        working: Bool?,
        attention: Bool
    ) async
}

/// Receives Mac notifications (banner + iOS push fan-out) emitted by plugins.
public protocol PluginNotificationSink: AnyObject, Sendable {
    func deliverNotification(
        pluginID: String,
        sessionID: String?,
        title: String,
        body: String
    ) async
}

/// Receives iOS-bound response requests (and dismissals).
public protocol PluginResponseRequestSink: AnyObject, Sendable {
    func deliverRequest(
        pluginID: String,
        sessionID: String,
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
    func handle(pluginID: String, action: AppAction) async
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

/// A simplified key descriptor the runtime exposes for sidecar-driven sends.
///
/// `ClaudeSpyServerFeature.TmuxKey` (the canonical one used by the tmux
/// driver) lives outside this package's dep graph. We mirror the small closed
/// set the sidecars actually emit here and let the app adapter (Task 15)
/// translate to the production key type.
///
/// The raw values match what sidecars emit on the wire as `send_keys` params.
public enum PluginTmuxKey: String, Codable, Sendable, Equatable {
    case enter
    case escape
    case tab
    case backspace
    case space

    case up
    case down
    case left
    case right

    case home
    case end
    case pageUp = "page_up"
    case pageDown = "page_down"

    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    case ctrlC = "ctrl_c"
    case ctrlD = "ctrl_d"
    case ctrlZ = "ctrl_z"
}
