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

    public init(
        deviceId: String,
        deviceName: String,
        pairingCode: String,
        publicKey: String,
        publicKeyId: String
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.pairingCode = pairingCode
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
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

/// Response from pairing operations
public struct PairingResponse: Codable, Sendable {
    public let success: Bool
    public let pairId: String?
    public let partnerDeviceName: String?
    /// Base64-encoded public key of the partner device for E2EE (nil on failure)
    public let partnerPublicKey: String?
    /// Unique identifier for the partner's public key (nil on failure)
    public let partnerPublicKeyId: String?
    public let error: String?

    public init(
        success: Bool,
        pairId: String? = nil,
        partnerDeviceName: String? = nil,
        partnerPublicKey: String? = nil,
        partnerPublicKeyId: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.pairId = pairId
        self.partnerDeviceName = partnerDeviceName
        self.partnerPublicKey = partnerPublicKey
        self.partnerPublicKeyId = partnerPublicKeyId
        self.error = error
    }

    public static func success(
        pairId: String,
        partnerDeviceName: String,
        partnerPublicKey: String,
        partnerPublicKeyId: String
    ) -> PairingResponse {
        PairingResponse(
            success: true,
            pairId: pairId,
            partnerDeviceName: partnerDeviceName,
            partnerPublicKey: partnerPublicKey,
            partnerPublicKeyId: partnerPublicKeyId
        )
    }

    public static func failure(_ error: String) -> PairingResponse {
        PairingResponse(success: false, error: error)
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
    public let error: String?

    public init(
        success: Bool,
        macDeviceName: String? = nil,
        macPublicKey: String? = nil,
        macPublicKeyId: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.macDeviceName = macDeviceName
        self.macPublicKey = macPublicKey
        self.macPublicKeyId = macPublicKeyId
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
