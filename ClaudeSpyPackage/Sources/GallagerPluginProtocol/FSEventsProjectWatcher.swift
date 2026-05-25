#if os(macOS)
    import CoreServices
    import Foundation
    import Logging

    // MARK: - FSEventsProjectWatcher

    /// Watches one or more directories (typically `~/.claude/projects/` or
    /// `~/.codex/sessions/`) for any change, debounces by `debounce`
    /// (default 250 ms), then fires `onChange()` so the sidecar can re-scan
    /// + push a fresh `set_projects`.
    ///
    /// Agent-blind: lives in `GallagerPluginProtocol` so both the Claude and
    /// Codex sidecars (and any future plugin) can consume the same type
    /// without copy-paste.
    ///
    /// The FSEvents C API hands us a C callback on a dispatch queue. We
    /// route the change notification onto the actor and start a debounce
    /// timer task; subsequent changes within the debounce window cancel
    /// and replace the pending task. Once the timer settles, the
    /// `onChange` closure runs exactly once for that burst of events.
    ///
    /// macOS-only — FSEvents is part of CoreServices and unavailable on
    /// Linux. The Linux SPM graph still compiles because the type is
    /// gated by `#if os(macOS)`.
    public actor FSEventsProjectWatcher {
        // MARK: - State

        private let paths: [URL]
        private let debounce: Duration
        private let logger: Logger
        private let dispatchQueueLabel: String
        private var stream: FSEventStreamRef?
        private var pendingTask: Task<Void, Never>?
        private var onChange: (@Sendable () async -> Void)?
        private var callbackBox: CallbackBox?

        // MARK: - Init

        public init(
            paths: [URL],
            debounce: Duration = .milliseconds(250),
            dispatchQueueLabel: String = "gallager.plugin.fsevents",
            logger: Logger
        ) {
            self.paths = paths
            self.debounce = debounce
            self.dispatchQueueLabel = dispatchQueueLabel
            self.logger = logger
        }

        // MARK: - Lifecycle

        /// Start the FSEvents stream. `onChange` runs on a detached task
        /// after the debounce window elapses with no further events. Throws
        /// when the stream can't be created (typically a permissions issue
        /// on the watched path).
        public func start(onChange: @escaping @Sendable () async -> Void) async throws {
            guard stream == nil else { return }
            self.onChange = onChange

            // FSEvents wants C string paths in a CFArray. Filter to
            // directories that actually exist so the kernel doesn't refuse
            // the stream over a missing root.
            let existing = paths.filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    && isDir.boolValue
            }
            guard !existing.isEmpty else {
                logger.info("fsevents: no existing paths to watch — sidecar will rely on manual refresh")
                return
            }

            let cfPaths = existing.map { $0.path as CFString } as CFArray
            let box = CallbackBox(watcher: self)
            callbackBox = box
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
            guard
                let createdStream = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    fsEventsCallback,
                    &context,
                    cfPaths,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    /* latency */ 0,
                    flags
                ) else {
                throw FSEventsWatcherError.streamCreationFailed
            }

            FSEventStreamSetDispatchQueue(
                createdStream,
                DispatchQueue(label: dispatchQueueLabel)
            )
            guard FSEventStreamStart(createdStream) else {
                FSEventStreamInvalidate(createdStream)
                FSEventStreamRelease(createdStream)
                throw FSEventsWatcherError.streamStartFailed
            }
            stream = createdStream
            let joined = existing.map(\.path).joined(separator: ", ")
            logger.info("fsevents: watching \(joined)")
        }

        /// Stop the FSEvents stream and cancel any pending debounce.
        public func stop() async {
            pendingTask?.cancel()
            pendingTask = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            callbackBox = nil
            onChange = nil
        }

        // MARK: - Internal

        /// Called by the C trampoline whenever FSEvents reports activity.
        /// Cancels any in-flight debounce and schedules a fresh one.
        fileprivate func didReceiveEvents() {
            pendingTask?.cancel()
            let debounce = debounce
            let onChange = onChange
            pendingTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await onChange?()
                await self?.clearPending()
            }
        }

        private func clearPending() {
            pendingTask = nil
        }
    }

    // MARK: - CallbackBox

    /// `FSEventStreamContext.info` is an opaque pointer the C callback
    /// receives on every fire. We pass an instance of this class through it
    /// so the trampoline can find its way back onto the actor without
    /// risking lifetime issues with `Unmanaged.passUnretained` on the
    /// actor itself.
    final private class CallbackBox {
        weak var watcher: FSEventsProjectWatcher?

        init(watcher: FSEventsProjectWatcher) {
            self.watcher = watcher
        }
    }

    // MARK: - C callback

    /// FSEvents C callback. Re-enters the actor to bump the debounce.
    private func fsEventsCallback(
        _: ConstFSEventStreamRef,
        _ info: UnsafeMutableRawPointer?,
        _: Int,
        _: UnsafeMutableRawPointer,
        _: UnsafePointer<FSEventStreamEventFlags>,
        _: UnsafePointer<FSEventStreamEventId>
    ) {
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let watcher = box.watcher
        Task {
            await watcher?.didReceiveEvents()
        }
    }

    // MARK: - FSEventsWatcherError

    public enum FSEventsWatcherError: Error, Sendable {
        case streamCreationFailed
        case streamStartFailed
    }
#endif
