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
        case 0..<1_000:
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
