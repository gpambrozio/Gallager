import AppKit
import ClaudeSpyCommon
import SwiftUI
@preconcurrency import WebKit

/// A web URL opened as its own tab to the right of the file explorer/file tabs.
///
/// The tab struct is a value type — the actual `WKWebView` instance lives on a
/// matching `BrowserTabState` keyed by the tab's `id` in
/// `SessionFileTabsState.browserStates`. That separation lets SwiftUI re-render
/// the tab list cheaply (the struct is `Equatable`) while preserving the live
/// page state (history, scroll, JS context) across tab switches.
///
/// `originWindowId` is the tmux window that initiated the open via a terminal
/// click. When set, closing the tab returns the user to that terminal instead
/// of falling back to the file browser tree.
struct BrowserTab: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var displayTitle: String?
    var originWindowId: String?

    init(
        id: UUID = UUID(),
        url: URL,
        displayTitle: String? = nil,
        originWindowId: String? = nil
    ) {
        self.id = id
        self.url = url
        self.displayTitle = displayTitle
        self.originWindowId = originWindowId
    }

    /// Label rendered on the tab strip. Falls back to the URL host (then a
    /// truncated form of the full URL string) when the page hasn't reported a
    /// title yet. The truncation keeps long query/fragment URLs from
    /// overflowing the tab strip's max label width.
    var tabLabel: String {
        if let title = displayTitle, !title.isEmpty {
            return title
        }
        if let host = url.host, !host.isEmpty {
            return host
        }
        let absolute = url.absoluteString
        if absolute.count > 50 {
            return absolute.prefix(50) + "…"
        }
        return absolute
    }
}

/// Live state for a browser tab: holds the long-lived `WKWebView` and the
/// values mirrored back from its KVO properties so SwiftUI can drive the URL
/// field, navigation buttons, and progress indicator.
///
/// One instance per `BrowserTab.id`, stored in `SessionFileTabsState.browserStates`
/// so the page survives tab/window/session switches that destroy and rebuild
/// the SwiftUI view tree.
@Observable
@MainActor
final class BrowserTabState {
    /// Current URL displayed by the web view (kept in sync with WKWebView KVO).
    var currentURL: URL?
    /// Text shown in the URL field. Diverges from `currentURL` while the user
    /// is typing a new URL.
    var urlFieldText: String
    /// Page title, mirrored back from `WKWebView.title` so the tab strip can
    /// display it.
    var pageTitle: String?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var estimatedProgress: Double = 0

    let webView: WKWebView

    private var observers: [NSKeyValueObservation] = []

    init(initialURL: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Without this, WKWebView ships a User-Agent missing the
        // `Version/… Safari/…` suffix, which makes many sites think this is an
        // old/unsupported browser and degrade their layout. Appending a
        // Safari-style suffix here yields a UA equivalent to current Safari on
        // macOS, so servers serve the modern desktop experience.
        // swiftlint:disable:next custom_no_number_decimals
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        // Be explicit about JS + desktop content mode. `allowsContentJavaScript`
        // defaults to true, but pages like google.com fall back to a static
        // HTML rendering when their bootstrap script doesn't appear to run; the
        // explicit setting plus `.desktop` content mode keeps every navigation
        // on the rich desktop path.
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        pagePreferences.preferredContentMode = .desktop
        configuration.defaultWebpagePreferences = pagePreferences
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        self.webView = webView
        self.currentURL = initialURL
        self.urlFieldText = initialURL.absoluteString

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentURL = webView.url
                if let newURL = webView.url {
                    self.urlFieldText = newURL.absoluteString
                }
            }
        })
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.pageTitle = webView.title
            }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.canGoBack = webView.canGoBack
            }
        })
        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.canGoForward = webView.canGoForward
            }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.isLoading = webView.isLoading
            }
        })
        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.estimatedProgress = webView.estimatedProgress
            }
        })

        webView.load(URLRequest(url: initialURL))
    }

    /// Loads the URL currently in `urlFieldText`, fixing it up to a browsable
    /// URL when the user typed something incomplete (no scheme, plain host).
    func loadFromURLField() {
        guard let url = Self.normalizedURL(from: urlFieldText) else { return }
        urlFieldText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Coerces user input into a usable URL. Adds an `https://` scheme when
    /// missing and the input looks like a host or path-bearing URL; returns
    /// `nil` for empty input. Percent-encodes the trimmed input so values that
    /// contain spaces or other URL-illegal characters (e.g. a pasted query
    /// string) still produce a non-nil URL instead of silently no-opping.
    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "https://\(encoded)")
    }
}

/// Content view shown when the user selects a browser tab. Renders the URL
/// bar, navigation controls, and the embedded `WKWebView`.
struct BrowserTabContentView: View {
    @Bindable var state: BrowserTabState
    /// Called when the loaded page's title changes so the parent can update
    /// the tab label without owning a reference to the live web view.
    let onTitleChange: (String?) -> Void
    /// Called when the loaded URL changes so the parent can update the tab's
    /// stored `url` (used for tab persistence and the tooltip label).
    let onURLChange: (URL) -> Void

    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            if state.isLoading, state.estimatedProgress > 0, state.estimatedProgress < 1 {
                ProgressView(value: state.estimatedProgress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }
            BrowserWebViewRepresentable(webView: state.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: state.pageTitle) { _, newValue in
            onTitleChange(newValue)
        }
        .onChange(of: state.currentURL) { _, newValue in
            if let newValue {
                onURLChange(newValue)
            }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button {
                state.webView.goBack()
            } label: {
                Symbols.chevronLeft.image
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")

            Button {
                state.webView.goForward()
            } label: {
                Symbols.chevronRight.image
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")

            Button {
                if state.isLoading {
                    state.webView.stopLoading()
                } else {
                    state.webView.reload()
                }
            } label: {
                Group {
                    if state.isLoading {
                        Symbols.xmark.image
                    } else {
                        Symbols.arrowClockwise.image
                    }
                }
            }
            .buttonStyle(.borderless)
            .help(state.isLoading ? "Stop" : "Reload")
            .accessibilityLabel(state.isLoading ? "Stop" : "Reload")

            TextField("Enter URL", text: $state.urlFieldText)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFieldFocused)
                .onSubmit {
                    state.loadFromURLField()
                    isURLFieldFocused = false
                }
                .accessibilityLabel("URL")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Embeds an existing `WKWebView` instance in SwiftUI. The web view is created
/// once per `BrowserTabState` and reused across view rebuilds so navigation
/// state survives switching between tabs/sessions.
private struct BrowserWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // The web view is owned by `BrowserTabState`; nothing to push here.
    }
}

// MARK: - Terminal Link Confirmation

/// A pending decision for a clicked terminal link, surfaced via a sheet so the
/// user can pick where to open it. Carries enough context that the resolved
/// URL can be opened or routed to a browser tab without re-deriving anything.
struct PendingBrowserURLPrompt: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let sessionName: String
    let windowId: String
}

/// User's selection from the confirmation dialog.
enum BrowserPromptChoice {
    case inApp
    case defaultBrowser
}

/// Schemes the in-app browser tab is willing to handle. `file://` is handled
/// separately by the file tab flow; everything else falls through to the
/// system default browser.
enum BrowserURLDispatcher {
    static let supportedSchemes: Set = ["http", "https", "ftp"]

    static func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }
}

/// Confirmation dialog shown when the user clicks a web link in the terminal
/// and `settings.browserLinkBehavior == .ask`. Mirrors a standard macOS alert
/// layout (title + message + accessory checkbox + actions) but as a SwiftUI
/// sheet so the "Always do this" toggle can live alongside the buttons.
struct BrowserURLConfirmationView: View {
    let url: URL
    let onResolve: (BrowserPromptChoice, _ rememberChoice: Bool) -> Void
    let onCancel: () -> Void

    @State private var rememberChoice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open this link?")
                .font(.headline)

            Text(url.absoluteString)
                .font(.callout)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            Toggle("Always do this", isOn: $rememberChoice)
                .help("Remember this choice and stop asking. You can change it later in Settings → General → Behavior.")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("In Default Browser") {
                    onResolve(.defaultBrowser, rememberChoice)
                }

                Button("In App") {
                    onResolve(.inApp, rememberChoice)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
