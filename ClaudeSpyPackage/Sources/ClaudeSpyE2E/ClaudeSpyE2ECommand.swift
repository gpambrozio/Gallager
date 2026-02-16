import ArgumentParser
import ClaudeSpyE2ELib
import Foundation

@main
struct ClaudeSpyE2ECommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ClaudeSpyE2E",
        abstract: "E2E test coordinator for ClaudeSpy"
    )

    @Option(name: .long, help: "Path to built Gallager.app (iOS simulator)")
    var iosAppPath: String?

    @Option(name: .long, help: "Path to built Gallager.app (macOS)")
    var macosAppPath: String?

    @Option(name: .long, help: "Simulator device name")
    var simName = "iPhone 16"

    @Option(name: .long, help: "Run specific scenario by name (in interactive mode, runs it before waiting)")
    var scenario: String?

    @Option(name: .long, help: "Directory for screenshots")
    var screenshotsDir = "/tmp/e2e-screenshots"

    @Option(name: .long, help: "Directory for screenshot baselines (comparison reference images)")
    var baselinesDir = "E2ETests"

    @Option(name: .long, help: "Tmux socket path for isolation")
    var tmuxSocket: String?

    @Option(name: .long, help: "Path to E2E runner derived data (from build-for-testing)")
    var e2eRunnerPath: String?

    @Flag(name: .long, help: "Start server and apps, then wait for Enter before shutting down")
    var interactive = false

    @Flag(name: .long, help: "Skip all screenshot comparisons (still takes screenshots)")
    var noCompare = false

    @Option(name: .long, help: "Write detailed JSON results to this file path")
    var jsonOutput: String?

    @Flag(name: .long, help: "List all available scenarios and exit")
    var listScenarios = false

    func run() async throws {
        if listScenarios {
            printScenarioList()
            return
        }

        // Determine which scenarios we'll run to validate required paths
        let selectedScenarios: [TestScenario]
        if let scenarioName = scenario {
            selectedScenarios = Self.allScenarios.filter { $0.name == scenarioName }
        } else {
            selectedScenarios = Self.allScenarios
        }
        let needsIOS = selectedScenarios.contains { !$0.tags.contains("macos-only") }

        if needsIOS {
            guard iosAppPath != nil else {
                print("ERROR: --ios-app-path is required for scenarios that use iOS")
                throw ExitCode.failure
            }
        }
        guard let macosAppPath else {
            print("ERROR: --macos-app-path is required")
            throw ExitCode.failure
        }

        print("ClaudeSpy E2E Test Coordinator")
        print("==============================")
        print("iOS app:     \(iosAppPath ?? "(not needed)")")
        print("macOS app:   \(macosAppPath)")
        print("Simulator:   \(simName)")
        print("Screenshots: \(screenshotsDir)")
        print("Baselines:   \(baselinesDir)")
        print("Compare:     \(noCompare ? "disabled" : "enabled")")
        print("Tmux socket: \(tmuxSocket ?? "(default)")")
        print("E2E runner:  \(e2eRunnerPath ?? "(none)")")
        print()

        let orchestrator = TestOrchestrator(
            iosAppPath: iosAppPath,
            macOSAppPath: macosAppPath,
            simulatorName: simName,
            screenshotsDir: screenshotsDir,
            baselinesDir: baselinesDir,
            tmuxSocket: tmuxSocket,
            e2eRunnerPath: e2eRunnerPath,
            scenarioNames: Self.allScenarios.map(\.name),
            skipComparison: noCompare
        )

        if interactive {
            try await runInteractive(orchestrator: orchestrator)
        } else {
            try await runTests(orchestrator: orchestrator)
        }
    }

    private func printScenarioList() {
        print("Available scenarios:")
        print()
        for (index, scenario) in Self.allScenarios.enumerated() {
            let num = String(format: "%02d", index + 1)
            let tags = scenario.tags.map { "[\($0)]" }.joined(separator: " ")
            print("  \(num). \(scenario.name) (\(scenario.steps.count) steps) \(tags)")
        }
    }

    private func runInteractive(orchestrator: TestOrchestrator) async throws {
        let setupScenario: TestScenario
        if let scenarioName = scenario {
            guard let found = Self.allScenarios.first(where: { $0.name == scenarioName }) else {
                print("ERROR: No scenario named '\(scenarioName)'")
                print("Available: \(Self.allScenarios.map(\.name).joined(separator: ", "))")
                throw ExitCode.failure
            }
            print("Interactive mode: running '\(scenarioName)' then waiting...")
            setupScenario = found
        } else {
            print("Interactive mode: launching all apps...")
            setupScenario = LaunchAllScenario.scenario
        }
        print()

        let result = await orchestrator.run(setupScenario)

        guard result.success else {
            print("Setup failed at step \(result.failedStep ?? 0): \(result.error ?? "Unknown")")
            await orchestrator.cleanup()
            throw ExitCode.failure
        }

        print()
        print("==========================================")
        print("  Everything is running!")
        print("  Press Enter to shut down...")
        print("==========================================")
        print()

        _ = readLine()

        print("Shutting down...")
        await orchestrator.cleanup()
        print("Done.")
    }

    private static let allScenarios: [TestScenario] = [
        FreshPairingScenario.scenario,
        NewTerminalScenario.scenario,
        UnpairFromIOSScenario.scenario,
        UnpairFromMacOSScenario.scenario,
        DisconnectIOSUnpairMacOSScenario.scenario,
        DisconnectMacOSUnpairIOSScenario.scenario,
        ResizePaneScenario.scenario,
        ProjectListScenario.scenario,
    ]

    private func runTests(orchestrator: TestOrchestrator) async throws {
        // Filter if a specific scenario is requested
        let scenariosToRun: [TestScenario]
        if let scenarioName = scenario {
            scenariosToRun = Self.allScenarios.filter { $0.name == scenarioName }
            if scenariosToRun.isEmpty {
                print("ERROR: No scenario named '\(scenarioName)'")
                print("Available: \(Self.allScenarios.map(\.name).joined(separator: ", "))")
                throw ExitCode.failure
            }
        } else {
            scenariosToRun = Self.allScenarios
        }

        print("Running \(scenariosToRun.count) scenario(s)...")
        print()

        let results = await orchestrator.runAll(scenariosToRun)

        // Write JSON results if requested
        if let jsonOutputPath = jsonOutput {
            try writeJSONResults(results, to: jsonOutputPath)
        }

        // Print summary
        print()
        print("Results")
        print("-------")

        var allPassed = true
        for result in results {
            let status = result.success ? "PASS" : "FAIL"
            let duration = String(format: "%.1fs", result.duration)
            print("  [\(status)] \(result.scenarioName) (\(duration))")

            if let error = result.error, let step = result.failedStep {
                print("         Failed at step \(step): \(error)")
                allPassed = false
            }
        }

        print()
        if allPassed {
            print("All scenarios passed!")
        } else {
            print("Some scenarios failed.")
            throw ExitCode.failure
        }
    }

    /// Write detailed results as JSON for report generation
    private func writeJSONResults(_ results: [TestOrchestrator.ScenarioResult], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(results)

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        print("JSON results written to: \(path)")
    }
}
