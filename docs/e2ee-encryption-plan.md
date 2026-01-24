# End-to-End Encryption (E2EE) Implementation Plan

This document outlines the implementation of end-to-end encryption for ClaudeSpy, ensuring that the relay server cannot decrypt messages exchanged between Mac and iOS devices.

## Executive Summary

The goal is to encrypt all sensitive message payloads such that:
- Only paired devices (Mac ↔ iOS) can decrypt each other's messages
- The external relay server cannot read message contents
- Keys are established during the pairing process
- Forward secrecy is achievable through session key rotation

## Recommended Library: Apple CryptoKit + Swift Crypto

After evaluating available options, the recommended approach uses **Apple CryptoKit** (iOS/macOS) with **Swift Crypto** (Linux server, though server won't decrypt):

| Library | Pros | Cons |
|---------|------|------|
| **CryptoKit/Swift Crypto** | Native Apple support, modern API, Curve25519 + ChaChaPoly, cross-platform via Swift Crypto | Slightly more verbose than libsodium |
| swift-sodium (libsodium) | Battle-tested, excellent Box/SealedBox API, easy to use | External dependency, precompiled binaries |
| CryptoSwift | Pure Swift, no external deps | Slower than native, manual primitive composition |

**Recommendation:** Use CryptoKit/Swift Crypto for:
1. Native integration with Apple platforms
2. Same API across iOS, macOS, and Linux (for any server-side validation)
3. Hardware acceleration on Apple devices
4. Active maintenance by Apple

Reference: [CryptoKit Basics: End-to-End Encryption](https://dev.to/cardoso/cryptokit-basics-end-to-end-encryption-1d6d)

## Current Message Flow Analysis

### Messages Requiring Encryption

| Message Type | Sensitive Data | Priority |
|--------------|----------------|----------|
| `hookEvent` | Project paths, tool inputs/outputs, session IDs | **Critical** |
| `terminalStream` | Terminal content (may contain secrets) | **Critical** |
| `command` | Keystrokes (may contain passwords) | **High** |
| `commandResponse` | Execution results | **High** |
| `sessionState` | Session metadata, recent events | **Medium** |
| `registerMac/iOS` | Device names | Low |

### Messages NOT Requiring Encryption

| Message Type | Reason |
|--------------|--------|
| `ping/pong` | No sensitive data |
| `macConnected/iosConnected` | Connection state only |
| `error` | Generic error messages |
| `registerPushToken` | Token only useful with APNs credentials |

## Cryptographic Design

### Key Exchange: X25519 (Curve25519)

Each device generates a long-term key pair during first launch:

```swift
import CryptoKit

// Generate once and store in Keychain
let privateKey = Curve25519.KeyAgreement.PrivateKey()
let publicKey = privateKey.publicKey
```

### Shared Secret Derivation: ECDH + HKDF

During pairing, devices exchange public keys and derive a shared secret:

```swift
// On Mac (has iOS public key)
let sharedSecret = try macPrivateKey.sharedSecretFromKeyAgreement(
    with: iosPublicKey
)

// Derive symmetric key using HKDF
let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
    using: SHA256.self,
    salt: Data("ClaudeSpy-E2EE-v1".utf8),
    sharedInfo: Data(pairId.utf8),  // Bind to this pairing
    outputByteCount: 32
)
```

### Encryption: ChaChaPoly (AEAD)

All sensitive payloads encrypted with authenticated encryption:

```swift
// Encrypt
let sealedBox = try ChaChaPoly.seal(plaintextData, using: symmetricKey)
let encryptedData = sealedBox.combined  // nonce + ciphertext + tag

// Decrypt
let sealedBox = try ChaChaPoly.SealedBox(combined: encryptedData)
let decryptedData = try ChaChaPoly.open(sealedBox, using: symmetricKey)
```

**Why ChaChaPoly?**
- Faster than AES on devices without hardware AES (older iPhones)
- Built-in authentication (AEAD) prevents tampering
- Nonce is generated automatically and prepended

## Implementation Architecture

### New Module: `ClaudeSpyEncryption`

Create a new target in the Swift Package for encryption utilities:

```
ClaudeSpyPackage/
├── Sources/
│   ├── ClaudeSpyEncryption/           # NEW MODULE
│   │   ├── E2EEService.swift          # Main encryption service
│   │   ├── KeyManager.swift           # Keychain storage
│   │   ├── EncryptedPayload.swift     # Encrypted message wrapper
│   │   └── CryptoErrors.swift         # Error types
```

### Key Types

```swift
// Represents an encrypted payload in messages
public struct EncryptedPayload: Codable, Sendable {
    public let ciphertext: Data   // nonce + encrypted data + auth tag
    public let senderKeyId: String // Identifies which public key was used
    public let version: Int        // Protocol version for future upgrades
}

// Key pair wrapper for Keychain storage
public struct StoredKeyPair: Codable {
    public let privateKeyData: Data
    public let publicKeyData: Data
    public let keyId: String       // Unique identifier for this key
    public let createdAt: Date
}
```

### E2EEService Interface

```swift
@Observable
@MainActor
public final class E2EEService: Sendable {
    private let keyManager: KeyManager
    private var sessionKey: SymmetricKey?
    private var partnerPublicKey: Curve25519.KeyAgreement.PublicKey?

    // Initialize with stored keys or generate new
    public init() async throws

    // Get our public key for sharing during pairing
    public var publicKey: Data { get }

    // Set partner's public key and derive session key
    public func establishSession(partnerPublicKey: Data, pairId: String) throws

    // Encrypt data for partner
    public func encrypt(_ data: Data) throws -> EncryptedPayload

    // Decrypt data from partner
    public func decrypt(_ payload: EncryptedPayload) throws -> Data

    // Clear session (on disconnect/unpair)
    public func clearSession()
}
```

### KeyManager for Secure Storage

```swift
public actor KeyManager {
    private let keychainService = "com.claudespy.e2ee"

    // Generate and store new key pair
    public func generateKeyPair() async throws -> StoredKeyPair

    // Load existing key pair from Keychain
    public func loadKeyPair() async throws -> StoredKeyPair?

    // Delete keys (factory reset)
    public func deleteKeys() async throws
}
```

## Modified Message Flow

### Pairing Phase (Key Exchange)

Current pairing adds public key exchange:

```
1. Mac generates pairing code "ABCDEF"
2. Mac POSTs to /api/pairing/register:
   {
     deviceId: UUID,
     deviceName: "MacBook Pro",
     pairingCode: "ABCDEF",
     publicKey: <base64 Mac public key>  // NEW
   }

3. iOS POSTs to /api/pairing/complete:
   {
     pairingCode: "ABCDEF",
     deviceId: UUID,
     deviceName: "iPhone 16",
     publicKey: <base64 iOS public key>  // NEW
   }

4. Server returns partner's public key in response:
   {
     pairId: UUID,
     partnerDeviceName: "MacBook Pro",
     partnerPublicKey: <base64 Mac public key>  // NEW
   }

5. Both devices derive shared symmetric key from ECDH
```

### Message Transmission

Modify `WebSocketMessage` to support encrypted payloads:

```swift
public enum WebSocketMessage: Codable, Sendable {
    // Existing cases remain for routing
    case hookEvent(HookEventMessage)

    // NEW: Encrypted variant for sensitive messages
    case encryptedHookEvent(EncryptedHookEventMessage)
    case encryptedCommand(EncryptedCommandMessage)
    case encryptedSessionState(EncryptedSessionStateMessage)
    case encryptedTerminalSnapshot(EncryptedTerminalSnapshotMessage)

    // ... other cases
}

public struct EncryptedHookEventMessage: Codable, Sendable {
    public let pairId: String
    public let payload: EncryptedPayload  // Contains encrypted HookEvent
}
```

### Encryption Flow Example

```swift
// Mac sending hook event
func sendHookEvent(_ event: HookEvent) async throws {
    // 1. Encode event to JSON
    let eventData = try JSONEncoder().encode(event)

    // 2. Encrypt with session key
    let encrypted = try e2eeService.encrypt(eventData)

    // 3. Wrap in message
    let message = WebSocketMessage.encryptedHookEvent(
        EncryptedHookEventMessage(
            pairId: pairId,
            payload: encrypted
        )
    )

    // 4. Send via WebSocket
    try await websocket.send(message)
}
```

### Decryption Flow Example

```swift
// iOS receiving hook event
func handleMessage(_ message: WebSocketMessage) async throws {
    switch message {
    case .encryptedHookEvent(let encrypted):
        // 1. Decrypt payload
        let eventData = try e2eeService.decrypt(encrypted.payload)

        // 2. Decode event
        let event = try JSONDecoder().decode(HookEvent.self, from: eventData)

        // 3. Process event
        await sessionStore.handleEvent(event)

    // ... other cases
    }
}
```

## Server Changes

The relay server requires minimal changes:

1. **Store public keys** during pairing (for exchange only)
2. **Route encrypted messages** without modification
3. **No decryption capability** - server never sees plaintext

```swift
// RelayService changes
func relayToIOS(_ message: WebSocketMessage, pairId: String) async {
    // No change needed - encrypted payloads are just opaque Data
    // Server routes without inspecting contents
    await connectionHub.send(message, to: pairId, deviceType: .ios)
}
```

## Key Management Considerations

### Key Storage

| Platform | Storage Method |
|----------|----------------|
| iOS | Keychain with `kSecAttrAccessibleWhenUnlocked` |
| macOS | Keychain with `kSecAttrAccessibleWhenUnlocked` |
| Server | None - server does not store private keys |

### Key Rotation (Optional Enhancement)

For forward secrecy, implement session key rotation:

```swift
// Rotate keys every N messages or time period
public func rotateSessionKey() throws {
    // Generate ephemeral key pair
    let ephemeralPrivate = Curve25519.KeyAgreement.PrivateKey()

    // Derive new session key
    let newSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(
        with: partnerPublicKey
    )

    // Send ephemeral public key to partner (encrypted with current key)
    // Partner derives same new key

    sessionKey = newSecret.hkdfDerivedSymmetricKey(...)
}
```

### Unpairing

When devices unpair:
1. Clear session key from memory
2. Optionally regenerate long-term keys (paranoid mode)
3. Server deletes pairing record and stored public keys

## Migration Strategy

### Phase 1: Infrastructure (No Breaking Changes)
1. Add `ClaudeSpyEncryption` module
2. Implement `E2EEService` and `KeyManager`
3. Add `publicKey` field to pairing API (optional field)
4. Add encrypted message variants to `WebSocketMessage`

### Phase 2: Opt-In Encryption
1. Mac/iOS detect if partner supports encryption (has public key)
2. If both support, use encrypted variants
3. Fall back to plaintext for backward compatibility
4. Add UI indicator showing encryption status

### Phase 3: Mandatory Encryption
1. Remove plaintext variants for sensitive messages
2. Require public key in pairing
3. Reject connections without encryption support

## Security Considerations

### Addressed Threats

| Threat | Mitigation |
|--------|------------|
| Server reads messages | E2EE - server only sees ciphertext |
| Man-in-the-middle | Authenticated encryption + key pinning after pairing |
| Message tampering | ChaChaPoly provides authentication |
| Replay attacks | Nonces prevent replay (ChaChaPoly generates unique nonces) |

### Remaining Risks

| Risk | Mitigation Available |
|------|----------------------|
| Device compromise | Keys stored in Keychain (OS protection) |
| Key compromise exposes history | Key rotation for forward secrecy |
| Pairing code interception | Short window (5 min), 6-char = 27 bits entropy |
| Metadata exposure | Server sees pairId, timestamps, message sizes |

### Pairing Security Enhancement (Optional)

Strengthen pairing with code verification:

```swift
// After key exchange, both devices compute verification code
let verificationData = macPublicKey + iosPublicKey + pairId
let hash = SHA256.hash(data: verificationData)
let verificationCode = hash.prefix(3).map { String(format: "%02X", $0) }.joined()
// Display "AB-CD-EF" on both devices for user to verify
```

## Testing Strategy

### Unit Tests

```swift
@Test func encryptionRoundTrip() async throws {
    let service1 = try await E2EEService()
    let service2 = try await E2EEService()

    // Exchange public keys
    try service1.establishSession(
        partnerPublicKey: service2.publicKey,
        pairId: "test-pair"
    )
    try service2.establishSession(
        partnerPublicKey: service1.publicKey,
        pairId: "test-pair"
    )

    // Encrypt and decrypt
    let plaintext = Data("Hello, encrypted world!".utf8)
    let encrypted = try service1.encrypt(plaintext)
    let decrypted = try service2.decrypt(encrypted)

    #expect(decrypted == plaintext)
}

@Test func wrongKeyFails() async throws {
    let service1 = try await E2EEService()
    let service2 = try await E2EEService()
    let service3 = try await E2EEService()  // Attacker

    // Service1 paired with Service2
    try service1.establishSession(partnerPublicKey: service2.publicKey, pairId: "pair")
    try service2.establishSession(partnerPublicKey: service1.publicKey, pairId: "pair")

    // Service3 tries to decrypt
    try service3.establishSession(partnerPublicKey: service1.publicKey, pairId: "pair")

    let encrypted = try service1.encrypt(Data("secret".utf8))

    #expect(throws: CryptoError.self) {
        try service3.decrypt(encrypted)
    }
}
```

### Integration Tests

1. Full pairing flow with key exchange
2. Encrypted message relay through server
3. Reconnection with persisted keys
4. Cross-platform (Mac ↔ iOS) encryption

## Implementation Checklist

### Module Setup
- [ ] Create `ClaudeSpyEncryption` target in Package.swift
- [ ] Add CryptoKit/Swift Crypto dependencies
- [ ] Implement `CryptoErrors.swift`

### Key Management
- [ ] Implement `KeyManager` actor
- [ ] Keychain storage for iOS
- [ ] Keychain storage for macOS
- [ ] Key generation on first launch

### Encryption Service
- [ ] Implement `E2EEService`
- [ ] Public key export
- [ ] Session establishment from partner key
- [ ] Encrypt/decrypt methods
- [ ] Session clearing

### Message Types
- [ ] Add `EncryptedPayload` type
- [ ] Add encrypted variants to `WebSocketMessage`
- [ ] Update encoders/decoders

### Pairing Flow
- [ ] Add `publicKey` to `RegisterPairingRequest`
- [ ] Add `partnerPublicKey` to `PairingResponse`
- [ ] Update `PairingManager` (Mac)
- [ ] Update pairing flow (iOS)
- [ ] Store partner public key with pairing info

### Integration
- [ ] Update `ExternalServerClient` (Mac) to encrypt outgoing
- [ ] Update `ExternalServerClient` (Mac) to decrypt incoming
- [ ] Update `RelayClient` (iOS) to encrypt outgoing
- [ ] Update `RelayClient` (iOS) to decrypt incoming

### Server Updates
- [ ] Store public keys in pairing records
- [ ] Return partner public key on pairing completion
- [ ] Route encrypted messages unchanged

### UI/UX
- [ ] Add encryption status indicator
- [ ] Handle encryption errors gracefully
- [ ] Show re-pairing option on key mismatch

### Testing
- [ ] Unit tests for encryption/decryption
- [ ] Unit tests for key derivation
- [ ] Integration tests for full flow
- [ ] Cross-platform verification

## References

- [Apple CryptoKit Documentation](https://developer.apple.com/documentation/cryptokit/)
- [Swift Crypto (Cross-Platform)](https://www.swift.org/blog/crypto/)
- [CryptoKit E2EE Tutorial](https://dev.to/cardoso/cryptokit-basics-end-to-end-encryption-1d6d)
- [swift-sodium (Alternative)](https://github.com/jedisct1/swift-sodium)
- [CryptoKit Public Key Cryptography](https://tanaschita.com/cryptokit-public-key-cryptography/)

## Appendix: Alternative Approach with swift-sodium

If libsodium is preferred for its simpler API:

```swift
import Sodium

let sodium = Sodium()

// Key generation
let keyPair = sodium.box.keyPair()!

// Encryption (Box - authenticated)
let encrypted = sodium.box.seal(
    message: messageBytes,
    recipientPublicKey: partnerPublicKey,
    senderSecretKey: mySecretKey
)

// Decryption
let decrypted = sodium.box.open(
    authenticatedCipherText: encrypted,
    senderPublicKey: partnerPublicKey,
    recipientSecretKey: mySecretKey
)
```

The `Box` API handles nonce generation internally, similar to ChaChaPoly's SealedBox.

**Trade-off:** Simpler API but adds external dependency with precompiled binaries.
