//
//  main.swift
//  BridgeCoreTests
//
//  Checks for the BatteryBridge core (client store, device mapping, Nearcast filter). The app has
//  no test target, so run.sh compiles this together with the real model sources instead.
//

import Foundation

// Each target defines these in its entry file (GlassyBatteryApp.swift, abt/main.swift).
let fd = FileManager.default
let ud = UserDefaults(suiteName: "glassybattery-bridge-tests")!

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ label: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("✘ line \(line): \(label)")
    }
}

func expectError(_ expected: BridgeError, _ label: String, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("✘ line \(line): \(label) — no error, expected \(expected.code)")
    } catch let error as BridgeError where error == expected {
    } catch {
        failures += 1
        print("✘ line \(line): \(label) — got \(error), expected \(expected.code)")
    }
}

let tempDir = fd.temporaryDirectory.appendingPathComponent("bridge-tests-\(UUID().uuidString)")
func freshStore() -> (BridgeClientStore, URL) {
    let url = tempDir.appendingPathComponent("\(UUID().uuidString)/clients.json")
    return (BridgeClientStore(fileURL: url), url)
}

// MARK: Client store

do {
    let (store, url) = freshStore()
    let (client, token) = try store.register(name: "Logi Bridge", bundleID: "com.example.logi", mode: .blocklist)
    check(client.status == .active, "blocklist mode accepts new clients")
    check(token.hasPrefix("gbb_") && token.count > 40, "token has prefix and 256 bits")
    check((try? store.authenticate(token: token))?.id == client.id, "token authenticates")
    let onDisk = try String(contentsOf: url, encoding: .utf8)
    check(!onDisk.contains(token) && onDisk.contains(BridgeClientStore.hash(token)), "only the hash is persisted")
    let perms = try fd.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    check(perms == 0o600, "client file is private")
    expectError(.unauthorized, "unknown token") { _ = try store.authenticate(token: "gbb_nope") }

    let reloaded = BridgeClientStore(fileURL: url)
    // lastSeen is persisted at most once a minute, so compare everything else.
    check(reloaded.all.map { [$0.id, $0.name, $0.bundleID ?? "", $0.status.rawValue, $0.tokenHash] }
          == store.all.map { [$0.id, $0.name, $0.bundleID ?? "", $0.status.rawValue, $0.tokenHash] },
          "clients survive a reload")
}

do {
    let (store, _) = freshStore()
    let (client, token) = try store.register(name: "Pi Sensor", bundleID: nil, mode: .allowlist)
    check(client.status == .pending, "allowlist mode holds new clients")
    expectError(.pending, "pending client can't push") { _ = try store.authenticate(token: token) }
    store.setStatus(.active, for: client.id)
    check((try? store.authenticate(token: token)) != nil, "approved client authenticates")

    // Same identity again: new token, old one dead, approval revoked in allowlist mode.
    let (again, newToken) = try store.register(name: "pi sensor", bundleID: "", mode: .allowlist)
    check(again.id == client.id && store.all.count == 1, "re-registration reuses the entry (name, case-insensitive)")
    check(again.status == .pending, "re-registration in allowlist mode needs approval again")
    expectError(.unauthorized, "old token stops working") { _ = try store.authenticate(token: token) }
    expectError(.pending, "new token is pending") { _ = try store.authenticate(token: newToken) }

    store.applyMode(.blocklist)
    check(store.client(id: client.id)?.status == .active, "switching to blocklist admits pending clients")

    store.setStatus(.blocked, for: client.id)
    expectError(.blocked, "blocked client can't push") { _ = try store.authenticate(token: newToken) }
    expectError(.blocked, "blocked client can't re-register") {
        _ = try store.register(name: "Pi Sensor", bundleID: nil, mode: .blocklist)
    }
    store.applyMode(.blocklist)
    check(store.client(id: client.id)?.status == .blocked, "blocklist mode doesn't unblock")

    let reset = store.resetToken(for: client.id)
    check(reset != nil && reset != newToken, "reset issues a new token")
    check(store.resetToken(for: "missing") == nil, "reset of unknown client")

    store.remove(id: client.id)
    check(store.all.isEmpty, "remove")
}

do {
    let (store, _) = freshStore()
    expectError(.invalid("name", "must be 1–64 characters"), "blank name") {
        _ = try store.register(name: "   ", bundleID: nil, mode: .blocklist)
    }
    let a = try store.register(name: "Same Name", bundleID: "com.a", mode: .blocklist).client
    let b = try store.register(name: "Same Name", bundleID: "com.b", mode: .blocklist).client
    check(a.id != b.id, "bundle ID beats name for identity")
}

// MARK: Device mapping

let clientID = "abc123def456"
func payload(_ id: String = "mouse", name: String = "Bridge Mouse", type: String = "Mouse",
             level: Int? = 55, charging: Bool? = true, hasBattery: Bool? = nil) -> BridgeDevicePayload {
    BridgeDevicePayload(id: id, name: name, type: type, model: " M720 ", level: level,
                        charging: charging, hasBattery: hasBattery, parent: nil)
}

do {
    let d = try BridgeDevices.make(from: payload(), clientID: clientID, existing: [], now: 1000)
    check(d.deviceID == "bridge:abc123def456:mouse", "device ID is namespaced")
    check(BridgeDevices.clientID(of: d.deviceID) == clientID, "owner is recoverable from the ID")
    check(BridgeDevices.clientID(of: "AA:BB:CC") == nil, "non-bridge devices have no owner")
    check(d.deviceType == "Mouse" && d.batteryLevel == 55 && d.isCharging == 1, "fields carried over")
    check(d.deviceModel == "M720" && d.parentName == "" && d.lastUpdate == 1000, "trimmed model, no parent")
    check(getDeviceIcon(d) == "computermouse.fill", "type maps to the right icon")

    let odd = try BridgeDevices.make(from: payload(type: "Toaster"), clientID: clientID, existing: [])
    check(odd.deviceType == "general_bt", "unknown type falls back to general_bt")

    let noBattery = try BridgeDevices.make(from: payload(level: nil, hasBattery: false), clientID: clientID, existing: [])
    check(!noBattery.hasBattery && noBattery.batteryLevel == 0, "devices without a battery")

    for type in BridgeDevices.knownTypes {
        let icon = getDeviceIcon(Device(deviceID: "x", deviceType: type, deviceName: "x", batteryLevel: 1, isCharging: 0, lastUpdate: 0))
        check(icon != "questionmark.circle.fill", "known type \(type) has an icon")
    }

    expectError(.invalid("level", "must be 0–100"), "level too high") {
        _ = try BridgeDevices.make(from: payload(level: 101), clientID: clientID, existing: [])
    }
    expectError(.invalid("level", "is required when hasBattery is true"), "missing level") {
        _ = try BridgeDevices.make(from: payload(level: nil), clientID: clientID, existing: [])
    }
    expectError(.invalid("id", "must be 1–64 characters of A–Z, a–z, 0–9, '.', '_' or '-'"), "id with a colon") {
        _ = try BridgeDevices.make(from: payload("a:b"), clientID: clientID, existing: [])
    }

    let realMouse = Device(deviceID: "AA:BB", deviceType: "MMouse", deviceName: "Magic Mouse", batteryLevel: 80, isCharging: 0, lastUpdate: 0)
    expectError(.nameTaken("Magic Mouse"), "can't take a real device's name") {
        _ = try BridgeDevices.make(from: payload(name: "Magic Mouse"), clientID: clientID, existing: [realMouse])
    }
    check((try? BridgeDevices.make(from: payload(level: 40), clientID: clientID, existing: [d])) != nil,
          "updating your own device keeps its name")

    let full = (0..<BridgeDevices.maxPerClient).map {
        Device(deviceID: BridgeDevices.deviceID(client: clientID, localID: "d\($0)"), deviceType: "Mouse",
               deviceName: "Device \($0)", batteryLevel: 1, isCharging: 0, lastUpdate: 0)
    }
    expectError(.tooManyDevices, "per-client cap") {
        _ = try BridgeDevices.make(from: payload("one-more", name: "One More"), clientID: clientID, existing: full)
    }
    check((try? BridgeDevices.make(from: payload("d3", name: "Device 3"), clientID: clientID, existing: full)) != nil,
          "the cap doesn't block updates")
    check((try? BridgeDevices.make(from: payload("x", name: "X"), clientID: "otherclient1", existing: full)) != nil,
          "the cap is per client")
}

// MARK: Nearcast filter

do {
    let (store, _) = freshStore()
    let sharing = try store.register(name: "Sharing", bundleID: nil, mode: .blocklist).client
    let quiet = try store.register(name: "Quiet", bundleID: nil, mode: .blocklist).client
    store.setNearcast(false, for: quiet.id)
    func device(_ owner: String?, _ name: String) -> Device {
        Device(deviceID: owner.map { BridgeDevices.deviceID(client: $0, localID: name) } ?? name,
               deviceType: "Mouse", deviceName: name, batteryLevel: 1, isCharging: 0, lastUpdate: 0)
    }
    let list = [device(nil, "local"), device(sharing.id, "shared"), device(quiet.id, "quiet"), device("gone00000000", "orphan")]
    let names = BridgeDevices.forNearcast(list, store: store).map(\.deviceName)
    check(names == ["local", "shared"], "Nearcast keeps local and sharing clients only (got \(names))")
}

// MARK: Model hooks

do {
    GlassyBatteryModel.updateDevice(Device(deviceID: "bridge:c1:a", deviceType: "Mouse", deviceName: "Bridged A", batteryLevel: 1, isCharging: 0, lastUpdate: 0))
    GlassyBatteryModel.updateDevice(Device(deviceID: "AA", deviceType: "Mouse", deviceName: "Local", batteryLevel: 1, isCharging: 0, lastUpdate: 0))
    check(GlassyBatteryModel.snapshot().count == 2, "snapshot includes expired devices")
    GlassyBatteryModel.removeDevices { BridgeDevices.clientID(of: $0.deviceID) == "c1" }
    check(GlassyBatteryModel.snapshot().map(\.deviceName) == ["Local"], "removeDevices drops one client's devices")
}

try? fd.removeItem(at: tempDir)
print(failures == 0 ? "✔ \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
