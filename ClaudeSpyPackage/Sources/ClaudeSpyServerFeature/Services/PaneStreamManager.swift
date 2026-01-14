import Foundation

/// A subscription to a shared PaneStream.
///
/// Holds information about the subscription and provides access to stream state.
/// The subscription is automatically cleaned up when deallocated.
@MainActor
final public class PaneStreamSubscription: Identifiable {
    public let id: String
    public let target: String

    private weak var manager: PaneStreamManager?

    /// Current connection state of the underlying stream
    public var state: StreamState {
        manager?.getStreamState(for: target) ?? .disconnected
    }

    /// Current width in columns
    public var width: Int {
        manager?.getStreamWidth(for: target) ?? 80
    }

    /// Current height in rows
    public var height: Int {
        manager?.getStreamHeight(for: target) ?? 24
    }

    /// Number of scrollback lines
    public var scrollbackLines: Int {
        manager?.getScrollbackLines(for: target) ?? 0
    }

    init(id: String, target: String, manager: PaneStreamManager) {
        self.id = id
        self.target = target
        self.manager = manager
    }

    /// Manually unsubscribe from the stream.
    /// This is also called automatically when the subscription is deallocated.
    public func unsubscribe() async {
        await manager?.unsubscribe(self)
    }

    /// Update dimensions (called when pane dimensions change externally)
    public func updateDimensions(width: Int, height: Int) {
        manager?.updateDimensions(for: target, width: width, height: height)
    }
}

/// Manages shared access to PaneStreams.
///
/// Multiple consumers (Mac mirror windows, iOS streams) can subscribe to the same
/// pane and receive data simultaneously. The underlying PaneStream is only created
/// when the first subscriber connects and only disconnected when the last subscriber
/// leaves.
@Observable
@MainActor
final public class PaneStreamManager {
    // MARK: - Types

    /// Callbacks for a subscriber
    struct SubscriberCallbacks {
        let onData: @MainActor (Data) -> Void
        let onDimensionChange: (@MainActor (Int, Int) -> Void)?
    }

    /// A managed stream with its subscribers
    private struct ManagedStream {
        let paneStream: PaneStream
        var subscribers: [String: SubscriberCallbacks]
    }

    // MARK: - Properties

    private let tmuxService: TmuxService

    /// Active streams keyed by pane target
    private var streams: [String: ManagedStream] = [:]

    // MARK: - Initialization

    public init(tmuxService: TmuxService) {
        self.tmuxService = tmuxService
    }

    // MARK: - Subscription Management

    /// Subscribe to a pane stream.
    ///
    /// If this is the first subscriber for this pane, a new PaneStream is created
    /// and connected. Otherwise, the existing stream is reused.
    ///
    /// - Parameters:
    ///   - target: The pane target (e.g., "session:window.pane")
    ///   - onData: Callback for incoming terminal data
    ///   - onDimensionChange: Optional callback for dimension changes
    ///   - sendInitialContent: Whether to send initial content when joining an existing stream.
    ///     Set to false if the subscriber handles initial content separately. Default is true.
    /// - Returns: A subscription that can be used to unsubscribe
    public func subscribe(
        target: String,
        onData: @escaping @MainActor (Data) -> Void,
        onDimensionChange: (@MainActor (Int, Int) -> Void)? = nil,
        sendInitialContent: Bool = true
    ) async throws -> PaneStreamSubscription {
        let subscriberId = UUID().uuidString

        if var managed = streams[target] {
            // Existing stream - add subscriber
            managed.subscribers[subscriberId] = SubscriberCallbacks(
                onData: onData,
                onDimensionChange: onDimensionChange
            )
            streams[target] = managed

            // Send current content to new subscriber (unless they handle it themselves)
            if sendInitialContent, managed.paneStream.state == .connected {
                let content = try await tmuxService.capturePaneWithPositioning(target)
                onData(content)
            }
        } else {
            // New stream - create and connect
            let paneStream = PaneStream(target: target, tmuxService: tmuxService)

            // Set up data forwarding to all subscribers
            paneStream.onData = { [weak self] data in
                self?.forwardData(target: target, data: data)
            }

            // Set up dimension change forwarding
            paneStream.onDimensionChange = { [weak self] width, height in
                self?.forwardDimensionChange(target: target, width: width, height: height)
            }

            // Store before connecting (so callbacks work)
            streams[target] = ManagedStream(
                paneStream: paneStream,
                subscribers: [subscriberId: SubscriberCallbacks(
                    onData: onData,
                    onDimensionChange: onDimensionChange
                )]
            )

            // Connect
            try await paneStream.connect()
        }

        return PaneStreamSubscription(id: subscriberId, target: target, manager: self)
    }

    /// Unsubscribe from a pane stream.
    ///
    /// If this was the last subscriber, the underlying PaneStream is disconnected.
    ///
    /// - Parameter subscription: The subscription to remove
    public func unsubscribe(_ subscription: PaneStreamSubscription) async {
        guard var managed = streams[subscription.target] else { return }

        managed.subscribers.removeValue(forKey: subscription.id)

        if managed.subscribers.isEmpty {
            // Last subscriber - disconnect and remove
            await managed.paneStream.disconnect()
            streams.removeValue(forKey: subscription.target)
        } else {
            streams[subscription.target] = managed
        }
    }

    // MARK: - Stream State Access

    func getStreamState(for target: String) -> StreamState {
        streams[target]?.paneStream.state ?? .disconnected
    }

    func getStreamWidth(for target: String) -> Int {
        streams[target]?.paneStream.width ?? 80
    }

    func getStreamHeight(for target: String) -> Int {
        streams[target]?.paneStream.height ?? 24
    }

    func getScrollbackLines(for target: String) -> Int {
        streams[target]?.paneStream.scrollbackLines ?? 0
    }

    func updateDimensions(for target: String, width: Int, height: Int) {
        streams[target]?.paneStream.updateDimensions(width: width, height: height)
    }

    // MARK: - Private Methods

    private func forwardData(target: String, data: Data) {
        guard let managed = streams[target] else { return }
        for subscriber in managed.subscribers.values {
            subscriber.onData(data)
        }
    }

    private func forwardDimensionChange(target: String, width: Int, height: Int) {
        guard let managed = streams[target] else { return }
        for subscriber in managed.subscribers.values {
            subscriber.onDimensionChange?(width, height)
        }
    }
}
