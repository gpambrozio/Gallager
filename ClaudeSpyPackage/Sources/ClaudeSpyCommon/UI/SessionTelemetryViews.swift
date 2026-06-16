import ClaudeSpyNetworking
import SwiftUI

// MARK: - Model Name

/// Shortens a Claude model id for a glanceable tag: `"claude-opus-4-8" →
/// "opus-4.8"`, `"claude-sonnet-4-6" → "sonnet-4.6"`. Best-effort: drops the
/// `claude-` prefix and a trailing `yyyymmdd` date, and collapses a numeric
/// `major-minor` pair into `major.minor`. Unknown shapes pass through readable.
public func shortModelName(_ model: String) -> String {
    let stripped = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    var parts = stripped.split(separator: "-").map(String.init)
    guard !parts.isEmpty else { return model }
    if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
        parts.removeLast()
    }
    var result = ""
    for (index, part) in parts.enumerated() {
        if index == 0 {
            result = part
            continue
        }
        let prevIsNumber = parts[index - 1].allSatisfy(\.isNumber)
        let currentIsNumber = part.allSatisfy(\.isNumber)
        result += (prevIsNumber && currentIsNumber) ? "." + part : "-" + part
    }
    return result.isEmpty ? model : result
}

// MARK: - Permission Mode

/// Visual presentation for a Claude permission mode chip. Returns `nil` only for
/// an *unknown* mode (`nil`/empty — e.g. before any hook has reported one), so a
/// session with a known mode always shows a chip. `default` renders a calm,
/// neutral chip; the supervision-relevant modes get louder treatment, and
/// `bypassPermissions` is loud/filled (issue #597, surface A).
public struct PermissionModePresentation {
    public let label: String
    public let symbol: Symbols
    public let tint: Color
    /// `bypassPermissions` runs unsupervised — render it loud (filled).
    public let isElevated: Bool

    public init?(mode: String?) {
        guard let mode, !mode.isEmpty else { return nil }
        switch mode {
        case "default":
            // The normal, supervised mode (Claude asks before acting). A neutral
            // gray shield — the calm counterpart to bypass's loud warning lock —
            // kept unobtrusive since it rides every default session's row.
            self.label = "Default"
            self.symbol = .shield
            self.tint = .secondary
            self.isElevated = false
        case "plan":
            self.label = "Plan"
            self.symbol = .listBulletClipboard
            self.tint = .blue
            self.isElevated = false
        case "acceptEdits":
            self.label = "Accept Edits"
            self.symbol = .checkmarkCircle
            self.tint = .orange
            self.isElevated = false
        case "auto":
            // `auto` lets Claude Code pick the permission level per action — a
            // distinct (newer) mode, so give it its own symbol/tint rather than
            // aliasing `acceptEdits`.
            self.label = "Auto"
            self.symbol = .wandAndStars
            self.tint = .purple
            self.isElevated = false
        case "bypassPermissions":
            self.label = "Bypass"
            self.symbol = .lockTriangleBadgeExclamationmark
            self.tint = .red
            self.isElevated = true
        default:
            self.label = mode
            self.symbol = .gearshape
            self.tint = .secondary
            self.isElevated = false
        }
    }
}

/// A small capsule chip indicating the session's permission mode. Renders
/// nothing only when the mode is unknown (unset/`nil`).
public struct PermissionModeChip: View {
    private let presentation: PermissionModePresentation?

    public init(mode: String?) {
        self.presentation = PermissionModePresentation(mode: mode)
    }

    public var body: some View {
        if let presentation {
            Label {
                Text(presentation.label)
            } icon: {
                presentation.symbol.image
            }
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(presentation.isElevated ? Color.white : presentation.tint)
            .background(
                presentation.tint.opacity(presentation.isElevated ? 1 : 0.18),
                in: Capsule()
            )
            .accessibilityIdentifier("permission-mode-chip")
            .accessibilityLabel("Permission mode \(presentation.label)")
        }
    }
}

// MARK: - Model Tag

/// A small capsule tag showing the (shortened) model name, e.g. `opus-4.8`.
public struct ModelTag: View {
    private let model: String

    public init(model: String) {
        self.model = model
    }

    public var body: some View {
        Text(shortModelName(model))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .accessibilityIdentifier("model-tag")
            .accessibilityLabel("Model \(shortModelName(model))")
    }
}

// MARK: - Session Meter

/// Glanceable token + cumulative-cost meter, e.g. `⚡ 12.4k · $0.42`. Used on
/// session rows (iOS + Mac sidebar) and the mirror header (issue #597).
public struct SessionMeterView: View {
    private let telemetry: SessionTelemetry

    public init(telemetry: SessionTelemetry) {
        self.telemetry = telemetry
    }

    private var meterText: String {
        "\(telemetry.tokensUsed.abbreviatedTokenCount) · \(telemetry.costUSD.usdCostString)"
    }

    public var body: some View {
        Label {
            Text(meterText)
                .monospacedDigit()
        } icon: {
            Symbols.bolt.image
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("session-meter")
        .accessibilityLabel(
            "\(telemetry.tokensUsed) tokens, \(telemetry.costUSD.usdCostString)"
        )
    }
}

// MARK: - Row Summary

/// Compact one-line telemetry summary for a session row: meter + model tag +
/// permission-mode chip. Renders nothing until there's something worth showing,
/// so plain terminals and just-started sessions stay clean. Shared by the iOS
/// session list and the macOS sidebar (issue #597, surface A).
public struct SessionTelemetrySummary: View {
    private let telemetry: SessionTelemetry?
    private let permissionMode: String?

    public init(telemetry: SessionTelemetry?, permissionMode: String?) {
        self.telemetry = telemetry
        self.permissionMode = permissionMode
    }

    public var body: some View {
        let showMeter = (telemetry?.tokensUsed ?? 0) > 0 || (telemetry?.costUSD ?? 0) > 0
        let model = telemetry?.model
        let hasMode = PermissionModePresentation(mode: permissionMode) != nil
        if showMeter || model != nil || hasMode {
            HStack(spacing: 6) {
                if showMeter, let telemetry {
                    // The bolt SF Symbol carries intrinsic left side-bearing, so the
                    // meter would sit visually inset from the text fields stacked
                    // above it. Cancel that bearing so the glyph aligns flush to the
                    // row's leading edge. (Only applied to the leading meter — the
                    // model tag / mode chip are capsules whose inset reads as
                    // intentional.)
                    SessionMeterView(telemetry: telemetry)
                        .padding(.leading, -2)
                }
                if let model {
                    ModelTag(model: model)
                }
                PermissionModeChip(mode: permissionMode)
            }
        }
    }
}

// MARK: - Sparkline

/// A minimal line chart over a series of values, normalized to its own
/// min/max. Renders nothing meaningful for fewer than two points. Used for the
/// per-turn cost/latency sparkline in the session detail view (surface B).
public struct Sparkline: View {
    private let values: [Double]
    private let tint: Color

    public init(values: [Double], tint: Color = .accentColor) {
        self.values = values
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                path(in: geo.size)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                // A single (or no) sample: a flat baseline so the row isn't blank.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(tint.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .accessibilityHidden(true)
    }

    private func path(in size: CGSize) -> Path {
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = maxValue - minValue
        let stepX = size.width / CGFloat(values.count - 1)
        return Path { path in
            for (index, value) in values.enumerated() {
                // Flat series → center line; otherwise scale into [0, height].
                let normalized = range > 0 ? (value - minValue) / range : 0.5
                let x = stepX * CGFloat(index)
                let y = size.height * (1 - CGFloat(normalized))
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}
