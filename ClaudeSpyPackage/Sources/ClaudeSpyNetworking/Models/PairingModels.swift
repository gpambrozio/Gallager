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
    /// Username of the Mac user (e.g., "john")
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
    /// Mac successfully registered a pairing code, waiting for iOS to complete
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

/// Info returned when Mac successfully registers a pairing code
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
    /// Username of the Mac user
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

/// Message sent by Mac to register with the relay server
public struct RegisterMacMessage: Codable, Sendable {
    public let pairId: String
    public let deviceId: String
    public let deviceName: String
    /// Base64-encoded public key for E2EE
    public let publicKey: String
    /// Unique identifier for the public key
    public let publicKeyId: String
    /// Username of the Mac user (e.g., "john")
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

/// Message sent by iOS to register with the relay server
public struct RegisterIOSMessage: Codable, Sendable {
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

/// Response confirming Mac registration
public struct MacRegisteredMessage: Codable, Sendable {
    public let success: Bool
    /// Name of paired iOS device (nil if iOS not connected yet)
    public let iosDeviceName: String?
    /// Base64-encoded public key of the iOS device for E2EE (nil if iOS not connected yet)
    public let iosPublicKey: String?
    /// Unique identifier for the iOS device's public key (nil if iOS not connected yet)
    public let iosPublicKeyId: String?
    public let error: String?

    public init(
        success: Bool,
        iosDeviceName: String? = nil,
        iosPublicKey: String? = nil,
        iosPublicKeyId: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.iosDeviceName = iosDeviceName
        self.iosPublicKey = iosPublicKey
        self.iosPublicKeyId = iosPublicKeyId
        self.error = error
    }
}

/// Response confirming iOS registration
public struct IOSRegisteredMessage: Codable, Sendable {
    public let success: Bool
    /// Name of paired Mac device (nil if Mac not connected yet)
    public let macDeviceName: String?
    /// Base64-encoded public key of the Mac device for E2EE (nil if Mac not connected yet)
    public let macPublicKey: String?
    /// Unique identifier for the Mac device's public key (nil if Mac not connected yet)
    public let macPublicKeyId: String?
    /// Username of the Mac user (nil if Mac not connected yet or not provided)
    public let macUsername: String?
    public let error: String?

    public init(
        success: Bool,
        macDeviceName: String? = nil,
        macPublicKey: String? = nil,
        macPublicKeyId: String? = nil,
        macUsername: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.macDeviceName = macDeviceName
        self.macPublicKey = macPublicKey
        self.macPublicKeyId = macPublicKeyId
        self.macUsername = macUsername
        self.error = error
    }
}

// MARK: - Pairing Status

/// Status of a device pair
public struct PairingStatus: Codable, Sendable {
    public let valid: Bool
    public let macConnected: Bool
    public let iosConnected: Bool

    public init(valid: Bool, macConnected: Bool, iosConnected: Bool) {
        self.valid = valid
        self.macConnected = macConnected
        self.iosConnected = iosConnected
    }
}

// MARK: - Mac Viewer Registration Messages

/// Message sent by Mac viewer to register with the relay server
public struct RegisterMacViewerMessage: Codable, Sendable {
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

/// Response confirming Mac viewer registration
public struct MacViewerRegisteredMessage: Codable, Sendable {
    public let success: Bool
    /// Name of paired Mac host device (nil if Mac not connected yet)
    public let macDeviceName: String?
    /// Base64-encoded public key of the Mac host device for E2EE (nil if Mac not connected yet)
    public let macPublicKey: String?
    /// Unique identifier for the Mac host device's public key (nil if Mac not connected yet)
    public let macPublicKeyId: String?
    /// Username of the Mac host user (nil if Mac not connected yet or not provided)
    public let macUsername: String?
    public let error: String?

    public init(
        success: Bool,
        macDeviceName: String? = nil,
        macPublicKey: String? = nil,
        macPublicKeyId: String? = nil,
        macUsername: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.macDeviceName = macDeviceName
        self.macPublicKey = macPublicKey
        self.macPublicKeyId = macPublicKeyId
        self.macUsername = macUsername
        self.error = error
    }
}
