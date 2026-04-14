import Foundation
import Logging

/// Coordinates all drivers and runs test scenarios
public actor TestOrchestrator {
    private let simulatorDriver = SimulatorDriver()
    /// macOS drivers keyed by instance number. Created lazily via `macDriver(for:)`.
    private var macDrivers: [Int: MacOSDriver] = [:]
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
    /// Base path for the hook server port file. E2E tests use a separate file
    /// (`~/.claudespy-port-test`) to avoid colliding with a production instance.
    /// Instance 0 uses this path directly; instance N uses `\(hookPortFile)-\(N)`.
    private let hookPortFile: String
    private let skipComparison: Bool
    private let reporter: (any TestProgressReporter)?
    private var screenshotCounter = 0
    /// Paths of scripts copied to TMPDIR via `injectScript`, cleaned up after each scenario.
    private var injectedScriptPaths: [String] = []

    /// Result of a single step
    public struct StepResult: Sendable, Codable {
        public let stepNumber: Int
        public let description: String
        public let success: Bool
        public let error: String?
        public let screenshot: ScreenshotResult?
    }

    /// Result of a screenshot comparison
    public struct ScreenshotResult: Sendable, Codable {
        public let label: String
        public let actualPath: String
        public let baselinePath: String?
        public let diffPath: String?
        public let diffPercentage: Double?
        public let passed: Bool
        public let baselineCreated: Bool
    }

    /// Result of running a scenario
    public struct ScenarioResult: Sendable, Codable {
        public let scenarioName: String
        public let success: Bool
        public let failedStep: Int?
        public let error: String?
        public let duration: TimeInterval
        public let steps: [StepResult]
    }

    /// - Note: The tmux socket path is injected into the execution context as `${tmuxSocket}`
    ///   for scenarios to reference.
    public init(
        iosAppPath: String? = nil,
        macOSAppPath: String,
        simulatorName: String = "iPhone 16",
        screenshotsDir: String = NSTemporaryDirectory() + "e2e-screenshots",
        baselinesDir: String = "E2ETests",
        tmuxSocket: String? = nil,
        e2eRunnerPath: String? = nil,
        skipComparison: Bool = false,
        hookPortFile: String? = nil,
        reporter: (any TestProgressReporter)? = nil
    ) {
        self.iosAppPath = iosAppPath
        self.macOSAppPath = macOSAppPath
        self.simulatorName = simulatorName
        self.screenshotsDir = screenshotsDir
        self.baselinesDir = baselinesDir
        self.tmuxSocket = tmuxSocket
        self.e2eRunnerPath = e2eRunnerPath
        self.skipComparison = skipComparison
        self.reporter = reporter
        self.hookPortFile = hookPortFile ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/.claudespy-port-test"
        }()
    }

    // MARK: - Run Scenarios

    /// Run a single scenario
    public func run(_ scenario: TestScenario) async -> ScenarioResult {
        logger.info("=== Starting scenario: \(scenario.name) ===")
        await reporter?.scenarioStarted(scenario.name, totalSteps: scenario.steps.count)
        let startTime = ContinuousClock.now

        let scenarioDirName = sanitizeForPath(scenario.name)

        // Ensure per-scenario screenshots directory exists
        let scenarioScreenshotsDir = "\(screenshotsDir)/\(scenarioDirName)"
        try? FileManager.default.createDirectory(
            atPath: scenarioScreenshotsDir,
            withIntermediateDirectories: true
        )

        context.clear()
        screenshotCounter = 0
        injectedScriptPaths.removeAll()

        // Pre-populate context with orchestrator configuration
        context.set("tmuxSocket", value: tmuxSocket ?? NSTemporaryDirectory() + "claudespy-e2e.sock")
        context.set("notificationLogPath", value: notificationLogPath(for: 0))
        context.set("pushLogPath", value: pushLogPath(for: 0))
        context.set("scenarioName", value: scenarioDirName)

        var stepResults: [StepResult] = []
        var firstFailedStep: Int?
        var firstError: String?

        for (index, step) in scenario.steps.enumerated() {
            let stepNumber = index + 1
            logger.info("  Step \(stepNumber)/\(scenario.steps.count): \(step)")
            await reporter?.stepStarted(stepNumber, totalSteps: scenario.steps.count, description: "\(step)")

            do {
                let screenshotResult = try await executeStep(step)
                stepResults.append(StepResult(
                    stepNumber: stepNumber,
                    description: "\(step)",
                    success: true,
                    error: nil,
                    screenshot: screenshotResult
                ))
                await reporter?.stepCompleted(stepNumber, screenshot: screenshotResult)
            } catch {
                logger.error("  FAILED at step \(stepNumber): \(error)")
                // Extract screenshot result from mismatch errors
                let screenshotResult: ScreenshotResult?
                if case let OrchestratorError.screenshotMismatch(result, _) = error {
                    screenshotResult = result
                } else {
                    screenshotResult = nil
                }
                stepResults.append(StepResult(
                    stepNumber: stepNumber,
                    description: "\(step)",
                    success: false,
                    error: error.localizedDescription,
                    screenshot: screenshotResult
                ))
                await reporter?.stepFailed(stepNumber, error: error.localizedDescription, screenshot: screenshotResult)

                if firstFailedStep == nil {
                    firstFailedStep = stepNumber
                    firstError = error.localizedDescription
                }

                // Screenshot mismatches are non-fatal — continue executing remaining steps
                if case OrchestratorError.screenshotMismatch = error {
                    continue
                }

                // All other errors are fatal — stop the scenario
                cleanupInjectedScripts()
                let duration = ContinuousClock.now - startTime
                let result = ScenarioResult(
                    scenarioName: scenario.name,
                    success: false,
                    failedStep: firstFailedStep,
                    error: firstError,
                    duration: Double(duration.components.seconds),
                    steps: stepResults
                )
                await reporter?.scenarioCompleted(result)
                return result
            }
        }

        cleanupInjectedScripts()

        let duration = ContinuousClock.now - startTime
        let success = firstFailedStep == nil
        if success {
            logger.info("=== Scenario PASSED: \(scenario.name) (\(duration)) ===")
        } else {
            logger.info("=== Scenario FAILED: \(scenario.name) (\(duration)) ===")
        }
        let result = ScenarioResult(
            scenarioName: scenario.name,
            success: success,
            failedStep: firstFailedStep,
            error: firstError,
            duration: Double(duration.components.seconds),
            steps: stepResults
        )
        await reporter?.scenarioCompleted(result)
        return result
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
        await reporter?.printSummary(results)
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
        cleanupInjectedScripts()
        await simulatorDriver.resetStatusBar()
        await simulatorDriver.stopE2ERunner()
        try? await simulatorDriver.terminateApp()
        let instanceKeys = Array(macDrivers.keys)
        for driver in macDrivers.values {
            try? await driver.terminateApp()
        }
        macDrivers.removeAll()
        try? await serverDriver.stop()

        // Kill isolated tmux servers for all instances and remove socket files
        // so the next scenario starts with a clean slate (a stale socket causes
        // "server exited unexpectedly" errors).
        let instanceIndices = instanceKeys + [0]
        let uniqueIndices = Set(instanceIndices)
        for idx in uniqueIndices {
            let socket = tmuxSocketPath(for: idx)
            logger.info("Killing isolated tmux server at \(socket)")
            let runner = processRunner
            _ = try? await runner.run("tmux", arguments: ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(atPath: socket)
        }

        logger.info("=== Cleanup complete ===")
    }

    // MARK: - Step Execution

    @discardableResult
    private func executeStep(_ step: TestStep) async throws -> ScreenshotResult? {
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

        case let .serverBlockDevice(deviceType):
            await serverDriver.blockDevice(type: deviceType)

        case let .serverUnblockDevice(deviceType):
            await serverDriver.unblockDevice(type: deviceType)

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
                return try compareScreenshot(actualPath: actualPath, label: numberedLabel, tolerance: tolerance, perPixelThreshold: perPixelThreshold)
            } else {
                return try captureWithoutComparison(actualPath: actualPath, label: numberedLabel)
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

        // macOS App (all cases use `instance` to select which app instance to target)
        case let .launchMacApp(instance):
            let driver = macDriver(for: instance)
            let instanceSocket = tmuxSocketPath(for: instance)
            var arguments = [
                "--e2e-test",
                "--server-url", "ws://127.0.0.1:\(serverPort)",
                "--tmux-socket", instanceSocket,
                "--hook-port-file", hookPortFilePath(for: instance),
                "--test-accessibility-port", "\(driver.testAccessibilityPort)",
                "--notification-log", notificationLogPath(for: instance),
                "--push-log", pushLogPath(for: instance),
            ]
            if
                let sampleDir = Bundle.module.resourcePath.map({ $0 + "/SampleFiles" }),
                FileManager.default.fileExists(atPath: sampleDir) {
                arguments += ["--sample-files-dir", sampleDir]
            }
            try await driver.launchApp(path: macOSAppPath, arguments: arguments)

        case let .terminateMacApp(instance):
            try? await macDriver(for: instance).terminateApp()

        case let .macOpenSettings(instance):
            try await macDriver(for: instance).openSettings()

        case let .macCloseWindow(titled, instance):
            try await macDriver(for: instance).closeWindow(titled: titled)

        case let .macWaitForWindow(titled, timeout, instance):
            try await macDriver(for: instance).waitForWindow(titled: titled, timeout: timeout)

        case let .macSelectSettingsTab(tab, instance):
            try await macDriver(for: instance).selectSettingsTab(tab)

        case let .macClickButton(titled, instance):
            try await macDriver(for: instance).clickButton(titled: titled)

        case let .macClickMenuItem(menuButtonTitle, itemTitle, instance):
            try await macDriver(for: instance).clickMenuItem(menuButtonTitle: menuButtonTitle, itemTitle: itemTitle)

        case let .macPressTab(instance):
            try await macDriver(for: instance).pressTab()

        case let .macPressEscape(instance):
            try await macDriver(for: instance).pressEscape()

        case let .macPressReturn(instance):
            try await macDriver(for: instance).pressReturn()

        case let .macSelectAll(instance):
            try await macDriver(for: instance).selectAll()

        case let .macCGClick(titled, instance):
            try await macDriver(for: instance).cgClick(titled: titled)

        case let .macRightClick(titled, instance):
            try await macDriver(for: instance).rightClick(titled: titled)

        case let .macContextMenuClick(elementTitle, menuItem, instance):
            try await macDriver(for: instance).contextMenuClick(elementTitle: elementTitle, menuItem: menuItem)

        case let .macUnpair(instance):
            try await macDriver(for: instance).unpair()

        case let .macReadClipboard(storeAs, instance):
            let value = await macDriver(for: instance).readClipboard()
            let suffix = instance > 0 ? " (mac\(instance + 1))" : ""
            logger.info("  Clipboard value\(suffix): \(value) → stored as ${\(storeAs)}")
            context.set(storeAs, value: value)

        case let .macWaitForElement(titled, timeout, instance):
            let resolvedTitle = context.resolve(titled)
            try await macDriver(for: instance).waitForElement(titled: resolvedTitle, timeout: timeout)

        case let .macWaitForElementToDisappear(titled, timeout, instance):
            let resolvedTitle = context.resolve(titled)
            try await macDriver(for: instance).waitForElementToDisappear(titled: resolvedTitle, timeout: timeout)

        case let .macWaitForElementQuery(query, timeout, instance):
            try await macDriver(for: instance).waitForElement(matching: query, timeout: timeout)

        case let .macWaitForElementQueryToDisappear(query, timeout, instance):
            try await macDriver(for: instance).waitForElementToDisappear(matching: query, timeout: timeout)

        case let .macOpenPanesWindow(instance):
            try await macDriver(for: instance).openPanesWindow()

        case let .macMoveWindow(x, y, instance):
            try await macDriver(for: instance).moveWindow(x: x, y: y)

        case let .macResizeWindow(width, height, instance):
            try await macDriver(for: instance).resizeWindow(width: width, height: height)

        case let .macSetSidebarWidth(width, instance):
            try await macDriver(for: instance).setSidebarWidth(width)

        case let .macFocusElement(titled, instance):
            try await macDriver(for: instance).focusElement(titled: titled)

        case let .macType(text, pressReturn, charDelay, instance):
            let resolvedText = context.resolve(text)
            try await macDriver(for: instance).type(text: resolvedText, pressReturn: pressReturn, charDelay: charDelay)

        case let .macScrollUp(pages, instance):
            try await macDriver(for: instance).scrollUp(pages: pages)

        case let .macScrollWheel(deltaY, count, instance):
            try await macDriver(for: instance).scrollWheel(deltaY: deltaY, count: count)

        case let .macClickAtPoint(x, y, instance):
            try await macDriver(for: instance).clickAtScreenPoint(x: x, y: y)

        case let .macDrag(fromX, fromY, toX, toY, instance):
            try await macDriver(for: instance).drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)

        case let .macScreenshot(label, compare, tolerance, perPixelThreshold, instance):
            let numberedLabel = nextScreenshotLabel(label)
            let actualPath = screenshotPath(for: numberedLabel)
            try await macDriver(for: instance).screenshot(output: actualPath)
            if compare, !skipComparison {
                return try compareScreenshot(actualPath: actualPath, label: numberedLabel, tolerance: tolerance, perPixelThreshold: perPixelThreshold)
            } else {
                return try captureWithoutComparison(actualPath: actualPath, label: numberedLabel)
            }

        // Tmux
        case let .tmuxCreateSession(name, width, height):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedName = context.resolve(name)
            let runner = processRunner
            // Use -f /dev/null to ignore user's tmux.conf (avoids base-index/pane-base-index
            // being set to non-zero values which would change pane targets).
            // Set DISABLE_AUTO_UPDATE to suppress oh-my-zsh update prompts that block the shell.
            _ = try await runner.runOrThrow(
                "tmux",
                arguments: ["-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", resolvedName, "-x", "\(width)", "-y", "\(height)", "-c", NSHomeDirectory(), "-e", "DISABLE_AUTO_UPDATE=true", "-e", "DISABLE_UPDATE_PROMPT=true"]
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

        case let .tmuxStorePaneId(target, storeAs):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedTarget = context.resolve(target)
            let runner = processRunner
            let result = try await runner.runOrThrow(
                "tmux",
                arguments: ["-S", socket, "display-message", "-t", resolvedTarget, "-p", "#{pane_id}"]
            )
            let paneId = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneId.isEmpty else {
                throw OrchestratorError.assertionFailed(
                    "Empty pane ID from tmux display-message for target '\(resolvedTarget)'"
                )
            }
            context.set(storeAs, value: paneId)
            logger.info("  Stored \(storeAs)=\(paneId)")

        case let .tmuxCapturePaneContent(target, storeAs):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedTarget = context.resolve(target)
            let runner = processRunner
            let result = try await runner.runOrThrow(
                "tmux",
                arguments: ["-S", socket, "capture-pane", "-t", resolvedTarget, "-p"]
            )
            let content = result.stdoutString
            context.set(storeAs, value: content)
            logger.info("  Captured pane content (\(content.count) chars) → stored as ${\(storeAs)}")

        case let .tmuxSendKeys(target, keys, literal):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedTarget = context.resolve(target)
            let resolvedKeys = context.resolve(keys)
            let runner = processRunner
            var args = ["-S", socket, "send-keys", "-t", resolvedTarget]
            if literal {
                args.append("-l")
            }
            args.append(resolvedKeys)
            _ = try await runner.runOrThrow("tmux", arguments: args)

        case let .tmuxCommand(arguments):
            let socket = context.resolve("${tmuxSocket}")
            let runner = processRunner
            let resolvedArgs = arguments.map { context.resolve($0) }
            _ = try await runner.runOrThrow("tmux", arguments: ["-f", "/dev/null", "-S", socket] + resolvedArgs)

        case let .tmuxStoreDisplayMessage(target, format, storeAs):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedTarget = context.resolve(target)
            let resolvedFormat = context.resolve(format)
            let runner = processRunner
            let result = try await runner.runOrThrow(
                "tmux",
                arguments: ["-S", socket, "display-message", "-t", resolvedTarget, "-p", resolvedFormat]
            )
            let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            context.set(storeAs, value: output)
            logger.info("  tmux display-message → '\(output)' stored as ${\(storeAs)}")

        case let .waitForTmuxDisplayMessage(target, format, contains, timeout):
            let socket = context.resolve("${tmuxSocket}")
            let resolvedTarget = context.resolve(target)
            let resolvedFormat = context.resolve(format)
            let resolvedContains = context.resolve(contains)
            let runner = processRunner
            try await Polling.waitUntil(
                description: "tmux display-message '\(resolvedFormat)' contains '\(resolvedContains)'",
                timeout: timeout,
                pollInterval: 1
            ) {
                let result = try? await runner.runOrThrow(
                    "tmux",
                    arguments: ["-S", socket, "display-message", "-t", resolvedTarget, "-p", resolvedFormat]
                )
                let value = result?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.contains(resolvedContains)
            }

        // Hook Events
        case let .macSendHookEvent(json, tmuxPane, projectPath, instance):
            let resolvedJson = context.resolve(json)
            let resolvedPane = context.resolve(tmuxPane)
            let resolvedPath = projectPath.map { context.resolve($0) }
            try await macDriver(for: instance).sendHookEvent(
                json: resolvedJson,
                tmuxPane: resolvedPane,
                projectPath: resolvedPath,
                hookPortFile: hookPortFilePath(for: instance)
            )

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

        case let .assertStoredContains(key, substring):
            guard let value = context.get(key) else {
                throw OrchestratorError.assertionFailed("Key '\(key)' not found in context")
            }
            let resolvedSubstring = context.resolve(substring)
            guard value.contains(resolvedSubstring) else {
                throw OrchestratorError.assertionFailed(
                    "\(key) does not contain '\(resolvedSubstring)'. Value: '\(value.prefix(200))'"
                )
            }

        case let .assertStoredNotContains(key, substring):
            guard let value = context.get(key) else {
                throw OrchestratorError.assertionFailed("Key '\(key)' not found in context")
            }
            let resolvedSubstring = context.resolve(substring)
            guard !value.contains(resolvedSubstring) else {
                throw OrchestratorError.assertionFailed(
                    "\(key) should NOT contain '\(resolvedSubstring)'. Value: '\(value.prefix(200))'"
                )
            }

        // Scripts
        case let .injectScript(name):
            // NOTE: The script is copied to NSTemporaryDirectory() and later executed inside
            // tmux via `$TMPDIR/<name>`. This works because the tmux server inherits the test
            // runner's environment, so `$TMPDIR` resolves to the same directory. If the tmux
            // server were started independently (different env), this assumption would break.
            let destPath = NSTemporaryDirectory() + name
            guard
                let sourceURL = Bundle.module.url(
                    forResource: name,
                    withExtension: nil,
                    subdirectory: "Scripts"
                ) else {
                throw OrchestratorError.configurationError(
                    "Script '\(name)' not found in bundled Scripts directory"
                )
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: destPath) {
                try fm.removeItem(atPath: destPath)
            }
            try fm.copyItem(atPath: sourceURL.path, toPath: destPath)
            injectedScriptPaths.append(destPath)
            logger.info("  Injected script '\(name)' → \(destPath)")

        // General
        case let .wait(seconds):
            try await Task.sleep(for: .seconds(seconds))

        case let .storeValue(key, value):
            context.set(key, value: value)

        case let .readFile(path, storeAs):
            let resolvedPath = context.resolve(path)
            let content = (try? String(contentsOfFile: resolvedPath, encoding: .utf8)) ?? ""
            context.set(storeAs, value: content)
            logger.info("  Read file (\(content.count) chars) → stored as ${\(storeAs)}")

        case let .waitForFileContains(path, substring, storeAs, timeout, pollInterval):
            let resolvedPath = context.resolve(path)
            let resolvedSubstring = context.resolve(substring)
            try await Polling.waitUntil(
                description: "file '\(resolvedPath)' contains '\(resolvedSubstring)'",
                timeout: timeout,
                pollInterval: pollInterval
            ) {
                guard let content = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
                    return false
                }
                return content.contains(resolvedSubstring)
            }
            let content = (try? String(contentsOfFile: resolvedPath, encoding: .utf8)) ?? ""
            context.set(storeAs, value: content)
            logger.info("  File contains '\(resolvedSubstring)' (\(content.count) chars) → stored as ${\(storeAs)}")

        case let .log(message):
            logger.info("  LOG: \(context.resolve(message))")
        }
        return nil
    }

    // MARK: - Mac Instance Helpers

    /// Return (or create) the macOS driver for the given instance number.
    /// Instance 0 is the primary app; instance 1+ are additional instances with
    /// derived ports and labels.
    private func macDriver(for instance: Int) -> MacOSDriver {
        if let driver = macDrivers[instance] {
            return driver
        }
        let port = MacOSDriver.defaultTestAccessibilityPort + UInt16(instance)
        let label = instance == 0 ? "e2e.macos-driver" : "e2e.macos-driver-\(instance + 1)"
        let driver = MacOSDriver(label: label, testAccessibilityPort: port)
        macDrivers[instance] = driver
        return driver
    }

    /// Return the hook port file path for the given instance number.
    /// Instance 0 uses the base `hookPortFile`; instance N uses `hookPortFile-N`.
    private func hookPortFilePath(for instance: Int) -> String {
        instance == 0 ? hookPortFile : "\(hookPortFile)-\(instance)"
    }

    /// Return the tmux socket path for the given instance number.
    /// Each instance gets its own tmux socket so it doesn't see the other's
    /// local sessions (important for Mac-to-Mac pairing tests where the viewer
    /// must only see the host's sessions via the relay, not locally).
    private func tmuxSocketPath(for instance: Int) -> String {
        let base = tmuxSocket ?? NSTemporaryDirectory() + "claudespy-e2e.sock"
        return instance == 0 ? base : "\(base)-\(instance)"
    }

    /// Return the notification log file path for the given instance number.
    /// The macOS app writes terminal notifications here during E2E tests
    /// so scenarios can verify notification delivery via `readFile`.
    private func notificationLogPath(for instance: Int) -> String {
        let base = NSTemporaryDirectory() + "claudespy-e2e-notifications.log"
        return instance == 0 ? base : "\(base)-\(instance)"
    }

    /// Return the push notification log file path for the given instance number.
    /// The macOS app writes push notification sends here during E2E tests
    /// so scenarios can verify push delivery or suppression via `readFile`.
    private func pushLogPath(for instance: Int) -> String {
        let base = NSTemporaryDirectory() + "claudespy-e2e-push.log"
        return instance == 0 ? base : "\(base)-\(instance)"
    }

    // MARK: - Script Cleanup

    /// Remove all scripts that were injected via `injectScript` during this scenario.
    private func cleanupInjectedScripts() {
        guard !injectedScriptPaths.isEmpty else { return }
        let fm = FileManager.default
        for path in injectedScriptPaths {
            do {
                try fm.removeItem(atPath: path)
                logger.info("  Removed injected script: \(path)")
            } catch {
                logger.warning("  Failed to remove injected script \(path): \(error)")
            }
        }
        injectedScriptPaths.removeAll()
    }

    // MARK: - Helpers

    /// Capture a screenshot without comparison, saving it as a baseline if none exists.
    private func captureWithoutComparison(actualPath: String, label: String) throws -> ScreenshotResult {
        let baseline = baselinePath(for: label)
        let baselineCreated: Bool
        if !FileManager.default.fileExists(atPath: baseline) {
            try saveScreenshot(from: actualPath, to: baseline)
            baselineCreated = true
        } else {
            baselineCreated = false
        }
        return ScreenshotResult(
            label: label,
            actualPath: actualPath,
            baselinePath: baseline,
            diffPath: nil,
            diffPercentage: nil,
            passed: true,
            baselineCreated: baselineCreated
        )
    }

    /// Compare a screenshot against its baseline and throw on mismatch.
    /// If no baseline exists yet, saves the actual screenshot as the new baseline.
    private func compareScreenshot(actualPath: String, label: String, tolerance: Double, perPixelThreshold: Double) throws -> ScreenshotResult {
        let baselinePath = baselinePath(for: label)
        let diffPath = baselinePath.replacingOccurrences(of: ".png", with: "_diff.png")
        let fm = FileManager.default

        // Clean up stale diff images from prior runs
        try? fm.removeItem(atPath: diffPath)

        // No baseline yet — save this screenshot as the new baseline
        guard fm.fileExists(atPath: baselinePath) else {
            try saveScreenshot(from: actualPath, to: baselinePath)
            logger.info("  Baseline created for '\(label)'")
            return ScreenshotResult(
                label: label,
                actualPath: actualPath,
                baselinePath: baselinePath,
                diffPath: nil,
                diffPercentage: nil,
                passed: true,
                baselineCreated: true
            )
        }

        let result: ComparisonResult
        do {
            result = try ScreenshotComparator.compare(
                actualPath: actualPath,
                baselinePath: baselinePath,
                diffPath: diffPath,
                tolerance: tolerance,
                perPixelThreshold: perPixelThreshold
            )
        } catch {
            // Wrap pre-comparison errors (e.g. size mismatch) so the screenshot
            // result with actual/baseline paths is preserved in the report.
            let screenshotResult = ScreenshotResult(
                label: label,
                actualPath: actualPath,
                baselinePath: baselinePath,
                diffPath: nil,
                diffPercentage: nil,
                passed: false,
                baselineCreated: false
            )
            throw OrchestratorError.screenshotMismatch(
                screenshotResult,
                error.localizedDescription
            )
        }

        let screenshotResult = ScreenshotResult(
            label: label,
            actualPath: actualPath,
            baselinePath: baselinePath,
            diffPath: result.diffPath,
            diffPercentage: result.diffPercentage,
            passed: result.passed,
            baselineCreated: false
        )

        guard result.passed else {
            let diffStr = String(format: "%.2f", result.diffPercentage)
            let tolStr = String(format: "%.2f", tolerance)
            let diffInfo = result.diffPath.map { " — diff: \($0)" } ?? ""
            throw OrchestratorError.screenshotMismatch(
                screenshotResult,
                "Screenshot '\(label)' differs from baseline by \(diffStr)% (tolerance: \(tolStr)%)\(diffInfo)"
            )
        }

        return screenshotResult
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
    case screenshotMismatch(TestOrchestrator.ScreenshotResult, String)

    public var errorDescription: String? {
        switch self {
        case let .assertionFailed(message):
            "Assertion failed: \(message)"
        case let .configurationError(message):
            "Configuration error: \(message)"
        case let .stepFailed(step, underlying):
            "Step \(step) failed: \(underlying.localizedDescription)"
        case let .screenshotMismatch(_, message):
            "Screenshot mismatch: \(message)"
        }
    }
}
