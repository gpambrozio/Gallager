import SwiftUI

/// User-selected app appearance: follow the system, force light, or force
/// dark. Persisted by both the macOS and iOS apps and applied via the
/// platform-appropriate primitive (`NSApp.appearance` on macOS,
/// `.preferredColorScheme(_:)` on iOS).
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The SwiftUI `ColorScheme` to drive `.preferredColorScheme(_:)` from.
    /// `nil` means "use the system setting".
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
