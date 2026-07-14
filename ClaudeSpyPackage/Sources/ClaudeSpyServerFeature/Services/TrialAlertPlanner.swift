// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TrialAlertPlanner.swift
#if os(macOS)
    import Foundation

    /// Trial-expiry alert thresholds, in hours before expiry.
    public enum TrialAlertThreshold: Int, CaseIterable, Sendable {
        case hours48 = 48
        case hours24 = 24
    }

    /// Pure planning logic for trial-expiry alerts, kept free of I/O so the
    /// 48h/24h windows are unit-testable.
    public enum TrialAlertPlanner {
        /// All crossed-but-unfired thresholds while the trial is still live,
        /// most urgent (smallest) first. Caller fires ONE notification (the
        /// first) and marks every returned threshold as fired, so a Mac that
        /// slept through 48h doesn't get two back-to-back alerts.
        public static func thresholdsToFire(
            now: Date, expiresAt: Date, alreadyFired: Set<Int>
        ) -> [TrialAlertThreshold] {
            let remaining = expiresAt.timeIntervalSince(now)
            guard remaining > 0 else { return [] }
            return TrialAlertThreshold.allCases
                .filter { threshold in
                    remaining <= TimeInterval(threshold.rawValue) * 3_600
                        && !alreadyFired.contains(threshold.rawValue)
                }
                .sorted { $0.rawValue < $1.rawValue }
        }
    }
#endif
