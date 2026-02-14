import SwiftUI

/// About view explaining the naming of Gallager
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("About Gallager")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Gallager is named after ")
                        + Text("Robert Gallager")
                            .underline()
                            .foregroundStyle(.blue)
                            .onTapGesture {
                                if let url = URL(string: "https://en.wikipedia.org/wiki/Robert_G._Gallager") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        + Text(", a close colleague of ")
                        + Text("Claude Shannon")
                            .underline()
                            .foregroundStyle(.blue)
                            .onTapGesture {
                                if let url = URL(string: "https://en.wikipedia.org/wiki/Claude_Shannon") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        + Text(". Anthropic's Claude is named after Claude Shannon.")

                    Text("Version \(Bundle.main.appVersion ?? "Unknown")")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
    }
}

extension Bundle {
    var appVersion: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

#Preview {
    AboutView()
}
