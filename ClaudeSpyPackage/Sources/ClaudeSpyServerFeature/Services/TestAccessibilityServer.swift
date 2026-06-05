#if canImport(AppKit)
    #if DEBUG
        import AppKit
        import ClaudeSpyNetworking
        import Foundation
        import Network

        /// Minimal HTTP server for E2E test operations that require in-process access.
        ///
        /// Most UI interaction has moved to external Accessibility APIs (MacOSAccessibility).
        /// This server only handles:
        /// - `/set-sidebar-width` — NSSplitView.setPosition() requires in-process access
        /// - `/unpair` — Posts a NotificationCenter notification inside the app
        /// - `/reconnect` — Updates optional `VersionCompatibility` overrides and kicks a reconnect
        ///
        /// Only active when the app is launched with `--e2e-test`.
        @MainActor
        final public class TestAccessibilityServer {
            private var listener: NWListener?
            private static var instance: TestAccessibilityServer?

            /// Start the server if running in E2E test mode.
            /// Reads `--test-accessibility-port <port>` from launch arguments (default: 18081).
            public static func startIfNeeded() {
                guard CommandLine.arguments.contains("--e2e-test") else { return }

                var port: UInt16 = 18_081
                if
                    let idx = CommandLine.arguments.firstIndex(of: "--test-accessibility-port"),
                    idx + 1 < CommandLine.arguments.count,
                    let parsed = UInt16(CommandLine.arguments[idx + 1]) {
                    port = parsed
                }

                // Probe Local Network access in the background. This both records
                // the result for the `/local-network-status` endpoint AND triggers
                // the system Local Network prompt on a machine that hasn't decided
                // yet — which the E2E orchestrator's preflight relies on.
                LocalNetworkProbe.runAndCache()

                let server = TestAccessibilityServer()
                do {
                    try server.start(port: port)
                    instance = server
                } catch {
                    print("[TestAccessibilityServer-Mac] Failed to start: \(error)")
                }
            }

            private func start(port: UInt16 = 18_081) throws {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    print("[TestAccessibilityServer-Mac] Invalid port: \(port)")
                    return
                }
                listener = try NWListener(using: params, on: nwPort)
                listener?.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        print("[TestAccessibilityServer-Mac] Listener failed: \(error)")
                    }
                }
                listener?.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener?.start(queue: .main)
                print("[TestAccessibilityServer-Mac] Listening on port \(port)")
            }

            private nonisolated func handleConnection(_ connection: NWConnection) {
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.receiveRequest(connection)
                    case .failed:
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: .main)
            }

            private nonisolated func receiveRequest(_ connection: NWConnection) {
                receiveFullRequest(connection, accumulated: Data())
            }

            /// Read until the full HTTP request (headers + Content-Length body) has
            /// arrived. NWConnection's `receive` may return only the headers on the
            /// first call when the kernel happens to flush them separately from the
            /// body — `/drop-files` carries its payload in the body, so dispatching
            /// before the body arrives drops the request as `bad_request`.
            private nonisolated func receiveFullRequest(
                _ connection: NWConnection,
                accumulated: Data
            ) {
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 65_536
                ) { [weak self] data, _, isComplete, error in
                    var current = accumulated
                    if let data { current.append(data) }

                    guard error == nil, !current.isEmpty else {
                        connection.cancel()
                        return
                    }

                    if Self.requestIsComplete(current) || isComplete {
                        self?.dispatchRequest(connection, raw: current)
                    } else {
                        self?.receiveFullRequest(connection, accumulated: current)
                    }
                }
            }

            /// Returns true once `data` contains a full HTTP request: headers
            /// terminated by `\r\n\r\n`, plus at least `Content-Length` body bytes
            /// after that boundary. Requests without a `Content-Length` header are
            /// considered complete as soon as the headers are received.
            private nonisolated static func requestIsComplete(_ data: Data) -> Bool {
                guard
                    let request = String(data: data, encoding: .utf8),
                    let range = request.range(of: "\r\n\r\n") else {
                    return false
                }
                let headers = request[..<range.lowerBound]
                let body = request[range.upperBound...]
                return body.utf8.count >= contentLength(from: headers)
            }

            /// Pull `Content-Length` out of an HTTP header block. Case-insensitive
            /// match; returns 0 when the header is absent.
            private nonisolated static func contentLength(from headers: Substring) -> Int {
                for line in headers.split(separator: "\r\n", omittingEmptySubsequences: false) {
                    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard
                        parts.count == 2,
                        parts[0].lowercased() == "content-length" else { continue }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
                return 0
            }

            private nonisolated func dispatchRequest(_ connection: NWConnection, raw: Data) {
                guard let request = String(data: raw, encoding: .utf8) else {
                    connection.cancel()
                    return
                }

                if request.hasPrefix("GET /healthz") {
                    // Liveness probe used by the E2E orchestrator to confirm the app
                    // finished launching (see MacOSDriver.launchApp). Any HTTP reply
                    // proves the listener is up.
                    let response = Data(
                        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                            .utf8
                    )
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else if request.hasPrefix("GET /local-network-status") {
                    // Reports this app's macOS Local Network access ("granted" /
                    // "denied" / "pending"), used by the E2E orchestrator's preflight
                    // to fail fast before running scenarios when access hasn't been
                    // granted yet. See LocalNetworkProbe.
                    let body = LocalNetworkProbe.lastStatus?.rawValue ?? "pending"
                    let response = Data(
                        "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                            .utf8
                    )
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else if request.hasPrefix("POST /unpair") {
                    Task { @MainActor in
                        NotificationCenter.default.post(
                            name: .init("com.claudespy.e2e.unpairViewer"), object: nil
                        )
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                                .utf8
                        )
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else if request.hasPrefix("POST /reconnect") {
                    // Optional query params: appVersion, minRequiredPartnerVersion.
                    // A present-but-empty value clears the override (back to bundle
                    // version); an absent param leaves the current override alone.
                    let appVersion = Self.extractQueryParam(from: request, key: "appVersion")
                    let minRequired = Self.extractQueryParam(
                        from: request, key: "minRequiredPartnerVersion"
                    )
                    Task { @MainActor in
                        if let appVersion {
                            VersionCompatibility.appVersionOverride = appVersion.isEmpty ? nil : appVersion
                        }
                        if let minRequired {
                            VersionCompatibility.minRequiredPartnerVersionOverride =
                                minRequired.isEmpty ? nil : minRequired
                        }
                        NotificationCenter.default.post(
                            name: .init("com.claudespy.e2e.reconnectViewers"), object: nil
                        )
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                                .utf8
                        )
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else if request.hasPrefix("POST /drop-files") {
                    // Simulates a Finder file drop on a specific terminal
                    // pane. Body is `paneId\npath1\npath2\n...` —
                    // newline-separated to keep the wire format trivial
                    // for the E2E orchestrator without re-introducing
                    // JSON parsing in this tiny test server.
                    let body = Self.extractRequestBody(from: request)
                    Task { @MainActor [weak self] in
                        let outcome = self?.handleDropFiles(rawBody: body) ?? "no_server"
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Length: \(outcome.utf8.count)\r\nConnection: close\r\n\r\n\(outcome)"
                                .utf8
                        )
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else if request.hasPrefix("POST /set-sidebar-width") {
                    let widthStr = Self.extractQueryParam(from: request, key: "width")
                    Task { @MainActor [weak self] in
                        let width = Int(widthStr ?? "") ?? 0
                        var found = false
                        if width > 0 {
                            for window in NSApp.windows
                                where window.isVisible && window.level == .normal {
                                if
                                    let contentView = window.contentView,
                                    let splitView = self?.findSplitView(in: contentView) {
                                    splitView.setPosition(CGFloat(width), ofDividerAt: 0)
                                    found = true
                                    break
                                }
                            }
                        }
                        let body = found ? "ok" : "not_found"
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                                .utf8
                        )
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else {
                    let response = Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }

            /// Extract a query parameter from a raw HTTP request line.
            /// e.g. "POST /set-sidebar-width?width=250 HTTP/1.1\r\n..." → "250"
            private nonisolated static func extractQueryParam(from request: String, key: String) -> String? {
                // Get the first line (request line)
                guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
                // Find the query string after '?'
                guard let questionMark = requestLine.firstIndex(of: "?") else { return nil }
                let afterQuestion = requestLine[requestLine.index(after: questionMark)...]
                // Remove the " HTTP/1.1" suffix
                let queryString = afterQuestion.components(separatedBy: " ").first ?? String(afterQuestion)
                // Parse key=value pairs
                for pair in queryString.components(separatedBy: "&") {
                    let parts = pair.components(separatedBy: "=")
                    guard parts.count == 2, parts[0] == key else { continue }
                    // Decode URL encoding: + → space, then percent-decode
                    return parts[1]
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? parts[1]
                }
                return nil
            }

            /// Recursively search the view hierarchy for an NSSplitView.
            private func findSplitView(in view: NSView) -> NSSplitView? {
                if let splitView = view as? NSSplitView {
                    return splitView
                }
                for subview in view.subviews {
                    if let found = findSplitView(in: subview) {
                        return found
                    }
                }
                return nil
            }

            /// Extract the body of an HTTP request from a raw request string.
            /// Splits on "\r\n\r\n" — the standard HTTP separator between
            /// headers and body. Returns the empty string if no body is
            /// present (e.g., a header-only request was received).
            private nonisolated static func extractRequestBody(from request: String) -> String {
                guard let range = request.range(of: "\r\n\r\n") else { return "" }
                return String(request[range.upperBound...])
            }

            /// Resolve a `paneId\npath1\npath2…` body into a real file drop
            /// on the matching `InteractiveTerminalView`. Returns the
            /// HTTP response body — `ok`, `not_found`, or `bad_request`.
            private func handleDropFiles(rawBody: String) -> String {
                let lines = rawBody
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
                guard lines.count >= 2 else { return "bad_request" }

                let paneId = lines[0]
                let paths = lines.dropFirst().filter { !$0.isEmpty }
                guard !paths.isEmpty else { return "bad_request" }

                guard let terminal = findInteractiveTerminal(forPaneId: paneId) else {
                    return "not_found"
                }
                let urls = paths.map { URL(fileURLWithPath: $0) }
                terminal.simulateFileDrop(urls)
                return "ok"
            }

            /// Walks all visible windows looking for an
            /// `InteractiveTerminalView` whose accessibility identifier
            /// matches `terminal-<paneId>`. Returns the first match.
            private func findInteractiveTerminal(forPaneId paneId: String) -> InteractiveTerminalView? {
                let identifier = "terminal-\(paneId)"
                for window in NSApp.windows where window.isVisible {
                    if
                        let contentView = window.contentView,
                        let match = findTerminalView(in: contentView, identifier: identifier) {
                        return match
                    }
                }
                return nil
            }

            private func findTerminalView(
                in view: NSView,
                identifier: String
            ) -> InteractiveTerminalView? {
                if
                    let terminal = view as? InteractiveTerminalView,
                    terminal.terminalAccessibilityIdentifier == identifier {
                    return terminal
                }
                for subview in view.subviews {
                    if let match = findTerminalView(in: subview, identifier: identifier) {
                        return match
                    }
                }
                return nil
            }
        }
    #endif
#endif
