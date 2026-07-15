#if os(macOS)
    import ClaudeSpyNetworking
    import SwiftUI

    /// Pure mapping from license state to toolbar-badge appearance. Kept free of
    /// view state so the trial/expired/urgent rules are unit-testable. `nil` means
    /// render nothing. The `isPaired` gate lives in the view (it's app state).
    enum TrialBadgeAppearance: Equatable {
        /// `urgent` → orange (≤ 2 days left), else secondary grey.
        case trial(daysLeft: Int, urgent: Bool)
        case expired
    }

    func trialBadgeAppearance(
        state: LicenseStatus.State?,
        trialDaysLeft: Int?
    ) -> TrialBadgeAppearance? {
        switch state {
        case .trial:
            guard let days = trialDaysLeft else { return nil }
            return .trial(daysLeft: days, urgent: days <= 2)
        case .expired:
            return .expired
        default:
            return nil
        }
    }
#endif
