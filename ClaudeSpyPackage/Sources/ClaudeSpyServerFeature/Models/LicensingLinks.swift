// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/LicensingLinks.swift
#if os(macOS)
    import Foundation

    /// Lemon Squeezy storefront links. Constants by design: they change
    /// rarely, and an app update is an acceptable cost to change them
    /// (spec §Mac app changes). Values come from the LS dashboard (Task 0).
    enum LicensingLinks {
        static let checkout = URL(string: "https://gallager.lemonsqueezy.com/checkout/buy/8138d147-0adc-4f9c-83cc-407cbf7c6ab0")!
        static let billingPortal = URL(string: "https://gallager.lemonsqueezy.com/billing")!
    }
#endif
