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
    private let serverPort: Int
    private let screenshotsDir: String

    /// Result of running a scenario
    public struct ScenarioResult: Sendable {
        public let scenarioName: String
        public let success: Bool
        public let failedStep: Int?
        public let error: String?
        public let duration: TimeInterval
    }

    public init(
        iosAppPath: String,
        macOSAppPath: String,
        simulatorName: String = "iPhone 16",
        serverPort: Int = 8_765,
        screenshotsDir: String = "/tmp/e2e-screenshots"
    ) {
        self.iosAppPath = iosAppPath
        self.macOSAppPath = macOSAppPath
        self.simulatorName = simulatorName
        self.serverPort = serverPort
        self.screenshotsDir = screenshotsDir
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

    /// Run multiple scenarios
    public func runAll(_ scenarios: [TestScenario]) async -> [ScenarioResult] {
        var results: [ScenarioResult] = []
        for scenario in scenarios {
            let result = await run(scenario)
            results.append(result)
        }
        return results
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

        case .stopServer:
            try await serverDriver.stop()

        // iOS Simulator
        case let .launchIOSApp(arguments):
            try await simulatorDriver.bootSimulator(name: simulatorName)
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
            let element = try await simulatorDriver.waitForElement(matching: query, timeout: 5)
            try await simulatorDriver.tap(element: element)

        case let .iosTapCoordinate(x, y):
            try await simulatorDriver.tap(x: x, y: y)

        case let .iosType(text):
            let resolvedText = context.resolve(text)
            try await simulatorDriver.type(text: resolvedText)

        case let .iosScreenshot(label):
            let path = "\(screenshotsDir)/\(label).png"
            _ = try await simulatorDriver.screenshot(output: path)

        // macOS App
        case let .launchMacApp(arguments):
            let resolvedArgs = arguments.map { context.resolve($0) }
            try await macOSDriver.launchApp(path: macOSAppPath, arguments: resolvedArgs)

        case .terminateMacApp:
            try await macOSDriver.terminateApp()

        case .macOpenSettings:
            try await macOSDriver.openSettings()

        case let .macWaitForWindow(titled, timeout):
            try await macOSDriver.waitForWindow(titled: titled, timeout: timeout)

        case let .macSelectSettingsTab(tab):
            try await macOSDriver.selectSettingsTab(tab)

        case let .macClickButton(titled):
            try await macOSDriver.clickButton(titled: titled)

        case let .macReadClipboard(storeAs):
            let value = await macOSDriver.readClipboard()
            logger.info("  Clipboard value: \(value) → stored as ${\(storeAs)}")
            context.set(storeAs, value: value)

        case let .macScreenshot(label):
            let path = "\(screenshotsDir)/\(label).png"
            try await macOSDriver.screenshot(output: path)

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
