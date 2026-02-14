#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import SwiftUI

    /// Custom About window content shown when clicking the app name > "About Gallager".
    ///
    /// Explains why the app is called "Gallager" and provides links to
    /// the Wikipedia pages for Robert Gallager and Claude Shannon.
    public struct AboutWindowView: View {
        public init() { }

        public var body: some View {
            VStack(spacing: 16) {
                // App icon and name
                headerSection

                Divider()

                // Explanation
                explanationSection

                // Links
                linksSection
            }
            .padding(24)
            .frame(width: 420)
        }

        // MARK: - Header

        @ViewBuilder
        private var headerSection: some View {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Gallager")
                    .font(.title)
                    .fontWeight(.bold)

                if
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // MARK: - Explanation

        @ViewBuilder
        private var explanationSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Why \"Gallager\"?")
                    .font(.headline)

                Text("This app is named after Robert G. Gallager, a pioneering information theorist and professor at MIT.")

                Text("Gallager was a close colleague of Claude Shannon, the father of information theory, after whom Anthropic's Claude AI is named.")

                Text("Just as Gallager extended and built upon Shannon's foundational work, this app extends your ability to monitor and interact with Claude Code sessions.")
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // MARK: - Links

        @ViewBuilder
        private var linksSection: some View {
            HStack(spacing: 16) {
                Link(destination: AboutLinks.gallagerWikipedia) {
                    Label("Robert G. Gallager", symbol: .linkCircle)
                }

                Link(destination: AboutLinks.shannonWikipedia) {
                    Label("Claude Shannon", symbol: .linkCircle)
                }
            }
            .font(.callout)
        }
    }
#endif
