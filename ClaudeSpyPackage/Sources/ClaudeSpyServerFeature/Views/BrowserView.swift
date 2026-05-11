import AppKit
import ClaudeSpyCommon
import Dependencies
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
        // WKWebView's default User-Agent omits the `Version/… Safari/…` suffix,
        // so sites like google.com gate their modern HTML behind a "recent
        // enough Safari" sniff and serve a degraded layout. Append a
        // Safari-shaped suffix so servers route us to the desktop experience.
        //
        // The `Version/X.Y` segment tracks the installed Safari (read from
        // its bundle), keeping us aligned with whatever version checks sites
        // are doing today without manual maintenance. The trailing
        // `Safari/605.1.15` is a frozen build token Apple keeps stable across
        // Safari versions for UA-sniff compatibility and isn't exposed by any
        // public API — hardcoding is the supported approach.
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix()
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
        // Allows Safari's Develop menu to attach Web Inspector to this view
        // (right-click → Inspect Element). Crucial for diagnosing why a site
        // misrenders or its JS bootstrap fails inside our embedded browser.
        webView.isInspectable = true
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
    /// Composes the `Version/… Safari/…` UA suffix that `applicationNameForUserAgent`
    /// appends to WKWebView's default User-Agent. The Safari version is read
    /// from the installed Safari.app bundle so the value tracks the system
    /// without manual bumps; the build token is frozen by Apple for UA-sniff
    /// stability. When Safari can't be located (extremely unlikely on macOS),
    /// falls back to a known-good recent value.
    static func safariUserAgentSuffix() -> String {
        // swiftlint:disable:next custom_no_number_decimals
        let safariVersion = installedSafariVersion() ?? "26.0"
        return "Version/\(safariVersion) Safari/605.1.15"
    }

    /// Returns the installed Safari's `CFBundleShortVersionString` (e.g.
    /// `"26.4"`), or `nil` if Safari can't be located or has no version key.
    /// Uses `NSWorkspace.urlForApplication(withBundleIdentifier:)` so the
    /// lookup resolves correctly whether Safari lives in `/Applications` or
    /// inside the system cryptex on macOS 13+.
    private static func installedSafariVersion() -> String? {
        guard
            let safariURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Safari"
            ),
            let bundle = Bundle(url: safariURL),
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else { return nil }
        return version
    }

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
        HStack(spacing: 14) {
            Button {
                state.webView.goBack()
            } label: {
                Symbols.chevronLeft.image
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
            .accessibilityLabel("Back")

            Button {
                state.webView.goForward()
            } label: {
                Symbols.chevronRight.image
            }
            .buttonStyle(.borderless)
            .disabled(!state.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
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
            .keyboardShortcut("r", modifiers: .command)
            .help(state.isLoading ? "Stop" : "Reload")
            .accessibilityLabel(state.isLoading ? "Stop" : "Reload")

            Button {
                if let url = state.currentURL {
                    @Dependency(URLOpener.self) var urlOpener
                    urlOpener.openInDefaultBrowser(url)
                }
            } label: {
                Symbols.arrowUpRightSquare.image
            }
            .buttonStyle(.borderless)
            .disabled(state.currentURL == nil)
            .help("Open in default browser")
            .accessibilityLabel("Open in default browser")

            TextField("Enter URL", text: $state.urlFieldText)
                .textFieldStyle(.roundedBorder)
                .focused($isURLFieldFocused)
                .onSubmit {
                    state.loadFromURLField()
                    isURLFieldFocused = false
                }
                .accessibilityLabel("URL")
        }
        .padding(.trailing, 8)
        .padding(.leading, 16)
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

/// Scope of the user's "remember my choice" decision on the confirmation
/// dialog: either no scope (one-off), the global setting, or a per-domain
/// override.
enum BrowserPromptRememberScope: Equatable {
    case none
    case global
    case domain(String)
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
/// and the effective behavior for that URL is `.ask`. Mirrors a standard
/// macOS alert layout (title + message + accessory checkboxes + actions) but
/// as a SwiftUI sheet so the "remember my choice" toggles can live alongside
/// the buttons.
///
/// Two remember-my-choice toggles are presented when the URL has a host:
///
/// - "Don't ask again." — applies the choice to every domain by updating the
///   global `browserLinkBehavior` setting.
/// - "Don't ask again for {host}." — applies the choice only to the URL's
///   host (added as a per-domain rule), leaving the global setting alone.
///
/// The two toggles are mutually exclusive: turning one on turns the other
/// off. URLs without a host (e.g. an `ftp:///` style URL) hide the
/// per-domain toggle entirely.
struct BrowserURLConfirmationView: View {
    let url: URL
    let onResolve: (BrowserPromptChoice, BrowserPromptRememberScope) -> Void
    let onCancel: () -> Void

    @State private var rememberScope: BrowserPromptRememberScope = .none

    /// Canonical rule key for this URL: `host` for default-port URLs, or
    /// `host:port` when the URL carries an explicit port. Used as both the
    /// label on the per-domain "don't ask again" toggle and the key passed to
    /// `setBrowserBehavior(_:for:)` so the saved rule matches future clicks on
    /// the same host+port combination.
    private var host: String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    private var isRememberGlobal: Binding<Bool> {
        Binding(
            get: { rememberScope == .global },
            set: { isOn in
                rememberScope = isOn ? .global : .none
            }
        )
    }

    private func isRememberDomain(_ host: String) -> Binding<Bool> {
        Binding(
            get: {
                if case let .domain(scoped) = rememberScope { return scoped == host }
                return false
            },
            set: { isOn in
                rememberScope = isOn ? .domain(host) : .none
            }
        )
    }

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

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Don't ask again.", isOn: isRememberGlobal)
                    .help("Remember this choice for every domain. You can change it later in Settings → Browser.")

                if let host {
                    Toggle("Don't ask again for \(host).", isOn: isRememberDomain(host))
                        .help("Remember this choice only for \(host). You can manage per-domain rules in Settings → Browser.")
                }
            }

            HStack {
                Button("In App") {
                    onResolve(.inApp, rememberScope)
                }
                .keyboardShortcut(.defaultAction)

                Button("In Default Browser") {
                    onResolve(.defaultBrowser, rememberScope)
                }

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Previews

private enum BrowserPreviewSample {
    /// A `data:` URL renders synchronously without a network round-trip, so
    /// previews don't depend on host connectivity or DNS.
    static var inlineHTMLURL: URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "data:text/html;base64," + Data("""
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>Preview Page</title>
            <style>
              body { font: 16px/1.4 -apple-system, sans-serif; padding: 24px; }
              h1 { color: #1d6fdb; }
            </style>
          </head>
          <body>
            <h1>Preview Page</h1>
            <p>This page is loaded from a <code>data:</code> URL so the preview
              renders without a network connection.</p>
            <ul>
              <li>One</li>
              <li>Two</li>
              <li>Three</li>
            </ul>
          </body>
        </html>
        """.utf8).base64EncodedString())!
    }

    // swiftlint:disable:next force_unwrapping
    static let pullRequestURL = URL(string: "https://github.com/gpambrozio/ClaudeSpy/pull/499")!
}

#Preview("BrowserTabContentView") {
    BrowserTabContentView(
        state: BrowserTabState(initialURL: BrowserPreviewSample.inlineHTMLURL),
        onTitleChange: { _ in },
        onURLChange: { _ in }
    )
    .frame(width: 720, height: 480)
}

#Preview("BrowserURLConfirmationView — short URL") {
    BrowserURLConfirmationView(
        url: BrowserPreviewSample.pullRequestURL,
        onResolve: { _, _ in },
        onCancel: { }
    )
}

#Preview("BrowserURLConfirmationView — long URL") {
    BrowserURLConfirmationView(
        // swiftlint:disable:next force_unwrapping
        url: URL(string: "https://example.com/very/long/path/with?many=query&parameters=so&we=can&see=how&the=sheet&handles=it&plus=more&content=here#anchor")!,
        onResolve: { _, _ in },
        onCancel: { }
    )
}
