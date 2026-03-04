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

        /// Global notification handler — called for any notification on any pane,
        /// regardless of which subscribers are active. Used by macOS to show desktop notifications.
        public var onNotification: (@MainActor (String, TerminalStreamMessage.TerminalNotification) -> Void)?

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
                await context.stream.disconnect()
                streams.removeValue(forKey: paneId)

                logger.info("Disconnected stream (no subscribers)", metadata: [
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
            logger.info("Disconnected all streams")
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
            guard let context = streams[paneId] else { return }

            // Call global handler (macOS desktop notification)
            onNotification?(paneId, notification)

            // Forward to per-subscriber handlers
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
