#!/usr/bin/env python3
"""
Gallager sidecar plugin — starter template.

A sidecar is a long-lived child process Gallager spawns once and talks to over
stdin/stdout using JSON-RPC with LSP-style `Content-Length` framing. Your job is
to translate your coding agent's hook events into the agent-blind `PluginEvent`
shape Gallager understands, and (optionally) push text/keys back into the pane.

The ONLY method you must get right to see something happen is `translate_event`.
Everything else has a safe default below. Search for "EDIT HERE".

Run requirements: Python 3.9+. No third-party packages.

IMPORTANT: stdout is the RPC channel. Never `print()` to stdout — it corrupts the
frame stream. Use `log(...)` (structured, shows in Settings → View Logs) or write
to stderr (captured at ~/.gallager/state/plugins/<id>/logs/stderr.log).
"""
import json
import sys

# ---------------------------------------------------------------------------
# Identity — keep in sync with plugin.json. `command_for_launch` returns this so
# Gallager can start your agent in a fresh pane. Set to None to disable launch.
# ---------------------------------------------------------------------------
AGENT_LAUNCH_COMMAND = None  # e.g. {"command": "my-agent", "args": [], "env": {}}


# ---------------------------------------------------------------------------
# Framing — read/write one Content-Length-framed JSON message.
# ---------------------------------------------------------------------------
def read_message():
    """Block until one full message arrives. Returns the decoded dict, or None on EOF."""
    header = b""
    while b"\r\n\r\n" not in header:
        ch = sys.stdin.buffer.read(1)
        if not ch:
            return None  # stdin closed → Gallager is gone, exit the loop
        header += ch
    length = 0
    for line in header.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    body = sys.stdin.buffer.read(length)
    return json.loads(body)


def write_message(msg):
    body = json.dumps(msg).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
    sys.stdout.buffer.flush()


def respond(req_id, result):
    """Answer a request. `result` may be any JSON value (use {} when you have nothing)."""
    write_message({"id": req_id, "result": result})


def fail(req_id, code, message):
    write_message({"id": req_id, "error": {"code": code, "message": message}})


def notify(method, params):
    """Send a fire-and-forget notification to Gallager (no `id` → no response)."""
    write_message({"method": method, "params": params})


def log(level, message):
    """Structured log line. level ∈ {"debug","info","warn","error"}. Shows in Settings → View Logs."""
    notify("log", {"level": level, "message": message})


# ---------------------------------------------------------------------------
# AgentState builders — what goes in a PluginEvent's `state` field.
# Encoding is a single-key tagged object (Swift enum form). `state: None` means
# "no opinion, leave the session's state unchanged" (still useful for a
# notification-only event).
# ---------------------------------------------------------------------------
def state_working():
    """Agent is actively processing. Sidebar spins; no attention badge."""
    return {"working": {}}


def state_done(summary=None):
    """Agent finished a turn (clean or error). Raises the attention badge.
    `summary` is the last assistant message or error string, or None."""
    return {"doneWorking": {"summary": summary}}


def state_idle():
    """Fresh/handled session. No attention badge."""
    return {"idle": {}}


# ---------------------------------------------------------------------------
# RPC handlers
# ---------------------------------------------------------------------------
def handle_translate_event(req_id, params):
    """
    THE CORE METHOD. Gallager calls this once per hook event your agent fires.

    `params` (camelCase!) is:
        {
          "pluginID": "<your id>",
          "context":  { "TMUX_PANE": "%4", "<AGENT>_PROJECT_DIR": "/path", ... },
          "payload":  <your agent's raw hook event, already parsed to JSON>
        }

    Return a PluginEvent (respond with the object), or respond with `None` to
    say "ignore this event".

    PluginEvent fields (camelCase, all optional except pluginID/sessionID):
        pluginID, sessionID, state, notification {title, body},
        tmuxPane, projectPath, permissionMode
    """
    context = params.get("context") or {}
    payload = params.get("payload") or {}

    tmux_pane = context.get("TMUX_PANE")

    # ===================== EDIT HERE =====================
    # Map YOUR agent's hook payload onto a session id and a state. The branches
    # below are illustrative — replace the field names and event values with
    # whatever your agent actually puts in its hook JSON.

    session_id = payload.get("session_id") or tmux_pane or "unknown"
    project_path = context.get("CLAUDE_PROJECT_DIR") or payload.get("cwd")

    hook_event = payload.get("hook_event_name") or payload.get("event")
    if hook_event in ("Stop", "SubagentStop", "turn_end", "done"):
        state = state_done(summary=payload.get("summary"))
    elif hook_event in ("Notification", "PreToolUse", "PostToolUse", "turn_start"):
        state = state_working()
    else:
        state = None  # unknown event → emit nothing of interest, just ignore
        respond(req_id, None)
        return
    # =====================================================

    event = {
        "pluginID": params.get("pluginID"),
        "sessionID": session_id,
        "state": state,
        "tmuxPane": tmux_pane,
        "projectPath": project_path,
    }
    respond(req_id, event)


def handle_initialize(req_id, params):
    """Sent once at startup (and again after any crash-restart). `params` is the
    PluginEnvWire: {pluginRoot, stateDir, appVersion, settings, marketplaceSource,
    otlpReceiverEndpoint}. Treat every initialize as a clean-slate boot."""
    # Stash anything you need from params (e.g. stateDir for scratch files).
    log("info", "sidecar initialized (app %s)" % (params or {}).get("appVersion", "?"))
    respond(req_id, {})


def handle_command_for_launch(req_id, params):
    """Return {command, args, env} to auto-start your agent in a new pane, or None."""
    respond(req_id, AGENT_LAUNCH_COMMAND)


def handle_install_status(req_id, params):
    """Report whether your agent's hooks are wired up. Tagged-object form:
    {"installed": {"version": "1.0.0"}} | {"notInstalled": {}} | {"agentUnavailable": {}}."""
    # EDIT HERE: check whether your hook bridge is present in the agent's config.
    respond(req_id, {"notInstalled": {}})


def handle_install(req_id, params):
    """Wire your agent's hooks to call the ingress bridge (see hook.py). `params`
    is {"configRoot": "/path" | null}. Return InstallResult:
    {"installed": {"message": "..."}} | {"alreadyInstalled": {}}."""
    # EDIT HERE: copy/template hook.py into the agent's config and register it.
    respond(req_id, {"installed": {"message": "Hooks installed."}})


def handle_uninstall(req_id, params):
    """Remove what install() added. `params` is {"configRoot": ...}. Respond {}."""
    respond(req_id, {})


def handle_apply_settings(req_id, params):
    """`params` is {"settings": <json>}. Persist if you like. Return SettingsResult:
    {"applied": {}} | {"error": {"field": null, "message": "..."}}."""
    respond(req_id, {"applied": {}})


# App → sidecar requests. Each MUST be answered (echo the id). Unknown → error.
REQUEST_HANDLERS = {
    "initialize": handle_initialize,
    "translate_event": handle_translate_event,
    "command_for_launch": handle_command_for_launch,
    "install_status": handle_install_status,
    "install": handle_install,
    "uninstall": handle_uninstall,
    "apply_settings": handle_apply_settings,
    "refresh_projects": lambda req_id, params: respond(req_id, {}),
}


def main():
    while True:
        try:
            msg = read_message()
        except Exception as exc:  # malformed frame — log and keep going
            sys.stderr.write("read error: %s\n" % exc)
            continue
        if msg is None:
            break  # EOF

        method = msg.get("method")
        req_id = msg.get("id")

        # A response/notification we don't expect — ignore (we only send requests
        # like agent_panes if you add them; their responses would land here).
        if method is None:
            continue

        if method == "shutdown":
            respond(req_id, {})
            break

        handler = REQUEST_HANDLERS.get(method)
        if handler is not None:
            try:
                handler(req_id, msg.get("params"))
            except Exception as exc:
                sys.stderr.write("handler error in %s: %s\n" % (method, exc))
                if req_id is not None:
                    fail(req_id, "internal_error", str(exc))
        elif req_id is not None:
            # Unknown request → method_not_found (mirrors Gallager's own behavior).
            fail(req_id, "method_not_found", "Unknown method: %s" % method)
        # Unknown notification (no id) → silently ignore.


if __name__ == "__main__":
    main()
