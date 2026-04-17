#if os(macOS)
    import SwiftUI
    import Textual

    /// Renders the Gallager CLI API reference markdown in a scrollable window.
    public struct APIReferenceView: View {
        private let markdown: String

        public init() {
            if
                let url = Bundle.module.url(forResource: "gallager-cli-api", withExtension: "md"),
                let content = try? String(contentsOf: url, encoding: .utf8) {
                self.markdown = content
            } else {
                self.markdown = "API reference not found."
            }
        }

        public var body: some View {
            ScrollView {
                StructuredText(markdown: markdown)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 600, minHeight: 400)
        }
    }
#endif
