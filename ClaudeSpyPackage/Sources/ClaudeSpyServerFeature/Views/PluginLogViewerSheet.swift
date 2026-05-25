#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import ClaudeSpyPluginRuntime
    import Dependencies
    import Foundation
    import SwiftUI

    /// Sheet that displays one plugin's sidecar log file (Spec §17.5).
    ///
    /// Renders the last `maxBytesLoaded` bytes of `sidecar.log` in a
    /// monospaced ScrollView with three actions:
    ///   - Refresh / Tail: re-read the file (Tail starts a 1s repeat task)
    ///   - Show in Finder: reveal the log file
    ///   - Copy All: copy the loaded buffer to the clipboard
    ///   - Clear: truncate the log file after confirmation
    ///
    /// No syntax highlighting, no filtering, no level toggles — Spec §17.5
    /// keeps the v1 viewer deliberately simple.
    public struct PluginLogViewerSheet: View {
        public let pluginID: String
        public let displayName: String

        @Environment(\.pluginManager) private var pluginManager
        @Environment(\.dismiss) private var dismiss
        @Dependency(ClipboardClient.self) private var clipboard

        // MARK: - Local state

        @State private var logText = ""
        @State private var isTailing = false
        @State private var showingClearConfirmation = false
        @State private var loadError: String?

        /// Polled refresh task started when the user taps Tail. Stored so
        /// we can stop it on dismiss or when the user taps Tail again.
        @State private var tailTask: Task<Void, Never>?

        /// Max bytes loaded from the tail of the log file. Beyond this the
        /// head is truncated with an ellipsis (Spec §17.5).
        private static let maxBytesLoaded = 256 * 1_024

        public init(pluginID: String, displayName: String) {
            self.pluginID = pluginID
            self.displayName = displayName
        }

        public var body: some View {
            VStack(spacing: 0) {
                titleBar
                Divider()
                actionBar
                Divider()
                logContent
                Divider()
                footerBar
            }
            .frame(minWidth: 600, minHeight: 400)
            .task {
                await reload()
            }
            .onDisappear {
                tailTask?.cancel()
                tailTask = nil
            }
            .confirmationDialog(
                "Clear the log file?",
                isPresented: $showingClearConfirmation
            ) {
                Button("Clear", role: .destructive) {
                    Task { await clearLog() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes the captured sidecar log for \(displayName).")
            }
        }

        // MARK: - Sections

        private var titleBar: some View {
            HStack {
                Text("Logs: \(displayName)")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await toggleTail() }
                } label: {
                    Label(
                        isTailing ? "Stop Tail" : "Tail",
                        symbol: isTailing ? .stopCircle : .arrowDownCircle
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", symbol: .arrowClockwise)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        private var actionBar: some View {
            HStack {
                Button {
                    showInFinder()
                } label: {
                    Label("Show in Finder", symbol: .folder)
                }
                .disabled(logFileURL == nil)

                Button {
                    copyAll()
                } label: {
                    Label("Copy All", symbol: .docOnClipboard)
                }
                .disabled(logText.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear", symbol: .trash)
                }
                .disabled(logFileURL == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }

        @ViewBuilder
        private var logContent: some View {
            if let error = loadError {
                VStack {
                    Spacer()
                    Label(error, symbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if logText.isEmpty {
                VStack {
                    Spacer()
                    Text("Log file is empty.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(logText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }

        private var footerBar: some View {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        // MARK: - File location

        private var logFileURL: URL? {
            guard let manager = pluginManager else { return nil }
            return manager.logsDir(pluginID: pluginID)
                .appendingPathComponent("sidecar.log")
        }

        // MARK: - Actions

        private func reload() async {
            loadError = nil
            guard let url = logFileURL else {
                loadError = "Plugin runtime not available."
                return
            }
            do {
                logText = try readTail(of: url, maxBytes: Self.maxBytesLoaded)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                logText = ""
            } catch {
                loadError = "Could not read log file: \(error.localizedDescription)"
            }
        }

        /// Read up to `maxBytes` from the end of `url`. Larger files have
        /// their head truncated with a marker line so the user can tell
        /// the buffer doesn't represent the entire log.
        private func readTail(of url: URL, maxBytes: Int) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let endOffset = try handle.seekToEnd()
            if endOffset <= UInt64(maxBytes) {
                try handle.seek(toOffset: 0)
                let data = try handle.readToEnd() ?? Data()
                return String(data: data, encoding: .utf8) ?? ""
            }
            let startOffset = endOffset - UInt64(maxBytes)
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            let body = String(data: data, encoding: .utf8) ?? ""
            // Drop any partial first line so the buffer always starts on
            // a clean line boundary.
            let cleaned: String
            if let nl = body.firstIndex(of: "\n") {
                cleaned = String(body[body.index(after: nl)...])
            } else {
                cleaned = body
            }
            return "[… truncated \(endOffset - UInt64(maxBytes)) earlier bytes …]\n" + cleaned
        }

        private func toggleTail() async {
            if isTailing {
                tailTask?.cancel()
                tailTask = nil
                isTailing = false
            } else {
                isTailing = true
                tailTask = Task { [reloadAction = { @MainActor in await reload() }] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { break }
                        await reloadAction()
                    }
                }
            }
        }

        private func showInFinder() {
            guard let url = logFileURL else { return }
            // Reveal even when the file doesn't exist yet; NSWorkspace's
            // single-URL `selectFile` requires existence, so fall back to
            // opening the parent dir.
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
        }

        private func copyAll() {
            clipboard.setString(logText)
        }

        private func clearLog() async {
            guard let url = logFileURL else { return }
            do {
                // Truncate by writing an empty file in place — preserves
                // the inode the sidecar's open file handle still points at.
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                await reload()
            } catch {
                loadError = "Failed to clear log: \(error.localizedDescription)"
            }
        }
    }
#endif
