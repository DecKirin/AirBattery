//
//  BridgeModels.swift
//  GlassyBattery
//
//  BatteryBridge lets other apps on this Mac push devices into the device list over a loopback
//  HTTP / WebSocket API. These are the types shared by the client store, the device mapper and
//  the server.
//

import Foundation

/// How BatteryBridge treats a client that registers for the first time.
enum BridgeMode: String, Codable, CaseIterable {
    /// Every client is accepted until it is blocked.
    case blocklist
    /// New clients wait as `pending` until they are approved.
    case allowlist
}

enum BridgeClientStatus: String, Codable {
    case active, pending, blocked
}

/// An app that registered with BatteryBridge. Only a hash of its token is kept.
struct BridgeClient: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var bundleID: String?
    var status: BridgeClientStatus
    var tokenHash: String
    /// Whether this client's devices are shared with other Macs over Nearcast.
    var nearcast: Bool = true
    let createdAt: Double
    var lastSeen: Double?

    /// What makes a second registration "the same app": the bundle ID when given, else the name.
    var identity: String { Self.identity(name: name, bundleID: bundleID) }

    static func identity(name: String, bundleID: String?) -> String {
        if let bundleID, !bundleID.isEmpty { return bundleID.lowercased() }
        return name.lowercased()
    }
}

/// A device as a client sends it. `id` is the client's own ID for the device; it is namespaced
/// with the client ID before it reaches the device list (see `BridgeDevices.deviceID`).
struct BridgeDevicePayload: Codable, Equatable {
    var id: String
    var name: String
    var type: String
    var model: String?
    var level: Int?
    var charging: Bool?
    var hasBattery: Bool?
    var parent: String?
}

/// An API error. `status` is the HTTP status, `code` a stable string clients can switch on.
struct BridgeError: Error, Equatable, Codable {
    let status: Int
    let code: String
    let message: String

    static let unauthorized = BridgeError(status: 401, code: "unauthorized", message: "Missing or unknown token")
    static let pending = BridgeError(status: 403, code: "pending", message: "This client is waiting for approval in GlassyBattery")
    static let blocked = BridgeError(status: 403, code: "blocked", message: "This client has been blocked in GlassyBattery")
    static let notFound = BridgeError(status: 404, code: "not_found", message: "No such device")
    static let tooManyDevices = BridgeError(status: 422, code: "too_many_devices",
                                            message: "A client can register at most \(BridgeDevices.maxPerClient) devices")

    static func nameTaken(_ name: String) -> BridgeError {
        BridgeError(status: 409, code: "name_taken", message: "\"\(name)\" is already used by another device")
    }

    static func invalid(_ field: String, _ reason: String) -> BridgeError {
        BridgeError(status: 422, code: "invalid_\(field)", message: "\(field): \(reason)")
    }
}
