// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/LicensingLinks.swift
#if os(macOS)
    import Foundation

    /// Lemon Squeezy storefront links. Constants by design: they change
    /// rarely, and an app update is an acceptable cost to change them
    /// (spec §Mac app changes). Values come from the LS dashboard (Task 0).
    enum LicensingLinks {
        static let checkout = URL(string: "https://gallager.lemonsqueezy.com/checkout/buy/9f58a798-1600-434a-893c-2d67644cd5f9")!
        static let billingPortal = URL(string: "https://gallager.lemonsqueezy.com/billing")!
    }
#endif
