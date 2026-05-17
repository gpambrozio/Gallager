# Silent badge-update push from host to iOS

## Problem

When the iOS app is offline (backgrounded/terminated), event pushes from the host go through APNs and bump the iOS app badge. When the user later clears a session from the "needs attention" state on the host (via `markSessionHandled`, either by the local user activating the Mac window or by a remote viewer command), nothing tells iOS to clear or decrement the badge. From the iOS side the badge stays stuck until the user opens the app.

A secondary issue: each push currently hardcodes `badge: 1` in `APNsService.swift`. So even when multiple sessions need attention, the badge is always 1 — it doesn't reflect the real count of unhandled sessions.

## Goal

Make the host the source of truth for the iOS app badge:

1. Every push notification carries the host's current `pendingSessionCount` as the badge value.
2. When `markSessionHandled` clears the last (or any) needs-attention flag, the host sends a **silent** APNs push (no alert, no sound) that updates the badge to the new lower count.

## Non-goals

- iOS-side badge aggregation across multiple paired hosts. For users with one Mac (common case) the badge will be exact. For multi-Mac users the last push wins; acceptable for v1.
- Recovering from missed pushes. APNs background pushes are best-effort; opening the app refreshes state. If drift becomes a real problem we can add an iOS-side `setBadgeCount` driven by `SessionStore.needsAttention` count.

## Design

### Networking model — `EncryptedPushPayload`

`ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PushModels.swift`. Add two unencrypted fields:

```swift
public struct EncryptedPushPayload: Codable, Sendable, Equatable {
    public let encryptedContent: EncryptedPayload
    public let pairId: String

    /// Absolute badge value to set on the iOS app. `nil` means "leave badge alone".
    public let badge: Int?

    /// When true, the server sends an APNs background notification (no alert,
    /// no sound, no Notification Service Extension) — only the badge is updated.
    public let silent: Bool

    public init(
        encryptedContent: EncryptedPayload,
        pairId: String,
        badge: Int? = nil,
        silent: Bool = false
    ) { ... }
}
```

Defaults keep existing call sites working (they'll opt in to passing `badge`). The two fields are *unencrypted* on purpose: the APNs server needs them in the unencrypted APS payload, and the badge value isn't sensitive (it's just a small integer).

### Server — `APNsService`

`ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/APNsService.swift`.

`sendEncryptedNotificationIfNeeded(payload:pairId:)` branches on `payload.silent`:

- **Alert path (`silent == false`)** — current behavior, but use `payload.badge` instead of hardcoded `1`. If `payload.badge == nil`, omit the badge field.
- **Silent path (`silent == true`)** — send an `APNSBackgroundNotification` (`apns-push-type: background`, `priority: 5`) with `aps.content-available: 1` and `aps.badge: <payload.badge>`. No `alert`, no `sound`, no `mutable-content` — iOS won't show anything but will update the badge.

Both paths still skip the send when `connectionHub.isViewerConnected(pairId:)` is true (badge will be kept in sync via the iOS app's local state when it's online — see follow-up note below).

### Host — `ConnectedViewerManager` & `ConnectedViewer`

`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/ConnectedViewerManager.swift`:

- Add a callback: `var pendingSessionCountProvider: (@Sendable () async -> Int)?`. `AppCoordinator.setupConnectedViewerManager` wires it to `{ winManager.pendingSessionCount }`.
- New method: `func broadcastBadgeUpdate(badge: Int) async` — for every connected viewer, calls the new `ConnectedViewer.sendBadgeUpdate(badge:)`.

`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/ConnectedViewer.swift`:

- `sendEncryptedPushNotification(for:)` — read the badge from the new provider and pass it through:

  ```swift
  let badge = await onPendingSessionCount?() // count after this event was added
  let payload = EncryptedPushPayload(
      encryptedContent: encryptedContent,
      pairId: id,
      badge: badge,
      silent: false
  )
  ```

  Add `onPendingSessionCount: (@Sendable () async -> Int)?` callback set up by `ConnectedViewerManager.setupConnectionCallbacks`.

- New `func sendBadgeUpdate(badge: Int) async`:
  - Guards on `state.isConnected` and `e2eeService.isSessionEstablished` (same as existing push methods).
  - Creates a minimal `NotificationContent` placeholder (empty title/body, `eventType: "badge.update"`) — the encryption isn't strictly needed for silent pushes since the extension won't run, but keeping the payload shape consistent avoids special-casing the relay.
  - Encrypts it, builds `EncryptedPushPayload(... badge: badge, silent: true)`, sends through `await send(.encryptedPush(payload))`.

`sendCustomPushNotification` also passes `badge: await onPendingSessionCount?()` for consistency.

### Host — triggering the silent push

`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` around line 1080 (`markHandled` command handler):

```swift
if case .markHandled = command.command {
    let wasNeeding = winManager.paneStates[command.paneId]?.claudeSession?.needsAttention == true
    winManager.markSessionHandled(paneId: command.paneId)
    if wasNeeding {
        await connectionManager?.pushSessionStateToAll()
        await connectionManager?.broadcastBadgeUpdate(badge: winManager.pendingSessionCount)
    }
    return .success(for: command.id)
}
```

`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MainView.swift` `markSelectedSessionsHandledIfActive` — when `stateChanged` is true after marking the local window's sessions, broadcast the new count alongside the existing `pushSessionStateToAll`.

### iOS

No code changes required for v1.

- `UIBackgroundModes` already includes `remote-notification`, so background pushes are delivered when the app is suspended.
- iOS automatically applies `aps.badge` from any incoming push (foreground, background, or silent).
- The Notification Service Extension is only invoked for `mutable-content: 1` alert pushes, which silent pushes are not — so it won't run and won't see (or need to decrypt) the silent payload.

## Trade-offs

- **Multi-host viewers.** Each Mac sends `badge = its own pendingSessionCount`. With two paired Macs, the last push wins on iOS rather than summing — the badge becomes approximate. Acceptable for v1; revisit with iOS-side aggregation if users complain.
- **Background-push delivery is best-effort.** Apple may throttle silent pushes. If a silent push is dropped, the badge stays stale until the user opens the app (WebSocket reconnect refreshes state). Same risk exists today for alert pushes.
- **Single-host correctness regression check.** Existing alert pushes will start sending `badge: pendingSessionCount` rather than `1`. With one needing-attention session that's still `1`; with three it'll be `3`. This is the desired behavior, but if there's any test that asserts `badge == 1` it needs updating.

## Implementation order

1. Extend `EncryptedPushPayload` (model).
2. Update `APNsService` to honor `badge` + `silent`.
3. Add `onPendingSessionCount` plumbing on `ConnectedViewer` / `ConnectedViewerManager`, wire from `AppCoordinator`.
4. Add `sendBadgeUpdate` / `broadcastBadgeUpdate`.
5. Trigger from `markHandled` paths (command + local).
6. Build macOS scheme to verify.

## Out of scope (possible follow-ups)

- iOS-side `setBadgeCount` from `SessionStore.needsAttention` so the badge stays accurate while the app is online (today APNs is skipped when WebSocket is up).
- Multi-host badge aggregation in the iOS extension via an App Group shared counter.
