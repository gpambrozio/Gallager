import Foundation
import Logging

/// Drives the iOS Simulator: boot, install, launch, UI interaction
public actor SimulatorDriver {
    private let processRunner = ProcessRunner()
    private let logger = Logger(label: "e2e.simulator-driver")

    private var udid: String?
    private var simulatorPID: pid_t?
    private var appBundleId: String?
    private var cachedContentOrigin: CGPoint?
    /// Skip macOS AX tree traversal (broken on Xcode 26.x — can't find
    /// iOSContentGroup, traversal takes ~2 min). Use HTTP-only by default.
    private var useHTTPOnly = true

    public init() { }

    // MARK: - Simulator Lifecycle

    /// Boot a simulator by name, returning its UDID
    @discardableResult
    public func bootSimulator(name: String) async throws -> String {
        logger.info("Booting simulator: \(name)")

        // Find the device UDID
        let listResult = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "-j"]
        )

        let json = try JSONSerialization.jsonObject(with: listResult.stdout) as? [String: Any]
        let devices = json?["devices"] as? [String: [[String: Any]]] ?? [:]

        var foundUDID: String?
        for (_, deviceList) in devices {
            for device in deviceList {
                if
                    let deviceName = device["name"] as? String,
                    deviceName == name,
                    let deviceUDID = device["udid"] as? String {
                    foundUDID = deviceUDID
                    // Check if already booted
                    if let state = device["state"] as? String, state == "Booted" {
                        logger.info("Simulator already booted: \(deviceUDID)")
                        self.udid = deviceUDID
                        // Ensure Simulator window is visible (it may have been
                        // closed during a previous cleanup)
                        _ = try await processRunner.run(
                            "/usr/bin/open",
                            arguments: ["-a", "Simulator"]
                        )
                        try await Task.sleep(for: .seconds(2))
                        try await findSimulatorPID()
                        try await SimulatorInteraction.enableHardwareKeyboard(udid: deviceUDID)
                        try await SimulatorInteraction.ensurePointAccurateMode()
                        return deviceUDID
                    }
                    break
                }
            }
            if foundUDID != nil { break }
        }

        guard let udid = foundUDID else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        // Boot the simulator
        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "boot", udid]
        )

        // Open Simulator.app to show the UI
        _ = try await processRunner.run(
            "/usr/bin/open",
            arguments: ["-a", "Simulator"]
        )

        // Wait for it to be ready
        try await Task.sleep(for: .seconds(3))

        self.udid = udid
        try await findSimulatorPID()

        // Ensure hardware keyboard is connected and Point Accurate mode
        try await SimulatorInteraction.enableHardwareKeyboard(udid: udid)
        try await SimulatorInteraction.ensurePointAccurateMode()

        return udid
    }

    /// Install an app in the simulator
    public func installApp(appPath: String) async throws {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        logger.info("Installing app: \(appPath)")
        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "install", udid, appPath]
        )
    }

    /// Launch an app in the simulator
    public func launchApp(bundleId: String, arguments: [String] = []) async throws {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        logger.info("Launching app: \(bundleId)")
        var args = ["simctl", "launch", udid, bundleId]
        args.append(contentsOf: arguments)

        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: args
        )

        appBundleId = bundleId
        // Give the app time to launch
        try await Task.sleep(for: .seconds(2))
    }

    /// Terminate a running app
    public func terminateApp(bundleId: String? = nil) async throws {
        guard let udid else { return }
        let bid = bundleId ?? appBundleId ?? ""
        guard !bid.isEmpty else { return }

        logger.info("Terminating app: \(bid)")
        _ = try await processRunner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "terminate", udid, bid]
        )
    }

    /// Uninstall an app from the simulator
    public func uninstallApp(bundleId: String? = nil) async throws {
        guard let udid else { return }
        let bid = bundleId ?? appBundleId ?? ""
        guard !bid.isEmpty else { return }

        logger.info("Uninstalling app: \(bid)")
        _ = try await processRunner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "uninstall", udid, bid]
        )
    }

    // MARK: - UI Inspection

    /// Describe the current UI tree.
    ///
    /// Tries macOS Accessibility API first (direct AX tree traversal).
    /// If that fails (broken on Xcode 26.3.0 RC), falls back to querying
    /// the iOS app's built-in HTTP accessibility server.
    public func describeUI(maxDepth: Int = 15) async -> [UIElement] {
        // Try AX-based approach first (skip if previously failed)
        if !useHTTPOnly, let pid = simulatorPID {
            let (elements, origin) = SimulatorAccessibility.describeUI(
                simulatorPID: pid,
                maxDepth: maxDepth
            )
            if let origin {
                cachedContentOrigin = origin
                return elements
            }
            // AX tree failed — don't try again (saves ~2 min per call)
            useHTTPOnly = true
            logger.info("AX tree failed, switching to HTTP-only mode")
        }

        // HTTP-based fallback
        do {
            let response = try await SimulatorHTTPClient.describeUI()

            // Calculate content origin from CGWindowList if we don't have one yet
            if cachedContentOrigin == nil {
                cachedContentOrigin = SimulatorHTTPClient.calculateContentOrigin(
                    screenSize: response.screenSize
                )
            }

            // Convert iOS screen coordinates to macOS screen coordinates
            if let contentOrigin = cachedContentOrigin {
                return response.elements.map { $0.offsettingFrames(by: contentOrigin) }
            } else {
                logger.warning("No content origin available, returning elements with iOS coordinates")
                return response.elements
            }
        } catch {
            logger.warning("HTTP accessibility server not available: \(error)")
            return []
        }
    }

    /// Find the first element matching a query
    public func findElement(matching query: ElementQuery) async -> UIElement? {
        let elements = await describeUI()
        return query.findFirst(in: elements)
    }

    /// Wait for an element to appear
    public func waitForElement(
        matching query: ElementQuery,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.5
    ) async throws -> UIElement {
        try await Polling.waitFor(
            description: "element matching \(query)",
            timeout: timeout,
            pollInterval: pollInterval
        ) {
            await self.findElement(matching: query)
        }
    }

    // MARK: - Interaction

    /// Tap on a UI element by query.
    /// Prefers HTTP-based tap (reliable, happens inside the app process).
    /// Falls back to CGEvent tap if HTTP is unavailable.
    public func tap(query: ElementQuery) async throws {
        // Try HTTP-based tap first (works regardless of window z-ordering)
        do {
            let success = try await SimulatorHTTPClient.tap(query: query)
            if success {
                logger.info("Tapped via HTTP: \(query)")
                return
            }
            logger.warning("HTTP tap returned not_found for \(query), falling back to CGEvent")
        } catch {
            logger.warning("HTTP tap failed (\(error)), falling back to CGEvent")
        }

        // Fall back to CGEvent-based tap
        let element = try await waitForElement(matching: query, timeout: 5)
        try await SimulatorInteraction.tap(at: element.center)
    }

    /// Tap on a UI element (AX frames are already in screen coordinates)
    public func tap(element: UIElement) async throws {
        try await SimulatorInteraction.tap(at: element.center)
    }

    /// Tap at raw iOS coordinates
    public func tap(x: CGFloat, y: CGFloat) async throws {
        guard let contentOrigin = cachedContentOrigin else {
            throw SimulatorDriverError.noContentGroup
        }

        let screenPoint = SimulatorWindow.toScreenCoordinates(
            point: CGPoint(x: x, y: y),
            contentOrigin: contentOrigin
        )
        try await SimulatorInteraction.tap(at: screenPoint)
    }

    /// Swipe left on a UI element (AX frames are already in screen coordinates)
    public func swipeLeft(on element: UIElement) async throws {
        let center = element.center
        // Use at least 200px swipe distance — small elements (e.g., label-only frames)
        // produce swipes too short to trigger iOS's swipe-to-delete gesture.
        let swipeDistance: CGFloat = max(element.frame.width * 0.6, 200)
        let start = CGPoint(x: center.x + swipeDistance / 2, y: center.y)
        let end = CGPoint(x: center.x - swipeDistance / 2, y: center.y)
        try await SimulatorInteraction.swipe(from: start, to: end)
    }

    /// Perform a custom accessibility action on an element.
    /// Used for swipe-to-delete via accessibility rather than gesture simulation.
    public func performCustomAction(query: ElementQuery, action: String) async throws -> Bool {
        do {
            let success = try await SimulatorHTTPClient.performCustomAction(query: query, action: action)
            if success {
                logger.info("Custom action '\(action)' via HTTP on \(query)")
                return true
            }
        } catch {
            logger.warning("HTTP custom action failed: \(error)")
        }
        return false
    }

    /// Wait for an element to disappear
    public func waitForElementToDisappear(
        matching query: ElementQuery,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.5
    ) async throws {
        try await Polling.waitUntil(
            description: "element \(query) to disappear",
            timeout: timeout,
            pollInterval: pollInterval
        ) {
            await self.findElement(matching: query) == nil
        }
    }

    /// Type text into the focused field.
    /// Prefers the HTTP accessibility server (reliable, no hardware keyboard needed).
    /// Falls back to AppleScript keystrokes if HTTP is unavailable.
    public func type(text: String, slow: Bool = false) async throws {
        // Try HTTP-based typing first (works regardless of hardware keyboard setting)
        do {
            let success = try await SimulatorHTTPClient.type(text: text)
            if success {
                logger.info("Typed via HTTP accessibility server")
                return
            }
            logger.warning("HTTP type returned no_responder, falling back to AppleScript")
        } catch {
            logger.warning("HTTP type failed (\(error)), falling back to AppleScript")
        }

        try await SimulatorInteraction.type(text: text, slow: slow)
    }

    /// Take a screenshot
    public func screenshot(output: String) async throws -> String {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "io", udid, "screenshot", output]
        )

        logger.info("Screenshot saved: \(output)")
        return output
    }

    // MARK: - Private

    private func findSimulatorPID() async throws {
        let result = try await processRunner.run(
            "/usr/bin/pgrep",
            arguments: ["-x", "Simulator"]
        )

        if result.isSuccess, let pid = Int32(result.stdoutString) {
            simulatorPID = pid
            logger.info("Simulator PID: \(pid)")
        }
    }
}
