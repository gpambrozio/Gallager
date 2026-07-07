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
///
/// `parentTabId` is set when this tab was spawned from another browser tab
/// (e.g. `target="_blank"` or `window.open()`). Closing the tab selects the
/// parent first if it still exists, falling through to `originWindowId` only
/// when the parent is gone.
struct BrowserTab: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var displayTitle: String?
    var originWindowId: String?
    var parentTabId: UUID?

    init(
        id: UUID = UUID(),
        url: URL,
        displayTitle: String? = nil,
        originWindowId: String? = nil,
        parentTabId: UUID? = nil
    ) {
        self.id = id
        self.url = url
        self.displayTitle = displayTitle
        self.originWindowId = originWindowId
        self.parentTabId = parentTabId
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

/// A network/navigation failure surfaced to the user as an overlay over the web
/// content. Carries the failed URL so a Retry action can reload exactly what
/// failed rather than whatever the web view last committed (a provisional
/// failure often leaves `WKWebView.url` nil).
struct BrowserLoadError: Equatable {
    let message: String
    let failedURL: URL?
}

/// Live state for a single file download started from a browser tab.
///
/// Created when WebKit converts a navigation into a `WKDownload` — a response
/// whose MIME type the web view can't render inline, or a link carrying the
/// `download` attribute. Holds the `WKDownload` strongly so the transfer keeps
/// running and its `Progress` stays observable (WebKit only references the
/// download weakly through its delegate), and mirrors the pieces the downloads
/// popover renders: filename, on-disk destination, completion fraction, and
/// terminal status.
@Observable
@MainActor
final class BrowserDownload: Identifiable {
    enum Status: Equatable {
        case inProgress
        case finished
        case failed(String)
    }

    let id = UUID()
    private(set) var filename: String
    /// Where the file is written on disk. `nil` until WebKit asks us to decide
    /// a destination via `decideDestinationUsing`.
    private(set) var destinationURL: URL?
    private(set) var fractionCompleted: Double = 0
    private(set) var status: Status = .inProgress

    let download: WKDownload
    private var progressObserver: NSKeyValueObservation?

    init(download: WKDownload) {
        self.download = download
        // Best-effort placeholder until `decideDestinationUsing` hands us the
        // server-suggested filename.
        self.filename = download.originalRequest?.url?.lastPathComponent ?? "download"
    }

    /// Records the resolved destination and starts mirroring the transfer's
    /// progress into `fractionCompleted`.
    func start(filename: String, destinationURL: URL) {
        self.filename = filename
        self.destinationURL = destinationURL
        // `Progress.fractionCompleted` is KVO-compliant, but its notifications
        // can arrive off the main thread, so hop explicitly rather than
        // `assumeIsolated` the way the WKWebView observers do.
        progressObserver = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self?.fractionCompleted = fraction
            }
        }
    }

    func markFinished() {
        fractionCompleted = 1
        status = .finished
        progressObserver = nil
    }

    func markFailed(_ message: String) {
        status = .failed(message)
        progressObserver = nil
    }

    /// Opens Finder with the finished file selected. No-op until a destination
    /// exists.
    func revealInFinder() {
        guard let destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
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
    /// Monotonic counter bumped from outside the view to request the URL
    /// field take keyboard focus. The browser content view observes the value
    /// via `.task(id:)` and drives `@FocusState` when it changes. Using a
    /// counter (rather than a Bool) lets a freshly-opened tab focus the field
    /// even when the value was already true earlier in the session.
    var urlFieldFocusRequest = 0
    /// Set by the `WKUIDelegate` when the page asks for a new window —
    /// `target="_blank"` links and `window.open()` calls land here. The
    /// owning `BrowserTabContentView` observes the value via `.onChange` and
    /// forwards the URL up to the parent so a new browser tab can open. The
    /// observer resets it back to `nil` after handling so subsequent requests
    /// for the same URL still fire `.onChange`.
    var pendingNewTabURL: URL?
    /// Set when a navigation fails at the network layer (host not found, no
    /// connection, TLS failure, timeout…). Rendered as an overlay over the web
    /// content with a Retry action; cleared when a fresh navigation starts or
    /// succeeds.
    var loadError: BrowserLoadError?
    /// Active and recently-finished downloads started from this tab, oldest
    /// first. Surfaced through the downloads popover in the navigation bar.
    var downloads: [BrowserDownload] = []

    let webView: WKWebView

    private var observers: [NSKeyValueObservation] = []
    /// Retained strongly because `WKWebView.uiDelegate` is a weak reference —
    /// without this property the adapter would deallocate immediately after
    /// `init` returns and new-tab requests would silently no-op. Not named
    /// `…Delegate` so SwiftLint's `weak_delegate` rule doesn't flag the
    /// strong storage that's intentional here.
    private var retainedUIDelegateAdapter: BrowserUIDelegateAdapter?
    /// Retained strongly for the same reason as `retainedUIDelegateAdapter`:
    /// both `WKWebView.navigationDelegate` and `WKDownload.delegate` are weak
    /// references, so the shared adapter would deallocate immediately after
    /// `init` and navigation errors / downloads would silently no-op.
    private var retainedNavigationAdapter: BrowserNavigationDelegateAdapter?

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

        // Route `target="_blank"` / `window.open()` requests back to this
        // state so the SwiftUI view can forward them to the parent and a new
        // browser tab opens. WKWebView's default behaviour is to silently
        // drop new-window requests unless a UIDelegate handles them.
        let adapter = BrowserUIDelegateAdapter { [weak self] url in
            self?.pendingNewTabURL = url
        }
        webView.uiDelegate = adapter
        self.retainedUIDelegateAdapter = adapter

        // Surface navigation failures and route downloads. A single adapter
        // serves as both the navigation and download delegate; the state holds
        // it strongly because both delegate properties are weak.
        let navigationAdapter = BrowserNavigationDelegateAdapter(state: self)
        webView.navigationDelegate = navigationAdapter
        self.retainedNavigationAdapter = navigationAdapter

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

    // MARK: - Downloads

    /// Registers a freshly-created `WKDownload` so it appears in the downloads
    /// popover. The returned model is updated by the download delegate as the
    /// transfer proceeds.
    @discardableResult
    func registerDownload(_ download: WKDownload) -> BrowserDownload {
        let item = BrowserDownload(download: download)
        downloads.append(item)
        return item
    }

    /// Resolves where a download is written: the user's Downloads folder, with
    /// the server-suggested filename made unique so a second download of
    /// `report.pdf` becomes `report (1).pdf` instead of failing on an
    /// existing-file collision. Also records the destination on the tracking
    /// model so the popover can reveal it in Finder once finished.
    func decideDownloadDestination(for download: WKDownload, suggestedFilename: String) -> URL? {
        let destination = Self.resolveDownloadDestination(
            directory: Self.downloadsDirectory(),
            suggestedFilename: suggestedFilename
        )
        downloads.first { $0.download === download }?
            .start(filename: destination.lastPathComponent, destinationURL: destination)
        return destination
    }

    func finishDownload(_ download: WKDownload) {
        downloads.first { $0.download === download }?.markFinished()
    }

    func failDownload(_ download: WKDownload, error: Error) {
        downloads.first { $0.download === download }?
            .markFailed(error.localizedDescription)
    }

    /// Drops finished and failed downloads from the list, leaving in-progress
    /// transfers untouched. Backs the popover's "Clear" action.
    func clearFinishedDownloads() {
        downloads.removeAll { $0.status != .inProgress }
    }

    static func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Builds a collision-free destination inside `directory` for
    /// `suggestedFilename`, matching Finder/Safari's de-duplication: an
    /// existing file gets a ` (n)` suffix inserted before the extension.
    /// `fileExists` is injected so the resolution logic is unit-testable
    /// without touching disk.
    static func resolveDownloadDestination(
        directory: URL,
        suggestedFilename: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let sanitized = sanitizedFilename(suggestedFilename)
        let candidate = directory.appendingPathComponent(sanitized)
        guard fileExists(candidate) else { return candidate }

        let ext = (sanitized as NSString).pathExtension
        let base = (sanitized as NSString).deletingPathExtension
        var index = 1
        while true {
            let numbered = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let next = directory.appendingPathComponent(numbered)
            if !fileExists(next) { return next }
            index += 1
        }
    }

    /// Reduces a server-suggested filename to a safe last path component:
    /// strips `/` (which would otherwise let a download escape the Downloads
    /// folder) and falls back to `"download"` for empty / `.` / `..` names.
    static func sanitizedFilename(_ suggested: String) -> String {
        let cleaned = suggested
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "download"
        }
        return cleaned
    }

    // MARK: - Load errors

    func reportLoadError(_ error: Error, failedURL: URL?) {
        guard Self.shouldReport(error) else { return }
        loadError = BrowserLoadError(
            message: error.localizedDescription,
            failedURL: failedURL ?? currentURL
        )
    }

    func clearLoadError() {
        loadError = nil
    }

    /// Reloads whatever failed. Prefers the captured failing URL because a
    /// provisional-navigation failure often leaves `webView.url` nil.
    func retryFailedLoad() {
        let target = loadError?.failedURL
        loadError = nil
        if let target {
            webView.load(URLRequest(url: target))
        } else {
            webView.reload()
        }
    }

    /// Whether a navigation error is worth surfacing. Filters the two
    /// "not really a failure" cases WebKit reports through the same callbacks:
    /// `NSURLErrorCancelled` (the user hit Stop, or a redirect / newer load
    /// superseded this one) and WebKit's "frame load interrupted" (code 102),
    /// which fires whenever a navigation is turned into a download.
    static func shouldReport(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return false
        }
        // `WebKitErrorDomain` / 102 == WebKitErrorFrameLoadInterruptedByPolicyChange.
        // Neither constant is exposed by the Swift WebKit module, so match the
        // raw values (same approach as the hardcoded Safari UA token above).
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return false
        }
        return true
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
    /// Called when the page asks to open a URL in a new window — typically a
    /// `target="_blank"` link click or a `window.open()` call. The parent
    /// routes the URL into a fresh browser tab on the same session.
    let onRequestNewTab: (URL) -> Void

    @FocusState private var isURLFieldFocused: Bool
    @State private var showDownloadsPopover = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            if state.isLoading, state.estimatedProgress > 0, state.estimatedProgress < 1 {
                ProgressView(value: state.estimatedProgress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            }
            ZStack {
                BrowserWebViewRepresentable(webView: state.webView)
                if let error = state.loadError {
                    BrowserErrorView(
                        error: error,
                        onRetry: { state.retryFailedLoad() },
                        onDismiss: { state.clearLoadError() }
                    )
                }
            }
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
        .onChange(of: state.pendingNewTabURL) { _, newValue in
            // Reset the trigger before forwarding so a future request for the
            // same URL still fires `.onChange`; the parent's
            // `onRequestNewTab` is what actually opens the tab.
            guard let newValue else { return }
            state.pendingNewTabURL = nil
            onRequestNewTab(newValue)
        }
        .task(id: state.urlFieldFocusRequest) {
            // Skip the initial .task fire — only steal focus when an external
            // caller bumps the counter. The brief sleep gives SwiftUI a tick
            // to insert the freshly-mounted TextField into the responder chain
            // before we ask it to become first responder.
            guard state.urlFieldFocusRequest > 0 else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            isURLFieldFocused = true
        }
        .task(id: isURLFieldFocused) {
            // Select the whole address when the field gains focus — matching
            // every browser's location bar — so the user can immediately type a
            // replacement URL. SwiftUI's `TextField` has no select-on-focus, so
            // reach the window's field editor (the `NSText` that becomes first
            // responder while editing) and select all. This covers both a mouse
            // click and the programmatic focus path above, since both flip
            // `isURLFieldFocused`. The brief sleep lets AppKit finish placing
            // the insertion point from a click before we override it with a
            // full selection.
            guard isURLFieldFocused else { return }
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, isURLFieldFocused else { return }
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
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
                .accessibilityIdentifier("browser-url-field")

            if !state.downloads.isEmpty {
                downloadsButton
            }
        }
        .padding(.trailing, 8)
        .padding(.leading, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var activeDownloadCount: Int {
        state.downloads.reduce(into: 0) { count, download in
            if download.status == .inProgress { count += 1 }
        }
    }

    private var downloadsButton: some View {
        Button {
            showDownloadsPopover.toggle()
        } label: {
            Symbols.squareAndArrowDown.image
                .overlay(alignment: .topTrailing) {
                    if activeDownloadCount > 0 {
                        Text("\(activeDownloadCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 7, y: -7)
                    }
                }
        }
        .buttonStyle(.borderless)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $showDownloadsPopover, arrowEdge: .bottom) {
            BrowserDownloadsView(state: state)
        }
    }
}

/// `WKUIDelegate` adapter that intercepts new-window requests (`target="_blank"`
/// links, `window.open()`) and reports the URL back to `BrowserTabState` so
/// the parent view can open it in a fresh tab. Returning `nil` from
/// `createWebViewWith` tells WebKit the request was handled out-of-band; the
/// originating webview keeps showing its current page.
///
/// `@MainActor`-isolated because the callback mutates `BrowserTabState`,
/// which is itself `@MainActor`. `WKUIDelegate` callbacks are invoked on the
/// main thread by WebKit so the isolation matches the actual call site.
@MainActor
final private class BrowserUIDelegateAdapter: NSObject, WKUIDelegate {
    private let onNewTabRequest: (URL) -> Void

    init(onNewTabRequest: @escaping (URL) -> Void) {
        self.onNewTabRequest = onNewTabRequest
    }

    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // The protocol isn't yet `@MainActor`-annotated in the WebKit headers,
        // but WebKit always invokes UI delegate methods on the main thread.
        // `assumeIsolated` lets us hop onto MainActor without a Task hop,
        // matching the KVO observers above.
        MainActor.assumeIsolated {
            // Skip URLs the in-app browser tab can't load (e.g. `javascript:`
            // or `about:blank` from `window.open()` / `window.open('javascript:…')`).
            // Forwarding those would spawn a dangling tab that WKWebView
            // silently ignores.
            if
                let url = navigationAction.request.url,
                BrowserURLDispatcher.canHandle(url) {
                onNewTabRequest(url)
            }
        }
        return nil
    }
}

/// `WKNavigationDelegate` + `WKDownloadDelegate` adapter that gives the browser
/// tab three things its bare `WKWebView` lacked: visible load errors, file
/// downloads, and the plumbing that converts a non-displayable response into a
/// download.
///
/// Holds the owning state weakly (the state retains this adapter strongly via
/// `retainedNavigationAdapter`, mirroring the UI-delegate arrangement). Like
/// `BrowserUIDelegateAdapter`, the protocol methods are `nonisolated` and hop
/// onto the main actor with `assumeIsolated` — valid because WebKit invokes
/// navigation and download delegate callbacks on the main thread.
@MainActor
final private class BrowserNavigationDelegateAdapter: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    private weak var state: BrowserTabState?

    init(state: BrowserTabState) {
        self.state = state
    }

    // MARK: Navigation lifecycle

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            state?.clearLoadError()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let failingURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        MainActor.assumeIsolated {
            state?.reportLoadError(error, failedURL: failingURL)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let failingURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        MainActor.assumeIsolated {
            state?.reportLoadError(error, failedURL: failingURL)
        }
    }

    // MARK: Download conversion

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        // Download instead of rendering when appropriate (see `shouldDownload`).
        // The SDK marks the decision handler `@MainActor`, so evaluate and call
        // it from an asserted main-actor context.
        MainActor.assumeIsolated {
            decisionHandler(shouldDownload(navigationResponse) ? .download : .allow)
        }
    }

    /// Whether a response should be saved rather than displayed. Two cases:
    /// a MIME type the web view can't render inline (a zip, a dmg, an
    /// `application/octet-stream`…) would otherwise show a blank page; and a
    /// response the server explicitly marked `Content-Disposition: attachment`,
    /// which a browser downloads even when it *could* display the type (a PDF
    /// behind a "Download" link is the common case).
    private func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
        if !navigationResponse.canShowMIMEType {
            return true
        }
        if
            let http = navigationResponse.response as? HTTPURLResponse,
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
            disposition.lowercased().contains("attachment") {
            return true
        }
        return false
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // Links carrying an explicit `download` attribute ask to be saved even
        // when their MIME type is displayable. Deliberately the overload
        // *without* a `preferences` argument so the desktop content mode / JS
        // defaults configured on the web view stay in force.
        MainActor.assumeIsolated {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated {
            beginDownload(download)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated {
            beginDownload(download)
        }
    }

    private func beginDownload(_ download: WKDownload) {
        download.delegate = self
        state?.registerDownload(download)
    }

    // MARK: WKDownloadDelegate

    nonisolated func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        MainActor.assumeIsolated {
            completionHandler(state?.decideDownloadDestination(for: download, suggestedFilename: suggestedFilename))
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            state?.finishDownload(download)
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            state?.failDownload(download, error: error)
        }
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

// MARK: - Downloads UI

/// Popover listing a browser tab's downloads with per-item progress and
/// actions: reveal a finished file in Finder, or read the failure message for a
/// failed one. The "Clear" button drops finished/failed rows.
private struct BrowserDownloadsView: View {
    @Bindable var state: BrowserTabState

    private var hasClearable: Bool {
        state.downloads.contains { $0.status != .inProgress }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                if hasClearable {
                    Button("Clear") {
                        state.clearFinishedDownloads()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.downloads) { download in
                        BrowserDownloadRow(download: download)
                        if download.id != state.downloads.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 320)
    }
}

/// A single row in the downloads popover: status glyph, filename, and either a
/// progress bar (in flight), a "Completed" caption + Show-in-Finder button
/// (finished), or the failure message (failed).
private struct BrowserDownloadRow: View {
    @Bindable var download: BrowserDownload

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(download.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch download.status {
                case .inProgress:
                    ProgressView(value: download.fractionCompleted)
                        .progressViewStyle(.linear)
                case .finished:
                    Text("Completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if download.status == .finished {
                Button {
                    download.revealInFinder()
                } label: {
                    Symbols.folder.image
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch download.status {
        case .inProgress:
            Symbols.arrowDownCircle.image
                .foregroundStyle(.secondary)
        case .finished:
            Symbols.checkmarkCircleFill.image
                .foregroundStyle(.green)
        case .failed:
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Load Error UI

/// Overlay shown over the web content when a navigation fails at the network
/// layer (host not found, no connection, TLS failure, timeout…). Presents the
/// system error message plus Retry / Dismiss actions over a dimmed backdrop.
private struct BrowserErrorView: View {
    let error: BrowserLoadError
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Symbols.exclamationmarkTriangle.image
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("This page couldn't load")
                    .font(.headline)
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if let url = error.failedURL {
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack {
                Button("Retry", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                Button("Dismiss", action: onDismiss)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.6))
    }
}

// MARK: - Terminal Link Confirmation

/// A pending decision for a clicked terminal link, surfaced via a sheet so the
/// user can pick where to open it. Carries enough context that the resolved
/// URL can be opened or routed to a browser tab without re-deriving anything.
///
/// `hostId` is `nil` for clicks coming from a local session and the paired
/// host's id otherwise — routing remote-session prompts back to the same
/// remote session's tab strip rather than the local one.
struct PendingBrowserURLPrompt: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let sessionName: String
    let windowId: String
    let hostId: String?
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
        onURLChange: { _ in },
        onRequestNewTab: { _ in }
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
