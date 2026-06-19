import ClaudeSpyNetworking
import SwiftUI

/// The shared session-info surface: a recap card (when a turn has finished), the
/// session identity (pane, project, status), and the OTEL usage breakdown
/// (tokens by type, cost, model, latency, the #598 aggregate counters, and a
/// per-turn latency sparkline).
///
/// Pure presentation — the host supplies the already-resolved values, so the
/// same `List` renders inside the iOS detail popover and the macOS sidebar's
/// "Session Info" sheet. Platform chrome (navigation title, Done button, sheet
/// sizing) lives in each caller's wrapper, not here.
public struct SessionInfoView: View {
    let session: AgentSession?
    let paneId: String
    let isPaneActive: Bool
    var telemetry: SessionTelemetry?
    var permissionMode: String?
    var permissionModeTrigger: String?
    var recap: SessionRecap?

    public init(
        session: AgentSession?,
        paneId: String,
        isPaneActive: Bool,
        telemetry: SessionTelemetry? = nil,
        permissionMode: String? = nil,
        permissionModeTrigger: String? = nil,
        recap: SessionRecap? = nil
    ) {
        self.session = session
        self.paneId = paneId
        self.isPaneActive = isPaneActive
        self.telemetry = telemetry
        self.permissionMode = permissionMode
        self.permissionModeTrigger = permissionModeTrigger
        self.recap = recap
    }

    private var hasMode: Bool {
        PermissionModePresentation(mode: permissionMode) != nil
    }

    public var body: some View {
        if let session {
            List {
                if let recap, recap.hasMeaningfulMetrics {
                    Section {
                        SessionRecapCard(recap: recap)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }

                Section("Session Info") {
                    LabeledContent("Pane ID", value: paneId)

                    if let projectPath = session.detectedProjectPath, !projectPath.isEmpty {
                        LabeledContent("Project") {
                            Text(projectPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Status") {
                        HStack {
                            Circle()
                                .fill(isPaneActive ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(session.statusLabel)
                        }
                    }
                }

                if telemetry != nil || hasMode {
                    usageSection
                }
            }
        } else {
            ContentUnavailableView(
                "Session Not Found",
                symbol: .exclamationmarkTriangle,
                description: "This session may have ended."
            )
        }
    }

    /// OTEL usage breakdown (issue #597, surface B): tokens by type, cost,
    /// model, last-turn latency, permission mode + trigger, and a per-turn
    /// latency sparkline.
    private var usageSection: some View {
        Section("Usage") {
            if let telemetry {
                LabeledContent("Tokens (input + output)", value: telemetry.tokensUsed.abbreviatedTokenCount)
                LabeledContent("Input", value: telemetry.inputTokens.abbreviatedTokenCount)
                LabeledContent("Output", value: telemetry.outputTokens.abbreviatedTokenCount)
                LabeledContent("Cache read", value: telemetry.cacheReadTokens.abbreviatedTokenCount)
                LabeledContent("Cache write", value: telemetry.cacheCreationTokens.abbreviatedTokenCount)
                // Codex emits no cost, so a `$0.00` would be misleading — omit it
                // like the recap line / overview do.
                if telemetry.costUSD > 0 {
                    LabeledContent("Cost", value: telemetry.costUSD.usdCostString)
                }
                if let model = telemetry.model {
                    LabeledContent("Model", value: shortModelName(model))
                }
                if let latency = telemetry.lastTurnLatencyMs {
                    LabeledContent("Last turn", value: latency.latencyString)
                }
                // Issue #598 aggregate counters, shown when non-zero.
                if telemetry.activeTimeSeconds > 0 {
                    LabeledContent("Active time", value: telemetry.activeTimeSeconds.activeTimeString)
                }
                if telemetry.toolInvocations > 0 {
                    LabeledContent("Tools", value: "\(telemetry.toolInvocations)")
                }
                if telemetry.linesAdded > 0 || telemetry.linesRemoved > 0 {
                    LabeledContent("Lines", value: "+\(telemetry.linesAdded) / −\(telemetry.linesRemoved)")
                }
                if telemetry.commitCount > 0 {
                    LabeledContent("Commits", value: "\(telemetry.commitCount)")
                }
                if telemetry.pullRequestCount > 0 {
                    LabeledContent("Pull requests", value: "\(telemetry.pullRequestCount)")
                }
            }

            if hasMode {
                LabeledContent("Permission mode") {
                    VStack(alignment: .trailing, spacing: 2) {
                        PermissionModeChip(mode: permissionMode)
                        if let trigger = permissionModeTrigger, !trigger.isEmpty {
                            Text(trigger)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let telemetry {
                let latencies = telemetry.recentTurns.compactMap { $0.latencyMs.map(Double.init) }
                if latencies.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Turn latency")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Sparkline(values: latencies)
                            .frame(height: 32)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

#if DEBUG
    #Preview("Session Info") {
        SessionInfoView(
            session: AgentSession(
                paneId: "%1",
                pluginID: "claude-code",
                detectedProjectPath: "/Users/dev/Development/ClaudeSpy",
                state: .doneWorking(summary: "Added the endpoint")
            ),
            paneId: "%1",
            isPaneActive: true,
            telemetry: SessionTelemetry(
                tokensUsed: 88_000,
                inputTokens: 60_000,
                outputTokens: 28_000,
                costUSD: 0.74,
                model: "claude-opus-4-8",
                activeTimeSeconds: 720,
                linesAdded: 120,
                linesRemoved: 30,
                toolInvocations: 28,
                commitCount: 3
            ),
            permissionMode: "default",
            recap: SessionRecap(
                projectName: "ClaudeSpy",
                model: "claude-opus-4-8",
                tokensUsed: 88_000,
                costUSD: 0.74,
                commitCount: 3,
                activeTimeSeconds: 720,
                toolInvocations: 28
            )
        )
    }
#endif
