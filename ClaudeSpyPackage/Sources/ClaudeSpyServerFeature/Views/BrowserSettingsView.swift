import ClaudeSpyCommon
import SwiftUI

/// Preferences tab for "how clicked links in the terminal should open".
///
/// Hosts both the global default — used when there's no domain-specific
/// rule — and a list of per-domain overrides that take precedence. The
/// global picker lives here (rather than under General → Behavior) so the
/// fallback and the overrides sit side by side.
struct BrowserSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var selection: BrowserDomainRule.ID?
    @State private var newDomainInput = ""
    @State private var newDomainBehavior: BrowserLinkBehavior = .alwaysInApp
    @State private var newDomainError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Default Behavior") {
                Picker("When clicking web links in terminal", selection: $settings.browserLinkBehavior) {
                    ForEach(BrowserLinkBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .help(
                    "How http/https/ftp links clicked in the terminal should open by default. " +
                        "Domain-specific rules below override this for matching hosts."
                )
            }

            Section("Per-Domain Rules") {
                Text("Override the default for specific domains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.browserDomainRules.isEmpty {
                    Text("No per-domain rules. Add one below or click \"Don't ask again for this domain\" on a link confirmation dialog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(settings.browserDomainRules) { rule in
                        domainRuleRow(rule)
                    }
                }
            }

            Section("Add Domain Rule") {
                HStack {
                    TextField("example.com", text: $newDomainInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("add-domain-rule-input")
                        .onSubmit { addDomainRule() }

                    Picker("", selection: $newDomainBehavior) {
                        ForEach(actionableBehaviors) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("add-domain-rule-behavior")

                    Button("Add") {
                        addDomainRule()
                    }
                    .accessibilityIdentifier("add-domain-rule-button")
                    .disabled(trimmedDomain.isEmpty)
                }

                if let newDomainError {
                    Text(newDomainError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Picker options for an actionable rule. `.ask` is hidden from
    /// per-domain choices because adding "ask for this domain" is the same as
    /// having no rule at all — the global default already produces that
    /// behavior when set to `.ask`.
    private var actionableBehaviors: [BrowserLinkBehavior] {
        [.alwaysInApp, .alwaysInDefaultBrowser]
    }

    private var trimmedDomain: String {
        newDomainInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func domainRuleRow(_ rule: BrowserDomainRule) -> some View {
        HStack {
            Text(rule.domain)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Picker("", selection: ruleBehaviorBinding(for: rule)) {
                ForEach(actionableBehaviors) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .accessibilityIdentifier("domain-rule-behavior-\(rule.domain)")

            Button {
                settings.removeBrowserDomainRule(id: rule.id)
            } label: {
                Symbols.minusCircleFill.image
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove rule for \(rule.domain)")
            .accessibilityIdentifier("domain-rule-remove-\(rule.domain)")
            .accessibilityLabel("Remove rule for \(rule.domain)")
        }
    }

    private func ruleBehaviorBinding(for rule: BrowserDomainRule) -> Binding<BrowserLinkBehavior> {
        Binding(
            get: { rule.behavior },
            set: { newValue in
                settings.updateBrowserDomainRule(id: rule.id, behavior: newValue)
            }
        )
    }

    private func addDomainRule() {
        let host = normalizedDomain(from: trimmedDomain)
        guard !host.isEmpty else {
            newDomainError = "Enter a domain like example.com"
            return
        }
        if settings.browserDomainRules.contains(where: { $0.domain == host }) {
            newDomainError = "A rule for \(host) already exists. Edit it above."
            return
        }
        settings.setBrowserBehavior(newDomainBehavior, for: host)
        newDomainInput = ""
        newDomainError = nil
    }

    /// Strips a leading scheme and any path component from raw user input so
    /// `https://example.com/foo` is stored as `example.com` — matching what
    /// `URL.host` produces for incoming link clicks.
    private func normalizedDomain(from raw: String) -> String {
        var value = raw.lowercased()
        if let schemeEnd = value.range(of: "://") {
            value = String(value[schemeEnd.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        return value
    }
}

#Preview("Empty") {
    let settings = AppSettings()
    return BrowserSettingsView()
        .environment(settings)
        .frame(width: 600, height: 500)
}

#Preview("With Rules") {
    let settings = AppSettings()
    settings.browserDomainRules = [
        BrowserDomainRule(domain: "github.com", behavior: .alwaysInApp),
        BrowserDomainRule(domain: "youtube.com", behavior: .alwaysInDefaultBrowser),
    ]
    return BrowserSettingsView()
        .environment(settings)
        .frame(width: 600, height: 500)
}
