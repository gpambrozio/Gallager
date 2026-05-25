import Foundation

// MARK: - PluginRPCMethod

/// String constants for every RPC method on the sidecar protocol.
///
/// Grouped by direction so the call sites can type-check that they're using
/// the right side of the channel. Raw values are the on-the-wire method
/// names (snake_case per Spec §6.1 / §6.2).
public enum PluginRPCMethod {
    /// Methods the Mac sends to a sidecar. Reference: Spec §6.1.
    public enum AppToSidecar: String, CaseIterable, Sendable {
        case initialize
        case shutdown
        case refreshProjects = "refresh_projects"
        case detectPane = "detect_pane"
        case install
        case uninstall
        case isInstalled = "is_installed"
        case translateEvent = "translate_event"
        case deliverResponse = "deliver_response"
        case getSettingsSchema = "get_settings_schema"
        case applySettings = "apply_settings"
        case commandForLaunch = "command_for_launch"
        case health
    }

    /// Methods a sidecar sends back to the Mac (callbacks).
    /// Reference: Spec §6.2.
    public enum SidecarToApp: String, CaseIterable, Sendable {
        case setProjects = "set_projects"
        case emitEvent = "emit_event"
        case sendText = "send_text"
        case sendKeys = "send_keys"
        case dismissResponseRequest = "dismiss_response_request"
        case requestNotification = "request_notification"
        case updateSessionStatus = "update_session_status"
        case log
        case promptUser = "prompt_user"
    }
}
