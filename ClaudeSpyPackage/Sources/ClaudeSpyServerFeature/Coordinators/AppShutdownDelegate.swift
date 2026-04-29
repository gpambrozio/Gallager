#if os(macOS)
    import AppKit
    import Foundation
    import Logging

    /// NSApplicationDelegate that runs async cleanup before the app terminates.
    ///
    /// AppKit calls `applicationShouldTerminate(_:)` for both interactive Quit
    /// and AppleScript "quit". We reply `.terminateLater`, run the registered
    /// async cleanup with a hard timeout, then call
    /// `NSApplication.reply(toApplicationShouldTerminate:)` so AppKit proceeds.
    ///
    /// Without this, tmux is left with `cat > FIFO` subprocesses whose reader
    /// (us) has just disappeared. The source pane then stalls until `cat`
    /// notices the broken pipe on its next write — which can be a long time
    /// for an idle pane. Wiring this hook lets us send `pipe-pane -t` to tmux
    /// before exit, which terminates the `cat` subprocesses immediately.
    @MainActor
    final public class AppShutdownDelegate: NSObject, NSApplicationDelegate {
        /// Async cleanup to run before the app terminates. Set this once at
        /// startup; if `nil` at quit time, AppKit terminates immediately.
        public var onShouldTerminate: (@MainActor () async -> Void)?

        /// Maximum time to wait for cleanup before forcing termination.
        public let shutdownTimeout: Duration

        private var didReply = false
        private let logger = Logger(label: "com.claudespy.shutdown")

        // `@NSApplicationDelegateAdaptor` instantiates via Objective-C `init()`,
        // which doesn't see Swift default arguments — so we need an explicit
        // zero-arg initializer.
        public override init() {
            self.shutdownTimeout = .seconds(3)
            super.init()
        }

        public init(shutdownTimeout: Duration) {
            self.shutdownTimeout = shutdownTimeout
            super.init()
        }

        public func applicationShouldTerminate(
            _: NSApplication
        ) -> NSApplication.TerminateReply {
            guard let cleanup = onShouldTerminate else { return .terminateNow }

            didReply = false
            logger.info("applicationShouldTerminate: running async cleanup")
            // Race the cleanup against a hard deadline. Whichever finishes
            // first calls `replyOnce()`; the second call is a no-op. This
            // guarantees the app eventually terminates even if a tmux IPC
            // hangs longer than the per-command timeout allows for.
            let timeout = shutdownTimeout
            Task { @MainActor in
                await cleanup()
                self.replyOnce()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !self.didReply {
                    self.logger.warning("Shutdown cleanup exceeded \(timeout); terminating anyway")
                }
                self.replyOnce()
            }
            return .terminateLater
        }

        private func replyOnce() {
            guard !didReply else { return }
            didReply = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
#endif
