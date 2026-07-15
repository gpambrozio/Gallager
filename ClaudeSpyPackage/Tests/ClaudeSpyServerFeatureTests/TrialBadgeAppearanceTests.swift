#if os(macOS)
    import ClaudeSpyNetworking
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("trialBadgeAppearance")
    struct TrialBadgeAppearanceTests {
        @Test("Trial with more than 2 days is a non-urgent trial badge")
        func trialRelaxed() {
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: 5) == .trial(daysLeft: 5, urgent: false))
        }

        @Test("Trial with 2 or fewer days is urgent")
        func trialUrgent() {
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: 2) == .trial(daysLeft: 2, urgent: true))
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: 1) == .trial(daysLeft: 1, urgent: true))
        }

        @Test("Expired maps to the expired badge")
        func expired() {
            #expect(trialBadgeAppearance(state: .expired, trialDaysLeft: nil) == .expired)
        }

        @Test("Hidden for non-trial/expired states and for a trial with no day count")
        func hidden() {
            #expect(trialBadgeAppearance(state: .active, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: .none, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: .notRequired, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: nil, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: nil) == nil)
        }
    }
#endif
