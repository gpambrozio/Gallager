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

/// Full-screen list of the third-party open-source acknowledgements.
///
/// Pushed from the iOS Settings "Licenses" row. The macOS About tab renders the
/// same ``LicenseRow``s inline in its own `Form` instead of pushing this view,
/// but both draw from the shared ``ThirdPartyLicense/all`` data.
public struct ThirdPartyLicensesView: View {
    public init() { }

    public var body: some View {
        Form {
            Section {
                ForEach(ThirdPartyLicense.all) { license in
                    LicenseRow(license)
                }
            } footer: {
                Text("Gallager is built on these open-source projects, each used under its own license. Full texts live in the linked repositories.")
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
