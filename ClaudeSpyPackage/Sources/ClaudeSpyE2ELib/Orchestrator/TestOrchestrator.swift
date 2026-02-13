import Foundation
import Logging

/// Coordinates all drivers and runs test scenarios
public actor TestOrchestrator {
    private let simulatorDriver = SimulatorDriver()
    private let macOSDriver = MacOSDriver()
    private let serverDriver = ServerDriver()
    private let context = ExecutionContext()
    private let logger = Logger(label: "e2e.orchestrator")

    private let iosAppPath: String
    private let macOSAppPath: String
    private let simulatorName: String
    private let screenshotsDir: String
    private let tmuxSocket: String?
    private let e2eRunnerPath: String?
    private let e2eHostBundleId = "br.eng.gustavo.claudespy.e2ehost"
    private let e2eRunnerBundleId = "br.eng.gustavo.claudespy.e2erunner.xctrunner"

    /// Result of running a scenario
    public struct ScenarioResult: Sendable {
        public let scenarioName: String
        public let success: Bool
        public let failedStep: Int?
        public let error: String?
        public let duration: TimeInterval
    }

    /// - Note: The server port is controlled per-scenario via `TestStep.startServer(port:)`,
    ///   not as an orchestrator-level configuration. The tmux socket path is injected into
    ///   the execution context as `${tmuxSocket}` for scenarios to reference.
    public init(
        iosAppPath: String,
        macOSAppPath: String,
        simulatorName: String = "iPhone 16",
        screenshotsDir: String = "/tmp/e2e-screenshots",
        tmuxSocket: String? = nil,
        e2eRunnerPath: String? = nil
    ) {
        self.iosAppPath = iosAppPath
        self.macOSAppPath = macOSAppPath
        self.simulatorName = simulatorName
        self.screenshotsDir = screenshotsDir
        self.tmuxSocket = tmuxSocket
        self.e2eRunnerPath = e2eRunnerPath
    }

    // MARK: - Run Scenarios

    /// Run a single scenario
    public func run(_ scenario: TestScenario) async -> ScenarioResult {
        logger.info("=== Starting scenario: \(scenario.name) ===")
        let startTime = ContinuousClock.now

        // Ensure screenshots directory exists
        try? FileManager.default.createDirectory(
            atPath: screenshotsDir,
            withIntermediateDirectories: true
        )

        context.clear()

        // Pre-populate context with orchestrator configuration
        context.set("tmuxSocket", value: tmuxSocket ?? "/tmp/claudespy-e2e.sock")

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
        await simulatorDriver.stopE2ERunner()
        try? await simulatorDriver.terminateApp()
        try? await macOSDriver.terminateApp()
        try? await serverDriver.stop()

        // Kill the isolated tmux server so the socket file is cleaned up
        if let tmuxSocket {
            logger.info("Killing isolated tmux server at \(tmuxSocket)")
            let runner = ProcessRunner()
            _ = try? await runner.run("tmux", arguments: ["-S", tmuxSocket, "kill-server"])
        }

        logger.info("=== Cleanup complete ===")
    }

    // MARK: - Step Execution

    private func executeStep(_ step: TestStep) async throws {
        switch step {
        // Server
        case let .startServer(port):
            try await serverDriver.start(port: port)

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
        case let .launchIOSApp(arguments):
            try await simulatorDriver.bootSimulator(name: simulatorName)
            if let e2eRunnerPath {
                await simulatorDriver.setE2ERunnerPath(e2eRunnerPath)
            }
            try await simulatorDriver.installApp(appPath: iosAppPath)
            let resolvedArgs = arguments.map { context.resolve($0) }
            try await simulatorDriver.launchApp(
                bundleId: iosBundleId(),
                arguments: resolvedArgs
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

        case let .iosScreenshot(label):
            let path = "\(screenshotsDir)/\(label).png"
            _ = try await simulatorDriver.screenshot(output: path)

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
        case let .launchMacApp(arguments):
            let resolvedArgs = arguments.map { context.resolve($0) }
            try await macOSDriver.launchApp(path: macOSAppPath, arguments: resolvedArgs)

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

        case let .macScreenshot(label):
            let path = "\(screenshotsDir)/\(label).png"
            do {
                try await macOSDriver.screenshot(output: path)
            } catch {
                logger.warning("macOS screenshot failed (non-fatal): \(error.localizedDescription)")
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

    private func iosBundleId() throws -> String {
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
