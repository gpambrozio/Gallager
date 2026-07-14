#if os(macOS)
    import ClaudeSpyCommon
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Covers the ⌘+ / ⌘- font-size helpers on `AppSettings` that the View-menu
    /// commands invoke. The bounds are shared with the Settings slider through
    /// `AppSettings.minFontSize` / `maxFontSize`.
    @MainActor
    struct TerminalFontSizeTests {
        /// Builds an `AppSettings` backed by in-memory preferences so each test
        /// starts from the default font size without touching real UserDefaults.
        private func makeSettings() -> AppSettings {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                AppSettings()
            }
        }

        @Test("increaseFontSize bumps up by one point")
        func increaseBumpsByOne() {
            let settings = makeSettings()
            settings.fontSize = 12
            settings.increaseFontSize()
            #expect(settings.fontSize == 13)
        }

        @Test("decreaseFontSize drops by one point")
        func decreaseDropsByOne() {
            let settings = makeSettings()
            settings.fontSize = 12
            settings.decreaseFontSize()
            #expect(settings.fontSize == 11)
        }

        @Test("increaseFontSize clamps at the maximum")
        func increaseClampsAtMax() {
            let settings = makeSettings()
            settings.fontSize = AppSettings.maxFontSize
            settings.increaseFontSize()
            #expect(settings.fontSize == AppSettings.maxFontSize)
        }

        @Test("decreaseFontSize clamps at the minimum")
        func decreaseClampsAtMin() {
            let settings = makeSettings()
            settings.fontSize = AppSettings.minFontSize
            settings.decreaseFontSize()
            #expect(settings.fontSize == AppSettings.minFontSize)
        }

        @Test("increaseFontSize pulls an out-of-range value back to the maximum")
        func increaseFromAboveMaxSnapsToMax() {
            let settings = makeSettings()
            // The property itself is unclamped; the helper still guarantees the
            // result never exceeds the max, even from an out-of-range start.
            settings.fontSize = AppSettings.maxFontSize + 5
            settings.increaseFontSize()
            #expect(settings.fontSize == AppSettings.maxFontSize)
        }
    }
#endif
