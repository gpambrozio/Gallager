import Foundation

/// Formatting helpers for the OTEL session meter (issue #597). Kept pure and
/// locale-independent so the glanceable strings render identically across
/// hosts/viewers and stay trivially testable.
public extension Int {
    /// Abbreviates a token count for the glanceable meter:
    /// `940 → "940"`, `1234 → "1.2k"`, `12_300 → "12.3k"`, `1_250_000 → "1.3M"`.
    /// Negative values (never expected) are clamped to `"0"`.
    var abbreviatedTokenCount: String {
        guard self > 0 else { return "0" }
        switch self {
        case 1..<1_000:
            return "\(self)"
        case 1_000..<1_000_000:
            return Self.trimmed(Double(self) / 1_000) + "k"
        default:
            return Self.trimmed(Double(self) / 1_000_000) + "M"
        }
    }

    /// Formats a millisecond latency for display: `840 → "840ms"`,
    /// `1500 → "1.5s"`, `12_000 → "12s"`.
    var latencyString: String {
        guard self > 0 else { return "—" }
        if self < 1_000 {
            return "\(self)ms"
        }
        return Self.trimmed(Double(self) / 1_000) + "s"
    }

    /// Formats an active-time duration in **seconds** for the recap / overview
    /// (issue #598): `0 → "0m"`, `45 → "45s"`, `720 → "12 min"`, `5400 → "1h 30m"`,
    /// `7200 → "2h"`. Negative values (never expected) read `"0m"`.
    var activeTimeString: String {
        guard self > 0 else { return "0m" }
        if self < 60 { return "\(self)s" }
        let minutes = self / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    /// Rounds to one decimal place, printing a whole result without any trailing
    /// fractional zero (so `1.25` becomes `"1.3"` but a round value stays compact).
    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

public extension Double {
    /// Formats a USD cost for the meter. Uses two decimals for the common case
    /// (`0.42 → "$0.42"`, `12.4 → "$12.40"`) and falls back to `"<$0.01"` for a
    /// non-zero sub-cent total so the meter never reads a misleading `"$0.00"`.
    var usdCostString: String {
        if self <= 0 {
            return "$0.00"
        }
        if self < 0.01 {
            return "<$0.01"
        }
        return "$" + String(format: "%.2f", self)
    }
}
