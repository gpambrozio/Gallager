#if canImport(AppKit)
    #if DEBUG
        import Foundation
        import Network

        /// Result of probing this process's macOS Local Network access.
        public enum LocalNetworkAccessStatus: String, Sendable {
            /// Access is allowed (or at least wasn't denied).
            case granted
            /// The system denied a local-network operation — the user hasn't allowed it.
            case denied
            /// Couldn't determine within the timeout (e.g. no usable network).
            case unknown
        }

        /// Probes whether this app has macOS 15+ Local Network access.
        ///
        /// Local network privacy gates *outgoing* local-network operations — making
        /// an outgoing connection to a local-network address, resolving a `.local`
        /// name, Bonjour — but NOT merely listening for inbound connections
        /// (see Apple's TN3179). Gallager hits it during normal use, e.g. when
        /// `PaneStreamManager` reads `ProcessInfo.hostName`, which resolves the
        /// machine's `.local` name.
        ///
        /// This probe attempts to connect a UDP socket to guaranteed local-network
        /// addresses (the IPv4 broadcast address and an mDNS multicast address) and
        /// inspects the connection path:
        ///   - `.waiting` with `unsatisfiedReason == .localNetworkDenied` → denied
        ///   - `.ready` (path satisfied) → granted
        ///
        /// Running it also *triggers* the system Local Network prompt on a machine
        /// that hasn't decided yet — which the E2E orchestrator's preflight relies on
        /// to fail fast and let an operator grant access before re-running.
        ///
        /// DEBUG-only: this is test-harness support, not shipping behaviour.
        public enum LocalNetworkProbe {
            /// Guaranteed local-network destinations per TN3179: the IPv4 broadcast
            /// address and an IPv4 multicast address are always "local network"
            /// regardless of the machine's interface configuration.
            private static let probeAddresses = ["255.255.255.255", "224.0.0.251"]

            private static let stateLock = NSLock()
            private nonisolated(unsafe) static var cachedStatus: LocalNetworkAccessStatus?

            /// The most recent probe result, or `nil` while the probe is still running.
            public static var lastStatus: LocalNetworkAccessStatus? {
                stateLock.withLock { cachedStatus }
            }

            /// Run the probe once in the background and cache the result for
            /// `lastStatus`. Safe to call at app startup.
            public static func runAndCache() {
                Task.detached(priority: .utility) {
                    let result = await check()
                    stateLock.withLock { cachedStatus = result }
                }
            }

            /// Probe every candidate address concurrently. A single `denied` wins
            /// (the grant is process-wide, so any denial is authoritative); otherwise
            /// `granted` if any probe reached the network, else `unknown`.
            public static func check(timeout: TimeInterval = 4) async -> LocalNetworkAccessStatus {
                await withTaskGroup(of: LocalNetworkAccessStatus.self) { group in
                    for address in probeAddresses {
                        group.addTask { await probe(address: address, timeout: timeout) }
                    }
                    var sawGranted = false
                    for await result in group {
                        switch result {
                        case .denied:
                            group.cancelAll()
                            return .denied
                        case .granted:
                            sawGranted = true
                        case .unknown:
                            break
                        }
                    }
                    return sawGranted ? .granted : .unknown
                }
            }

            private static func probe(address: String, timeout: TimeInterval) async -> LocalNetworkAccessStatus {
                let connection = NWConnection(host: NWEndpoint.Host(address), port: 9, using: .udp)
                let box = ProbeResumeBox(connection: connection)
                return await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<LocalNetworkAccessStatus, Never>) in
                        box.setContinuation(continuation)
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                box.finish(.granted)
                            case .waiting:
                                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                                    box.finish(.denied)
                                }
                            // Other waiting reasons (e.g. no route) are transient —
                            // let the timeout decide.
                            case .failed:
                                // Reached the stack but failed for a non-privacy reason
                                // (nothing is listening) → access wasn't the blocker.
                                box.finish(.granted)
                            case .cancelled:
                                box.finish(.unknown)
                            default:
                                break
                            }
                        }
                        connection.start(queue: .global())
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            box.finish(.unknown)
                        }
                    }
                } onCancel: {
                    box.finish(.unknown)
                }
            }
        }

        /// Resumes a probe's continuation exactly once and tears down the connection,
        /// tolerating either ordering of `setContinuation`/`finish`.
        final private class ProbeResumeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            private var continuation: CheckedContinuation<LocalNetworkAccessStatus, Never>?
            private var pending: LocalNetworkAccessStatus?
            private let connection: NWConnection

            init(connection: NWConnection) {
                self.connection = connection
            }

            func setContinuation(_ continuation: CheckedContinuation<LocalNetworkAccessStatus, Never>) {
                lock.lock()
                defer { lock.unlock() }
                if let pending {
                    continuation.resume(returning: pending)
                } else {
                    self.continuation = continuation
                }
            }

            func finish(_ status: LocalNetworkAccessStatus) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                if let continuation {
                    self.continuation = nil
                    continuation.resume(returning: status)
                } else {
                    pending = status
                }
            }
        }
    #endif
#endif
