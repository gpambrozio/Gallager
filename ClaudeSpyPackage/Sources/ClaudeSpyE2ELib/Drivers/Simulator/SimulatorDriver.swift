import Foundation
import Logging

/// Drives the iOS Simulator: boot, install, launch, UI interaction
public actor SimulatorDriver {
    private let processRunner = ProcessRunner()
    private let logger = Logger(label: "e2e.simulator-driver")

    private var udid: String?
    private var simulatorPID: pid_t?
    private var appBundleId: String?
    /// XCTest runner xcodebuild process (background)
    private var runnerProcess: Process?
    /// Path to the derived data containing the built XCTest runner
    private var e2eRunnerDerivedDataPath: String?

    /// Default port for the in-app `TestAccessibilityServer` on iOS.
    /// Chosen above the Mac range so parallel Mac instances don't collide.
    public static let defaultTestAccessibilityPort: UInt16 = 18_090

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
                        try await configureForTesting(udid: deviceUDID)
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
        try await configureForTesting(udid: udid)

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

        // Start the XCTest runner if we have a derived data path and it's not already running
        if e2eRunnerDerivedDataPath != nil && runnerProcess == nil {
            try await startE2ERunner()
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

    /// Clear the status bar override so the simulator shows real time again.
    public func resetStatusBar() async {
        guard let udid else { return }
        _ = try? await processRunner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "status_bar", udid, "clear"]
        )
        logger.info("Simulator status bar reset to defaults")
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

    // MARK: - E2E Runner Lifecycle

    /// Set the path to the E2E runner derived data (from build-for-testing)
    public func setE2ERunnerPath(_ path: String) {
        e2eRunnerDerivedDataPath = path
    }

    /// Install and start the XCTest E2E runner
    public func startE2ERunner() async throws {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }
        guard let derivedDataPath = e2eRunnerDerivedDataPath else {
            throw SimulatorDriverError.configurationError("E2E runner derived data path not set")
        }

        // Find the xctestrun file
        let xctestrunPath = try await findXCTestRunFile(in: derivedDataPath)
        logger.info("Found xctestrun: \(xctestrunPath)")

        // Install the host app
        let hostAppPath = try await findHostApp(in: derivedDataPath)
        logger.info("Installing E2E host app: \(hostAppPath)")
        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "install", udid, hostAppPath]
        )

        // Start xcodebuild test-without-building in the background
        logger.info("Starting XCTest runner via xcodebuild test-without-building")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "test-without-building",
            "-xctestrun", xctestrunPath,
            "-destination", "id=\(udid)",
        ]
        // Pipe xcodebuild output to a log file for debugging
        let logPath = NSTemporaryDirectory() + "e2e-runner-xcodebuild.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        logger.info("XCTest runner output: \(logPath)")

        try process.run()
        runnerProcess = process

        // Wait for the runner to be responsive
        try await waitForRunnerReady()
    }

    /// Stop the XCTest runner
    public func stopE2ERunner() {
        if let process = runnerProcess, process.isRunning {
            logger.info("Stopping XCTest runner (PID: \(process.processIdentifier))")
            process.terminate()
        }
        runnerProcess = nil
    }

    /// Wait for the runner's HTTP server to become responsive
    private func waitForRunnerReady(timeout: TimeInterval = 30) async throws {
        logger.info("Waiting for XCTest runner to be ready...")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await SimulatorHTTPClient.isRunnerReady() {
                logger.info("XCTest runner is ready")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }

        throw SimulatorDriverError.configurationError("XCTest runner did not start within \(Int(timeout))s")
    }

    /// Find the .xctestrun file in the derived data
    private func findXCTestRunFile(in derivedDataPath: String) async throws -> String {
        let buildDir = "\(derivedDataPath)/Build/Products"
        let fm = FileManager.default

        guard let items = try? fm.contentsOfDirectory(atPath: buildDir) else {
            throw SimulatorDriverError.configurationError("Build products not found at \(buildDir)")
        }

        if let xctestrun = items.first(where: { $0.hasSuffix(".xctestrun") }) {
            return "\(buildDir)/\(xctestrun)"
        }

        throw SimulatorDriverError.configurationError("No .xctestrun file found in \(buildDir)")
    }

    /// Find the E2E host app bundle in the derived data
    private func findHostApp(in derivedDataPath: String) async throws -> String {
        let buildDir = "\(derivedDataPath)/Build/Products"
        let fm = FileManager.default

        // Look in Debug-iphonesimulator or any *-iphonesimulator directory
        guard let items = try? fm.contentsOfDirectory(atPath: buildDir) else {
            throw SimulatorDriverError.configurationError("Build products not found at \(buildDir)")
        }

        for dir in items where dir.contains("iphonesimulator") {
            let appPath = "\(buildDir)/\(dir)/ClaudeSpyE2EHost.app"
            if fm.fileExists(atPath: appPath) {
                return appPath
            }
        }

        throw SimulatorDriverError.configurationError("ClaudeSpyE2EHost.app not found in \(buildDir)")
    }

    // MARK: - UI Inspection

    /// Describe the current UI tree via the XCTest runner's HTTP endpoint.
    public func describeUI(maxDepth: Int = 15) async -> [UIElement] {
        do {
            let response = try await SimulatorHTTPClient.describeUI(bundleId: appBundleId)
            return response.elements
        } catch {
            logger.warning("XCTest runner not available: \(error)")
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
    /// Uses the XCTest runner's HTTP API for coordinate-based tapping.
    public func tap(query: ElementQuery) async throws {
        let success = try await SimulatorHTTPClient.tap(query: query, bundleId: appBundleId)
        if success {
            logger.info("Tapped via XCTest runner: \(query)")
            return
        }

        logger.warning("XCTest runner tap returned not_found for \(query), falling back to CGEvent")
        let element = try await waitForElement(matching: query, timeout: 5)
        try await SimulatorInteraction.tap(at: element.center)
    }

    /// Tap at raw iOS coordinates
    public func tap(x: CGFloat, y: CGFloat) async throws {
        try await SimulatorHTTPClient.tap(x: x, y: y)
    }

    /// Swipe left on a UI element via the XCTest runner's touch synthesis
    public func swipeLeft(on element: UIElement) async throws {
        let center = element.center
        let swipeDistance: CGFloat = max(element.frame.width * 0.6, 200)
        let startX = center.x + swipeDistance / 2
        let endX = max(center.x - swipeDistance / 2, 10) // Don't swipe off-screen
        try await SimulatorHTTPClient.swipe(
            startX: startX, startY: center.y,
            endX: endX, endY: center.y
        )
    }

    /// Perform a custom accessibility action on an element.
    public func performCustomAction(query: ElementQuery, action: String) async throws -> Bool {
        do {
            let success = try await SimulatorHTTPClient.performCustomAction(query: query, action: action, bundleId: appBundleId)
            if success {
                logger.info("Custom action '\(action)' via XCTest runner on \(query)")
                return true
            }
        } catch {
            logger.warning("XCTest runner custom action failed: \(error)")
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

    /// Type text into the focused field via the XCTest runner.
    public func type(text: String, slow: Bool = false) async throws {
        let success = try await SimulatorHTTPClient.type(text: text)
        if success {
            logger.info("Typed via XCTest runner")
            return
        }
        logger.warning("XCTest runner type failed, falling back to AppleScript")
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

    /// Read the simulator clipboard via `simctl pbpaste`
    public func readClipboard() async throws -> String {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        let result = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "pbpaste", udid]
        )

        return result.stdoutString
    }

    // MARK: - Version Override

    /// Update the iOS app's `VersionCompatibility` overrides at runtime and kick a
    /// reconnect. `nil` clears the override (so the app reports its bundle version
    /// / default minimum); a non-nil value sets the override to that string.
    public func setAppVersion(appVersion: String?, minRequiredPartnerVersion: String?) async throws {
        logger.info(
            "Updating iOS version overrides: app=\(appVersion ?? "<clear>") min=\(minRequiredPartnerVersion ?? "<clear>")"
        )
        let success = try await IOSAppHTTPClient.setAppVersion(
            appVersion: appVersion,
            minRequiredPartnerVersion: minRequiredPartnerVersion,
            port: Self.defaultTestAccessibilityPort
        )
        if !success {
            throw SimulatorDriverError.configurationError(
                "iOS reconnect endpoint returned failure")
        }
    }

    // MARK: - Private

    /// Set a fixed status bar time and force light mode so screenshots are deterministic.
    private func configureForTesting(udid: String) async throws {
        // Fixed time (9:41 is Apple's canonical demo time)
        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "status_bar", udid, "override", "--time", "9:41"]
        )

        // Force light mode
        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "ui", udid, "appearance", "light"]
        )

        // Ensure accessibility and UI automation are enabled (required by XCUITest runner)
        for key in ["AccessibilityEnabled", "ApplicationAccessibilityEnabled", "AutomationEnabled"] {
            _ = try await processRunner.run(
                "/usr/bin/xcrun",
                arguments: ["simctl", "spawn", udid, "defaults", "write", "com.apple.Accessibility", key, "-bool", "true"]
            )
        }

        logger.info("Simulator configured: fixed time 9:41, light mode, accessibility enabled")
    }

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
