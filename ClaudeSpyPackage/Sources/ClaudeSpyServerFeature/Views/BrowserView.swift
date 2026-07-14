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
    /// field take keyboard focus. `BrowserURLField` observes the value and
    /// makes its `NSTextField` first responder when it changes. Using a
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
    /// Most recent main-frame navigation failure. Non-nil renders the error
    /// page overlay; cleared when the next navigation starts. The error
    /// page's Close button closes the whole tab instead of clearing this —
    /// the page behind a failed navigation is often blank, so "reveal it"
    /// isn't a useful escape hatch.
    var navigationError: BrowserNavigationError?
    /// Downloads started from this tab, oldest first. Rows stay in the
    /// downloads bar until dismissed; dismissing an in-flight row cancels it.
    var downloads: [BrowserDownload] = []

    let webView: WKWebView

    private var observers: [NSKeyValueObservation] = []
    /// Retained strongly because `WKWebView.uiDelegate` is a weak reference —
    /// without this property the adapter would deallocate immediately after
    /// `init` returns and new-tab requests would silently no-op. Not named
    /// `…Delegate` so SwiftLint's `weak_delegate` rule doesn't flag the
    /// strong storage that's intentional here.
    private var retainedUIDelegateAdapter: BrowserUIDelegateAdapter?
    /// Retained strongly for the same reason as the UI delegate adapter —
    /// `WKWebView.navigationDelegate` is a weak reference.
    private var retainedNavigationDelegateAdapter: BrowserNavigationDelegateAdapter?

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

        // Routes navigation failures to the error page overlay and converts
        // download-shaped navigations (anchor `download` attributes,
        // attachments, MIME types WebKit can't display inline) into
        // `WKDownload`s surfaced in the downloads bar.
        let navigationAdapter = BrowserNavigationDelegateAdapter(
            onNavigationStart: { [weak self] in
                self?.navigationError = nil
            },
            onNavigationError: { [weak self] error in
                self?.navigationError = error
                // Keep the failed URL in the address bar (Safari-like) so
                // the user can correct a typo — without this, the `\.url`
                // KVO observer reverts the field to the last committed
                // page's URL when a provisional load fails.
                if let failedURL = error.failedURL {
                    self?.urlFieldText = failedURL.absoluteString
                }
            },
            onDownloadStart: { [weak self] download in
                self?.register(download)
            },
            onExternalURL: { url in
                // Schemes WebKit can't load itself (mailto:, tel:, custom
                // app schemes) go to the system's registered handler,
                // matching Safari.
                @Dependency(URLOpener.self) var urlOpener
                urlOpener.openInDefaultBrowser(url)
            }
        )
        webView.navigationDelegate = navigationAdapter
        self.retainedNavigationDelegateAdapter = navigationAdapter

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
        navigationError = nil
        webView.load(URLRequest(url: url))
    }

    /// Retries the navigation that produced `navigationError`, preferring the
    /// URL that actually failed (the web view may still be on the previous
    /// page, so a plain `reload()` would re-render that instead).
    func retryAfterNavigationError() {
        guard let error = navigationError else { return }
        navigationError = nil
        if let url = error.failedURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    /// Wraps a `WKDownload` handed over by the navigation delegate in a
    /// `BrowserDownload` (which becomes the download's delegate) and adds it
    /// to the downloads bar.
    private func register(_ download: WKDownload) {
        @Dependency(BrowserDownloadsLocation.self) var downloadsLocation
        downloads.append(
            BrowserDownload(download: download, destinationDirectory: downloadsLocation.directory())
        )
    }

    /// Removes a download row from the bar, cancelling the transfer first if
    /// it is still running.
    func removeDownload(_ download: BrowserDownload) {
        download.cancel()
        downloads.removeAll { $0.id == download.id }
    }

    /// Cancels every in-flight download, deleting their partial files.
    /// Called when the owning tab (or its whole session) is torn down —
    /// letting the state deallocate mid-transfer would orphan half-written
    /// files with nothing left in the UI to manage them.
    func cancelActiveDownloads() {
        for download in downloads {
            download.cancel()
        }
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
    /// Called when the page asks to open a URL in a new window — typically a
    /// `target="_blank"` link click or a `window.open()` call. The parent
    /// routes the URL into a fresh browser tab on the same session.
    let onRequestNewTab: (URL) -> Void
    /// Called when this tab wants to close itself — the error page's Close
    /// button. The parent owns the tab list, so the close (and its
    /// return-to-origin selection behavior) happens there.
    let onRequestClose: () -> Void

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
                if let error = state.navigationError {
                    BrowserNavigationErrorView(
                        error: error,
                        onRetry: { state.retryAfterNavigationError() },
                        // Close the tab rather than just hiding the overlay —
                        // the page underneath is usually blank (failed first
                        // load), which would leave a dead-looking browser.
                        onClose: { onRequestClose() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !state.downloads.isEmpty {
                Divider()
                BrowserDownloadsBar(downloads: state.downloads) { download in
                    state.removeDownload(download)
                }
            }
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

            BrowserURLField(
                text: $state.urlFieldText,
                focusRequest: state.urlFieldFocusRequest,
                onSubmit: { state.loadFromURLField() }
            )
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .padding(.trailing, 8)
        .padding(.leading, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Address Bar Field

/// AppKit-backed address-bar text field.
///
/// SwiftUI's `TextField` can't reproduce a browser address bar's "first click
/// selects the whole URL, a later click positions the caret" behavior. On the
/// click that moves focus into the field, AppKit's field editor sets the caret
/// from the click location on *mouse-up*, which discards any selection applied
/// earlier in the same event — so a `TextField` + `TextSelection` binding
/// flashes the selection and immediately loses it on a real mouse click
/// (issue #651). It only appeared to work under keyboard/AX focus, where no
/// mouse tracking overrides the selection.
///
/// `AddressBarTextField` fixes this by selecting all *after* the field editor's
/// mouse-tracking loop returns (see its `mouseDown`), so the selection sticks.
private struct BrowserURLField: NSViewRepresentable {
    @Binding var text: String
    /// Monotonic counter mirroring `BrowserTabState.urlFieldFocusRequest`. When
    /// it changes to a fresh value the field takes keyboard focus (and, via
    /// `becomeFirstResponder`, selects all).
    let focusRequest: Int
    /// Called when the user presses Return to load the typed URL.
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> AddressBarTextField {
        let field = AddressBarTextField()
        field.delegate = context.coordinator
        field.placeholderString = "Enter URL"
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        // Single-line, horizontally scrollable while editing; when it isn't
        // focused a long URL keeps its head (scheme + host) visible.
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        // Let the field stretch to fill the navigation bar rather than hug its
        // text, matching the old `.frame(maxWidth: .infinity)` TextField.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("URL")
        return field
    }

    func updateNSView(_ nsView: AddressBarTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        // Push SwiftUI's text in only when it actually diverges (URL KVO sync,
        // failed-URL restore). Rewriting on every keystroke round-trip would
        // stomp the user's caret and selection. Skip entirely while the field is
        // being edited so a background KVO update (redirect, `pushState`) can't
        // clobber a URL the user is mid-typing.
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Honor a fresh external focus request. Comparing against the last
        // handled value keeps unrelated re-renders from re-stealing focus.
        if focusRequest > 0, focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            // Deferred so a freshly-opened tab's field is inserted into the
            // window's responder chain before we ask it to become first
            // responder (mirrors the old `.task` 50 ms warm-up). Tracked so a
            // superseding request cancels the pending one, restoring the
            // `.task(id:)` cancellation semantics.
            context.coordinator.focusTask?.cancel()
            context.coordinator.focusTask = Task { @MainActor [weak nsView] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let nsView, let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        var onSubmit: () -> Void
        /// Last `focusRequest` acted on, so each bump focuses exactly once.
        var lastFocusRequest = 0
        /// Pending deferred focus request, tracked so a superseding request can
        /// cancel it (restoring the `.task(id:)` cancellation semantics).
        var focusTask: Task<Void, Never>?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            onSubmit()
            // Blur after submit (Safari-like): keeping the field first responder
            // would leave the just-loaded page unable to receive keystrokes.
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}

/// `NSTextField` that behaves like a browser address bar: the interaction that
/// moves keyboard focus into the field selects the whole URL; a later click
/// (while the field is already focused) positions the caret where clicked.
/// Keyboard, AX, and programmatic focus select all too.
///
/// The mouse case is the whole reason this subclass exists (issue #651). The
/// field editor sets the caret from the click on mouse-up, so any selection
/// applied *before* mouse-up is discarded — and inside this SwiftUI hosting
/// hierarchy, `becomeFirstResponder` runs *before* `mouseDown` is delivered
/// (the hosting view transfers focus first, then forwards the event), so a
/// selection applied on focus change is exactly such a doomed early selection:
/// its deferred task can fire during the field editor's mouse-tracking loop
/// (WebKit activity from a loaded page drains the main queue mid-track) and
/// the mouse-up caret placement then wipes it. `mouseDown` therefore treats
/// "focus arrived in this same event cycle" as the click-focus signal
/// (`pendingFocusSelectAll`), cancels the racing deferred select-all, and
/// selects after `super.mouseDown(with:)` returns — which is after the
/// tracking loop ends and the caret has been placed, so the selection sticks.
///
/// - Warning: The mouse fix relies on an *undocumented* AppKit detail —
///   `super.mouseDown(with:)` not returning until the field editor's tracking
///   loop has placed the caret. The `Browser Address Bar Refocus` e2e scenario
///   reproduces the race against a loaded page, so CI guards this; still worth
///   a manual click-to-select spot-check on future macOS betas.
final private class AddressBarTextField: NSTextField {
    /// Set by `becomeFirstResponder`, consumed by the `mouseDown` delivered in
    /// the same event cycle (click-driven focus) or cleared by the deferred
    /// select-all task (keyboard/AX/programmatic focus, where no `mouseDown`
    /// follows). This is how the two focus flavors are told apart:
    /// `becomeFirstResponder` runs before `mouseDown`, so a flag set *inside*
    /// `mouseDown` — or `currentEditor()`, which the pre-`mouseDown` focus
    /// change already installed — can't discriminate, and `NSApp.currentEvent`
    /// can hold a stale mouse event when focus is set via accessibility.
    private var pendingFocusSelectAll = false

    /// Pending deferred select-all, tracked so a superseding focus change or
    /// the focusing click's `mouseDown` can cancel it.
    private var selectAllTask: Task<Void, Never>?

    override func mouseDown(with event: NSEvent) {
        // If focus arrived in this same event cycle, this is the click that
        // focused the field: take over from the deferred select-all (which
        // would race the mouse-up caret placement) and select after the
        // tracking loop instead.
        let focusCameFromThisClick = pendingFocusSelectAll
        pendingFocusSelectAll = false
        if focusCameFromThisClick {
            selectAllTask?.cancel()
        }
        // Runs the field editor's mouse-tracking loop; returns after mouse-up,
        // by which point the caret has been placed.
        super.mouseDown(with: event)

        guard focusCameFromThisClick, let editor = currentEditor() else { return }
        // Only auto-select-all for a plain click. If the user dragged to select
        // a substring on the focusing click, honor that selection instead of
        // overriding it (matches Safari/Chrome).
        if editor.selectedRange.length == 0 {
            editor.selectAll(nil)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            pendingFocusSelectAll = true
            // Deferred: right after `becomeFirstResponder` returns the field
            // editor may not be fully installed, so selecting would no-op.
            // For click-driven focus the `mouseDown` that follows in this same
            // event cycle cancels this task and handles selection itself.
            selectAllTask?.cancel()
            selectAllTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.pendingFocusSelectAll = false
                guard let editor = self.currentEditor() else { return }
                editor.selectAll(nil)
            }
        }
        return didBecome
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

// MARK: - Navigation Delegate

/// A main-frame navigation failure, rendered by `BrowserNavigationErrorView`.
struct BrowserNavigationError: Equatable {
    let message: String
    /// The URL that failed to load, recovered from the error's userInfo.
    /// Kept separately from `WKWebView.url` because a failed *provisional*
    /// navigation leaves the web view on its previous page.
    let failedURL: URL?
}

/// Pure decision helpers for the navigation delegate, split out so they can
/// be unit tested without a live `WKWebView`.
enum BrowserNavigationPolicy {
    /// WebKit's "frame load interrupted" code, reported when a committed
    /// navigation is intentionally abandoned — most notably when a policy
    /// decision converts the navigation into a download. Not exposed as a
    /// Swift constant by the SDK.
    private static let webKitFrameLoadInterrupted = 102

    /// Errors that are part of normal operation and must not surface on the
    /// error page: explicit stop/cancel (`NSURLErrorCancelled`, also fired
    /// when a new navigation replaces an in-flight one) and download
    /// handoffs (`WebKitErrorDomain` 102).
    static func isIgnorableNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        if nsError.domain == "WebKitErrorDomain", nsError.code == webKitFrameLoadInterrupted {
            return true
        }
        return false
    }

    /// Whether the server marked the response as a file to save rather than
    /// a page to display (`Content-Disposition: attachment`). WebKit can
    /// often render these inline (PDFs, images), but the server's intent —
    /// and Safari's behavior — is to download them.
    static func isAttachment(_ response: URLResponse) -> Bool {
        guard
            let httpResponse = response as? HTTPURLResponse,
            let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")
        else { return false }
        return disposition
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("attachment")
    }
}

/// `WKNavigationDelegate` adapter owned by `BrowserTabState`. Four jobs:
///
/// - Convert download-shaped navigations into `WKDownload`s: anchor
///   `download` attributes (`shouldPerformDownload`), responses WebKit can't
///   display inline, and `Content-Disposition: attachment` responses.
/// - Hand navigations to schemes WebKit can't load (`mailto:`, `tel:`, app
///   schemes) to the system's registered handler instead of letting the
///   provisional navigation fail onto the error page.
/// - Report main-frame load failures so the tab can show an error page.
/// - Clear a stale error when a new navigation starts.
///
/// Same isolation story as `BrowserUIDelegateAdapter`: WebKit calls these on
/// the main thread, so `assumeIsolated` hops onto MainActor without a Task.
@MainActor
final private class BrowserNavigationDelegateAdapter: NSObject, WKNavigationDelegate {
    private let onNavigationStart: () -> Void
    private let onNavigationError: (BrowserNavigationError) -> Void
    private let onDownloadStart: (WKDownload) -> Void
    private let onExternalURL: (URL) -> Void

    init(
        onNavigationStart: @escaping () -> Void,
        onNavigationError: @escaping (BrowserNavigationError) -> Void,
        onDownloadStart: @escaping (WKDownload) -> Void,
        onExternalURL: @escaping (URL) -> Void
    ) {
        self.onNavigationStart = onNavigationStart
        self.onNavigationError = onNavigationError
        self.onDownloadStart = onDownloadStart
        self.onExternalURL = onExternalURL
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
            } else if
                let url = navigationAction.request.url,
                let scheme = url.scheme,
                !WKWebView.handlesURLScheme(scheme) {
                decisionHandler(.cancel)
                onExternalURL(url)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            let shouldDownload = !navigationResponse.canShowMIMEType
                || (
                    navigationResponse.isForMainFrame
                        && BrowserNavigationPolicy.isAttachment(navigationResponse.response)
                )
            decisionHandler(shouldDownload ? .download : .allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated {
            onDownloadStart(download)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        MainActor.assumeIsolated {
            onDownloadStart(download)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            onNavigationStart()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            handle(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        guard !BrowserNavigationPolicy.isIgnorableNavigationError(error) else { return }
        let nsError = error as NSError
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            .flatMap(URL.init(string:))
        onNavigationError(
            BrowserNavigationError(message: error.localizedDescription, failedURL: failedURL)
        )
    }
}

/// Full-content error page shown over the web view when a navigation fails —
/// DNS failures, refused connections, TLS errors, offline, etc. Opaque so the
/// stale previous page doesn't bleed through. "Try Again" retries the failed
/// URL; "Close" closes the tab (via `onClose`).
struct BrowserNavigationErrorView: View {
    let error: BrowserNavigationError
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Symbols.exclamationmarkTriangle.image
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("This page could not be loaded")
                .font(.title3.weight(.semibold))

            Text(error.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let url = error.failedURL {
                Text(url.absoluteString)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Try Again", action: onRetry)
                    .keyboardShortcut(.defaultAction)

                // The unique help string doubles as the E2E hook: "Close"
                // alone substring-collides with the tab strip's
                // "Close browser tab: …" buttons and the window's own close
                // button, but AXHelp is matched exactly.
                Button("Close", action: onClose)
                    .help("Close this browser tab")
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background()
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
        onRequestNewTab: { _ in },
        onRequestClose: { }
    )
    .frame(width: 720, height: 480)
}

#Preview("BrowserURLField") {
    // Interactive: click the field to see the whole URL select (issue #651),
    // click again to position the caret, type to replace the selection.
    @Previewable @State var url = "https://github.com/gpambrozio/ClaudeSpy"
    BrowserURLField(text: $url, focusRequest: 0, onSubmit: { })
        .frame(width: 420)
        .padding()
}

#Preview("BrowserNavigationErrorView") {
    BrowserNavigationErrorView(
        error: BrowserNavigationError(
            message: "A server with the specified hostname could not be found.",
            failedURL: URL(string: "https://nonexistent.example.invalid/some/path")
        ),
        onRetry: { },
        onClose: { }
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
