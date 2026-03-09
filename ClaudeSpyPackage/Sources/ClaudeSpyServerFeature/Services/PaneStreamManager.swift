#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Logging

    /// Manages PaneStream instances and their subscribers.
    ///
    /// This manager owns PaneStream instances independently of UI (mirror windows).
    /// Both mirror windows and terminal streaming can subscribe to the same stream,
    /// enabling streaming to work without requiring a mirror window to be open.
    ///
    /// Usage:
    /// 1. Call `subscribe(paneId:target:...)` to get a subscription ID
    /// 2. Data and dimension changes flow to your callbacks
    /// 3. Call `unsubscribe(_:)` when done
    /// 4. Stream is automatically disconnected when last subscriber leaves
    @Observable
    @MainActor
    final public class PaneStreamManager {
        // MARK: - Types

        /// A subscription to a pane stream
        private struct Subscription {
            let id: UUID
            let paneId: String
            let onData: @MainActor (Data) -> Void
            let onDimensionChange: (@MainActor (Int, Int) -> Void)?
            let onTitleChange: (@MainActor (String) -> Void)?
            let onNotification: (@MainActor (TerminalStreamMessage.TerminalNotification) -> Void)?
        }

        /// Context for a managed stream
        private struct StreamContext {
            let stream: PaneStream
            let target: String
            var subscriberIds: Set<UUID>
            /// Current terminal title detected via OSC escape sequences
            var terminalTitle: String?
        }

        // MARK: - Properties

        private let logger = Logger(label: "com.claudespy.panestreammanager")
        private let tmuxService: TmuxService
        private let controlClientManager: TmuxControlClientManager

        /// Active streams keyed by paneId
        private var streams: [String: StreamContext] = [:]

        /// All subscriptions keyed by subscription ID
        private var subscriptions: [UUID: Subscription] = [:]

        /// Context for a lightweight notification-only reader
        private struct NotificationReaderContext {
            let reader: PipePaneReader
            let sessionName: String
            /// The pane target (e.g., "mysession:0.1") for mapping title changes
            let target: String
        }

        /// Lightweight notification-only readers for panes that aren't fully mirrored
        private var notificationReaders: [String: NotificationReaderContext] = [:]

        /// Task for periodic pane discovery (needed to detect new tmux sessions)
        private var paneRefreshTask: Task<Void, Never>?

        /// Global notification handler — called for any notification on any pane,
        /// regardless of which subscribers are active. Used by macOS to show desktop notifications.
        public var onNotification: (@MainActor (String, TerminalStreamMessage.TerminalNotification) -> Void)?

        /// Global title change handler — called when a title change is detected on a
        /// notification-only reader (inactive pane). Parameters: (paneId, target, title).
        public var onTitleChange: (@MainActor (String, String, String) -> Void)?

        // MARK: - Public State

        /// Pane IDs that currently have active streams
        public var activeStreamPaneIds: [String] {
            Array(streams.keys)
        }

        /// Check if a pane has an active stream
        public func hasActiveStream(paneId: String) -> Bool {
            streams[paneId] != nil
        }

        /// Get current dimensions for a pane (if streaming)
        public func dimensions(for paneId: String) -> (width: Int, height: Int)? {
            guard let context = streams[paneId] else { return nil }
            return (context.stream.width, context.stream.height)
        }

        /// Get current terminal title for a pane (if streaming and title has been set)
        public func terminalTitle(for paneId: String) -> String? {
            streams[paneId]?.terminalTitle
        }

        // MARK: - Initialization

        public init(tmuxService: TmuxService, controlClientManager: TmuxControlClientManager) {
            self.tmuxService = tmuxService
            self.controlClientManager = controlClientManager

            // Wire up dimension changes from control client
            controlClientManager.setOnDimensionChange { [weak self] paneId, width, height in
                self?.updateDimensions(paneId: paneId, width: width, height: height)
            }
        }

        // MARK: - Public API

        /// Result of subscribing to a pane stream
        public struct SubscriptionResult {
            /// Subscription ID to use when unsubscribing
            public let subscriptionId: UUID
            /// Initial terminal content (scrollback + visible area)
            public let initialContent: Data
            /// Terminal width in columns
            public let width: Int
            /// Terminal height in rows
            public let height: Int
        }

        /// Subscribe to a pane stream.
        ///
        /// Creates a new PaneStream if one doesn't exist for this pane,
        /// or reuses an existing one. Returns the initial content captured
        /// atomically with the subscription to avoid timing gaps.
        ///
        /// - Parameters:
        ///   - paneId: The pane ID (e.g., "%1")
        ///   - target: The pane target (e.g., "mysession:0.1")
        ///   - onData: Callback for incoming terminal data (live updates only, not initial content)
        ///   - onDimensionChange: Optional callback for dimension changes
        ///   - onTitleChange: Optional callback for terminal title changes
        ///   - onNotification: Optional callback for terminal notifications (OSC 9/777)
        /// - Returns: Subscription result containing ID, initial content, and dimensions
        /// - Throws: If the stream fails to connect
        public func subscribe(
            paneId: String,
            target: String,
            onData: @escaping @MainActor (Data) -> Void,
            onDimensionChange: (@MainActor (Int, Int) -> Void)? = nil,
            onTitleChange: (@MainActor (String) -> Void)? = nil,
            onNotification: (@MainActor (TerminalStreamMessage.TerminalNotification) -> Void)? = nil
        ) async throws -> SubscriptionResult {
            let subscriptionId = UUID()
            let subscription = Subscription(
                id: subscriptionId,
                paneId: paneId,
                onData: onData,
                onDimensionChange: onDimensionChange,
                onTitleChange: onTitleChange,
                onNotification: onNotification
            )
            subscriptions[subscriptionId] = subscription

            let initialContent: Data
            let width: Int
            let height: Int

            // Get or create stream
            if var context = streams[paneId] {
                // Existing stream - capture initial content for this subscriber
                // Don't call onData - return it instead so caller handles it appropriately
                do {
                    initialContent = try await tmuxService.capturePaneWithScrollbackForStreaming(target)
                } catch {
                    logger.warning("Failed to capture initial content for new subscriber", metadata: [
                        "paneId": "\(paneId)",
                        "error": "\(error)",
                    ])
                    initialContent = Data()
                }

                width = context.stream.width
                height = context.stream.height

                // Now add subscriber so they receive future incremental updates
                context.subscriberIds.insert(subscriptionId)
                streams[paneId] = context

                // Send current terminal title to late-joining subscriber
                if let currentTitle = context.terminalTitle, let callback = onTitleChange {
                    callback(currentTitle)
                }

                logger.info("Added subscriber to existing stream", metadata: [
                    "paneId": "\(paneId)",
                    "subscriptionId": "\(subscriptionId)",
                    "totalSubscribers": "\(context.subscriberIds.count)",
                ])
            } else {
                // Stop notification-only reader first — both use the same FIFO path
                await stopNotificationReader(paneId: paneId)

                // Create new stream with control client manager for real-time updates
                let stream = PaneStream(
                    target: target,
                    tmuxService: tmuxService,
                    controlClientManager: controlClientManager
                )

                // Set up callbacks to forward to all subscribers
                stream.onData = { [weak self] data in
                    self?.forwardData(paneId: paneId, data: data)
                }
                stream.onDimensionChange = { [weak self] width, height in
                    self?.forwardDimensionChange(paneId: paneId, width: width, height: height)
                }
                stream.onNotification = { [weak self] notification in
                    self?.forwardNotification(paneId: paneId, notification: notification)
                }

                // Store context BEFORE connect() so callbacks work if triggered during connect
                streams[paneId] = StreamContext(
                    stream: stream,
                    target: target,
                    subscriberIds: [subscriptionId]
                )

                // Connect and get initial content atomically
                // The content is captured right after control client registration,
                // ensuring no gap between initial state and live updates
                do {
                    initialContent = try await stream.connect()
                } catch {
                    // Clean up on failure
                    streams.removeValue(forKey: paneId)
                    subscriptions.removeValue(forKey: subscriptionId)
                    throw error
                }

                width = stream.width
                height = stream.height

                logger.info("Created new stream", metadata: [
                    "paneId": "\(paneId)",
                    "target": "\(target)",
                    "subscriptionId": "\(subscriptionId)",
                ])
            }

            return SubscriptionResult(
                subscriptionId: subscriptionId,
                initialContent: initialContent,
                width: width,
                height: height
            )
        }

        /// Unsubscribe from a pane stream.
        ///
        /// If this is the last subscriber, the stream is disconnected.
        ///
        /// - Parameter subscriptionId: The subscription ID returned from subscribe()
        public func unsubscribe(_ subscriptionId: UUID) async {
            guard let subscription = subscriptions.removeValue(forKey: subscriptionId) else {
                logger.debug("Subscription not found: \(subscriptionId)")
                return
            }

            let paneId = subscription.paneId

            guard var context = streams[paneId] else {
                logger.warning("Stream not found for pane: \(paneId)")
                return
            }

            context.subscriberIds.remove(subscriptionId)

            if context.subscriberIds.isEmpty {
                // Last subscriber - disconnect stream
                let sessionName = TmuxControlClientManager.extractSessionName(from: context.target)
                let target = context.target
                await context.stream.disconnect()
                streams.removeValue(forKey: paneId)

                // Restart notification-only reader so we still detect OSC 9/777 and title changes
                await startNotificationReader(paneId: paneId, sessionName: sessionName, target: target)

                logger.info("Disconnected stream (no subscribers), restarted notification reader", metadata: [
                    "paneId": "\(paneId)",
                ])
            } else {
                // Update context with remaining subscribers
                streams[paneId] = context

                logger.info("Removed subscriber from stream", metadata: [
                    "paneId": "\(paneId)",
                    "subscriptionId": "\(subscriptionId)",
                    "remainingSubscribers": "\(context.subscriberIds.count)",
                ])
            }
        }

        /// Update dimensions for a pane (called when tmux refreshes pane info).
        ///
        /// This propagates dimension changes to the stream and all subscribers.
        public func updateDimensions(paneId: String, width: Int, height: Int) {
            guard let context = streams[paneId] else { return }
            context.stream.updateDimensions(width: width, height: height)
        }

        /// Report a terminal title change detected by a subscriber's SwiftTerm instance.
        ///
        /// SwiftTerm parses OSC 0/2 sequences from the data stream and calls its delegate.
        /// The subscriber (e.g., TerminalContainerView) reports the title back here so it can
        /// be forwarded to other subscribers (e.g., TerminalStreamService for iOS relay).
        ///
        /// - Parameters:
        ///   - paneId: The pane ID whose title changed
        ///   - title: The new terminal title
        ///   - fromSubscription: The subscription ID reporting the change (excluded from forwarding)
        public func reportTitleChange(paneId: String, title: String, fromSubscription: UUID) {
            guard var context = streams[paneId] else { return }
            guard !title.isEmpty, context.terminalTitle != title else { return }
            context.terminalTitle = title
            streams[paneId] = context

            // Notify global handler so MirrorWindowManager stays in sync
            // even when the pane is streamed without a local mirror window
            onTitleChange?(paneId, context.target, title)

            forwardTitleChange(paneId: paneId, title: title, excludingSubscription: fromSubscription)
        }

        /// Capture current content for a pane that is already streaming.
        ///
        /// This is used when a second viewer wants to view an already-streaming pane.
        /// Instead of creating a duplicate PaneStreamManager subscription (which would cause
        /// duplicate data forwarding), this captures the current terminal state.
        ///
        /// - Parameter paneId: The pane ID to capture content for
        /// - Returns: Current content, width, and height if the pane is streaming; nil otherwise
        public func currentContent(for paneId: String) async -> (content: Data, width: Int, height: Int)? {
            guard let context = streams[paneId] else { return nil }
            guard let content = try? await tmuxService.capturePaneWithScrollbackForStreaming(context.target) else {
                return nil
            }
            return (content, context.stream.width, context.stream.height)
        }

        /// Disconnect all streams (called on app shutdown).
        public func disconnectAll() async {
            let paneIds = Array(streams.keys)
            for paneId in paneIds {
                if let context = streams.removeValue(forKey: paneId) {
                    await context.stream.disconnect()
                }
            }
            subscriptions.removeAll()
            await stopAllNotificationReaders()
            logger.info("Disconnected all streams and notification readers")
        }

        // MARK: - Notification Monitoring

        /// Start notification-only readers for all panes not already fully mirrored.
        ///
        /// Called once on startup after initial pane discovery.
        public func startNotificationMonitoring(panes: [PaneInfo]) async {
            for pane in panes where streams[pane.paneId] == nil && notificationReaders[pane.paneId] == nil {
                await startNotificationReader(paneId: pane.paneId, sessionName: pane.sessionName, target: pane.target)
            }
        }

        /// Update notification readers based on current pane list.
        ///
        /// Stops readers for dead panes, starts readers for new panes.
        public func updateNotificationMonitoring(panes: [PaneInfo]) async {
            let currentPaneIds = Set(panes.map(\.paneId))

            // Stop readers for panes that no longer exist
            let staleIds = notificationReaders.keys.filter { !currentPaneIds.contains($0) }
            for paneId in staleIds {
                await stopNotificationReader(paneId: paneId)
            }

            // Start readers for new panes not already covered
            for pane in panes where streams[pane.paneId] == nil && notificationReaders[pane.paneId] == nil {
                await startNotificationReader(paneId: pane.paneId, sessionName: pane.sessionName, target: pane.target)
            }
        }

        /// Start periodic pane discovery to detect new tmux sessions.
        ///
        /// Control clients only detect changes within their own session;
        /// new tmux sessions need periodic discovery.
        public func startPeriodicPaneRefresh(tmuxService: TmuxService) {
            paneRefreshTask?.cancel()
            paneRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { break }
                    let panes = await tmuxService.refreshPanes()
                    await self?.updateNotificationMonitoring(panes: panes)
                }
            }
        }

        /// Stop all notification readers (for shutdown).
        public func stopAllNotificationReaders() async {
            let paneIds = Array(notificationReaders.keys)
            for paneId in paneIds {
                await stopNotificationReader(paneId: paneId)
            }
            paneRefreshTask?.cancel()
            paneRefreshTask = nil
        }

        // MARK: - Notification Reader Helpers

        private func startNotificationReader(paneId: String, sessionName: String, target: String) async {
            // scanOnly: true avoids building filtered output Data — only extracts notifications
            // and title changes, reducing CPU/memory overhead for panes that may produce
            // high-throughput output.
            let reader = PipePaneReader(paneId: paneId, scanOnly: true)

            // Set notification handler — no data handler means data is discarded
            await reader.setNotificationHandler { [weak self] notification in
                Task { @MainActor in
                    self?.forwardNotification(paneId: paneId, notification: notification)
                }
            }

            // Set title change handler for OSC 0/2 sequences on inactive panes
            await reader.setTitleChangeHandler { [weak self] title in
                Task { @MainActor in
                    self?.onTitleChange?(paneId, target, title)
                }
            }

            do {
                try await reader.startPipePane(
                    controlClientManager: controlClientManager,
                    sessionName: sessionName,
                    buffering: false
                )
                notificationReaders[paneId] = NotificationReaderContext(
                    reader: reader,
                    sessionName: sessionName,
                    target: target
                )
                logger.debug("Started notification reader", metadata: ["paneId": "\(paneId)"])
            } catch {
                logger.debug("Failed to start notification reader", metadata: [
                    "paneId": "\(paneId)",
                    "error": "\(error)",
                ])
            }
        }

        private func stopNotificationReader(paneId: String) async {
            guard let context = notificationReaders.removeValue(forKey: paneId) else { return }
            await context.reader.stopPipePane(
                controlClientManager: controlClientManager,
                sessionName: context.sessionName
            )
            logger.debug("Stopped notification reader", metadata: ["paneId": "\(paneId)"])
        }

        // MARK: - Private Methods

        private func forwardData(paneId: String, data: Data) {
            guard let context = streams[paneId] else { return }

            for subscriberId in context.subscriberIds {
                if let subscription = subscriptions[subscriberId] {
                    subscription.onData(data)
                }
            }
        }

        private func forwardDimensionChange(paneId: String, width: Int, height: Int) {
            guard let context = streams[paneId] else { return }

            for subscriberId in context.subscriberIds {
                if
                    let subscription = subscriptions[subscriberId],
                    let callback = subscription.onDimensionChange {
                    callback(width, height)
                }
            }
        }

        private func forwardTitleChange(paneId: String, title: String, excludingSubscription: UUID) {
            guard let context = streams[paneId] else { return }

            for subscriberId in context.subscriberIds where subscriberId != excludingSubscription {
                if
                    let subscription = subscriptions[subscriberId],
                    let callback = subscription.onTitleChange {
                    callback(title)
                }
            }
        }

        private func forwardNotification(
            paneId: String,
            notification: TerminalStreamMessage.TerminalNotification
        ) {
            // Call global handler unconditionally — notification-only readers
            // don't have a stream context but still need desktop notifications
            onNotification?(paneId, notification)

            // Forward to per-subscriber handlers (only if a full stream exists)
            guard let context = streams[paneId] else { return }
            for subscriberId in context.subscriberIds {
                if
                    let subscription = subscriptions[subscriberId],
                    let callback = subscription.onNotification {
                    callback(notification)
                }
            }
        }
    }
#endif
