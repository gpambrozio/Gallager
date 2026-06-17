import ClaudeSpyNetworking
import SwiftUI

// MARK: - Session Recap Card

/// A compact end-of-turn / end-of-session recap (issue #598, part A), shown in
/// the session detail when a turn finishes. Reads the ``SessionRecap`` stamped on
/// the pane; renders the same one-line summary the end-of-session push uses, plus
/// a lines-changed footnote when present. Shared by iOS and macOS.
public struct SessionRecapCard: View {
    private let recap: SessionRecap

    public init(recap: SessionRecap) {
        self.recap = recap
    }

    private var title: String {
        recap.isFinal ? "Session complete" : "Done"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let model = recap.model {
                    ModelTag(model: model)
                }
            }

            Text(recapDetailLine(recap))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if recap.linesAdded > 0 || recap.linesRemoved > 0 {
                Text("+\(recap.linesAdded) / −\(recap.linesRemoved) lines")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-recap-card")
        .accessibilityLabel("\(title). \(recapDetailLine(recap))")
    }
}

#Preview("End-of-turn recap") {
    SessionRecapCard(recap: SessionRecap(
        projectName: "Gallager",
        model: "claude-opus-4-8",
        tokensUsed: 45_000,
        costUSD: 1.20,
        commitCount: 3,
        activeTimeSeconds: 720,
        toolInvocations: 28,
        linesAdded: 120,
        linesRemoved: 30,
        summary: "Wired up the recap card",
        isFinal: false
    ))
    .padding()
    .frame(width: 360)
}

#Preview("Final recap, minimal") {
    SessionRecapCard(recap: SessionRecap(
        tokensUsed: 1_200,
        costUSD: 0.05,
        toolInvocations: 1,
        isFinal: true
    ))
    .padding()
    .frame(width: 360)
}
