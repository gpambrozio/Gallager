/**
 * Gallager ↔ pi ingress bridge (a pi extension).
 *
 * This is a pi *extension* (auto-loaded from ~/.pi/agent/extensions/). pi exposes
 * a rich extension event bus, so this subscribes to the lifecycle events Gallager
 * cares about and forwards them to Gallager's Unix-domain *ingress socket*, where
 * the pi sidecar's `translate_event` maps them onto session state.
 *
 * Two channels, do not confuse them:
 *   - Ingress socket (state)      → 4-byte big-endian length prefix + JSON body,
 *                                    snake_case (plugin_id, context, payload).
 *   - OTLP receiver (telemetry)   → HTTP POST /v1/logs, OTLP/JSON. One record per
 *                                    completed assistant message (issue #617).
 *
 * The Gallager sidecar's `install` rewrites the three placeholder tokens below
 * with the real ingress socket path, plugin id, and OTLP endpoint (pi does not
 * inherit Gallager's env, so they must be baked in). Left un-substituted (e.g.
 * running from the repo for a smoke test) they fall back to GALLAGER_* env vars,
 * then to Gallager's default conventions.
 *
 * Marker: the string "GallagerPiMonitor" below is how the sidecar's
 * install_status detects an installed copy — keep it.
 */
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

// --- Baked-in identity (install substitutes these exact tokens) ---------------
const RAW_SOCK = "__GALLAGER_INGRESS_SOCK__";
const RAW_ID = "__GALLAGER_PLUGIN_ID__";
const RAW_OTLP = "__GALLAGER_OTLP_ENDPOINT__";

const SOCKET_PATH = RAW_SOCK.startsWith("__GALLAGER")
  ? process.env.GALLAGER_INGRESS_SOCK || path.join(os.homedir(), ".gallager", "state", "ingress.sock")
  : RAW_SOCK;
const PLUGIN_ID = RAW_ID.startsWith("__GALLAGER") ? process.env.GALLAGER_PLUGIN_ID || "pi" : RAW_ID;
// Gallager's loopback OTLP receiver (issue #617). Empty → telemetry disabled (the
// receiver failed to bind, or this copy predates OTLP support).
const OTLP_ENDPOINT = RAW_OTLP.startsWith("__GALLAGER")
  ? process.env.GALLAGER_OTLP_ENDPOINT || ""
  : RAW_OTLP;

// Optional: GALLAGER_PI_DEBUG=1 records every forwarded event to a log next to
// the sidecar's stderr.log — handy for confirming pi's event flow.
const DEBUG = !!process.env.GALLAGER_PI_DEBUG;
const DEBUG_LOG =
  process.env.GALLAGER_PI_DEBUG_LOG ||
  path.join(os.homedir(), ".gallager", "state", "plugins", PLUGIN_ID, "logs", "bridge-debug.log");

function debug(line) {
  if (!DEBUG) return;
  try {
    fs.mkdirSync(path.dirname(DEBUG_LOG), { recursive: true });
    fs.appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${line}\n`);
  } catch {
    /* never break pi over a debug write */
  }
}

/**
 * Write one length-prefixed frame to Gallager's ingress socket.
 *
 * Returns a Promise that resolves once the frame has flushed (socket closed) or
 * the attempt gave up (Gallager not running / timeout) — never rejects. Most
 * callers fire-and-forget; `session_shutdown` awaits it so pi's shutdown waits
 * for the final "shutdown" frame to land before the process exits.
 */
function forward(type, properties, context) {
  return new Promise((resolve) => {
    if (!context.TMUX_PANE) return resolve(); // no pane → nothing to route
    let sock;
    let settled = false;
    const done = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    try {
      const payload = { type, properties };
      const body = Buffer.from(JSON.stringify({ plugin_id: PLUGIN_ID, context, payload }), "utf8");
      const prefix = Buffer.allocUnsafe(4);
      prefix.writeUInt32BE(body.length, 0);

      sock = net.createConnection({ path: SOCKET_PATH });
      sock.on("connect", () => {
        sock.write(Buffer.concat([prefix, body]), () => {
          try {
            sock.end();
          } catch {}
        });
      });
      sock.on("close", done); // frame flushed + server hung up
      sock.on("error", () => {
        try {
          sock.destroy();
        } catch {}
        done();
      });
      sock.setTimeout(5000, () => {
        try {
          sock.destroy();
        } catch {}
        done();
      });
    } catch {
      try {
        sock && sock.destroy();
      } catch {}
      done();
    }
  });
}

// --- OTLP telemetry (issue #617) ----------------------------------------------
// Every completed pi assistant message carries usage (tokens, cost, model). Emit
// ONE OTLP/JSON log record per message, straight to Gallager's loopback receiver
// (`POST /v1/logs`, plain fetch — no SDK). Attribute keys mirror Claude Code's
// `api_request` vocabulary exactly, so the host aggregates them additively (the
// manifest's `otlp` block maps the `pi.` namespace onto the meter). `session.id`
// is pi's OWN session UUID — the same id we stamp on the ingress frames, so the
// host's telemetry join key (re-stamped from every reported PluginEvent) matches.
const OTLP_EMITTED = new Set(); // dedupe by responseId (belt-and-suspenders)
const OTLP_EMITTED_CAP = 512;

function int(v) {
  return typeof v === "number" && isFinite(v) ? Math.max(0, Math.round(v)) : 0;
}

function emitTelemetry(message, sessionID, context, durationMs) {
  if (!OTLP_ENDPOINT || !context.TMUX_PANE) return;
  if (!message || message.role !== "assistant") return;
  const usage = message.usage;
  if (!usage) return;

  const dedupeKey = message.responseId || `${sessionID}:${message.timestamp}`;
  if (OTLP_EMITTED.has(dedupeKey)) return;
  OTLP_EMITTED.add(dedupeKey);
  if (OTLP_EMITTED.size > OTLP_EMITTED_CAP) {
    OTLP_EMITTED.delete(OTLP_EMITTED.values().next().value);
  }

  const cost = usage.cost || {};
  const attributes = [
    { key: "event.name", value: { stringValue: "pi.api_request" } },
    { key: "session.id", value: { stringValue: sessionID } },
    // pi reports a reasoning-token breakdown separately; fold it into output to
    // match Claude's api_request, where thinking tokens count as output.
    { key: "input_tokens", value: { intValue: int(usage.input) } },
    { key: "output_tokens", value: { intValue: int(usage.output) + int(usage.reasoning) } },
    { key: "cache_read_tokens", value: { intValue: int(usage.cacheRead) } },
    { key: "cache_creation_tokens", value: { intValue: int(usage.cacheWrite) } },
    {
      key: "cost_usd",
      value: { doubleValue: typeof cost.total === "number" && isFinite(cost.total) ? cost.total : 0 },
    },
  ];
  if (typeof durationMs === "number" && isFinite(durationMs) && durationMs >= 0) {
    attributes.push({ key: "duration_ms", value: { intValue: int(durationMs) } });
  }
  if (message.model) {
    attributes.push({ key: "model", value: { stringValue: String(message.model) } });
  }

  const requestBody = {
    resourceLogs: [{ scopeLogs: [{ logRecords: [{ eventName: "pi.api_request", attributes }] }] }],
  };
  debug(`otlp api_request session=${sessionID} model=${message.model} in=${int(usage.input)} out=${int(usage.output)}`);
  // Fire-and-forget: telemetry must never break pi. Loopback-local receiver, so a
  // failure means Gallager is gone — drop silently.
  try {
    fetch(`${OTLP_ENDPOINT}/v1/logs`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(requestBody),
    }).catch(() => {});
  } catch {
    /* fetch unavailable or sync throw — never break pi */
  }
}

// Extract a short, single-line summary from the final assistant message of a turn
// (for the doneWorking summary + the notification body). Best-effort.
function lastAssistantSummary(messages) {
  if (!Array.isArray(messages)) return "";
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (!m || m.role !== "assistant" || !Array.isArray(m.content)) continue;
    const text = m.content
      .filter((c) => c && c.type === "text" && typeof c.text === "string")
      .map((c) => c.text)
      .join(" ")
      .replace(/\s+/g, " ")
      .trim();
    if (text) return text.length > 200 ? `${text.slice(0, 197)}…` : text;
    return "";
  }
  return "";
}

/**
 * The extension entry point pi calls with the ExtensionAPI.
 *
 * `GallagerPiMonitor` is also the install marker the sidecar looks for.
 */
export function GallagerPiMonitor(pi) {
  // TMUX_PANE is how Gallager routes events to the right pane; captured once (pi
  // runs one process per pane).
  const tmuxPane = process.env.TMUX_PANE || "";

  // Per-session assistant-stream start times, so we can report duration_ms. One
  // in-flight assistant message per session at a time (interactive TUI).
  const streamStart = new Map();

  function context(ctx) {
    const c = { TMUX_PANE: tmuxPane };
    const cwd = (ctx && ctx.cwd) || process.cwd();
    if (cwd) c.PI_PROJECT_DIR = cwd;
    return c;
  }

  function sessionId(ctx) {
    try {
      return (ctx && ctx.sessionManager && ctx.sessionManager.getSessionId()) || tmuxPane || "unknown";
    } catch {
      return tmuxPane || "unknown";
    }
  }

  debug(`bridge loaded sock=${SOCKET_PATH} id=${PLUGIN_ID} pane=${tmuxPane} otlp=${OTLP_ENDPOINT || "off"}`);

  // Session appears (idle). pi fires this on launch, /reload, and session switch.
  pi.on("session_start", async (event, ctx) => {
    forward("pi.session.start", { sessionID: sessionId(ctx), reason: event.reason }, context(ctx));
  });

  // Agent loop started → working.
  pi.on("agent_start", async (_event, ctx) => {
    forward("pi.agent.start", { sessionID: sessionId(ctx) }, context(ctx));
  });

  // Agent loop ended → doneWorking (attention) + notification.
  pi.on("agent_end", async (event, ctx) => {
    const summary = lastAssistantSummary(event.messages);
    forward("pi.agent.end", { sessionID: sessionId(ctx), summary }, context(ctx));
  });

  // Session teardown. Only reason "quit" ends the pane's session; the sidecar
  // ignores reload/new/resume/fork. Awaited so the frame flushes before pi exits.
  pi.on("session_shutdown", async (event, ctx) => {
    try {
      await forward("pi.session.shutdown", { sessionID: sessionId(ctx), reason: event.reason }, context(ctx));
    } catch {
      /* never throw out of shutdown */
    }
  });

  // Telemetry: mark the start of an assistant stream (for duration), then emit
  // one OTLP record when it ends with usage.
  pi.on("message_start", async (event, ctx) => {
    const m = event.message;
    if (m && m.role === "assistant") streamStart.set(sessionId(ctx), Date.now());
  });

  pi.on("message_end", async (event, ctx) => {
    const m = event.message;
    if (!m || m.role !== "assistant") return;
    const sid = sessionId(ctx);
    const startedAt = streamStart.get(sid);
    streamStart.delete(sid);
    const durationMs = typeof startedAt === "number" ? Date.now() - startedAt : undefined;
    emitTelemetry(m, sid, context(ctx), durationMs);
  });
}

export default GallagerPiMonitor;
