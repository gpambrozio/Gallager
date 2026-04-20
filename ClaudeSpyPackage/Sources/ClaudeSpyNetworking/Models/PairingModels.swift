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
    case paired(PairedViewerInfo)
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
        .paired(PairedViewerInfo(
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
public struct PairedViewerInfo: Codable, Sendable, Equatable {
    public let pairId: String
    public let partnerDeviceName: String
    /// Base64-encoded public key of the partner for E2EE
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
    /// Marketing version of the host app (e.g. "1.23"). Empty if legacy client.
    public let appVersion: String
    /// Minimum partner version the host will accept. Empty if legacy client.
    public let minRequiredPartnerVersion: String

    public init(
        pairId: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String,
        username: String,
        appVersion: String = "",
        minRequiredPartnerVersion: String = ""
    ) {
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
        self.username = username
        self.appVersion = appVersion
        self.minRequiredPartnerVersion = minRequiredPartnerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case pairId
        case deviceId
        case deviceName
        case publicKey
        case publicKeyId
        case username
        case appVersion
        case minRequiredPartnerVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pairId = try container.decode(String.self, forKey: .pairId)
        self.deviceId = try container.decode(String.self, forKey: .deviceId)
        self.deviceName = try container.decode(String.self, forKey: .deviceName)
        self.publicKey = try container.decode(String.self, forKey: .publicKey)
        self.publicKeyId = try container.decode(String.self, forKey: .publicKeyId)
        self.username = try container.decode(String.self, forKey: .username)
        self.appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        self.minRequiredPartnerVersion = try container.decodeIfPresent(String.self, forKey: .minRequiredPartnerVersion) ?? ""
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
    /// Marketing version of the viewer app (e.g. "1.23"). Empty if legacy client.
    public let appVersion: String
    /// Minimum partner version the viewer will accept. Empty if legacy client.
    public let minRequiredPartnerVersion: String

    public init(
        pairId: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String,
        appVersion: String = "",
        minRequiredPartnerVersion: String = ""
    ) {
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
        self.appVersion = appVersion
        self.minRequiredPartnerVersion = minRequiredPartnerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case pairId
        case deviceId
        case deviceName
        case publicKey
        case publicKeyId
        case appVersion
        case minRequiredPartnerVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pairId = try container.decode(String.self, forKey: .pairId)
        self.deviceId = try container.decode(String.self, forKey: .deviceId)
        self.deviceName = try container.decode(String.self, forKey: .deviceName)
        self.publicKey = try container.decode(String.self, forKey: .publicKey)
        self.publicKeyId = try container.decode(String.self, forKey: .publicKeyId)
        self.appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        self.minRequiredPartnerVersion = try container.decodeIfPresent(String.self, forKey: .minRequiredPartnerVersion) ?? ""
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
    /// Marketing version of the paired viewer (nil if viewer not connected or legacy client)
    public let viewerAppVersion: String?
    /// Minimum partner version required by the paired viewer (nil if viewer not connected or legacy client)
    public let viewerMinRequiredPartnerVersion: String?
    public let error: String?

    public init(
        success: Bool,
        viewerDeviceName: String? = nil,
        viewerPublicKey: String? = nil,
        viewerPublicKeyId: String? = nil,
        viewerAppVersion: String? = nil,
        viewerMinRequiredPartnerVersion: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.viewerDeviceName = viewerDeviceName
        self.viewerPublicKey = viewerPublicKey
        self.viewerPublicKeyId = viewerPublicKeyId
        self.viewerAppVersion = viewerAppVersion
        self.viewerMinRequiredPartnerVersion = viewerMinRequiredPartnerVersion
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case success
        case viewerDeviceName
        case viewerPublicKey
        case viewerPublicKeyId
        case viewerAppVersion
        case viewerMinRequiredPartnerVersion
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decode(Bool.self, forKey: .success)
        self.viewerDeviceName = try container.decodeIfPresent(String.self, forKey: .viewerDeviceName)
        self.viewerPublicKey = try container.decodeIfPresent(String.self, forKey: .viewerPublicKey)
        self.viewerPublicKeyId = try container.decodeIfPresent(String.self, forKey: .viewerPublicKeyId)
        self.viewerAppVersion = try container.decodeIfPresent(String.self, forKey: .viewerAppVersion)
        self.viewerMinRequiredPartnerVersion = try container.decodeIfPresent(
            String.self,
            forKey: .viewerMinRequiredPartnerVersion
        )
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
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
    /// Marketing version of the paired host (nil if host not connected or legacy client)
    public let hostAppVersion: String?
    /// Minimum partner version required by the paired host (nil if host not connected or legacy client)
    public let hostMinRequiredPartnerVersion: String?
    public let error: String?

    public init(
        success: Bool,
        hostDeviceName: String? = nil,
        hostPublicKey: String? = nil,
        hostPublicKeyId: String? = nil,
        hostUsername: String? = nil,
        hostAppVersion: String? = nil,
        hostMinRequiredPartnerVersion: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.hostDeviceName = hostDeviceName
        self.hostPublicKey = hostPublicKey
        self.hostPublicKeyId = hostPublicKeyId
        self.hostUsername = hostUsername
        self.hostAppVersion = hostAppVersion
        self.hostMinRequiredPartnerVersion = hostMinRequiredPartnerVersion
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case success
        case hostDeviceName
        case hostPublicKey
        case hostPublicKeyId
        case hostUsername
        case hostAppVersion
        case hostMinRequiredPartnerVersion
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.success = try container.decode(Bool.self, forKey: .success)
        self.hostDeviceName = try container.decodeIfPresent(String.self, forKey: .hostDeviceName)
        self.hostPublicKey = try container.decodeIfPresent(String.self, forKey: .hostPublicKey)
        self.hostPublicKeyId = try container.decodeIfPresent(String.self, forKey: .hostPublicKeyId)
        self.hostUsername = try container.decodeIfPresent(String.self, forKey: .hostUsername)
        self.hostAppVersion = try container.decodeIfPresent(String.self, forKey: .hostAppVersion)
        self.hostMinRequiredPartnerVersion = try container.decodeIfPresent(
            String.self,
            forKey: .hostMinRequiredPartnerVersion
        )
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
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
