#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import SwiftUI

    /// About view explaining the Gallager name and its connection to Claude Shannon.
    ///
    /// Used in the Settings "About" tab.
    public struct AboutView: View {
        public init() { }

        public var body: some View {
            Form {
                Section("Why \"Gallager\"?") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Gallager is named after [Robert G. Gallager](https://en.wikipedia.org/wiki/Robert_G._Gallager), a pioneering information theorist and professor at MIT.")

                        Text("Gallager was a close colleague of [Claude Shannon](https://en.wikipedia.org/wiki/Claude_Shannon), the father of information theory, after whom Anthropic's Claude AI is named.")

                        Text("Just as Gallager extended and built upon Shannon's foundational work in information theory, this app extends your ability to monitor and interact with Claude Code sessions.")
                    }
                    .font(.body)
                }

                Section("Links") {
                    Link(destination: AboutLinks.gallagerWikipedia) {
                        HStack {
                            Label("Robert G. Gallager", symbol: .linkCircle)
                            Spacer()
                            Text("Wikipedia")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: AboutLinks.shannonWikipedia) {
                        HStack {
                            Label("Claude Shannon", symbol: .linkCircle)
                            Spacer()
                            Text("Wikipedia")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 400, minHeight: 300)
            .navigationTitle("About")
        }
    }
#endif
