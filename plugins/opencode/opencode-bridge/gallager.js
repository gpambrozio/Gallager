/**
 * Gallager ↔ opencode ingress bridge.
 *
 * This is an opencode *plugin* (auto-loaded from ~/.config/opencode/plugin/).
 * opencode removed config-based shell hooks (the old `experimental.hook`), so
 * the only robust way to observe session lifecycle is a plugin that subscribes
 * to the event bus and forwards the events Gallager cares about to Gallager's
 * Unix-domain *ingress socket*.
 *
 * Channel note: the ingress socket uses a 4-byte big-endian length prefix +
 * JSON body (NOT the sidecar's Content-Length framing). The frame's JSON is
 * snake_case (`plugin_id`, `context`, `payload`) — that's the ingress contract.
 *
 * The Gallager sidecar's `install` rewrites the two placeholder tokens below
 * with the real ingress socket path and plugin id (the opencode process does
 * not inherit Gallager's env, so they must be baked in). When the tokens are
 * left un-substituted (e.g. running this file straight from the repo for a
 * smoke test) it falls back to GALLAGER_INGRESS_SOCK / GALLAGER_PLUGIN_ID env
 * vars, then to Gallager's default conventions.
 */
import net from "node:net"
import os from "node:os"
import path from "node:path"
import fs from "node:fs"

// --- Baked-in identity (install substitutes these exact tokens) ---------------
const RAW_SOCK = "__GALLAGER_INGRESS_SOCK__"
const RAW_ID = "__GALLAGER_PLUGIN_ID__"
const RAW_OTLP = "__GALLAGER_OTLP_ENDPOINT__"

const SOCKET_PATH = RAW_SOCK.startsWith("__GALLAGER")
  ? process.env.GALLAGER_INGRESS_SOCK || path.join(os.homedir(), ".gallager", "state", "ingress.sock")
  : RAW_SOCK
const PLUGIN_ID = RAW_ID.startsWith("__GALLAGER")
  ? process.env.GALLAGER_PLUGIN_ID || "opencode"
  : RAW_ID
// Gallager's loopback OTLP receiver (issue #617). Baked in at install like the
// socket path (the port is whatever the receiver actually bound that launch);
// the env fallback serves repo smoke tests. Empty → telemetry disabled (the
// receiver failed to bind, or the bridge predates OTLP support).
const OTLP_ENDPOINT = RAW_OTLP.startsWith("__GALLAGER")
  ? process.env.GALLAGER_OTLP_ENDPOINT || ""
  : RAW_OTLP

// Optional: set GALLAGER_OPENCODE_DEBUG=1 to record every event type this bridge
// sees (and which it forwards) — handy for confirming opencode's event names on a
// new version. Lands next to the sidecar's stderr.log so `gallager plugin logs
// opencode` neighbours find it.
const DEBUG = !!process.env.GALLAGER_OPENCODE_DEBUG
const DEBUG_LOG =
  process.env.GALLAGER_OPENCODE_DEBUG_LOG ||
  path.join(os.homedir(), ".gallager", "state", "plugins", PLUGIN_ID, "logs", "bridge-debug.log")

// The lifecycle events Gallager maps. Forward a *broad* allowlist that covers
// both the current server names (`permission.asked`) and the names still
// declared in the published SDK types (`permission.updated`) so we stay correct
// across opencode versions; the sidecar parses whichever actually arrives.
const FORWARD = new Set([
  "session.status",
  "session.idle",
  "session.error",
  "permission.asked",
  "permission.updated",
  "permission.replied",
  "permission.v2.asked",
  "permission.v2.replied",
  "question.asked",
  "question.replied",
  "question.rejected",
  "question.v2.asked",
  "question.v2.replied",
  "question.v2.rejected",
])

function debug(line) {
  if (!DEBUG) return
  try {
    fs.mkdirSync(path.dirname(DEBUG_LOG), { recursive: true })
    fs.appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${line}\n`)
  } catch {
    /* never break opencode over a debug write */
  }
}

/**
 * Write one length-prefixed frame to Gallager's ingress socket.
 *
 * Returns a Promise that resolves once the frame has flushed (socket closed) or
 * the attempt gave up (Gallager not running / timeout) — never rejects. Event-bus
 * callers fire-and-forget (ignore the Promise); the `dispose` hook awaits it so
 * opencode's shutdown waits for the final "stopped" frame to land before exiting.
 */
function forward(event, context) {
  return new Promise((resolve) => {
    if (!context.TMUX_PANE) return resolve() // no pane → nothing to route
    let sock
    let settled = false
    const done = () => {
      if (settled) return
      settled = true
      resolve()
    }
    try {
      const body = Buffer.from(
        JSON.stringify({ plugin_id: PLUGIN_ID, context, payload: event }),
        "utf8",
      )
      const prefix = Buffer.allocUnsafe(4)
      prefix.writeUInt32BE(body.length, 0)

      sock = net.createConnection({ path: SOCKET_PATH })
      sock.on("connect", () => {
        sock.write(Buffer.concat([prefix, body]), () => {
          try {
            sock.end()
          } catch {}
        })
      })
      sock.on("close", done) // frame flushed + server hung up
      sock.on("error", () => {
        // Gallager not running / socket gone — drop silently.
        try {
          sock.destroy()
        } catch {}
        done()
      })
      sock.setTimeout(5000, () => {
        try {
          sock.destroy()
        } catch {}
        done()
      })
    } catch {
      try {
        sock && sock.destroy()
      } catch {}
      done()
    }
  })
}

// --- OTLP telemetry (issue #617) ----------------------------------------------
// opencode has no usable native OTEL export, but this bridge already sees every
// `message.updated` on the event bus — and a completed AssistantMessage carries
// everything Gallager's meter surfaces (tokens, cost, model, latency). Emit ONE
// OTLP/JSON log record per completed assistant message, straight to Gallager's
// loopback receiver (`POST /v1/logs`, plain fetch — no SDK, no third-party
// plugin, no user-set OPENCODE_* env vars). This never goes through the ingress
// socket: telemetry is the OTLP channel, and message.updated fires on every
// streaming metadata change — far too chatty to forward.
//
// The attribute keys mirror Claude Code's `api_request` vocabulary exactly, so
// the host aggregates them with the same additive per-message semantics (the
// manifest's `otlp` declaration maps the `opencode.` namespace onto it).
// `session.id` is opencode's OWN session id (`info.sessionID`, "ses_…"): the
// host stamps a pane's telemetry join key from the sessionID the sidecar
// reports in its PluginEvents, and for every real opencode event that IS the
// opencode session id — the pane id is only reported by the synthetic launch
// frame, before any turn. Stamping the pane id here would therefore join only
// until the first turn's `session.status busy` re-stamps the key, and never
// again. Bonus: the meter follows the ACTIVE opencode session in the pane, and
// switching sessions resets the visible meter exactly like Claude's `/clear`
// (the receiver keeps each session's running totals, so switching back
// restores them on the next completed message).

// Assistant-message ids already exported, so a post-completion re-emit of
// `message.updated` can't double-count a turn. Bounded FIFO (Sets iterate in
// insertion order).
const OTLP_EMITTED = new Set()
const OTLP_EMITTED_CAP = 512

function emitTelemetry(info, context) {
  if (!OTLP_ENDPOINT || !context.TMUX_PANE) return
  if (!info || info.role !== "assistant") return
  // `time.completed` ONLY (live-verified as the final-tally signal). Emission
  // is deduped by message id, so a broader trigger (e.g. `finish`) that could
  // fire before the final token/cost tally would freeze this message's
  // contribution at the early values forever.
  const completed = info.time && info.time.completed
  if (!completed || !info.id || OTLP_EMITTED.has(info.id)) return
  // opencode's session id — the join key (see the header comment). The pane-id
  // fallback covers a hypothetical message without one; such records only join
  // before the first turn.
  const sessionID = info.sessionID || context.TMUX_PANE
  OTLP_EMITTED.add(info.id)
  if (OTLP_EMITTED.size > OTLP_EMITTED_CAP) {
    OTLP_EMITTED.delete(OTLP_EMITTED.values().next().value)
  }

  const tokens = info.tokens || {}
  const cache = tokens.cache || {}
  const int = (v) => (typeof v === "number" && isFinite(v) ? Math.max(0, Math.round(v)) : 0)
  const attributes = [
    { key: "event.name", value: { stringValue: "opencode.api_request" } },
    { key: "session.id", value: { stringValue: sessionID } },
    // opencode's reasoning tokens are folded into output — matching Claude's
    // api_request, where thinking tokens are billed/reported as output tokens.
    { key: "input_tokens", value: { intValue: int(tokens.input) } },
    { key: "output_tokens", value: { intValue: int(tokens.output) + int(tokens.reasoning) } },
    { key: "cache_read_tokens", value: { intValue: int(cache.read) } },
    { key: "cache_creation_tokens", value: { intValue: int(cache.write) } },
    // opencode computes cost itself (a plain number on the message).
    { key: "cost_usd", value: { doubleValue: typeof info.cost === "number" && isFinite(info.cost) ? info.cost : 0 } },
  ]
  if (info.time && typeof info.time.created === "number" && typeof info.time.completed === "number") {
    attributes.push({ key: "duration_ms", value: { intValue: int(info.time.completed - info.time.created) } })
  }
  if (info.modelID) {
    attributes.push({ key: "model", value: { stringValue: String(info.modelID) } })
  }

  const body = {
    resourceLogs: [{ scopeLogs: [{ logRecords: [{ eventName: "opencode.api_request", attributes }] }] }],
  }
  debug(`otlp api_request message=${info.id} session=${sessionID} pane=${context.TMUX_PANE}`)
  // Fire-and-forget: telemetry must never break opencode. The receiver is
  // loopback-local, so a failure means Gallager is gone — drop silently.
  try {
    fetch(`${OTLP_ENDPOINT}/v1/logs`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).catch(() => {})
  } catch {
    /* fetch unavailable or sync throw — never break opencode */
  }
}

// Synthetic lifecycle frames Gallager understands (handled by the sidecar's
// translate_event): one when opencode loads this bridge (≈ TUI start → the
// session appears as idle), one when opencode disposes it (≈ TUI quit → the
// session is removed). opencode itself emits no event on a fresh idle launch or
// on exit, so these are the bridge's own signal.
const LIFECYCLE_STARTED = { id: "gallager-started", type: "gallager.lifecycle.started", properties: {} }
const LIFECYCLE_STOPPED = { id: "gallager-stopped", type: "gallager.lifecycle.stopped", properties: {} }

export const GallagerMonitor = async ({ serverUrl, directory, worktree, project }) => {
  // Captured once per opencode process. TMUX_PANE is how Gallager routes the
  // event to the right pane; serverUrl lets the sidecar answer permission
  // prompts via opencode's HTTP API; the directory seeds the project name.
  const tmuxPane = process.env.TMUX_PANE || ""
  const serverURLString = serverUrl ? String(serverUrl.origin || serverUrl) : ""
  const projectDir = directory || worktree || project?.worktree || ""

  const context = { TMUX_PANE: tmuxPane }
  if (serverURLString) context.OPENCODE_SERVER_URL = serverURLString
  if (projectDir) context.OPENCODE_PROJECT_DIR = projectDir

  debug(`bridge loaded sock=${SOCKET_PATH} id=${PLUGIN_ID} pane=${tmuxPane} server=${serverURLString}`)

  // Announce the session the moment opencode loads us — opencode emits nothing on
  // a fresh idle launch, so this is what makes the (idle) session appear in the
  // sidebar before the first turn. Fire-and-forget; the process is alive and will
  // keep sending.
  forward(LIFECYCLE_STARTED, context)

  return {
    event: async ({ event }) => {
      if (!event || typeof event.type !== "string") return
      debug(`event ${event.type}`)
      if (event.type === "message.updated") {
        // Telemetry rides the OTLP channel, not the ingress socket (see
        // emitTelemetry) — message.updated is never forwarded.
        emitTelemetry((event.properties || {}).info, context)
        return
      }
      if (!FORWARD.has(event.type)) return
      forward(event, context)
    },
    // opencode runs this finalizer on a graceful shutdown (the quit command,
    // `/exit`, Ctrl-C). It's the only exit signal we get — the bridge dies with
    // the process — so tell Gallager to drop the session. Awaited so opencode
    // waits for the frame to flush. A hard kill (SIGKILL/crash) skips finalizers
    // and so won't fire this; that's the one uncovered case.
    dispose: async () => {
      debug("dispose → lifecycle.stopped")
      try {
        await forward(LIFECYCLE_STOPPED, context)
      } catch {
        /* never throw out of dispose */
      }
    },
  }
}

export default GallagerMonitor
