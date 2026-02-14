import Foundation
import Logging

/// Coordinates all drivers and runs test scenarios
public actor TestOrchestrator {
    private let simulatorDriver = SimulatorDriver()
    private let macOSDriver = MacOSDriver()
    private let serverDriver = ServerDriver()
    private let processRunner = ProcessRunner()
    private let context = ExecutionContext()
    private let logger = Logger(label: "e2e.orchestrator")

    private let iosAppPath: String?
    private let macOSAppPath: String
    private let simulatorName: String
    private let screenshotsDir: String
    private let baselinesDir: String
    private let tmuxSocket: String?
    private let e2eRunnerPath: String?
    private let e2eHostBundleId = "br.eng.gustavo.claudespy.e2ehost"
    private let e2eRunnerBundleId = "br.eng.gustavo.claudespy.e2erunner.xctrunner"
    private let serverPort = 8_765
    private let scenarioNames: [String]
    private let skipComparison: Bool
    private var screenshotCounter = 0

    /// Result of running a scenario
    public struct ScenarioResult: Sendable {
        public let scenarioName: String
        public let success: Bool
        public let failedStep: Int?
        public let error: String?
        public let duration: TimeInterval
    }

    /// - Note: The tmux socket path is injected into the execution context as `${tmuxSocket}`
    ///   for scenarios to reference.
    /// - Parameter scenarioNames: The full ordered list of scenario names (used to number
    ///   screenshot directories consistently regardless of which subset is actually run).
    public init(
        iosAppPath: String? = nil,
        macOSAppPath: String,
        simulatorName: String = "iPhone 16",
        screenshotsDir: String = "/tmp/e2e-screenshots",
        baselinesDir: String = "E2ETests",
        tmuxSocket: String? = nil,
        e2eRunnerPath: String? = nil,
        scenarioNames: [String] = [],
        skipComparison: Bool = false
    ) {
        self.iosAppPath = iosAppPath
        self.macOSAppPath = macOSAppPath
        self.simulatorName = simulatorName
        self.screenshotsDir = screenshotsDir
        self.baselinesDir = baselinesDir
        self.tmuxSocket = tmuxSocket
        self.e2eRunnerPath = e2eRunnerPath
        self.scenarioNames = scenarioNames
        self.skipComparison = skipComparison
    }

    // MARK: - Run Scenarios

    /// Run a single scenario
    public func run(_ scenario: TestScenario) async -> ScenarioResult {
        logger.info("=== Starting scenario: \(scenario.name) ===")
        let startTime = ContinuousClock.now

        // Build the numbered scenario directory name (e.g. "03-fresh-pairing").
        // The number comes from the scenario's position in the full registry so it
        // stays stable even when running a single scenario.
        let sanitizedName = sanitizeForPath(scenario.name)
        let scenarioDirName: String
        if let index = scenarioNames.firstIndex(of: scenario.name) {
            scenarioDirName = String(format: "%02d-%@", index + 1, sanitizedName)
        } else {
            scenarioDirName = sanitizedName
        }

        // Ensure per-scenario screenshots directory exists
        let scenarioScreenshotsDir = "\(screenshotsDir)/\(scenarioDirName)"
        try? FileManager.default.createDirectory(
            atPath: scenarioScreenshotsDir,
            withIntermediateDirectories: true
        )

        context.clear()
        screenshotCounter = 0

        // Pre-populate context with orchestrator configuration
        context.set("tmuxSocket", value: tmuxSocket ?? "/tmp/claudespy-e2e.sock")
        context.set("scenarioName", value: scenarioDirName)

        for (index, step) in scenario.steps.enumerated() {
            let stepNumber = index + 1
            logger.info("  Step \(stepNumber)/\(scenario.steps.count): \(step)")

            do {
                try await executeStep(step)
            } catch {
                let duration = ContinuousClock.now - startTime
                logger.error("  FAILED at step \(stepNumber): \(error)")
                return ScenarioResult(
                    scenarioName: scenario.name,
                    success: false,
                    failedStep: stepNumber,
                    error: error.localizedDescription,
                    duration: Double(duration.components.seconds)
                )
            }
        }

        let duration = ContinuousClock.now - startTime
        logger.info("=== Scenario PASSED: \(scenario.name) (\(duration)) ===")
        return ScenarioResult(
            scenarioName: scenario.name,
            success: true,
            failedStep: nil,
            error: nil,
            duration: Double(duration.components.seconds)
        )
    }

    /// Run multiple scenarios, cleaning up after each one
    public func runAll(_ scenarios: [TestScenario]) async -> [ScenarioResult] {
        var results: [ScenarioResult] = []
        for scenario in scenarios {
            let result = await run(scenario)
            await cleanup()
            results.append(result)
        }
        await uninstallSimulatorApps()
        return results
    }

    /// Remove all E2E apps from the simulator after test runs complete
    private func uninstallSimulatorApps() async {
        logger.info("=== Uninstalling simulator apps ===")
        await simulatorDriver.stopE2ERunner()
        try? await simulatorDriver.terminateApp()
        try? await simulatorDriver.uninstallApp()
        try? await simulatorDriver.terminateApp(bundleId: e2eHostBundleId)
        try? await simulatorDriver.uninstallApp(bundleId: e2eHostBundleId)
        try? await simulatorDriver.terminateApp(bundleId: e2eRunnerBundleId)
        try? await simulatorDriver.uninstallApp(bundleId: e2eRunnerBundleId)
        logger.info("=== Simulator apps uninstalled ===")
    }

    /// Tear down all running processes regardless of scenario outcome
    public func cleanup() async {
        logger.info("=== Cleaning up ===")
        await simulatorDriver.resetStatusBar()
        await simulatorDriver.stopE2ERunner()
        try? await simulatorDriver.terminateApp()
        try? await macOSDriver.terminateApp()
        try? await serverDriver.stop()

        // Kill the isolated tmux server so the socket file is cleaned up
        if let tmuxSocket {
            logger.info("Killing isolated tmux server at \(tmuxSocket)")
            let runner = processRunner
            _ = try? await runner.run("tmux", arguments: ["-S", tmuxSocket, "kill-server"])
        }

        logger.info("=== Cleanup complete ===")
    }

    // MARK: - Step Execution

    private func executeStep(_ step: TestStep) async throws {
        switch step {
        // Server
        case .startServer:
            try await serverDriver.start(port: serverPort)

        case .verifyServerHealth:
            try await serverDriver.waitForHealthy()

        case let .verifyServerHasPairings(count):
            let actual = await serverDriver.getActivePairingCount()
            guard actual == count else {
                throw OrchestratorError.assertionFailed(
                    "Expected \(count) pairings, got \(actual)"
                )
            }

        case let .waitForHostConnected(timeout):
            try await Polling.waitUntil(
                description: "host connected to relay server",
                timeout: timeout,
                pollInterval: 1
            ) {
                await self.serverDriver.isAnyHostConnected()
            }

        case let .waitForViewerConnected(timeout):
            try await Polling.waitUntil(
                description: "viewer connected to relay server",
                timeout: timeout,
                pollInterval: 1
            ) {
                await self.serverDriver.isAnyViewerConnected()
            }

        case let .serverDisconnectDevice(deviceType):
            await serverDriver.disconnectDevice(type: deviceType)

        case let .waitForNoPairings(timeout):
            try await serverDriver.waitForNoPairings(timeout: timeout)

        case .stopServer:
            try await serverDriver.stop()

        // iOS Simulator
        case .launchIOSApp:
            guard let iosAppPath else {
                throw OrchestratorError.configurationError("--ios-app-path is required for iOS scenarios")
            }
            try await simulatorDriver.bootSimulator(name: simulatorName)
            if let e2eRunnerPath {
                await simulatorDriver.setE2ERunnerPath(e2eRunnerPath)
            }
            try await simulatorDriver.installApp(appPath: iosAppPath)
            try await simulatorDriver.launchApp(
                bundleId: iosBundleId(),
                arguments: ["--e2e-test", "--server-url", "ws://127.0.0.1:\(serverPort)"]
            )

        case .terminateIOSApp:
            try await simulatorDriver.terminateApp()

        case .uninstallIOSApp:
            try await simulatorDriver.terminateApp()
            try await simulatorDriver.uninstallApp()

        case let .iosWaitForElement(query, timeout):
            _ = try await simulatorDriver.waitForElement(matching: query, timeout: timeout)

        case let .iosTap(query):
            try await simulatorDriver.tap(query: query)

        case let .iosTapCoordinate(x, y):
            try await simulatorDriver.tap(x: x, y: y)

        case let .iosType(text):
            let resolvedText = context.resolve(text)
            try await simulatorDriver.type(text: resolvedText)

        case let .iosSwipeLeft(query):
            // Swipe left via XCTest runner's touch synthesis.
            // The scenario should follow this with taps for the revealed delete button
            // and confirmation dialog — the XCUITest runner can see all UI elements.
            let element = try await simulatorDriver.waitForElement(matching: query, timeout: 5)
            try await simulatorDriver.swipeLeft(on: element)

        case let .iosWaitForElementToDisappear(query, timeout):
            try await simulatorDriver.waitForElementToDisappear(matching: query, timeout: timeout)

        case let .iosScreenshot(label, compare, tolerance, perPixelThreshold):
            let numberedLabel = nextScreenshotLabel(label)
            let actualPath = screenshotPath(for: numberedLabel)
            _ = try await simulatorDriver.screenshot(output: actualPath)
            if compare, !skipComparison {
                try compareScreenshot(actualPath: actualPath, label: numberedLabel, tolerance: tolerance, perPixelThreshold: perPixelThreshold)
            }

        case .iosLogUI:
            let elements = await simulatorDriver.describeUI()
            func logTree(_ elements: [UIElement], indent: String = "") {
                for element in elements {
                    logger.info("\(indent)\(element)")
                    logTree(element.children, indent: indent + "  ")
                }
            }
            logger.info("=== iOS UI Tree ===")
            logTree(elements)
            logger.info("=== End iOS UI Tree ===")

        // macOS App
        case .launchMacApp:
            let resolvedSocket = context.resolve("${tmuxSocket}")
            try await macOSDriver.launchApp(
                path: macOSAppPath,
                arguments: [
                    "--e2e-test",
                    "--server-url", "ws://127.0.0.1:\(serverPort)",
                    "--tmux-socket", resolvedSocket,
                ]
            )

        case .terminateMacApp:
            try? await macOSDriver.terminateApp()

        case .macOpenSettings:
            try await macOSDriver.openSettings()

        case let .macWaitForWindow(titled, timeout):
            try await macOSDriver.waitForWindow(titled: titled, timeout: timeout)

        case let .macSelectSettingsTab(tab):
            try await macOSDriver.selectSettingsTab(tab)

        case let .macClickButton(titled):
            try await macOSDriver.clickButton(titled: titled)

        case let .macClickMenuItem(menuButtonTitle, itemTitle):
            try await macOSDriver.clickMenuItem(menuButtonTitle: menuButtonTitle, itemTitle: itemTitle)

        case .macUnpair:
            try await macOSDriver.unpair()

        case let .macReadClipboard(storeAs):
            let value = await macOSDriver.readClipboard()
            logger.info("  Clipboard value: \(value) → stored as ${\(storeAs)}")
            context.set(storeAs, value: value)

        case let .macWaitForElement(titled, timeout):
            try await macOSDriver.waitForElement(titled: titled, timeout: timeout)

        case .macOpenPanesWindow:
            try await macOSDriver.openPanesWindow()

        case let .macResizeWindow(width, height):
            try await macOSDriver.resizeWindow(width: width, height: height)

        case let .macSetSidebarWidth(width):
            try await macOSDriver.setSidebarWidth(width)

        case let .macType(text, pressReturn):
            let resolvedText = context.resolve(text)
            try await macOSDriver.type(text: resolvedText, pressReturn: pressReturn)

        case let .macScreenshot(label, compare, tolerance, perPixelThreshold):
            let numberedLabel = nextScreenshotLabel(label)
            let actualPath = screenshotPath(for: numberedLabel)
            try await macOSDriver.screenshot(output: actualPath)
            if compare, !skipComparison {
                try compareScreenshot(actualPath: actualPath, label: numberedLabel, tolerance: tolerance, perPixelThreshold: perPixelThreshold)
            }

        // Tmux
        case let .tmuxCreateSession(name, width, height):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedName = context.resolve(name)
            let runner = processRunner
            // Use -f /dev/null to ignore user's tmux.conf (avoids base-index/pane-base-index
            // being set to non-zero values which would change pane targets)
            _ = try await runner.runOrThrow(
                "tmux",
                arguments: ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", resolvedName, "-x", "\(width)", "-y", "\(height)"]
            )

        case let .tmuxStorePaneDimensions(target, widthKey, heightKey):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedTarget = context.resolve(target)
            let runner = processRunner
            let result = try await runner.runOrThrow(
                "tmux",
                arguments: ["-S", socket, "display-message", "-t", resolvedTarget, "-p", "#{pane_width} #{pane_height}"]
            )
            let parts = result.stdoutString.split(separator: " ")
            guard parts.count == 2 else {
                throw OrchestratorError.assertionFailed(
                    "Expected 'width height' from tmux display-message, got: '\(result.stdoutString)'"
                )
            }
            context.set(widthKey, value: String(parts[0]))
            context.set(heightKey, value: String(parts[1]))
            logger.info("  Stored \(widthKey)=\(parts[0]), \(heightKey)=\(parts[1])")

        // Assertions
        case let .assertStoredEqual(key, otherKey):
            guard let value1 = context.get(key) else {
                throw OrchestratorError.assertionFailed("Key '\(key)' not found in context")
            }
            guard let value2 = context.get(otherKey) else {
                throw OrchestratorError.assertionFailed("Key '\(otherKey)' not found in context")
            }
            guard value1 == value2 else {
                throw OrchestratorError.assertionFailed(
                    "\(key)='\(value1)' != \(otherKey)='\(value2)'"
                )
            }

        case let .assertStoredNotEqual(key, otherKey):
            guard let value1 = context.get(key) else {
                throw OrchestratorError.assertionFailed("Key '\(key)' not found in context")
            }
            guard let value2 = context.get(otherKey) else {
                throw OrchestratorError.assertionFailed("Key '\(otherKey)' not found in context")
            }
            guard value1 != value2 else {
                throw OrchestratorError.assertionFailed(
                    "\(key)='\(value1)' should differ from \(otherKey)='\(value2)'"
                )
            }

        // General
        case let .wait(seconds):
            try await Task.sleep(for: .seconds(seconds))

        case let .storeValue(key, value):
            context.set(key, value: value)

        case let .log(message):
            logger.info("  LOG: \(context.resolve(message))")
        }
    }

    // MARK: - Helpers

    /// Compare a screenshot against its baseline and throw on mismatch.
    /// If no baseline exists yet, saves the actual screenshot as the new baseline.
    private func compareScreenshot(actualPath: String, label: String, tolerance: Double, perPixelThreshold: Double) throws {
        let baselinePath = baselinePath(for: label)
        let diffPath = baselinePath.replacingOccurrences(of: ".png", with: "_diff.png")
        let fm = FileManager.default

        // Clean up stale diff images from prior runs
        try? fm.removeItem(atPath: diffPath)

        // No baseline yet — save this screenshot as the new baseline
        guard fm.fileExists(atPath: baselinePath) else {
            try saveScreenshot(from: actualPath, to: baselinePath)
            logger.info("  Baseline created for '\(label)'")
            return
        }

        let result = try ScreenshotComparator.compare(
            actualPath: actualPath,
            baselinePath: baselinePath,
            diffPath: diffPath,
            tolerance: tolerance,
            perPixelThreshold: perPixelThreshold
        )
        guard result.passed else {
            let diffStr = String(format: "%.2f", result.diffPercentage)
            let tolStr = String(format: "%.2f", tolerance)
            let diffInfo = result.diffPath.map { " — diff: \($0)" } ?? ""
            throw OrchestratorError.assertionFailed(
                "Screenshot '\(label)' differs from baseline by \(diffStr)% (tolerance: \(tolStr)%)\(diffInfo)"
            )
        }
    }

    /// Copy a screenshot to a destination, creating parent directories and overwriting if needed.
    private func saveScreenshot(from sourcePath: String, to destPath: String) throws {
        let fm = FileManager.default
        let dir = (destPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destPath) {
            try fm.removeItem(atPath: destPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: destPath)
    }

    /// Return a screenshot label prefixed with an auto-incremented counter (e.g. "01-label")
    private func nextScreenshotLabel(_ label: String) -> String {
        screenshotCounter += 1
        return String(format: "%02d-%@", screenshotCounter, label)
    }

    /// Build the full path for a screenshot file, scoped to the current scenario
    private func screenshotPath(for label: String) -> String {
        let scenarioName = context.resolve("${scenarioName}")
        return "\(screenshotsDir)/\(scenarioName)/\(label).png"
    }

    /// Build the full path for a baseline file, scoped to the current scenario
    private func baselinePath(for label: String) -> String {
        let scenarioName = context.resolve("${scenarioName}")
        return "\(baselinesDir)/\(scenarioName)/\(label).png"
    }

    /// Convert a scenario name into a safe directory name
    private func sanitizeForPath(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private func iosBundleId() throws -> String {
        guard let iosAppPath else {
            throw OrchestratorError.configurationError("--ios-app-path is required to read bundle ID")
        }
        // Extract bundle ID from the app's Info.plist
        let plistPath = "\(iosAppPath)/Info.plist"
        guard
            let plistData = FileManager.default.contents(atPath: plistPath),
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData, format: nil
            ) as? [String: Any],
            let bundleId = plist["CFBundleIdentifier"] as? String
        else {
            throw OrchestratorError.configurationError("Could not read bundle ID from \(plistPath)")
        }
        return bundleId
    }
}

/// Orchestrator-specific errors
public enum OrchestratorError: Error, LocalizedError {
    case assertionFailed(String)
    case configurationError(String)
    case stepFailed(step: Int, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .assertionFailed(message):
            "Assertion failed: \(message)"
        case let .configurationError(message):
            "Configuration error: \(message)"
        case let .stepFailed(step, underlying):
            "Step \(step) failed: \(underlying.localizedDescription)"
        }
    }
}
