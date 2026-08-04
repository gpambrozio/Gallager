#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Foundation
    import UIKit
    import UserNotifications

    /// Executes notification action taps (issue #710): answering a permission
    /// request (Yes / Always / No) or an agent question straight from the
    /// notification, without opening the app.
    ///
    /// The decision logic lives in the pure, unit-tested
    /// `NotificationActionPlanner`; this service is the thin executor that
    /// resolves a relay connection (reusing the app's live one, or spinning up
    /// a short-lived one when the app was cold-launched into the action
    /// handler), submits the structured `AgentResponse`, and drives the
    /// question-by-question follow-up notifications. Multi-question progress
    /// rides each follow-up notification's `userInfo`, so the flow survives
    /// app relaunches with no local storage.
    @MainActor
    public final class NotificationActionService {
        public static let shared = NotificationActionService()

        private let logger = Logger(label: "com.claudespy.notificationaction")

        /// The app's live connection manager, registered by `ContentView` so
        /// action taps reuse existing sockets. `weak` so the service never
        /// extends UI lifetime; when absent, a temporary manager is created.
        public weak var connectionManager: ViewerConnectionManager?

        /// How long to wait for the E2EE handshake before giving up.
        private static let connectTimeout: TimeInterval = 12

        private init() { }

        // MARK: - Category registration

        /// Registers the static permission categories. Merging (rather than
        /// replacing) keeps dynamically-registered question categories from
        /// pending notifications functional across app launches.
        public func registerBaseCategories() async {
            await NotificationActionCategories.registerMerging(
                NotificationActionCategories.permissionCategories
            )
        }

        // MARK: - Action handling

        /// Handles an action-button tap. Returns `false` when the response is
        /// not an action this service owns (default tap, dismiss, or a
        /// notification with no action context) so the caller falls back to
        /// the regular deep-link handling.
        public func handle(_ response: UNNotificationResponse) async -> Bool {
            let userInfo = response.notification.request.content.userInfo
            guard let context = decode(
                NotificationActionContext.self,
                from: userInfo[NotificationUserInfoKey.actionContext]
            ) else { return false }

            let progress = decode(
                NotificationActionProgress.self,
                from: userInfo[NotificationUserInfoKey.actionProgress]
            )
            return await performAction(
                context: context,
                progress: progress,
                actionIdentifier: response.actionIdentifier,
                userText: (response as? UNTextInputNotificationResponse)?.userText,
                pairId: userInfo["pairId"] as? String,
                paneId: userInfo["paneId"] as? String,
                originalTitle: response.notification.request.content.title
            )
        }

        /// The `UNNotificationResponse`-free core of `handle`, so the E2E
        /// harness (which cannot construct a `UNNotificationResponse`) can
        /// drive the exact same path. Returns `false` when the identifier is
        /// not one of ours.
        func performAction(
            context: NotificationActionContext,
            progress: NotificationActionProgress?,
            actionIdentifier: String,
            userText: String?,
            pairId: String?,
            paneId: String?,
            originalTitle: String
        ) async -> Bool {
            guard let plan = NotificationActionPlanner.plan(
                context: context,
                progress: progress,
                actionIdentifier: actionIdentifier,
                userText: userText
            ) else { return false }

            // Action taps run without UI — ask for background time so iOS
            // doesn't suspend the process mid-submission.
            let bgTask = UIApplication.shared.beginBackgroundTask(withName: "NotificationAction")
            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }

            switch plan {
            case let .submit(agentResponse):
                let delivered: Bool
                if let pairId {
                    delivered = await submit(agentResponse, context: context, hostId: pairId)
                } else {
                    // The NSE / local scheduler always stamp pairId; without it
                    // there is no host to route to.
                    delivered = false
                }
                if !delivered {
                    logger.error("Failed to deliver notification action response")
                    await scheduleFailureNotification(pairId: pairId, paneId: paneId)
                }

            case let .nextQuestion(index, progress):
                await scheduleNextQuestion(
                    context: context,
                    index: index,
                    progress: progress,
                    originalTitle: originalTitle,
                    pairId: pairId,
                    paneId: paneId
                )
            }
            return true
        }

        // MARK: - Incoming actionable notifications

        /// The last actionable agent notification received over the live
        /// socket, kept so the E2E harness can simulate an action-button tap
        /// through the real submission path (notification UI itself lives in
        /// SpringBoard, out of the harness's reach).
        public struct IncomingActionNotification {
            public let title: String
            public let pairId: String
            public let paneId: String?
            public let context: NotificationActionContext
        }

        public private(set) var lastIncomingAction: IncomingActionNotification?

        /// Records an actionable agent notification as it arrives over the
        /// live socket — including while the app is active, when no local
        /// notification is materialized.
        public func noteIncomingAgentNotification(
            title: String,
            pairId: String,
            paneId: String?,
            action: NotificationActionContext
        ) {
            lastIncomingAction = IncomingActionNotification(
                title: title,
                pairId: pairId,
                paneId: paneId,
                context: action
            )
        }

        #if DEBUG
            /// The notification the last simulated tap acted on, kept so a
            /// stale-tap simulation (`reuseLast`) can act on it again.
            private var lastSimulatedAction: IncomingActionNotification?

            /// E2E-only: simulate tapping `actionIdentifier` on the most
            /// recently received actionable notification, waiting briefly for
            /// one to arrive (the harness races the live-socket delivery).
            ///
            /// Each simulated tap CONSUMES the notification — the next call
            /// waits for a fresh one, so back-to-back forms can't accidentally
            /// answer with a stale context. `reuseLast` instead re-taps the
            /// previously consumed notification without waiting, modeling a
            /// stale lock-screen tap on a form the agent already moved past.
            public func simulateActionOnLastIncoming(
                actionIdentifier: String,
                userText: String?,
                reuseLast: Bool = false
            ) async -> Bool {
                let incoming: IncomingActionNotification
                if reuseLast {
                    guard let last = lastSimulatedAction ?? lastIncomingAction else {
                        logger.error("No previously tapped notification to reuse")
                        return false
                    }
                    incoming = last
                } else {
                    let deadline = Date().addingTimeInterval(5)
                    while lastIncomingAction == nil, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard let fresh = lastIncomingAction else {
                        logger.error("No actionable notification received to simulate a tap on")
                        return false
                    }
                    incoming = fresh
                    lastIncomingAction = nil
                    lastSimulatedAction = fresh
                }
                return await performAction(
                    context: incoming.context,
                    progress: nil,
                    actionIdentifier: actionIdentifier,
                    userText: userText,
                    pairId: incoming.pairId,
                    paneId: incoming.paneId,
                    originalTitle: incoming.title
                )
            }
        #endif

        // MARK: - Live-socket fallback notifications

        /// Materializes an actionable local notification for a host
        /// notification that arrived over the live WebSocket while the app was
        /// backgrounded (the relay drops the APNs push while we're connected,
        /// so this path mirrors what the NSE does for pushes).
        public func scheduleActionableLocalNotification(
            title: String,
            body: String,
            paneId: String?,
            hostId: String,
            action: NotificationActionContext
        ) async {
            guard PushNotificationService.shared.permissionStatus == .authorized else { return }
            guard let contextJSON = encodeJSONString(action) else { return }

            let (categoryId, dynamicCategory) = NotificationActionCategories.initialCategory(for: action)
            if let dynamicCategory {
                await NotificationActionCategories.registerMerging([dynamicCategory])
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.badge = 1
            content.categoryIdentifier = categoryId
            var userInfo: [String: Any] = [
                NotificationUserInfoKey.actionContext: contextJSON,
                "pairId": hostId,
            ]
            if let paneId {
                userInfo["paneId"] = paneId
            }
            content.userInfo = userInfo

            await addNotification(content)
        }

        // MARK: - Submission

        /// Submits the structured response for the context's request, reusing
        /// the app's live connection manager when possible. Returns whether
        /// the submission was handed to a connected host.
        private func submit(
            _ response: AgentResponse,
            context: NotificationActionContext,
            hostId: String
        ) async -> Bool {
            let settings = IOSSettings()
            guard
                let host = settings.pairedHosts.first(where: { $0.id == hostId }),
                let serverURL = URL(string: settings.externalServerURL)
            else {
                logger.error("No paired host / server URL for notification action")
                return false
            }

            // Prefer the app's live manager. A temporary one is created only
            // when the app process was launched straight into this handler —
            // in that case the socket was down anyway (that's why the APNs
            // push existed), so a fresh connection is required regardless.
            var temporary: ViewerConnectionManager?
            let manager: ViewerConnectionManager
            if let live = connectionManager {
                manager = live
            } else {
                guard let created = try? await ViewerConnectionManager() else {
                    logger.error("Failed to create temporary connection manager")
                    return false
                }
                temporary = created
                manager = created
            }

            let delivered = await submitThroughManager(
                response,
                context: context,
                hostId: hostId,
                host: host,
                serverURL: serverURL,
                settings: settings,
                manager: manager
            )

            // A temporary manager's sockets aren't managed by anyone else —
            // tear them down (awaited) once the submission is done, after a
            // short grace so the transport flushes the just-sent frame.
            if let temporary {
                if delivered {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                await temporary.disconnectAll()
            }
            return delivered
        }

        private func submitThroughManager(
            _ response: AgentResponse,
            context: NotificationActionContext,
            hostId: String,
            host: PairedHost,
            serverURL: URL,
            settings: IOSSettings,
            manager: ViewerConnectionManager
        ) async -> Bool {
            if manager.connection(for: hostId)?.isHostConnected != true {
                await manager.connect(
                    to: host,
                    serverURL: serverURL,
                    deviceId: settings.deviceId,
                    deviceName: settings.deviceName
                )
            }

            // `connect` returns once the WebSocket is up; the host link is
            // usable only after the E2EE handshake (`isHostConnected`). Poll
            // with a deadline rather than hooking connection callbacks the app
            // may already own.
            let deadline = Date().addingTimeInterval(Self.connectTimeout)
            while manager.connection(for: hostId)?.isHostConnected != true, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }

            guard
                let connection = manager.connection(for: hostId),
                connection.isHostConnected
            else {
                logger.error("Host not reachable for notification action submission")
                return false
            }

            await connection.submitAgentResponse(
                sessionId: context.sessionId,
                pluginId: context.pluginId,
                requestId: context.requestId,
                response: response
            )
            return true
        }

        // MARK: - Follow-up notifications

        /// Posts the next question of a multi-question flow as a local
        /// notification carrying the accumulated answers in its `userInfo`.
        private func scheduleNextQuestion(
            context: NotificationActionContext,
            index: Int,
            progress: NotificationActionProgress,
            originalTitle: String,
            pairId: String?,
            paneId: String?
        ) async {
            guard
                case let .askUserQuestion(actions) = context.form,
                actions.questions.indices.contains(index),
                let contextJSON = encodeJSONString(context),
                let progressJSON = encodeJSONString(progress)
            else { return }
            let question = actions.questions[index]

            let category = NotificationActionCategories.questionCategory(
                for: question,
                requestId: context.requestId,
                questionIndex: index
            )
            await NotificationActionCategories.registerMerging([category])

            let content = UNMutableNotificationContent()
            // Keep the original title so the flow reads as one conversation;
            // the body advances to the next question.
            content.title = originalTitle
            content.body = question.question
            content.sound = .default
            content.categoryIdentifier = category.identifier
            var userInfo: [String: Any] = [
                NotificationUserInfoKey.actionContext: contextJSON,
                NotificationUserInfoKey.actionProgress: progressJSON,
            ]
            if let pairId {
                userInfo["pairId"] = pairId
            }
            if let paneId {
                userInfo["paneId"] = paneId
            }
            content.userInfo = userInfo

            await addNotification(content)
        }

        /// Posts a tap-to-open notification when a submission could not be
        /// delivered, so the user's answer is never silently dropped.
        private func scheduleFailureNotification(pairId: String?, paneId: String?) async {
            let content = UNMutableNotificationContent()
            content.title = "Answer not delivered"
            content.body = "Couldn't reach your Mac. Tap to open the session and answer there."
            content.sound = .default
            var userInfo: [String: Any] = [:]
            if let pairId {
                userInfo["pairId"] = pairId
            }
            if let paneId {
                userInfo["paneId"] = paneId
            }
            content.userInfo = userInfo

            await addNotification(content)
        }

        // MARK: - Helpers

        private func addNotification(_ content: UNMutableNotificationContent) async {
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.error("Failed to schedule notification: \(error)")
            }
        }

        private func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
            guard let json = value as? String else { return nil }
            return try? JSONDecoder().decode(type, from: Data(json.utf8))
        }

        private func encodeJSONString(_ value: some Encodable) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
#endif
