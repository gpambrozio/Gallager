import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Logging

// MARK: - Helpers

private let logger = Logger(label: "echo-sidecar")

/// Write a framed JSON-RPC message to stdout.
private func send(_ message: RPCMessage) {
    guard let data = try? JSONEncoder().encode(message) else { return }
    let frame = StdioFramer.encode(data)
    FileHandle.standardOutput.write(frame)
}

/// Emit an RPC notification to the host.
private func notify(_ method: String, _ params: JSONValue?) {
    send(.notification(method: method, params: params))
}

// MARK: - Request handlers

/// Handle `initialize` → empty result.
private func handleInitialize(id: String) {
    send(.response(id: id, result: .object([:])))
}

/// Handle `translate_event` → decode `EchoDirective` from `IngressFrameWire`,
/// honor `abort`, build and return a `PluginEvent`.
private func handleTranslateEvent(id: String, params: JSONValue?) {
    guard let params else {
        send(.failure(id: id, error: .init(code: "invalid_params", message: "params required")))
        return
    }
    do {
        let wire = try params.decode(IngressFrameWire.self)
        let directive = try wire.payload.decode(EchoDirective.self)

        // Crash-test hook: if the directive asks us to abort, do so.
        if directive.abort == true {
            Foundation.abort()
        }

        // Derive tmuxPane: directive overrides context, context fallback via TMUX_PANE.
        let tmuxPane = directive.tmuxPane ?? wire.context["TMUX_PANE"]

        let event = PluginEvent(
            pluginID: wire.pluginID,
            sessionID: directive.sessionID,
            state: directive.state,
            notification: directive.notification,
            appActions: directive.appActions ?? [],
            tmuxPane: tmuxPane,
            projectPath: directive.projectPath
        )
        let resultValue = try JSONValue(encoding: event)
        send(.response(id: id, result: resultValue))
    } catch {
        logger.error("translate_event error: \(error)")
        send(.failure(id: id, error: .init(code: "decode_error", message: "\(error)")))
    }
}

/// Params shape for `deliver_response`.
private struct DeliverResponseParams: Decodable {
    let sessionID: String
    let requestID: String
    let response: AgentResponse
}

/// Handle `deliver_response` → send `send_text` / `send_keys` notifications
/// mirroring the in-process `EchoPluginCore.deliverResponse` semantics.
private func handleDeliverResponse(id: String, params: JSONValue?) {
    defer { send(.response(id: id, result: .object([:]))) }
    guard let params, let p = try? params.decode(DeliverResponseParams.self) else { return }
    let sessionID = p.sessionID

    func sendText(_ text: String) {
        notify(HostRPC.sendText, .object(["sessionID": .string(sessionID), "text": .string(text)]))
    }
    func sendKeys(_ keys: [PluginTmuxKey]) {
        guard let keysValue = try? JSONValue(encoding: keys) else { return }
        notify(HostRPC.sendKeys, .object(["sessionID": .string(sessionID), "keys": keysValue]))
    }

    switch p.response {
    case let .prompt(text),
         let .replyAfterStop(text):
        sendText(text)
    case let .permission(decision, _):
        switch decision {
        case .allow: sendKeys([.text("1")])
        case .deny: sendKeys([.escape])
        case let .denyWithFeedback(text): sendText(text)
        }
    case let .askUserQuestion(answers):
        sendText(answers.map(\.questionID).joined(separator: ","))
    case let .approvePlan(decision, editedPlan):
        switch decision {
        case .approve:
            if let editedPlan {
                sendText(editedPlan)
            } else {
                sendKeys([.text("3")])
            }
        case .reject:
            sendKeys([.escape])
        }
    }
}

/// Handle `refresh_projects` → send `set_projects` notification, then respond.
private func handleRefreshProjects(id: String) {
    let project = AgentProject(name: "echo-project", path: "/tmp/echo-project", pluginID: "echo-sidecar")
    if let projectsValue = try? JSONValue(encoding: [project]) {
        notify(HostRPC.setProjects, .object(["projects": projectsValue]))
    }
    send(.response(id: id, result: .object([:])))
}

/// Handle `install` → template GALLAGER_INGRESS_SOCK + GALLAGER_PLUGIN_ID into a hook script.
///
/// Reads both env vars injected by the supervisor (spec §3/§5) and writes a self-contained
/// `<plugin_root>/generated/hook.sh` that bakes in the socket path and plugin id so the
/// script needs no env at runtime. Responds with `InstallResult.installed(message:)`.
private func handleInstall(id: String) {
    let env = ProcessInfo.processInfo.environment
    let sock = env["GALLAGER_INGRESS_SOCK"] ?? ""
    let pluginID = env["GALLAGER_PLUGIN_ID"] ?? "echo-sidecar"
    let pluginRoot = env["GALLAGER_PLUGIN_ROOT"] ?? ""

    // Create <plugin_root>/generated/ and write the hook script.
    let generatedDir = URL(fileURLWithPath: pluginRoot)
        .appendingPathComponent("generated")
    let hookURL = generatedDir.appendingPathComponent("hook.sh")
    do {
        try FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        # Auto-generated by EchoPluginSidecar install — do not edit.
        # Baked-in values (no env required at runtime):
        SOCK=\(sock)
        PLUGIN_ID=\(pluginID)

        # Write a {plugin_id, context, payload} frame to the ingress socket.
        CONTEXT="${TMUX_PANE:-}"
        PAYLOAD="${1:-{}}"
        FRAME=$(printf '{"plugin_id":"%s","context":{"TMUX_PANE":"%s"},"payload":%s}' \\
            "$PLUGIN_ID" "$CONTEXT" "$PAYLOAD")
        LEN=${#FRAME}
        printf "Content-Length: %d\\r\\n\\r\\n%s" "$LEN" "$FRAME" | nc -U "$SOCK"
        """
        try script.write(to: hookURL, atomically: true, encoding: .utf8)
        // Make it executable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: hookURL.path
        )
        let result = InstallResult.installed(message: "hook.sh written to \(hookURL.path)")
        if let value = try? JSONValue(encoding: result) {
            send(.response(id: id, result: value))
        } else {
            send(.response(id: id, result: .object([:])))
        }
    } catch {
        logger.error("install error: \(error)")
        send(.failure(id: id, error: .init(code: "install_error", message: "\(error)")))
    }
}

/// Handle `install_status` → respond with `.installed(version:"echo")`.
private func handleInstallStatus(id: String) {
    let status = PluginInstallStatus.installed(version: "echo")
    if let value = try? JSONValue(encoding: status) {
        send(.response(id: id, result: value))
    } else {
        send(.response(id: id, result: .object([:])))
    }
}

/// Handle `shutdown` → respond then exit.
private func handleShutdown(id: String) {
    send(.response(id: id, result: .object([:])))
    // Flush stdout before exiting.
    FileHandle.standardOutput.synchronizeFile()
    exit(0)
}

// MARK: - Main read loop

var decoder = FrameDecoder()

while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty {
        // EOF on stdin — host closed the pipe.
        break
    }
    let bodies: [Data]
    do {
        bodies = try decoder.push(chunk)
    } catch {
        logger.error("framing error: \(error)")
        break
    }

    for body in bodies {
        guard let message = try? JSONDecoder().decode(RPCMessage.self, from: body) else {
            logger.warning("failed to decode RPCMessage from body")
            continue
        }
        // Only handle inbound requests (have id + method).
        guard message.isRequest, let id = message.id, let method = message.method else {
            continue
        }

        switch method {
        case SidecarRPC.initialize:
            handleInitialize(id: id)
        case SidecarRPC.translateEvent:
            handleTranslateEvent(id: id, params: message.params)
        case SidecarRPC.deliverResponse:
            handleDeliverResponse(id: id, params: message.params)
        case SidecarRPC.refreshProjects:
            handleRefreshProjects(id: id)
        case SidecarRPC.install:
            handleInstall(id: id)
        case SidecarRPC.uninstall,
             SidecarRPC.applySettings,
             SidecarRPC.commandForLaunch:
            send(.response(id: id, result: .object([:])))
        case SidecarRPC.installStatus:
            handleInstallStatus(id: id)
        case SidecarRPC.shutdown:
            handleShutdown(id: id)
        default:
            send(.failure(id: id, error: .methodNotFound(method)))
        }
    }
}
