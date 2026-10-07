import Foundation

/// `POST /v1/devices` body.
public struct RegisterDeviceRequest: Hashable, Sendable, Codable {
    public var setupSecret: String
    public var deviceName: String

    public init(setupSecret: String, deviceName: String) {
        self.setupSecret = setupSecret
        self.deviceName = deviceName
    }
}

/// `201` response of `POST /v1/devices`. `token` goes into `Authorization: Bearer <token>`.
public struct RegisterDeviceResponse: Hashable, Sendable, Codable {
    public var deviceID: UUID
    public var token: String

    public init(deviceID: UUID, token: String) {
        self.deviceID = deviceID
        self.token = token
    }
}
