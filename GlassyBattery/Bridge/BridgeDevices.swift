//
//  BridgeDevices.swift
//  GlassyBattery
//
//  Turns what a BatteryBridge client sends into a `Device` for the device list.
//

import Foundation

enum BridgeDevices {
    /// Every bridged device ID is `bridge:<clientID>:<client's own ID>`, so the device list can
    /// tell bridged devices apart and find their owner without a field of its own on `Device`.
    static let idPrefix = "bridge:"
    static let maxPerClient = 32

    /// The `deviceType` values `getDeviceIcon` draws an icon for. Anything else falls back to
    /// `general_bt` rather than being rejected, so a client written against a newer list still works.
    static let knownTypes: [String] = [
        "general_bt",
        "iPhone", "MobilePhone", "iPad", "iPod", "Watch", "RealityDevice",
        "ap_pod_left", "ap_pod_right", "ap_pod_all", "ap_case", "Headphones", "Headset", "Speaker",
        "Trackpad", "Keyboard", "MMouse", "Mouse", "Gamepad", "ApplePencil", "Pencil",
        "mac", "macbook", "macbookpro", "macbookair", "macmini", "macstudio", "macpro", "imac", "imacpro",
    ]
    static let fallbackType = "general_bt"

    static func deviceID(client clientID: String, localID: String) -> String {
        "\(idPrefix)\(clientID):\(localID)"
    }

    /// The client that owns a device, or nil if the device didn't come from BatteryBridge.
    static func clientID(of deviceID: String) -> String? {
        guard deviceID.hasPrefix(idPrefix) else { return nil }
        let rest = deviceID.dropFirst(idPrefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        return String(rest[..<colon])
    }

    /// Validates a payload and builds the device to store.
    ///
    /// - Parameter existing: the stored devices (`GlassyBatteryModel.snapshot()`), used to keep a
    ///   client from taking over another device's name — the device list is keyed by name, so a
    ///   bridged "Magic Mouse" would otherwise overwrite the real one — and to enforce `maxPerClient`.
    static func make(from payload: BridgeDevicePayload, clientID: String, existing: [Device],
                     now: Double = Date().timeIntervalSince1970) throws -> Device {
        guard payload.id.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
            throw BridgeError.invalid("id", "must be 1–64 characters of A–Z, a–z, 0–9, '.', '_' or '-'")
        }
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else { throw BridgeError.invalid("name", "must be 1–64 characters") }
        let model = try optionalText(payload.model, field: "model")
        let parent = try optionalText(payload.parent, field: "parent")

        let hasBattery = payload.hasBattery ?? true
        var level = 0
        if hasBattery {
            guard let given = payload.level else { throw BridgeError.invalid("level", "is required when hasBattery is true") }
            guard (0...100).contains(given) else { throw BridgeError.invalid("level", "must be 0–100") }
            level = given
        }

        let id = deviceID(client: clientID, localID: payload.id)
        if existing.contains(where: { $0.deviceName == name && $0.deviceID != id }) {
            throw BridgeError.nameTaken(name)
        }
        let isUpdate = existing.contains { $0.deviceID == id }
        if !isUpdate && existing.filter({ Self.clientID(of: $0.deviceID) == clientID }).count >= maxPerClient {
            throw BridgeError.tooManyDevices
        }

        return Device(hasBattery: hasBattery,
                      deviceID: id,
                      deviceType: knownTypes.contains(payload.type) ? payload.type : fallbackType,
                      deviceName: name,
                      deviceModel: model,
                      batteryLevel: level,
                      isCharging: payload.charging == true ? 1 : 0,
                      parentName: parent ?? "",
                      lastUpdate: now)
    }

    /// Drops bridged devices whose client has Nearcast turned off, or no longer exists or is active.
    static func forNearcast(_ devices: [Device], store: BridgeClientStore = .shared) -> [Device] {
        devices.filter { device in
            guard let owner = clientID(of: device.deviceID) else { return true }
            return store.sharesOnNearcast(clientID: owner)
        }
    }

    private static func optionalText(_ value: String?, field: String) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.count <= 64 else { throw BridgeError.invalid(field, "must be at most 64 characters") }
        return value
    }
}
