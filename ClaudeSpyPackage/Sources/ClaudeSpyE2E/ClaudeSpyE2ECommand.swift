import ArgumentParser
import ClaudeSpyE2ELib
import Dispatch
import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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

    @Option(name: .long, help: "Run specific scenario(s) by name; comma-separated for multiple (in interactive mode, runs the first one before waiting)")
    var scenario: String?

    @Option(name: .long, help: "Directory for screenshots")
    var screenshotsDir = NSTemporaryDirectory() + "e2e-screenshots"

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

    @Option(
        name: .long,
        help: "Base directory for per-instance --gallager-state-root (plugin ingress socket + state). Default: <tmpdir>/claudespy-e2e-gallager"
    )
    var gallagerStateRoot: String?

    @Option(name: .long, help: "Path to write verbose logs (default: <tmpdir>/claudespy-e2e/e2e.log)")
    var logFile: String?

    @Option(name: .long, help: "Dashboard URL for live CI progress updates (e.g. http://localhost:3000). Fails silently if unreachable.")
    var dashboardUrl: String?

    @Option(name: .long, help: "PR number to display in dashboard CI updates")
    var dashboardPrNumber: Int?

    @Option(name: .long, help: "PR title to display in dashboard CI updates")
    var dashboardPrTitle: String?

    @Flag(name: .long, help: "List all available scenarios and exit")
    var listScenarios = false

    func run() async throws {
        if listScenarios {
            printScenarioList()
            return
        }

        // Redirect verbose swift-log output to a file so the terminal stays clean
        let logPath = logFile ?? (NSTemporaryDirectory() + "claudespy-e2e/e2e.log")
        let logDir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        E2ELogging.bootstrapFileLogging(to: logPath)

        // Determine which scenarios we'll run to validate required paths
        let selectedScenarios: [TestScenario] = resolveScenarios()
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

        let isTTY = isatty(fileno(stderr)) != 0
        let bold = isTTY ? "\u{1b}[1m" : ""
        let dim = isTTY ? "\u{1b}[2m" : ""
        let cyan = isTTY ? "\u{1b}[36m" : ""
        let reset = isTTY ? "\u{1b}[0m" : ""

        fputs("\n\(cyan)\(bold)ClaudeSpy E2E Test Coordinator\(reset)\n", stderr)
        fputs("\(dim)  iOS app:     \(iosAppPath ?? "(not needed)")\n", stderr)
        fputs("  macOS app:   \(macosAppPath)\n", stderr)
        fputs("  Simulator:   \(simName)\n", stderr)
        fputs("  Screenshots: \(screenshotsDir)\n", stderr)
        fputs("  Baselines:   \(baselinesDir)\n", stderr)
        fputs("  Compare:     \(noCompare ? "disabled" : "enabled")\n", stderr)
        fputs("  Tmux socket: \(tmuxSocket ?? "(default)")\n", stderr)
        fputs("  E2E runner:  \(e2eRunnerPath ?? "(none)")\n", stderr)
        fputs("  State root:  \(gallagerStateRoot ?? "(default: <tmpdir>/claudespy-e2e-gallager)")\n", stderr)
        fputs("  Log file:    \(logPath)\(reset)\n\n", stderr)

        var reporters: [any TestProgressReporter] = [TerminalReporter()]
        var dashboardReporter: DashboardReporter?
        if let urlString = dashboardUrl, let url = URL(string: urlString) {
            let dr = DashboardReporter(dashboardURL: url, prNumber: dashboardPrNumber, prTitle: dashboardPrTitle)
            dashboardReporter = dr
            reporters.append(dr)
        }

        // Resolve scenarios up front for the non-interactive run so the
        // Gallager progress reporter knows the total count.
        let scenariosToRun: [TestScenario] = interactive ? [] : resolveScenarios()
        if !interactive {
            reporters.append(GallagerProgressReporter(totalScenarios: scenariosToRun.count))
        }

        let reporter = CompositeReporter(reporters)

        let orchestrator = TestOrchestrator(
            iosAppPath: iosAppPath,
            macOSAppPath: macosAppPath,
            simulatorName: simName,
            screenshotsDir: screenshotsDir,
            baselinesDir: baselinesDir,
            tmuxSocket: tmuxSocket,
            e2eRunnerPath: e2eRunnerPath,
            skipComparison: noCompare,
            gallagerStateRootBase: gallagerStateRoot,
            reporter: reporter
        )

        // Handle Ctrl-C: clean up processes then exit
        setupSignalHandler(orchestrator: orchestrator)

        if interactive {
            try await runInteractive(orchestrator: orchestrator)
        } else {
            await dashboardReporter?.sendRunStarted(totalScenarios: scenariosToRun.count)
            try await runTests(scenarios: scenariosToRun, orchestrator: orchestrator)
        }
    }

    /// Install a SIGINT handler that runs cleanup before exiting.
    private func setupSignalHandler(orchestrator: TestOrchestrator) {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        // Ignore default SIGINT so our handler runs instead
        signal(SIGINT, SIG_IGN)
        source.setEventHandler {
            fputs("\n\u{1b}[33mInterrupted — cleaning up...\u{1b}[0m\n", stderr)
            Task {
                await orchestrator.cleanup()
                fputs("\u{1b}[33mCleanup complete.\u{1b}[0m\n", stderr)
                _Exit(130)
            }
        }
        source.resume()
        // Keep the source alive for the process lifetime
        Self._signalSource = source
    }

    /// Stored to prevent the dispatch source from being deallocated.
    private nonisolated(unsafe) static var _signalSource: DispatchSourceSignal?

    private func printScenarioList() {
        print("Available scenarios:")
        print()
        for scenario in Self.allScenarios {
            let tags = scenario.tags.map { "[\($0)]" }.joined(separator: " ")
            print("  - \(scenario.name) (\(scenario.steps.count) steps) \(tags)")
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

        print()
        print("==========================================")
        if result.success {
            print("  Everything is running!")
        } else {
            print("  Setup failed at step \(result.failedStep ?? 0): \(result.error ?? "Unknown")")
            print("  Apps are still running so you can inspect state.")
        }
        print("  Press Enter to shut down...")
        print("==========================================")
        print()

        _ = readLine()

        print("Shutting down...")
        await orchestrator.cleanup()
        print("Done.")

        if !result.success {
            throw ExitCode.failure
        }
    }

    private static let allScenarios: [TestScenario] = [
        NewTerminalScenario.scenario,
        UnpairFromIOSScenario.scenario,
        UnpairFromMacOSScenario.scenario,
        DisconnectIOSUnpairMacOSScenario.scenario,
        DisconnectMacOSUnpairIOSScenario.scenario,
        ResizePaneScenario.scenario,
        ProjectListScenario.scenario,
        ClaudeSessionsShowScenario.scenario,
        ClaudeSessionUpdatesScenario.scenario,
        ClaudeSessionRepliesPersistScenario.scenario,
        ProjectSearchMacOSScenario.scenario,
        ProjectSearchIOSScenario.scenario,
        EmptyStateNewSessionScenario.scenario,
        TwoMacPairingScenario.scenario,
        TerminalRenderingBugsScenario.scenario,
        RapidKeystrokeOrderScenario.scenario,
        StopHookSummaryScenario.scenario,
        TerminalLinksScenario.scenario,
        TerminalFileLinkScenario.scenario,
        TerminalTitleMacToMacScenario.scenario,
        TerminalTitleMacToIOSScenario.scenario,
        TerminalTitleInitialConnectionScenario.scenario,
        TerminalTitlePersistenceScenario.scenario,
        TruecolorRenderingScenario.scenario,
        ScrollbackGapScenario.scenario,
        YoloModeStateSyncScenario.scenario,
        YoloModeMacToMacScenario.scenario,
        YoloModeContextCompactionScenario.scenario,
        TerminalNotificationScenario.scenario,
        CursorStyleScenario.scenario,
        TableRenderingScenario.scenario,
        YoloModeAutoApproveScenario.scenario,
        EmojiTableRenderingScenario.scenario,
        MultiPaneWindowScenario.scenario,
        DAResponseLeakScenario.scenario,
        MarkHandledScenario.scenario,
        BadgeAggregationScenario.scenario,
        WindowDescriptionSyncScenario.scenario,
        MultiPaneIOSScenario.scenario,
        KittyKeyboardProtocolScenario.scenario,
        FooterRenderingScenario.scenario,
        AlwaysAutoResizeScenario.scenario,
        MultiWindowTabsScenario.scenario,
        MultiWindowTabsIOSScenario.scenario,
        MultiWindowTabsMacViewerScenario.scenario,
        WindowRenameScenario.scenario,
        MouseSupportScenario.scenario,
        RemoteMouseSupportScenario.scenario,
        FileBrowserScenario.scenario,
        GitBrowserScenario.scenario,
        OpenInEditorScenario.scenario,
        SidebarLayoutScenario.scenario,
        HostDisconnectClearsSessionsScenario.scenario,
        PromptEditorScenario.scenario,
        PromptEditorRemoteScenario.scenario,
        CloseWindowTabScenario.scenario,
        GallagerCLIScenario.scenario,
        CloseRemoteWindowIOSScenario.scenario,
        CloseRemoteWindowMacScenario.scenario,
        ClipboardSyncScenario.scenario,
        ClipboardSyncMacViewerScenario.scenario,
        ImagePasteRemoteScenario.scenario,
        FileDropLocalScenario.scenario,
        FileDropRemoteScenario.scenario,
        UnderlineLeakScenario.scenario,
        BackgroundLeakScenario.scenario,
        VersionMismatchOldIOSViewerScenario.scenario,
        VersionMismatchOldMacHostScenario.scenario,
        VersionMismatchOldMacViewerScenario.scenario,
        VersionMismatchOldMacHostIOSViewerScenario.scenario,
        AskUserQuestionScenario.scenario,
        MarkdownWriteOpenSuggestionScenario.scenario,
        TerminalFileLinkMouseModeScenario.scenario,
        CloseFirstWindowAfterNavigationScenario.scenario,
        IOSMouseModeDragScenario.scenario,
        MirrorAttachExtraNewlinesScenario.scenario,
        TerminalProgressBarScenario.scenario,
        SessionColorSyncScenario.scenario,
        SessionEmojiSyncScenario.scenario,
        AppearanceModeScenario.scenario,
        RenameViewerDeviceScenario.scenario,
        TerminalEnvVarsScenario.scenario,
        OTELTelemetryRenderScenario.scenario,
        OTELUsageOverviewScenario.scenario,
        MacSessionInfoSheetScenario.scenario,
        BrowserTabFromTerminalLinkScenario.scenario,
        FileTextSearchScenario.scenario,
        SplitTabScenario.scenario,
        TabReorderScenario.scenario,
        RemoteTabReorderScenario.scenario,
        RemoteSplitCollapseResizeScenario.scenario,
        ProjectPickerArrowNavScenario.scenario,
        NewLocalSessionAfterRemoteScenario.scenario,
        CloseBrowserTabReturnsToParentScenario.scenario,
        TerminalFileLinkStaleCacheScenario.scenario,
        OSCBackgroundProbeScenario.scenario,
        EchoIngressRoundTripScenario.scenario,
        EchoResponseRoundTripScenario.scenario,
        PluginSidecarIngressScenario.scenario,
        PluginSidecarResponseRoundTripScenario.scenario,
        PluginCrashRestartScenario.scenario,
        PluginCLIScenario.scenario,
        PluginEnableDisableScenario.scenario,
        ClosePaneOnSessionEndScenario.scenario,
        CodexSessionUpdatesScenario.scenario,
        CodexResponseRoundTripScenario.scenario,
        MultiPluginPresentationsScenario.scenario,
        CreateFromProjectLaunchScenario.scenario,
        MultiPluginCoexistenceScenario.scenario,
        CodexFormsParityScenario.scenario,
        PermissionSuggestionDenyScenario.scenario,
        AgentsSettingsTabScenario.scenario,
        TabCycleReorderScenario.scenario,
        BadgeClearsOnAgentResumeScenario.scenario,
        GitTabFileActionsScenario.scenario,
        ComposerBandRecaptureScenario.scenario,
        CodexGuardianSuppressionScenario.scenario,
        CodexOTELTelemetryRenderScenario.scenario,
        ScrollbackBandRecaptureScenario.scenario,
        LongTitleTruncationIOSScenario.scenario,
        FolderLayoutPersistenceScenario.scenario,
        RemoteLayoutPersistenceMacViewerScenario.scenario,
        PluginSidecarQuestionRoundTripScenario.scenario,
        PluginSidecarPlanApprovalScenario.scenario,
        PluginSidecarPermissionAllowScenario.scenario,
        PluginSidecarSessionEndedScenario.scenario,
        AgentsRemovePluginLiveScenario.scenario,
        AgentsInstallZipAutoSelectScenario.scenario,
        OTELPortFallbackScenario.scenario,
    ]

    private func resolveScenarios() -> [TestScenario] {
        guard let scenario else { return Self.allScenarios }
        let requested = scenario
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Preserve the user-provided order so scenarios run in the sequence
        // the caller asked for, regardless of `allScenarios` ordering.
        return requested.compactMap { name in
            Self.allScenarios.first { $0.name == name }
        }
    }

    private func runTests(scenarios scenariosToRun: [TestScenario], orchestrator: TestOrchestrator) async throws {
        if scenariosToRun.isEmpty, let scenarioName = scenario {
            print("ERROR: No scenario named '\(scenarioName)'")
            print("Available: \(Self.allScenarios.map(\.name).joined(separator: ", "))")
            throw ExitCode.failure
        }

        print("Running \(scenariosToRun.count) scenario(s)...")

        let results = await orchestrator.runAll(scenariosToRun)

        // Write JSON results if requested
        if let jsonOutputPath = jsonOutput {
            try writeJSONResults(results, to: jsonOutputPath)
        }

        // Summary is printed by the reporter via runAll.
        // Just check for failures to set exit code.
        let allPassed = results.allSatisfy(\.success)
        if !allPassed {
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
