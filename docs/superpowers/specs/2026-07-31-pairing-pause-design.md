# Pairing Pause (relay maintenance switch) — Design

**Date:** 2026-07-31
**Status:** Approved

## Problem

During server migrations (and potentially under overload) the hosted relay needs a
way to stop accepting **new** pairings while leaving every existing pairing —
WebSocket relay traffic, status polling, unpairing — completely untouched. The
switch must be operable by the relay operator alone: no macOS or iOS client
changes, driven by a single environment variable whose value is the user-facing
message.

## Behavior

- **Env var:** `PAIRING_PAUSED_MESSAGE`
  - Absent, empty, or whitespace-only → feature fully off; zero behavior change.
  - Set (after trimming) → pairing **registration** is paused and the trimmed
    value is the exact message shown to users.
- **Gate scope:** `POST /api/pairing/register` only (the host generating a new
  code). `complete`, `status`, `delete`, and all WebSocket/relay traffic are
  untouched. Consequence (accepted): an iOS user who types a code sees the
  ordinary "invalid or expired code" error, not the pause message — the pause
  message surfaces where the flow starts, on the Mac.
- **Response shape:** the gate returns a normal 200 `PairingResponse` of
  `.error(ErrorInfo(message: <env text>, code: "PAIRING_PAUSED"))`. This is the
  only zero-client-change way to show a custom message: both clients render
  `errorInfo.message` verbatim for codes they don't recognize
  (`PairingManager.swift` on Mac, `PairingView.swift` on iOS). An HTTP-level
  rejection (e.g. 503) would decode-fail on clients and show a generic
  "Network error" instead.

## What the user sees

Mac: Settings → Remote Access → "Generate Pairing Code" / "Add Viewer" → brief
spinner → the existing pairing error view: red warning triangle + the env-var
message verbatim + "Try Again" button. Styled as an error (red), so the message
text should read calmly, e.g. "Pairing is temporarily paused while we migrate
servers. Existing pairings are unaffected — please try again in a few hours."

## Implementation

All changes in `ClaudeSpyPackage`:

1. **`Sources/ClaudeSpyNetworking/Models/WebSocketMessage.swift`** — add
   `ErrorMessage.pairingPausedCode = "PAIRING_PAUSED"` next to
   `subscriptionRequiredCode`. (Shared constant only; no client logic change.)
2. **`Sources/ClaudeSpyExternalServerLib/configure.swift`** — read
   `PAIRING_PAUSED_MESSAGE` from the injected `env`, trim whitespace, store the
   non-empty value in `app.storage` via a new `PairingPausedMessageKey`
   (`Value = String?`, same shape as `MetricsTokenKey`) + an
   `Application.pairingPausedMessage` accessor. Log at boot when enabled:
   "Pairing PAUSED — new pairing registrations will be refused".
3. **`Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift`** —
   first check in `registerPairingCode`, before the licensing entitlement check:
   if a pause message is configured, increment the metrics counter and return
   `.error(ErrorInfo(message: message, code: ErrorMessage.pairingPausedCode))`.
4. **`Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift`** — add
   `pausedPairingAttemptsTotal` counter (`&+= 1`), an
   `incrementPausedPairingAttempts()` method, and export it as
   `claudespy_paused_pairing_attempts_total`, mirroring
   `blockedHostAttemptsTotal`.

## Operations

`docker-compose.yml` loads the entire `.env` via `env_file`, so no compose
change is needed. To pause: set `PAIRING_PAUSED_MESSAGE="…"` in `.env` on the
server and `docker compose up -d` (container recreate applies the new env). To
resume: clear the var and recreate again. Boot-time read matches the existing
`MIN_CLIENT_VERSION` / `METRICS_TOKEN` patterns; a dynamic (no-restart) switch
was considered and rejected as YAGNI.

## Testing

Unit tests against `configure(env:)` + the register route (vars passed via the
`env` parameter, never `setenv`):

- Var set → register returns `.error` with the exact message and
  `PAIRING_PAUSED` code; metrics counter increments; `/metrics` line present.
- Var absent → registration works normally.
- Var empty or whitespace-only → registration works normally.
- Pause active → `complete` for a pre-registered code still succeeds
  (documents the register-only scope).

No e2e scenario: the client-side rendering path (verbatim message for unknown
codes) is existing shipped behavior.

## Documentation

- Commented example in `.env.example` and `.env.staging.example`.
- Short note in `docs/self-hosting.md`.
