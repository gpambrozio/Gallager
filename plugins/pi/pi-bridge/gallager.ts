/**
 * Gallager ↔ pi ingress bridge.
 *
 * This is a pi *extension* (auto-loaded from ~/.pi/agent/extensions/, TypeScript
 * via jiti — no compile step). pi exposes a first-class extension event bus, so
 * the bridge subscribes to the few lifecycle events Gallager cares about and
 * forwards compact frames to Gallager's Unix-domain *ingress socket*, where the
 * pi sidecar's `translate_event` maps them onto session state.
 *
 * Unlike opencode, pi fires REAL events at both ends of a session's life
 * (`session_start` on launch//new//resume, `session_shutdown` on quit — including
 * Ctrl+C/Ctrl+D/SIGTERM), so no synthetic lifecycle frames are needed.
 *
 * Two channels, do not confuse them:
 *   - Ingress socket (state)     → 4-byte big-endian length prefix + JSON body,
 *                                   snake_case top-level (plugin_id, context, payload).
 *   - OTLP receiver (telemetry)  → HTTP POST /v1/logs, OTLP/JSON. One record per
 *                                   completed assistant message (issue #617).
 *
 * The Gallager sidecar's `install` rewrites the three placeholder tokens below
 * with the real ingress socket path, plugin id, and OTLP endpoint (pi does not
 * inherit Gallager's env, so they must be baked in). Left un-substituted (e.g.
 * loading this file straight from the repo with `pi -e` for a smoke test) they
 * fall back to GALLAGER_* env vars, then to Gallager's default conventions.
 *
 * Marker: the string "GallagerPiBridge" is how the sidecar's install_status
 * detects an installed copy — keep it.
 */
import net from "node:net"
import os from "node:os"
import path from "node:path"
import fs from "node:fs"
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

// --- Baked-in identity (install substitutes these exact tokens) ---------------
const RAW_SOCK = "__GALLAGER_INGRESS_SOCK__"
const RAW_ID = "__GALLAGER_PLUGIN_ID__"
const RAW_OTLP = "__GALLAGER_OTLP_ENDPOINT__"

const SOCKET_PATH = RAW_SOCK.startsWith("__GALLAGER")
  ? process.env.GALLAGER_INGRESS_SOCK || path.join(os.homedir(), ".gallager", "state", "ingress.sock")
  : RAW_SOCK
const PLUGIN_ID = RAW_ID.startsWith("__GALLAGER") ? process.env.GALLAGER_PLUGIN_ID || "pi" : RAW_ID
// Gallager's loopback OTLP receiver (issue #617). Baked in at install like the
// socket path (the port is whatever the receiver actually bound that launch);
// the env fallback serves repo smoke tests. Empty → telemetry disabled.
const OTLP_ENDPOINT = RAW_OTLP.startsWith("__GALLAGER")
  ? process.env.GALLAGER_OTLP_ENDPOINT || ""
  : RAW_OTLP

// Optional: set GALLAGER_PI_DEBUG=1 to record every event this bridge sees and
// forwards. Lands next to the sidecar's stderr.log so `gallager plugin logs pi`
// neighbours find it.
const DEBUG = !!process.env.GALLAGER_PI_DEBUG
const DEBUG_LOG =
  process.env.GALLAGER_PI_DEBUG_LOG ||
  path.join(os.homedir(), ".gallager", "state", "plugins", PLUGIN_ID, "logs", "bridge-debug.log")

function debug(line: string) {
  if (!DEBUG) return
  try {
    fs.mkdirSync(path.dirname(DEBUG_LOG), { recursive: true })
    fs.appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${line}\n`)
  } catch {
    /* never break pi over a debug write */
  }
}

/**
 * Write one length-prefixed frame to Gallager's ingress socket.
 *
 * Resolves once the frame has flushed or the attempt gave up (Gallager not
 * running / timeout) — never rejects. Event handlers fire-and-forget (ignore the
 * Promise); the `session_shutdown` handler awaits it so pi's teardown waits for
 * the final frame to land before the process exits.
 */
function forward(payload: Record<string, unknown>, context: Record<string, string>): Promise<void> {
  return new Promise((resolve) => {
    if (!context.TMUX_PANE) return resolve() // no pane → nothing to route
    let sock: net.Socket | undefined
    let settled = false
    const done = () => {
      if (settled) return
      settled = true
      resolve()
    }
    try {
      const body = Buffer.from(JSON.stringify({ plugin_id: PLUGIN_ID, context, payload }), "utf8")
      const prefix = Buffer.allocUnsafe(4)
      prefix.writeUInt32BE(body.length, 0)

      sock = net.createConnection({ path: SOCKET_PATH })
      sock.on("connect", () => {
        sock!.write(Buffer.concat([prefix, body]), () => {
          try {
            sock!.end()
          } catch {}
        })
      })
      sock.on("close", done) // frame flushed + server hung up
      sock.on("error", () => {
        // Gallager not running / socket gone — drop silently.
        try {
          sock!.destroy()
        } catch {}
        done()
      })
      sock.setTimeout(5000, () => {
        try {
          sock!.destroy()
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

/** The last assistant message's visible text, trimmed for a notification body. */
function summarize(messages: any[] | undefined): string | undefined {
  if (!Array.isArray(messages)) return undefined
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (!m || m.role !== "assistant") continue
    const text = (Array.isArray(m.content) ? m.content : [])
      .filter((part: any) => part && part.type === "text" && typeof part.text === "string")
      .map((part: any) => part.text)
      .join("\n")
      .trim()
    if (text) return text.length > 300 ? `${text.slice(0, 297)}…` : text
    return undefined // last assistant message had no text (e.g. pure tool call)
  }
  return undefined
}

// --- OTLP telemetry (issue #617) ----------------------------------------------
// pi's `message_end` fires once per finalized message, and an assistant message
// carries everything Gallager's meter surfaces (tokens, cost, model). Emit ONE
// OTLP/JSON log record per assistant message, straight to Gallager's loopback
// receiver (`POST /v1/logs`, plain fetch — no SDK). This never rides the ingress
// socket: telemetry is the OTLP channel.
//
// The attribute keys mirror Claude Code's `api_request` vocabulary exactly, so
// the host aggregates them with the same additive per-message semantics (the
// manifest's `otlp` declaration maps the `pi.` namespace onto it). `session.id`
// is pi's session UUID — the same id the sidecar reports in its PluginEvents,
// which is what the host uses to stamp the pane's telemetry join key. pi has no
// separate reasoning-token count: thinking output is already inside
// `usage.output` (Claude's convention — thinking bills as output).
//
// Dedup by message id: pi fires `message_end` once per finalized message today,
// but if it ever re-fired for the same message (retry/edit/re-render) the meter
// would double-count its tokens (additive per-session semantics). A bounded FIFO
// Set of seen ids guards against that, matching the opencode bridge's guarantee.
// A message with no id can't be deduped — emit it rather than drop telemetry.
const OTLP_EMITTED = new Set<string>()
const OTLP_EMITTED_CAP = 512

function emitTelemetry(
  message: any,
  sessionID: string,
  paneID: string,
  durationMs: number | undefined,
) {
  if (!OTLP_ENDPOINT || !paneID) return
  if (!message || message.role !== "assistant") return
  const id = typeof message.id === "string" ? message.id : undefined
  if (id) {
    if (OTLP_EMITTED.has(id)) return
    OTLP_EMITTED.add(id)
    if (OTLP_EMITTED.size > OTLP_EMITTED_CAP) {
      OTLP_EMITTED.delete(OTLP_EMITTED.values().next().value as string)
    }
  }
  const usage = message.usage || {}
  const cost = usage.cost || {}
  const int = (v: unknown) =>
    typeof v === "number" && isFinite(v) ? Math.max(0, Math.round(v)) : 0

  const attributes: any[] = [
    { key: "event.name", value: { stringValue: `${PLUGIN_ID}.api_request` } },
    { key: "session.id", value: { stringValue: sessionID } },
    { key: "input_tokens", value: { intValue: int(usage.input) } },
    { key: "output_tokens", value: { intValue: int(usage.output) } },
    { key: "cache_read_tokens", value: { intValue: int(usage.cacheRead) } },
    { key: "cache_creation_tokens", value: { intValue: int(usage.cacheWrite) } },
    { key: "cost_usd", value: { doubleValue: typeof cost.total === "number" && isFinite(cost.total) ? cost.total : 0 } },
  ]
  if (typeof durationMs === "number" && durationMs >= 0) {
    attributes.push({ key: "duration_ms", value: { intValue: Math.round(durationMs) } })
  }
  if (message.model) {
    attributes.push({ key: "model", value: { stringValue: String(message.model) } })
  }

  const body = {
    resourceLogs: [{ scopeLogs: [{ logRecords: [{ eventName: `${PLUGIN_ID}.api_request`, attributes }] }] }],
  }
  debug(`otlp api_request session=${sessionID} in=${int(usage.input)} out=${int(usage.output)}`)
  // Fire-and-forget: telemetry must never break pi. The receiver is
  // loopback-local, so a failure means Gallager is gone — drop silently.
  try {
    fetch(`${OTLP_ENDPOINT}/v1/logs`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).catch(() => {})
  } catch {
    /* fetch unavailable or sync throw — never break pi */
  }
}

export default function GallagerPiBridge(pi: ExtensionAPI) {
  // Captured once per pi process. TMUX_PANE is how Gallager routes events to the
  // right pane; without it (pi outside a Gallager-managed tmux pane) every
  // forward is a no-op.
  const tmuxPane = process.env.TMUX_PANE || ""

  // Streaming start time of the in-flight assistant message, for the OTLP
  // duration_ms attribute. pi streams one assistant message at a time, so a
  // single slot suffices; message_start → message_end brackets one model call.
  let assistantStartedAt: number | undefined

  const contextFor = (ctx: any): Record<string, string> => {
    const context: Record<string, string> = { TMUX_PANE: tmuxPane }
    try {
      if (ctx && typeof ctx.cwd === "string" && ctx.cwd) context.PI_PROJECT_DIR = ctx.cwd
    } catch {}
    return context
  }

  const sessionIdOf = (ctx: any): string => {
    try {
      const id = ctx?.sessionManager?.getSessionId?.()
      if (typeof id === "string" && id) return id
    } catch {}
    return tmuxPane || "unknown"
  }

  debug(`bridge loaded sock=${SOCKET_PATH} id=${PLUGIN_ID} pane=${tmuxPane} otlp=${OTLP_ENDPOINT || "(off)"}`)

  // Session appears (idle) the moment a session starts — on launch, /new,
  // /resume, and /fork alike. pi fires this natively; the sidecar maps it to
  // AgentState.idle and stamps the pane↔session mapping.
  pi.on("session_start", async (event: any, ctx: any) => {
    try {
      debug(`session_start reason=${event?.reason}`)
      forward(
        { type: "session_start", sessionId: sessionIdOf(ctx), reason: event?.reason },
        contextFor(ctx),
      )
    } catch {}
  })

  // One user prompt = one agent loop. Start → working.
  pi.on("agent_start", async (_event: any, ctx: any) => {
    try {
      forward({ type: "agent_start", sessionId: sessionIdOf(ctx) }, contextFor(ctx))
    } catch {}
  })

  // Loop finished (clean, error, or user-aborted) → doneWorking + attention.
  pi.on("agent_end", async (event: any, ctx: any) => {
    try {
      const messages = event?.messages
      const last = Array.isArray(messages)
        ? [...messages].reverse().find((m: any) => m && m.role === "assistant")
        : undefined
      forward(
        {
          type: "agent_end",
          sessionId: sessionIdOf(ctx),
          summary: summarize(messages),
          stopReason: last?.stopReason,
          errorMessage: typeof last?.errorMessage === "string" ? last.errorMessage : undefined,
        },
        contextFor(ctx),
      )
    } catch {}
  })

  // Telemetry: bracket each streamed assistant message for duration, then emit
  // one OTLP record when it finalizes. Never forwarded to the ingress socket.
  pi.on("message_start", async (event: any, _ctx: any) => {
    try {
      if (event?.message?.role === "assistant") assistantStartedAt = Date.now()
    } catch {}
  })

  pi.on("message_end", async (event: any, ctx: any) => {
    try {
      const message = event?.message
      if (!message || message.role !== "assistant") return
      const duration = assistantStartedAt !== undefined ? Date.now() - assistantStartedAt : undefined
      assistantStartedAt = undefined
      emitTelemetry(message, sessionIdOf(ctx), tmuxPane, duration)
    } catch {}
  })

  // pi runs this on every session teardown: quit (Ctrl+C, Ctrl+D, SIGHUP,
  // SIGTERM, /exit) AND session replacement (/new, /resume, /fork, /reload).
  // Forward the reason; the sidecar ends the Gallager session only for "quit" —
  // for replacements a fresh session_start follows immediately and re-stamps the
  // pane. Awaited so pi's shutdown waits for the final frame to flush. A hard
  // SIGKILL skips handlers and the session lingers until the host reconciles.
  pi.on("session_shutdown", async (event: any, ctx: any) => {
    try {
      debug(`session_shutdown reason=${event?.reason}`)
      await forward(
        { type: "session_shutdown", sessionId: sessionIdOf(ctx), reason: event?.reason },
        contextFor(ctx),
      )
    } catch {
      /* never throw out of shutdown */
    }
  })
}
