import ClaudeSpyCommon
import Vapor

// MARK: - Vapor Content Conformance

// Extend ClaudeSpyCommon types to work with Vapor's Content protocol.
// This keeps ClaudeSpyCommon free of Vapor dependencies while allowing
// these types to be used as HTTP request/response bodies.

extension PairingResponse: Content {}
extension PairingStatus: Content {}
extension PairingRegistration: Content {}
extension PairingCompletion: Content {}
