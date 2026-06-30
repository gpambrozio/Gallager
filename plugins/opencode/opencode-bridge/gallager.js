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

const SOCKET_PATH = RAW_SOCK.startsWith("__GALLAGER")
  ? process.env.GALLAGER_INGRESS_SOCK || path.join(os.homedir(), ".gallager", "state", "ingress.sock")
  : RAW_SOCK
const PLUGIN_ID = RAW_ID.startsWith("__GALLAGER")
  ? process.env.GALLAGER_PLUGIN_ID || "opencode"
  : RAW_ID

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

/** Write one length-prefixed frame to Gallager's ingress socket, fire-and-forget. */
function forward(event, context) {
  if (!context.TMUX_PANE) return // no pane → nothing to route
  let sock
  try {
    const body = Buffer.from(
      JSON.stringify({ plugin_id: PLUGIN_ID, context, payload: event }),
      "utf8",
    )
    const prefix = Buffer.allocUnsafe(4)
    prefix.writeUInt32BE(body.length, 0)

    sock = net.createConnection({ path: SOCKET_PATH })
    sock.on("connect", () => {
      sock.write(Buffer.concat([prefix, body]), () => sock.end())
    })
    sock.on("error", () => {
      // Gallager not running / socket gone — drop silently.
      try {
        sock.destroy()
      } catch {}
    })
    sock.setTimeout(5000, () => {
      try {
        sock.destroy()
      } catch {}
    })
  } catch {
    try {
      sock && sock.destroy()
    } catch {}
  }
}

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

  return {
    event: async ({ event }) => {
      if (!event || typeof event.type !== "string") return
      debug(`event ${event.type}`)
      if (!FORWARD.has(event.type)) return
      forward(event, context)
    },
  }
}

export default GallagerMonitor
