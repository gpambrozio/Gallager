import ClaudeSpyNetworking
import Vapor

/// Handles WebSocket connections for real-time communication
struct WebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Configure WebSocket with larger frame size (1MB) to handle terminal snapshots
        routes.webSocket("ws", maxFrameSize: .init(integerLiteral: 1 << 20), onUpgrade: handleWebSocketUpgrade)
    }

    /// Handle WebSocket upgrade
    /// WS /api/ws?pairId=xxx&deviceType=host|viewer&deviceId=xxx
    @Sendable
    func handleWebSocketUpgrade(req: Request, ws: WebSocket) async {
        // Extract query parameters
        guard
            let pairId = req.query[String.self, at: "pairId"],
            let deviceTypeString = req.query[String.self, at: "deviceType"],
            let deviceType = DeviceType(rawValue: deviceTypeString),
            let deviceId = req.query[String.self, at: "deviceId"]
        else {
            req.logger.warning("WebSocket connection rejected: missing parameters")
            try? await ws.close(code: .policyViolation)
            return
        }

        let pairingService = req.application.pairingService
        let connectionHub = req.application.connectionHub
        let relayService = req.application.relayService

        // Reject connections from blocked device types (for E2E testing).
        // This prevents auto-reconnection while the test verifies server-side state.
        // The `await` suspension point before message handler registration is acceptable
        // here: blocked connections are closed immediately and never registered, so any
        // messages arriving during the brief window are harmlessly dropped.
        if await connectionHub.isBlocked(deviceType: deviceType) {
            req.logger.info("WebSocket connection rejected: \(deviceType) is blocked")
            try? await ws.close(code: .goingAway)
            return
        }

        // Relay gate: a host's frames must not reach the viewer until its entitlement
        // check (below) passes. Because the handlers are registered before that check
        // resolves — and `checkEntitlement` may embed a live LS revalidation of up to
        // 15s — a lapsed/modified host would otherwise stream to the viewer during that
        // window on every reconnect. The gate buffers host frames that arrive while the
        // check is pending and replays them in order once entitled (or drops them if
        // rejected). Viewers are never gated, so their gate starts open — no buffering,
        // no behavior change (this also keeps the `config == nil` / E2E path unchanged,
        // where the host check resolves instantly to `.unrestricted`).
        let relayGate = RelayGate(open: deviceType != .host)

        // CRITICAL: Set up message handlers BEFORE any `await` suspension point.
        //
        // On localhost (E2E tests), the client sends its registration message almost
        // instantly after the WebSocket upgrade completes. Every `await` creates a
        // suspension point where NIO can deliver the client's frame. If the handler
        // isn't registered yet, the frame is silently dropped.
        //
        // Each handler ensures the connection is registered BEFORE processing the
        // message. This guarantees connectionHub.send() can find the connection when
        // sending responses (e.g. hostRegistered). Without this, the response could
        // be silently dropped because Swift actors do not guarantee FIFO ordering
        // of enqueued jobs — register() and send() on the same actor can execute
        // in either order even if register() was enqueued first.
        ws.onText { ws, text in
            let data = Data(text.utf8)
            guard await relayGate.admit(data) else { return }
            await handleIncomingMessage(
                data: data,
                ws: ws,
                pairId: pairId,
                deviceType: deviceType,
                deviceId: deviceId,
                connectionHub: connectionHub,
                relayService: relayService,
                logger: req.logger
            )
        }

        ws.onBinary { ws, buffer in
            let data = Data(buffer: buffer)
            guard await relayGate.admit(data) else { return }
            await handleIncomingMessage(
                data: data,
                ws: ws,
                pairId: pairId,
                deviceType: deviceType,
                deviceId: deviceId,
                connectionHub: connectionHub,
                relayService: relayService,
                logger: req.logger
            )
        }

        ws.onClose.whenComplete { _ in
            Task {
                // Only tear down if THIS socket is still the registered one. After a
                // network switch the device reconnects with a new socket that replaces
                // this entry; this (old) socket's close can arrive seconds-to-minutes
                // later. Unregistering unconditionally would evict the live replacement
                // and falsely notify the peer that the device disconnected.
                let removed = await connectionHub.unregisterIfCurrent(
                    pairId: pairId,
                    deviceType: deviceType,
                    webSocket: ws
                )
                if removed {
                    await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: false)
                    req.logger.info("WebSocket disconnected: \(deviceType) for pair \(pairId)")
                } else {
                    req.logger.info("Stale \(deviceType) WebSocket closed for pair \(pairId); newer connection retained")
                }
            }
        }

        // Register connection. The message handlers above also register defensively
        // before processing each message, so this is not strictly required for
        // correctness — but it keeps the connection registered for the notifyConnection
        // call below even if no message has arrived yet.
        let connection = Connection(
            pairId: pairId,
            deviceType: deviceType,
            deviceId: deviceId,
            webSocket: ws
        )
        await connectionHub.register(connection)
        req.logger.info("WebSocket connected: \(deviceType) for pair \(pairId)")

        // Validate the pair (after registration so messages aren't lost)
        guard await pairingService.isValidPair(pairId: pairId) else {
            req.logger.warning("WebSocket connection rejected: invalid pairId \(pairId)")
            await connectionHub.unregister(pairId: pairId, deviceType: deviceType)
            let errorMessage = WebSocketMessage.error(.invalidPair())
            if let data = try? JSONEncoder().encode(errorMessage) {
                try? await ws.send(raw: data, opcode: .text)
            }
            try? await ws.close(code: .policyViolation)
            return
        }

        // Hosted-relay gate for hosts (viewers are never gated). Mirrors the
        // invalidPair rejection flow above.
        if deviceType == .host {
            // Migration safety net for grandfathered pairings: an ACTIVE
            // (completed) pair that predates licensing being enabled — or predates
            // trial-on-pairing — has no trial record. Start it on connect so such a
            // host begins its trial rather than getting ungated `.preTrial` access
            // forever. Gated to active pairs via `getPair` (nil for pending pairs),
            // so a pending pair connecting mid-pairing still never starts a trial —
            // that stays `completePairing`'s job. Idempotent no-op for normal new
            // pairings (trial already started) and for expired trials.
            if let pair = await pairingService.getPair(pairId: pairId) {
                await req.application.licensingService.startTrialIfNeeded(hostDeviceId: pair.hostDeviceId)
            }

            let entitlement = await req.application.licensingService
                .checkEntitlement(hostDeviceId: deviceId)
            if !entitlement.isAllowed {
                req.logger.info("WebSocket host rejected: subscription required for pair \(pairId)")
                await req.application.metricsService.incrementBlockedHostAttempts()
                await connectionHub.unregister(pairId: pairId, deviceType: deviceType)
                let errorMessage = WebSocketMessage.error(.subscriptionRequired())
                if let data = try? JSONEncoder().encode(errorMessage) {
                    try? await ws.send(raw: data, opcode: .text)
                }
                await connectionHub.send(.hostSubscriptionInactive, to: pairId, deviceType: .viewer)
                try? await ws.close(code: .policyViolation)
                // Gate is left closed: any frames buffered during the check are dropped.
                return
            }

            // Entitled — open the relay gate and replay, in order, any frames that
            // arrived while the check was pending. `drainOrOpen` only flips the gate
            // open once its buffer is empty, so frames arriving mid-replay keep queueing
            // behind the ones already relayed (no reordering).
            while let batch = await relayGate.drainOrOpen() {
                for data in batch {
                    await handleIncomingMessage(
                        data: data,
                        ws: ws,
                        pairId: pairId,
                        deviceType: deviceType,
                        deviceId: deviceId,
                        connectionHub: connectionHub,
                        relayService: relayService,
                        logger: req.logger
                    )
                }
            }
        }

        // Notify the other device
        await relayService.notifyConnection(pairId: pairId, deviceType: deviceType, connected: true)
    }
}

// MARK: - Message Handling

private func handleIncomingMessage(
    data: Data,
    ws: WebSocket,
    pairId: String,
    deviceType: DeviceType,
    deviceId: String,
    connectionHub: ConnectionHub,
    relayService: RelayService,
    logger: Logger
) async {
    // Ensure connection is registered before processing. This is critical because the
    // message handler may run before handleWebSocketUpgrade's register() call completes.
    // By registering here (sequentially, before relay processing), we guarantee that
    // connectionHub.send() will find the connection when sending responses like hostRegistered.
    let connection = Connection(pairId: pairId, deviceType: deviceType, deviceId: deviceId, webSocket: ws)
    await connectionHub.register(connection)

    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(WebSocketMessage.self, from: data)

        switch deviceType {
        case .host:
            await relayService.handleHostMessage(message, pairId: pairId)
        case .viewer:
            await relayService.handleViewerMessage(message, pairId: pairId)
        }
    } catch {
        logger.error("Failed to decode WebSocket message: \(error)")
    }
}

// MARK: - Device Type

enum DeviceType: String {
    case host
    case viewer
}

// MARK: - Relay Gate

/// Per-connection gate that holds a host's inbound frames until its entitlement
/// check passes, then replays them in order. Viewers construct it already-open,
/// so `admit` is a pass-through with no buffering.
///
/// Actor isolation serializes `admit` and `drainOrOpen`, which gives the
/// ordering guarantee: `drainOrOpen` only flips the gate open once its buffer is
/// empty, so a frame that arrives while buffered frames are still being replayed
/// is queued (not passed through ahead of them).
private actor RelayGate {
    private var isOpen: Bool
    private var pending: [Data] = []

    init(open: Bool) {
        self.isOpen = open
    }

    /// Returns `true` if the caller should relay `data` now; `false` if it was
    /// buffered to replay later (gate still closed).
    func admit(_ data: Data) -> Bool {
        if isOpen { return true }
        pending.append(data)
        return false
    }

    /// Drain step for opening the gate. Returns the next batch of buffered frames
    /// to replay, or `nil` once the buffer is empty — at which point the gate is
    /// flipped open so subsequent `admit` calls pass through directly. Call in a
    /// `while let` loop until it returns `nil`.
    func drainOrOpen() -> [Data]? {
        if pending.isEmpty {
            isOpen = true
            return nil
        }
        defer { pending.removeAll() }
        return pending
    }
}
