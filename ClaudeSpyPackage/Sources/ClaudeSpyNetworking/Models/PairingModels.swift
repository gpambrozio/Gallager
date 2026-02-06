import Foundation

// MARK: - Pairing Request/Response

/// Request to register a pairing code with the external server
public struct PairingRegistration: Codable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let pairingCode: String
    /// Base64-encoded public key for E2EE
    public let publicKey: String
    /// Unique identifier for the public key
    public let publicKeyId: String
    /// Username of the host user (e.g., "john")
    public let username: String

    public init(
        deviceId: String,
        deviceName: String,
        pairingCode: String,
        publicKey: String,
        publicKeyId: String,
        username: String
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.pairingCode = pairingCode
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
        self.username = username
    }
}

/// Request to complete pairing using a code
public struct PairingCompletion: Codable, Sendable {
    public let pairingCode: String
    public let deviceId: String
    public let deviceName: String
    /// Base64-encoded public key for E2EE
    public let publicKey: String
    /// Unique identifier for the public key
    public let publicKeyId: String

    public init(
        pairingCode: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String
    ) {
        self.pairingCode = pairingCode
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
    }
}

/// Response from pairing operations using a Result-style enum
public enum PairingResponse: Codable, Sendable, Equatable {
    /// Host successfully registered a pairing code, waiting for viewer to complete
    case registered(RegistrationInfo)
    /// Pairing completed successfully with partner device info
    case paired(PairedDeviceInfo)
    /// Pairing operation failed
    case error(ErrorInfo)

    // MARK: - Convenience Factory Methods

    public static func registered(pairId: String) -> PairingResponse {
        .registered(RegistrationInfo(pairId: pairId))
    }

    public static func paired(
        pairId: String,
        partnerDeviceName: String,
        partnerPublicKey: String,
        partnerPublicKeyId: String,
        partnerUsername: String
    ) -> PairingResponse {
        .paired(PairedDeviceInfo(
            pairId: pairId,
            partnerDeviceName: partnerDeviceName,
            partnerPublicKey: partnerPublicKey,
            partnerPublicKeyId: partnerPublicKeyId,
            partnerUsername: partnerUsername
        ))
    }

    public static func error(_ message: String) -> PairingResponse {
        .error(ErrorInfo(message: message))
    }
}

/// Info returned when host successfully registers a pairing code
public struct RegistrationInfo: Codable, Sendable, Equatable {
    public let pairId: String

    public init(pairId: String) {
        self.pairId = pairId
    }
}

/// Info returned when pairing is completed successfully
public struct PairedDeviceInfo: Codable, Sendable, Equatable {
    public let pairId: String
    public let partnerDeviceName: String
    /// Base64-encoded public key of the partner device for E2EE
    public let partnerPublicKey: String
    /// Unique identifier for the partner's public key
    public let partnerPublicKeyId: String
    /// Username of the host user
    public let partnerUsername: String

    public init(
        pairId: String,
        partnerDeviceName: String,
        partnerPublicKey: String,
        partnerPublicKeyId: String,
        partnerUsername: String
    ) {
        self.pairId = pairId
        self.partnerDeviceName = partnerDeviceName
        self.partnerPublicKey = partnerPublicKey
        self.partnerPublicKeyId = partnerPublicKeyId
        self.partnerUsername = partnerUsername
    }
}

/// Error info for failed pairing operations
public struct ErrorInfo: Codable, Sendable, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - Device Registration Messages

/// Message sent by host to register with the relay server
public struct RegisterHostMessage: Codable, Sendable {
    public let pairId: String
    public let deviceId: String
    public let deviceName: String
    /// Base64-encoded public key for E2EE
    public let publicKey: String
    /// Unique identifier for the public key
    public let publicKeyId: String
    /// Username of the host user (e.g., "john")
    public let username: String

    public init(
        pairId: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String,
        username: String
    ) {
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
        self.username = username
    }
}

/// Message sent by viewer (iOS or macOS viewer) to register with the relay server
public struct RegisterViewerMessage: Codable, Sendable {
    public let pairId: String
    public let deviceId: String
    public let deviceName: String
    /// Base64-encoded public key for E2EE
    public let publicKey: String
    /// Unique identifier for the public key
    public let publicKeyId: String

    public init(
        pairId: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String
    ) {
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
    }
}

/// Response confirming host registration
public struct HostRegisteredMessage: Codable, Sendable {
    public let success: Bool
    /// Name of paired viewer device (nil if viewer not connected yet)
    public let viewerDeviceName: String?
    /// Base64-encoded public key of the viewer device for E2EE (nil if viewer not connected yet)
    public let viewerPublicKey: String?
    /// Unique identifier for the viewer device's public key (nil if viewer not connected yet)
    public let viewerPublicKeyId: String?
    public let error: String?

    public init(
        success: Bool,
        viewerDeviceName: String? = nil,
        viewerPublicKey: String? = nil,
        viewerPublicKeyId: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.viewerDeviceName = viewerDeviceName
        self.viewerPublicKey = viewerPublicKey
        self.viewerPublicKeyId = viewerPublicKeyId
        self.error = error
    }
}

/// Response confirming viewer registration
public struct ViewerRegisteredMessage: Codable, Sendable {
    public let success: Bool
    /// Name of paired host device (nil if host not connected yet)
    public let hostDeviceName: String?
    /// Base64-encoded public key of the host device for E2EE (nil if host not connected yet)
    public let hostPublicKey: String?
    /// Unique identifier for the host device's public key (nil if host not connected yet)
    public let hostPublicKeyId: String?
    /// Username of the host user (nil if host not connected yet or not provided)
    public let hostUsername: String?
    public let error: String?

    public init(
        success: Bool,
        hostDeviceName: String? = nil,
        hostPublicKey: String? = nil,
        hostPublicKeyId: String? = nil,
        hostUsername: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.hostDeviceName = hostDeviceName
        self.hostPublicKey = hostPublicKey
        self.hostPublicKeyId = hostPublicKeyId
        self.hostUsername = hostUsername
        self.error = error
    }
}

// MARK: - Pairing Status

/// Status of a device pair
public struct PairingStatus: Codable, Sendable {
    public let valid: Bool
    public let hostConnected: Bool
    public let viewerConnected: Bool

    public init(valid: Bool, hostConnected: Bool, viewerConnected: Bool) {
        self.valid = valid
        self.hostConnected = hostConnected
        self.viewerConnected = viewerConnected
    }
}
