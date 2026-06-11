#if os(macOS)
    import Foundation

    /// Watches a directory tree under a CODEX_HOME for changes and fires a
    /// debounced callback — `sessions/` so the plugin core can rescan projects
    /// when Codex writes a new rollout, and the CODEX_HOME root itself
    /// (filtered to `config.toml` events) so the core can re-read the
    /// approvals-reviewer posture live.
    ///
    /// Uses an `FSEventStream` (recursive, file-level) on a dedicated serial
    /// queue. Changes are coalesced with a ~500ms trailing debounce so a burst of
    /// rollout writes triggers a single rescan. macOS-only — on Linux the core
    /// falls back to the initial scan + manual refresh.
    ///
    /// Ported from the Claude core's `ClaudeCodeProjectsWatcher`. Not an actor:
    /// `FSEventStream` requires a callback with a C function pointer, so the
    /// bridging context and debounce timer are guarded by an internal lock
    /// instead. The public surface is `Sendable`.
    final class CodexDirectoryWatcher: @unchecked Sendable {
        private let path: String
        private let debounce: DispatchTimeInterval
        private let pathFilter: (@Sendable (String) -> Bool)?
        private let onChange: @Sendable () -> Void

        private let queue = DispatchQueue(label: "com.gallager.codex.directory-watcher")
        private var stream: FSEventStreamRef?
        private var debounceWorkItem: DispatchWorkItem?

        /// - Parameters:
        ///   - path: Directory to watch (e.g. `~/.codex/sessions`). Recursive.
        ///   - debounceMilliseconds: Trailing debounce window; defaults to 500ms.
        ///   - pathFilter: When set, only events whose path passes the filter
        ///     schedule the callback (cheap string check — lets a watch on the
        ///     busy CODEX_HOME root ignore everything but `config.toml`).
        ///     `nil` means every event counts.
        ///   - onChange: Invoked (off the main actor) after the debounce settles.
        init(
            path: String,
            debounceMilliseconds: Int = 500,
            pathFilter: (@Sendable (String) -> Bool)? = nil,
            onChange: @escaping @Sendable () -> Void
        ) {
            self.path = path
            self.debounce = .milliseconds(debounceMilliseconds)
            self.pathFilter = pathFilter
            self.onChange = onChange
        }

        deinit {
            stop()
        }

        /// Starts watching. No-op if already started or the directory is missing.
        func start() {
            queue.sync {
                guard stream == nil else { return }

                var isDirectory: ObjCBool = false
                guard
                    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { return }

                let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
                context.initialize(to: FSEventStreamContext(
                    version: 0,
                    info: Unmanaged.passUnretained(self).toOpaque(),
                    retain: nil,
                    release: nil,
                    copyDescription: nil
                ))
                defer {
                    context.deinitialize(count: 1)
                    context.deallocate()
                }

                let flags = UInt32(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                )

                guard
                    let created = FSEventStreamCreate(
                        kCFAllocatorDefault,
                        Self.callback,
                        context,
                        [path] as CFArray,
                        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                        0.5,
                        flags
                    )
                else { return }

                FSEventStreamSetDispatchQueue(created, queue)
                guard FSEventStreamStart(created) else {
                    FSEventStreamInvalidate(created)
                    FSEventStreamRelease(created)
                    return
                }
                stream = created
            }
        }

        /// Stops watching and tears down the stream + any pending debounce.
        func stop() {
            queue.sync {
                debounceWorkItem?.cancel()
                debounceWorkItem = nil
                guard let stream else { return }
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }

        /// Called on `queue` from the FSEvents callback; schedules a trailing
        /// debounced `onChange` when any event path passes the filter.
        private func handleEvents(paths: [String]) {
            if let pathFilter, !paths.contains(where: pathFilter) { return }
            scheduleDebounced()
        }

        private func scheduleDebounced() {
            debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onChange()
            }
            debounceWorkItem = work
            queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }

        /// FSEvents C callback. `info` is the unretained `self` pointer;
        /// `eventPaths` is a `char **` (we don't pass `kFSEventStreamCreateFlagUseCFTypes`).
        private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<CodexDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let raw = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
            var paths: [String] = []
            paths.reserveCapacity(numEvents)
            for index in 0..<numEvents {
                if let cString = raw[index] {
                    paths.append(String(cString: cString))
                }
            }
            watcher.handleEvents(paths: paths)
        }
    }
#endif
