/**
 * Gallager ↔ omp ingress bridge.
 *
 * This is an omp *extension* (auto-loaded from ~/.omp/agent/extensions/,
 * TypeScript executed by omp's embedded Bun — no compile step). omp (oh-my-pi,
 * https://omp.sh) forked pi's first-class extension event bus, so the bridge
 * subscribes to the lifecycle events Gallager cares about and forwards compact
 * frames to Gallager's Unix-domain *ingress socket*, where the omp sidecar's
 * `translate_event` maps them onto session state.
 *
 * omp fires REAL events at both ends of a session's life, but the vocabulary
 * diverged from pi: `session_start` fires only on the initial load and carries
 * no reason; session replacement is its own `session_switch` / `session_branch`
 * / `session_tree` family; and `session_shutdown` means process exit only
 * (SIGINT/SIGTERM/Ctrl+C/Ctrl+D) — so no reason filtering is needed on quit.
 * omp also runs each `task` subagent in-process with the SAME extensions
 * re-bound against a headless runtime (ctx.hasUI === false), so every handler
 * gates on ctx.hasUI to keep subagent churn from flipping the pane's state.
 *
 * Unlike core pi, omp HAS a tool-approval gate (tools.approvalMode:
 * always-ask/write; default yolo). The bridge forwards
 * `tool_approval_requested`/`tool_approval_resolved` so Gallager can raise an
 * awaitingPermission form, enriching the request with the tool's input captured
 * from the preceding `tool_call` event (the approval event itself only carries
 * the tool name).
 *
 * Two channels, do not confuse them:
 *   - Ingress socket (state)     → 4-byte big-endian length prefix + JSON body,
 *                                   snake_case top-level (plugin_id, context, payload).
 *   - OTLP receiver (telemetry)  → HTTP POST /v1/logs, OTLP/JSON. One record per
 *                                   completed assistant message (issue #617).
 *
 * The Gallager sidecar's `install` rewrites the three placeholder tokens below
 * with the real ingress socket path, plugin id, and OTLP endpoint (omp does not
 * inherit Gallager's env, so they must be baked in). Left un-substituted (e.g.
 * loading this file straight from the repo with `omp -e` for a smoke test) they
 * fall back to GALLAGER_* env vars, then to Gallager's default conventions.
 *
 * Marker: the string "GallagerOmpBridge" is how the sidecar's install_status
 * detects an installed copy — keep it.
 */
import net from "node:net"
import os from "node:os"
import path from "node:path"
import fs from "node:fs"
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent"

// --- Baked-in identity (install substitutes these exact tokens) ---------------
const RAW_SOCK = "__GALLAGER_INGRESS_SOCK__"
const RAW_ID = "__GALLAGER_PLUGIN_ID__"
const RAW_OTLP = "__GALLAGER_OTLP_ENDPOINT__"

const SOCKET_PATH = RAW_SOCK.startsWith("__GALLAGER")
  ? process.env.GALLAGER_INGRESS_SOCK || path.join(os.homedir(), ".gallager", "state", "ingress.sock")
  : RAW_SOCK
const PLUGIN_ID = RAW_ID.startsWith("__GALLAGER") ? process.env.GALLAGER_PLUGIN_ID || "omp" : RAW_ID
// Gallager's loopback OTLP receiver (issue #617). Baked in at install like the
// socket path (the port is whatever the receiver actually bound that launch);
// the env fallback serves repo smoke tests. Empty → telemetry disabled.
const OTLP_ENDPOINT = RAW_OTLP.startsWith("__GALLAGER")
  ? process.env.GALLAGER_OTLP_ENDPOINT || ""
  : RAW_OTLP

// Optional: set GALLAGER_OMP_DEBUG=1 to record every event this bridge sees and
// forwards. Lands next to the sidecar's stderr.log so `gallager plugin logs omp`
// neighbours find it.
const DEBUG = !!process.env.GALLAGER_OMP_DEBUG
const DEBUG_LOG =
  process.env.GALLAGER_OMP_DEBUG_LOG ||
  path.join(os.homedir(), ".gallager", "state", "plugins", PLUGIN_ID, "logs", "bridge-debug.log")

function debug(line: string) {
  if (!DEBUG) return
  try {
    fs.mkdirSync(path.dirname(DEBUG_LOG), { recursive: true })
    fs.appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${line}\n`)
  } catch {
    /* never break omp over a debug write */
  }
}

/**
 * Write one length-prefixed frame to Gallager's ingress socket.
 *
 * Resolves once the frame has flushed or the attempt gave up (Gallager not
 * running / timeout) — never rejects. Event handlers fire-and-forget (ignore the
 * Promise); the `session_shutdown` handler awaits it so omp's teardown waits for
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

/** A one-line description of a tool call's input, for the approval form body. */
function describeToolInput(toolName: string, input: any): string | undefined {
  try {
    if (!input || typeof input !== "object") return undefined
    let detail: string | undefined
    if (typeof input.command === "string") detail = input.command // bash
    else if (typeof input.path === "string") detail = input.path // read/write/edit/glob
    else if (typeof input.file_path === "string") detail = input.file_path
    else if (typeof input.code === "string") detail = input.code // python
    else if (typeof input.url === "string") detail = input.url // browser/fetch
    else {
      const json = JSON.stringify(input)
      detail = json === "{}" ? undefined : json
    }
    if (!detail) return undefined
    detail = detail.replace(/\s+/g, " ").trim()
    return detail.length > 200 ? `${detail.slice(0, 197)}…` : detail
  } catch {
    return undefined
  }
}

// --- OTLP telemetry (issue #617) ----------------------------------------------
// omp's `message_end` fires once per finalized message, and an assistant message
// carries everything Gallager's meter surfaces (tokens, cost, model). Emit ONE
// OTLP/JSON log record per assistant message, straight to Gallager's loopback
// receiver (`POST /v1/logs`, plain fetch — no SDK). This never rides the ingress
// socket: telemetry is the OTLP channel.
//
// The attribute keys mirror Claude Code's `api_request` vocabulary exactly, so
// the host aggregates them with the same additive per-message semantics (the
// manifest's `otlp` declaration maps the `omp.` namespace onto it). `session.id`
// is omp's session UUID — the same id the sidecar reports in its PluginEvents,
// which is what the host uses to stamp the pane's telemetry join key. omp keeps
// pi's usage shape: no separate reasoning-token count — thinking output is
// already inside `usage.output` (Claude's convention — thinking bills as
// output).
//
// Dedup by message id: omp fires `message_end` once per finalized message today,
// but if it ever re-fired for the same message (retry/edit/re-render) the meter
// would double-count its tokens (additive per-session semantics). A bounded FIFO
// Set of seen ids guards against that. omp assistant messages don't always carry
// an `id` — fall back to the provider `responseId`; a message with neither can't
// be deduped — emit it rather than drop telemetry.
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
  const id =
    typeof message.id === "string"
      ? message.id
      : typeof message.responseId === "string"
        ? message.responseId
        : undefined
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
  // Fire-and-forget: telemetry must never break omp. The receiver is
  // loopback-local, so a failure means Gallager is gone — drop silently.
  try {
    fetch(`${OTLP_ENDPOINT}/v1/logs`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).catch(() => {})
  } catch {
    /* fetch unavailable or sync throw — never break omp */
  }
}

export default function GallagerOmpBridge(omp: ExtensionAPI) {
  // Captured once per omp process. TMUX_PANE is how Gallager routes events to
  // the right pane; without it (omp outside a Gallager-managed tmux pane) every
  // forward is a no-op.
  const tmuxPane = process.env.TMUX_PANE || ""

  // Streaming start time of the in-flight assistant message, for the OTLP
  // duration_ms fallback (omp usually stamps `message.duration` itself). omp
  // streams one assistant message at a time in this runtime, so a single slot
  // suffices; message_start → message_end brackets one model call.
  let assistantStartedAt: number | undefined

  // toolCallId → one-line input description, captured at `tool_call`
  // (arg-prep, which fires BEFORE the approval gate) so a following
  // `tool_approval_requested` — which carries only the tool name — can show
  // WHAT is being approved. Bounded FIFO.
  const toolInputs = new Map<string, string | undefined>()
  const TOOL_INPUTS_CAP = 128
  const rememberToolInput = (toolCallId: unknown, toolName: unknown, input: unknown) => {
    if (typeof toolCallId !== "string" || !toolCallId) return
    toolInputs.set(toolCallId, describeToolInput(String(toolName ?? ""), input))
    if (toolInputs.size > TOOL_INPUTS_CAP) {
      toolInputs.delete(toolInputs.keys().next().value as string)
    }
  }

  // omp runs each `task` subagent in-process with the same extensions re-bound
  // against a headless runtime — ctx.hasUI is false there (and in print/-p
  // mode). Only the interactive session in the pane drives Gallager state;
  // without this gate every subagent's agent_start/agent_end would flip the
  // pane between working and done (the opencode issue #670 lesson).
  const isMainSession = (ctx: any): boolean => {
    try {
      return !!ctx?.hasUI
    } catch {
      return false
    }
  }

  const contextFor = (ctx: any): Record<string, string> => {
    const context: Record<string, string> = { TMUX_PANE: tmuxPane }
    try {
      if (ctx && typeof ctx.cwd === "string" && ctx.cwd) context.OMP_PROJECT_DIR = ctx.cwd
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

  // Session appears (idle) the moment the initial session loads. Session
  // REPLACEMENT diverged from pi: /new, /resume, /fork and tree/branch jumps
  // fire their own events (below) instead of a session_start.
  omp.on("session_start", async (_event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      debug("session_start")
      forward({ type: "session_start", sessionId: sessionIdOf(ctx) }, contextFor(ctx))
    } catch {}
  })

  // Session replacement: switch (/new, /resume, /fork, handoff), branch, and
  // tree navigation. All fire AFTER the new session is live, so getSessionId()
  // returns the NEW id — forward as a session_start so the sidecar re-stamps
  // the same pane (idle) without the row ever flickering out.
  for (const replacement of ["session_switch", "session_branch", "session_tree"] as const) {
    omp.on(replacement as any, async (event: any, ctx: any) => {
      try {
        if (!isMainSession(ctx)) return
        debug(`${replacement} reason=${event?.reason ?? ""}`)
        forward(
          { type: "session_start", sessionId: sessionIdOf(ctx), reason: event?.reason },
          contextFor(ctx),
        )
      } catch {}
    })
  }

  // One user prompt = one agent loop. Start → working.
  omp.on("agent_start", async (_event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      forward({ type: "agent_start", sessionId: sessionIdOf(ctx) }, contextFor(ctx))
    } catch {}
  })

  // Loop finished (clean, error, or user-aborted) → doneWorking + attention.
  // `willContinue` means omp already scheduled an automatic continuation
  // (auto-retry, empty-stop retry) — not a user-visible settle, so skip it or
  // the user gets a spurious "Finished" mid-turn.
  omp.on("agent_end", async (event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      if (event?.willContinue) return
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

  // Interception hook, observability only here: capture the (possibly revised)
  // input each tool will run with, keyed by toolCallId, for approval forms.
  // Returning nothing leaves the call untouched.
  omp.on("tool_call", async (event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      rememberToolInput(event?.toolCallId, event?.toolName, event?.input)
    } catch {}
  })

  // The TUI is showing an Approve/Deny select dialog for this tool call →
  // awaitingPermission form (answered remotely by keystroke injection).
  omp.on("tool_approval_requested", async (event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      debug(`tool_approval_requested tool=${event?.toolName} call=${event?.toolCallId}`)
      forward(
        {
          type: "tool_approval_requested",
          sessionId: event?.sessionId || sessionIdOf(ctx),
          toolCallId: event?.toolCallId,
          toolName: event?.toolName,
          reason: event?.reason,
          approvalMode: event?.approvalMode,
          detail: typeof event?.toolCallId === "string" ? toolInputs.get(event.toolCallId) : undefined,
        },
        contextFor(ctx),
      )
    } catch {}
  })

  // Approval answered (in the TUI or via Gallager's keystrokes) → the turn
  // continues either way (deny feeds the model an error), so → working.
  omp.on("tool_approval_resolved", async (event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      debug(`tool_approval_resolved tool=${event?.toolName} approved=${event?.approved}`)
      forward(
        {
          type: "tool_approval_resolved",
          sessionId: event?.sessionId || sessionIdOf(ctx),
          toolCallId: event?.toolCallId,
          approved: !!event?.approved,
        },
        contextFor(ctx),
      )
    } catch {}
  })

  // Telemetry: bracket each streamed assistant message for the duration
  // fallback, then emit one OTLP record when it finalizes. Never forwarded to
  // the ingress socket. Subagent usage is real cost but would join on the
  // subagent's session id (never stamped to the pane), so the meter would drop
  // it anyway — the hasUI gate keeps it out at the source.
  omp.on("message_start", async (event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      if (event?.message?.role === "assistant") assistantStartedAt = Date.now()
    } catch {}
  })

  omp.on("message_end", async (event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      const message = event?.message
      if (!message || message.role !== "assistant") return
      const bracket = assistantStartedAt !== undefined ? Date.now() - assistantStartedAt : undefined
      assistantStartedAt = undefined
      const duration =
        typeof message.duration === "number" && message.duration >= 0 ? message.duration : bracket
      emitTelemetry(message, sessionIdOf(ctx), tmuxPane, duration)
    } catch {}
  })

  // omp fires this on process exit only (SIGINT/SIGTERM/Ctrl+C/Ctrl+D/exit) —
  // session replacement has its own events above — so shutdown always ends the
  // Gallager session. Awaited so omp's teardown waits for the final frame to
  // flush. A hard SIGKILL skips handlers and the session lingers until the host
  // reconciles (process_names: ["omp"] — omp is a native binary, so the
  // process scan CAN see it, unlike pi's `node`).
  omp.on("session_shutdown", async (_event: any, ctx: any) => {
    try {
      if (!isMainSession(ctx)) return
      debug("session_shutdown")
      await forward({ type: "session_shutdown", sessionId: sessionIdOf(ctx) }, contextFor(ctx))
    } catch {
      /* never throw out of shutdown */
    }
  })
}
