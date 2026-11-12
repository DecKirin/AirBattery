//
//  BridgeRouter.swift
//  GlassyBattery
//
//  The BatteryBridge v1 API. Pure request → response, so it can be tested without a socket.
//

import Foundation

final class BridgeRouter {
    /// Where bridged devices are stored. `.model` is the app's device list; tests pass their own.
    struct DeviceList {
        var snapshot: () -> [Device]
        var update: (Device) -> Void
        var remove: (@escaping (Device) -> Bool) -> Void

        static let model = DeviceList(snapshot: { GlassyBatteryModel.snapshot() },
                                      update: { GlassyBatteryModel.updateDevice($0) },
                                      remove: { GlassyBatteryModel.removeDevices(where: $0) })
    }

    static let apiVersion = 1
    static let maxBatch = BridgeDevices.maxPerClient

    let store: BridgeClientStore
    let devices: DeviceList
    let icons: BridgeIconStore
    let mode: () -> BridgeMode
    /// The port the listener is bound to, for the Host check.
    var port: UInt16 = 0
    /// Called when a registration ends up waiting for approval.
    var onPendingClient: ((BridgeClient) -> Void)?
    var now: () -> Double = { Date().timeIntervalSince1970 }

    init(store: BridgeClientStore, devices: DeviceList = .model, icons: BridgeIconStore = .shared,
         mode: @escaping () -> BridgeMode) {
        self.store = store
        self.devices = devices
        self.icons = icons
        self.mode = mode
    }

    func handle(_ request: BridgeHTTPRequest) -> BridgeHTTPResponse {
        do {
            return try route(request)
        } catch let error as BridgeError {
            return .error(error)
        } catch {
            return .error(.malformedRequest)
        }
    }

    private func route(_ request: BridgeHTTPRequest) throws -> BridgeHTTPResponse {
        try checkCaller(request)

        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { throw BridgeError.routeNotFound }
        let rest = Array(parts.dropFirst())
        let method = request.method

        switch rest.first {
        case "health" where rest.count == 1:
            guard method == "GET" else { throw BridgeError.methodNotAllowed }
            return .json(200, Health(api: Self.apiVersion, app: "GlassyBattery",
                                     version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))
        case "types" where rest.count == 1:
            guard method == "GET" else { throw BridgeError.methodNotAllowed }
            return .json(200, ["types": BridgeDevices.knownTypes])
        case "register" where rest.count == 1:
            guard method == "POST" else { throw BridgeError.methodNotAllowed }
            return try register(request)
        case "me" where rest.count == 1:
            guard method == "GET" else { throw BridgeError.methodNotAllowed }
            let client = try authenticate(request)
            return .json(200, Me(client: BridgeClientInfo(client), devices: devices(of: client.id)))
        case "devices:batch" where rest.count == 1:
            guard method == "POST" else { throw BridgeError.methodNotAllowed }
            return try batch(request, client: authenticate(request))
        case "devices" where rest.count == 2:
            switch method {
            case "PUT": return try put(request, localID: rest[1], client: authenticate(request))
            case "DELETE": return try delete(localID: rest[1], client: authenticate(request))
            default: throw BridgeError.methodNotAllowed
            }
        case "icons" where rest.count == 1:
            guard method == "GET" else { throw BridgeError.methodNotAllowed }
            return .json(200, ["icons": icons.list(clientID: try authenticate(request).id)])
        case "icons" where rest.count == 2:
            switch method {
            case "PUT": return try putIcon(request, name: rest[1], client: authenticate(request))
            case "DELETE":
                try icons.delete(name: rest[1], clientID: authenticate(request).id)
                return .noContent
            default: throw BridgeError.methodNotAllowed
            }
        default:
            throw BridgeError.routeNotFound
        }
    }

    // MARK: Endpoints

    private func register(_ request: BridgeHTTPRequest) throws -> BridgeHTTPResponse {
        struct Body: Decodable { let name: String; let bundleID: String? }
        let body = try decode(Body.self, from: request)
        let (client, token) = try store.register(name: body.name, bundleID: body.bundleID, mode: mode(), now: now())
        if client.status == .pending { onPendingClient?(client) }
        return .json(client.status == .pending ? 202 : 201,
                     Registered(clientID: client.id, token: token, status: client.status))
    }

    private func put(_ request: BridgeHTTPRequest, localID: String, client: BridgeClient) throws -> BridgeHTTPResponse {
        var payload = try decode(DeviceBody.self, from: request)
        if let bodyID = payload.id, bodyID != localID {
            throw BridgeError.invalid("id", "doesn't match the URL")
        }
        payload.id = localID
        return .json(200, ["device": try upsert(payload.payload, for: client)])
    }

    private func batch(_ request: BridgeHTTPRequest, client: BridgeClient) throws -> BridgeHTTPResponse {
        let payloads = try decode([BridgeDevicePayload].self, from: request)
        return .json(200, ["devices": try upsert(batch: payloads, for: client)])
    }

    private func delete(localID: String, client: BridgeClient) throws -> BridgeHTTPResponse {
        try removeDevice(localID: localID, for: client)
        return .noContent
    }

    /// `{"format": "pdf" | "svg" | "png", "data": "<base64>"}`. JSON rather than raw bytes, as
    /// every body must be JSON (see `checkCaller`).
    private func putIcon(_ request: BridgeHTTPRequest, name: String, client: BridgeClient) throws -> BridgeHTTPResponse {
        struct Body: Decodable { let format: String; let data: String }
        let body = try decode(Body.self, from: request)
        guard let data = Data(base64Encoded: body.data, options: .ignoreUnknownCharacters) else {
            throw BridgeError.invalid("data", "must be base64")
        }
        return .json(200, ["icon": try icons.put(name: name, format: body.format, data: data, clientID: client.id)])
    }

    // MARK: Device operations (shared with the stream)

    func upsert(_ payload: BridgeDevicePayload, for client: BridgeClient) throws -> BridgeDeviceInfo {
        let device = try BridgeDevices.make(from: payload, clientID: client.id, existing: devices.snapshot(),
                                            hasIcon: { self.icons.exists(name: $0, clientID: client.id) }, now: now())
        devices.update(device)
        return BridgeDeviceInfo(device)
    }

    /// All or nothing: every device is validated, against the stored ones and each other, before any is stored.
    func upsert(batch payloads: [BridgeDevicePayload], for client: BridgeClient) throws -> [BridgeDeviceInfo] {
        guard payloads.count <= Self.maxBatch else { throw BridgeError.invalid("batch", "at most \(Self.maxBatch) devices") }
        var working = devices.snapshot()
        var accepted: [Device] = []
        for payload in payloads {
            let device = try BridgeDevices.make(from: payload, clientID: client.id, existing: working,
                                                hasIcon: { self.icons.exists(name: $0, clientID: client.id) }, now: now())
            working.removeAll { $0.deviceID == device.deviceID || $0.deviceName == device.deviceName }
            working.append(device)
            accepted.removeAll { $0.deviceID == device.deviceID }
            accepted.append(device)
        }
        accepted.forEach(devices.update)
        return accepted.map(BridgeDeviceInfo.init)
    }

    func removeDevice(localID: String, for client: BridgeClient) throws {
        let id = BridgeDevices.deviceID(client: client.id, localID: localID)
        guard devices.snapshot().contains(where: { $0.deviceID == id }) else { throw BridgeError.notFound }
        devices.remove { $0.deviceID == id }
    }

    // MARK: Helpers

    /// Only local, non-browser callers. A web page can reach 127.0.0.1 too, so:
    /// - the Host header must name loopback, which defeats DNS rebinding;
    /// - any Origin header is refused, since browsers send one and native clients don't;
    /// - bodies must be JSON, which a page can't send cross-origin without a (refused) preflight.
    private func checkCaller(_ request: BridgeHTTPRequest) throws {
        try Self.checkLocal(headers: request.headers, port: port)
        if !request.body.isEmpty || request.method == "POST" || request.method == "PUT" {
            guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                throw BridgeError.unsupportedMediaType
            }
        }
    }

    /// The Host and Origin half of `checkCaller`, shared with the stream's handshake.
    /// `headers` must have lowercased names.
    static func checkLocal(headers: [String: String], port: UInt16) throws {
        guard let host = headers["host"]?.lowercased() else { throw BridgeError.forbiddenHost }
        let allowed = ["127.0.0.1", "localhost", "[::1]"]
        guard allowed.contains(host) || allowed.contains(where: { host == "\($0):\(port)" }) else {
            throw BridgeError.forbiddenHost
        }
        if headers["origin"] != nil { throw BridgeError.forbiddenOrigin }
    }

    private func authenticate(_ request: BridgeHTTPRequest) throws -> BridgeClient {
        guard let token = request.bearerToken else { throw BridgeError.unauthorized }
        return try store.authenticate(token: token, now: now())
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: BridgeHTTPRequest) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: request.body)
        } catch let DecodingError.keyNotFound(key, _) {
            throw BridgeError.invalidBody("\(key.stringValue): missing")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw BridgeError.invalidBody("\(path.isEmpty ? "body" : path): wrong type")
        } catch {
            throw BridgeError.invalidBody("body: not valid JSON")
        }
    }

    private func devices(of clientID: String) -> [BridgeDeviceInfo] {
        devices.snapshot().filter { BridgeDevices.clientID(of: $0.deviceID) == clientID }.map(BridgeDeviceInfo.init)
    }
}

// MARK: Wire types

private struct Health: Encodable {
    let api: Int
    let app: String
    let version: String?
}

private struct Registered: Encodable {
    let clientID: String
    let token: String
    let status: BridgeClientStatus
}

private struct Me: Encodable {
    let client: BridgeClientInfo
    let devices: [BridgeDeviceInfo]
}

/// A client as the API shows it: no token hash.
struct BridgeClientInfo: Encodable {
    let id: String
    let name: String
    let bundleID: String?
    let status: BridgeClientStatus
    let nearcast: Bool

    init(_ client: BridgeClient) {
        id = client.id
        name = client.name
        bundleID = client.bundleID
        status = client.status
        nearcast = client.nearcast
    }
}

/// A stored device as the API shows it, with the client's own ID rather than the namespaced one.
struct BridgeDeviceInfo: Encodable {
    let id: String
    let name: String
    let type: String
    let model: String?
    let icon: String?
    let customIcon: String?
    let level: Int
    let charging: Bool
    let hasBattery: Bool
    let parent: String?
    let lastUpdate: Double

    init(_ device: Device) {
        id = device.deviceID.split(separator: ":", maxSplits: 2).last.map(String.init) ?? device.deviceID
        name = device.deviceName
        type = device.deviceType
        model = device.deviceModel
        icon = device.deviceIcon
        customIcon = device.deviceCustomIcon
        level = device.batteryLevel
        charging = device.isCharging != 0
        hasBattery = device.hasBattery
        parent = device.parentName.isEmpty ? nil : device.parentName
        lastUpdate = device.lastUpdate
    }
}

/// `PUT /v1/devices/{id}` takes the ID from the URL, so it is optional in the body.
private struct DeviceBody: Decodable {
    var id: String?
    let name: String
    let type: String
    let model: String?
    let level: Int?
    let charging: Bool?
    let hasBattery: Bool?
    let parent: String?
    let icon: String?
    let customIcon: String?

    var payload: BridgeDevicePayload {
        BridgeDevicePayload(id: id ?? "", name: name, type: type, model: model, level: level,
                            charging: charging, hasBattery: hasBattery, parent: parent, icon: icon,
                            customIcon: customIcon)
    }
}
