#if os(macOS)
    import ClaudeSpyNetworking
    import ClaudeSpyPluginRuntime
    import Foundation
    import GallagerPluginProtocol
    import Logging

    /// Implements `PluginAgentDriverSink` by translating sidecar-emitted
    /// `send_text` / `send_keys` notifications into `TmuxService` writes.
    ///
    /// The plugin protocol describes pane writes in terms of an agent session
    /// id; we look up the pane that hosts that session via
    /// `MirrorWindowManager.paneStates` (the same source of truth the
    /// `AppActionRouter` consults).
    @MainActor
    final public class TmuxAgentDriver: PluginAgentDriverSink {
        private let tmuxService: TmuxService
        private let mirrorManager: MirrorWindowManager
        private let logger = Logger(label: "com.claudespy.tmuxagentdriver")

        public init(tmuxService: TmuxService, mirrorManager: MirrorWindowManager) {
            self.tmuxService = tmuxService
            self.mirrorManager = mirrorManager
        }

        // MARK: - PluginAgentDriverSink

        public func sendText(pluginID: String, sessionID: String, text: String) async {
            guard let paneId = findPane(forSessionID: sessionID) else {
                logger.debug(
                    "sendText: no pane for session \(sessionID) (plugin \(pluginID))"
                )
                return
            }
            guard !text.isEmpty else { return }
            do {
                try await tmuxService.sendKeys(paneId, keys: text, literal: true)
            } catch {
                logger.warning(
                    "sendText failed for pane \(paneId): \(error)"
                )
            }
        }

        public func sendKeys(pluginID: String, sessionID: String, keys: [PluginTmuxKey]) async {
            guard let paneId = findPane(forSessionID: sessionID) else {
                logger.debug(
                    "sendKeys: no pane for session \(sessionID) (plugin \(pluginID))"
                )
                return
            }
            // Map each PluginTmuxKey to its tmux key name, then issue one
            // batched `send-keys` so we only spawn one tmux subprocess per
            // notification instead of one per key.
            let names = keys.map { Self.tmuxKeyName(for: $0) }
            do {
                try await tmuxService.sendBatchKeys(paneId, keys: names)
            } catch {
                logger.warning(
                    "sendKeys failed for pane \(paneId): \(error)"
                )
            }
        }

        // MARK: - Lookup

        private func findPane(forSessionID sessionID: String) -> String? {
            for (paneId, state) in mirrorManager.paneStates
                where state.agentSession?.id == sessionID {
                return paneId
            }
            return nil
        }

        // MARK: - PluginTmuxKey → tmux key name

        /// Translates a `PluginTmuxKey` (the simplified closed set in
        /// `GallagerPluginProtocol`) into the tmux key name the
        /// `send-keys` command accepts. Mirrors the existing `TmuxKey`
        /// enum's `tmuxKeyName` but stays self-contained so the protocol
        /// types don't have to depend on `ClaudeSpyNetworking`.
        private static func tmuxKeyName(for key: PluginTmuxKey) -> String {
            switch key {
            case .enter: "Enter"
            case .escape: "Escape"
            case .tab: "Tab"
            case .backspace: "BSpace"
            case .space: "Space"
            case .up: "Up"
            case .down: "Down"
            case .left: "Left"
            case .right: "Right"
            case .home: "Home"
            case .end: "End"
            case .pageUp: "PageUp"
            case .pageDown: "PageDown"
            case .f1: "F1"
            case .f2: "F2"
            case .f3: "F3"
            case .f4: "F4"
            case .f5: "F5"
            case .f6: "F6"
            case .f7: "F7"
            case .f8: "F8"
            case .f9: "F9"
            case .f10: "F10"
            case .f11: "F11"
            case .f12: "F12"
            case .ctrlC: "C-c"
            case .ctrlD: "C-d"
            case .ctrlZ: "C-z"
            }
        }
    }
#endif
