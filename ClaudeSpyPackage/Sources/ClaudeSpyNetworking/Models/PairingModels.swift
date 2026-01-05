import Foundation

// MARK: - Pairing Request/Response

/// Request to register a pairing code with the external server
public struct PairingRegistration: Codable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let pairingCode: String

    public init(deviceId: String, deviceName: String, pairingCode: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.pairingCode = pairingCode
    }
}

/// Request to complete pairing using a code
public struct PairingCompletion: Codable, Sendable {
    public let pairingCode: String
    public let deviceId: String
    public let deviceName: String

    public init(pairingCode: String, deviceId: String, deviceName: String) {
        self.pairingCode = pairingCode
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

/// Response from pairing operations
public struct PairingResponse: Codable, Sendable {
    public let success: Bool
    public let pairId: String?
    public let partnerDeviceName: String?
    public let error: String?

    public init(success: Bool, pairId: String? = nil, partnerDeviceName: String? = nil, error: String? = nil) {
        self.success = success
        self.pairId = pairId
        self.partnerDeviceName = partnerDeviceName
        self.error = error
    }

    public static func success(pairId: String, partnerDeviceName: String? = nil) -> PairingResponse {
        PairingResponse(success: true, pairId: pairId, partnerDeviceName: partnerDeviceName)
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

    public init(pairId: String, deviceId: String, deviceName: String) {
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

/// Message sent by iOS to register with the relay server
public struct RegisterIOSMessage: Codable, Sendable {
    public let pairId: String
    public let deviceId: String
    public let deviceName: String

    public init(pairId: String, deviceId: String, deviceName: String) {
        self.pairId = pairId
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

/// Response confirming Mac registration
public struct MacRegisteredMessage: Codable, Sendable {
    public let success: Bool
    public let iosDeviceName: String?
    public let error: String?

    public init(success: Bool, iosDeviceName: String? = nil, error: String? = nil) {
        self.success = success
        self.iosDeviceName = iosDeviceName
        self.error = error
    }
}

/// Response confirming iOS registration
public struct IOSRegisteredMessage: Codable, Sendable {
    public let success: Bool
    public let macDeviceName: String?
    public let error: String?

    public init(success: Bool, macDeviceName: String? = nil, error: String? = nil) {
        self.success = success
        self.macDeviceName = macDeviceName
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
