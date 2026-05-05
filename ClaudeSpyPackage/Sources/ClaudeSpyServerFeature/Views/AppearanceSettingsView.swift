import ClaudeSpyCommon
import SwiftUI

/// Preferences tab for choosing the macOS app appearance (System / Light / Dark).
struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                LabeledContent("Theme") {
                    HStack(spacing: 16) {
                        ForEach(AppearanceMode.allCases) { mode in
                            AppearanceTile(
                                mode: mode,
                                isSelected: settings.appearanceMode == mode
                            ) {
                                settings.appearanceMode = mode
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One selectable appearance preview tile. Shows a stylised mini-window in
/// the appearance's representative colours, the mode's display name, and a
/// blue rounded border when selected.
private struct AppearanceTile: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AppearancePreview(mode: mode)
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                lineWidth: isSelected ? 3 : 1
                            )
                    )

                Text(mode.displayName)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Stylised preview of a tiny app window in the given appearance.
///
/// `system` is rendered as a diagonal split between the light and dark
/// previews so the picker hints at "follows the system" without committing
/// to either side.
private struct AppearancePreview: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .system:
            ZStack {
                MiniWindow(scheme: .light)
                MiniWindow(scheme: .dark)
                    .mask {
                        GeometryReader { proxy in
                            Path { path in
                                path.move(to: .zero)
                                path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                                path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                                path.closeSubpath()
                            }
                        }
                    }
            }
        case .light:
            MiniWindow(scheme: .light)
        case .dark:
            MiniWindow(scheme: .dark)
        }
    }
}

private struct MiniWindow: View {
    let scheme: ColorScheme

    private var background: Color {
        scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)
    }

    private var contentBackground: Color {
        scheme == .dark ? Color(white: 0.20) : Color.white
    }

    private var lineColor: Color {
        scheme == .dark ? Color(white: 0.45) : Color(white: 0.70)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            HStack(spacing: 4) {
                Circle().fill(Color(red: 0.99, green: 0.37, blue: 0.33)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 0.99, green: 0.74, blue: 0.18)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 6, height: 6)
                Spacer()
            }
            .padding(6)

            VStack(spacing: 4) {
                Spacer().frame(height: 18)
                RoundedRectangle(cornerRadius: 3)
                    .fill(contentBackground)
                    .overlay(
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(lineColor)
                                    .frame(height: 2)
                            }
                        }
                        .padding(6)
                    )
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
        }
    }
}

#Preview("Light") {
    let settings = AppSettings()
    settings.appearanceMode = .light
    return AppearanceSettingsView()
        .environment(settings)
        .frame(width: 600, height: 300)
}

#Preview("Dark") {
    let settings = AppSettings()
    settings.appearanceMode = .dark
    return AppearanceSettingsView()
        .environment(settings)
        .frame(width: 600, height: 300)
}

#Preview("System") {
    AppearanceSettingsView()
        .environment(AppSettings())
        .frame(width: 600, height: 300)
}
