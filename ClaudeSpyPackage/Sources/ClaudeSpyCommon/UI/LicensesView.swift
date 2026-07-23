import SwiftUI

/// A single third-party acknowledgement row: the project name on the left, its
/// license on the right, tapping opens the upstream repository.
///
/// Shared between the macOS Settings → About "Licenses" section and the iOS
/// pushed ``ThirdPartyLicensesView`` so both platforms render attributions
/// identically.
public struct LicenseRow: View {
    private let license: ThirdPartyLicense

    public init(_ license: ThirdPartyLicense) {
        self.license = license
    }

    public var body: some View {
        Link(destination: license.url) {
            HStack {
                Label(license.name, symbol: .linkCircle)
                Spacer()
                Text(license.license)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}

/// Full-screen list of the third-party open-source acknowledgements: the
/// ``ThirdPartyLicense/intro`` blurb followed by one section per
/// ``ThirdPartyLicense/Usage`` (apps, build tools, website).
///
/// Pushed from the iOS Settings "Licenses" row. The macOS About tab renders the
/// same structure inline in its own `Form` instead of pushing this view, but
/// both draw from the shared ``ThirdPartyLicense/all`` data.
public struct ThirdPartyLicensesView: View {
    public init() { }

    public var body: some View {
        Form {
            Section {
                Text(ThirdPartyLicense.intro)
            }

            ForEach(ThirdPartyLicense.Usage.allCases, id: \.self) { usage in
                Section(usage.rawValue) {
                    ForEach(ThirdPartyLicense.all(in: usage)) { license in
                        LicenseRow(license)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Licenses")
    }
}

#Preview("Licenses View") {
    NavigationStack {
        ThirdPartyLicensesView()
    }
}

#Preview("License Row") {
    Form {
        LicenseRow(ThirdPartyLicense(
            name: "SwiftTerm",
            license: "MIT",
            url: URL(staticString: "https://github.com/migueldeicaza/SwiftTerm")
        ))
    }
}
