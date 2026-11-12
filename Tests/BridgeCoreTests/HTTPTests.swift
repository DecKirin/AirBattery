//
//  HTTPTests.swift
//  BridgeCoreTests
//
//  The HTTP parser, the v1 router, and the real loopback listener driven with curl.
//

import Foundation

// MARK: Helpers

/// A device list in memory, standing in for `GlassyBatteryModel`. Locked: the bridge's queue and
/// the test thread both use it.
final class MemoryDevices {
    private let lock = NSLock()
    private var storage: [Device] = []
    var list: [Device] {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    var deviceList: BridgeRouter.DeviceList {
        BridgeRouter.DeviceList(
            snapshot: { self.list },
            update: { device in
                self.lock.lock()
                defer { self.lock.unlock() }
                if let index = self.storage.firstIndex(where: { $0.deviceName == device.deviceName }) {
                    self.storage[index] = device
                } else {
                    self.storage.append(device)
                }
            },
            remove: { shouldRemove in
                self.lock.lock()
                self.storage.removeAll(where: shouldRemove)
                self.lock.unlock()
            })
    }
}

func request(_ method: String, _ path: String, token: String? = nil, json: String? = nil,
             headers extra: [String: String] = [:]) -> BridgeHTTPRequest {
    var headers = ["host": "127.0.0.1:48620"]
    if json != nil { headers["content-type"] = "application/json" }
    if let token { headers["authorization"] = "Bearer \(token)" }
    for (key, value) in extra { headers[key] = value }
    return BridgeHTTPRequest(method: method, path: path, query: [:], headers: headers, body: Data((json ?? "").utf8))
}

func object(_ response: BridgeHTTPResponse) -> [String: Any] {
    guard let body = response.body, let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
    return value
}

func errorCode(_ response: BridgeHTTPResponse) -> String? {
    (object(response)["error"] as? [String: Any])?["code"] as? String
}

// MARK: Parser

func runHTTPTests() throws {
    func parse(_ text: String) throws -> BridgeHTTP.ParseResult { try BridgeHTTP.parse(Data(text.utf8)) }

    guard case .complete(let get) = try parse("GET /v1/me?x=1&y=a+b HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer  gbb_abc \r\n\r\n") else {
        check(false, "simple GET parses")
        return
    }
    check(get.method == "GET" && get.path == "/v1/me" && get.query == ["x": "1", "y": "a b"], "request line and query")
    check(get.headers["host"] == "127.0.0.1" && get.bearerToken == "gbb_abc", "headers are lowercased and trimmed")

    let body = #"{"name":"A"}"#
    let head = "POST /v1/register HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.utf8.count)\r\n"
    if case .incomplete(let expects) = try parse(head) { check(!expects, "headers not finished") } else { check(false, "partial headers") }
    if case .incomplete(let expects) = try parse(head + "Expect: 100-continue\r\n\r\n{") {
        check(expects, "Expect: 100-continue is reported once headers are in")
    } else { check(false, "partial body") }
    if case .complete(let post) = try parse(head + "\r\n" + body + "trailing") {
        check(String(decoding: post.body, as: UTF8.self) == body, "body is exactly Content-Length bytes")
    } else { check(false, "full body") }

    expectError(.malformedRequest, "garbage") { _ = try parse("hello\r\n\r\n") }
    expectError(.malformedRequest, "header without colon") { _ = try parse("GET / HTTP/1.1\r\nbroken\r\n\r\n") }
    expectError(.lengthRequired, "chunked") { _ = try parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") }
    expectError(.payloadTooLarge, "huge body") { _ = try parse("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n") }
    expectError(.payloadTooLarge, "endless headers") { _ = try parse("GET / HTTP/1.1\r\n" + String(repeating: "a", count: 20_000)) }

    let wire = String(decoding: BridgeHTTPResponse.error(.notFound).serialized(), as: UTF8.self)
    check(wire.hasPrefix("HTTP/1.1 404 Not Found\r\n") && wire.contains("Connection: close") && wire.hasSuffix(#""message":"No such device"}}"#),
          "error responses serialize")
}

// MARK: Router

func runRouterTests() throws {
    let (store, _) = freshStore()
    let memory = MemoryDevices()
    var mode = BridgeMode.blocklist
    var pendingSeen: [String] = []
    let router = BridgeRouter(store: store, devices: memory.deviceList, icons: testIcons(), mode: { mode })
    router.port = 48620
    router.onPendingClient = { pendingSeen.append($0.name) }

    // Caller checks
    check(router.handle(request("GET", "/v1/health")).status == 200, "health")
    check(router.handle(request("GET", "/v1/health", headers: ["host": "localhost"])).status == 200, "localhost without port")
    check(errorCode(router.handle(request("GET", "/v1/health", headers: ["host": "evil.example:48620"]))) == "forbidden_host", "DNS rebinding host")
    check(errorCode(router.handle(request("GET", "/v1/health", headers: ["host": "127.0.0.1:9999"]))) == "forbidden_host", "wrong port")
    check(errorCode(router.handle(request("GET", "/v1/health", headers: ["origin": "https://evil.example"]))) == "forbidden_origin", "browser origin")
    let formPost = request("POST", "/v1/register", json: #"{"name":"x"}"#, headers: ["content-type": "text/plain"])
    check(errorCode(router.handle(formPost)) == "unsupported_media_type", "non-JSON body")
    check(errorCode(router.handle(request("GET", "/v2/health"))) == "no_such_route", "unknown version")
    check(errorCode(router.handle(request("DELETE", "/v1/health"))) == "method_not_allowed", "wrong method")
    check((object(router.handle(request("GET", "/v1/types")))["types"] as? [String])?.contains("Keyboard") == true, "types")

    // Registration and auth
    let registered = router.handle(request("POST", "/v1/register", json: #"{"name":"Logi Options","bundleID":"com.logi.options"}"#))
    check(registered.status == 201 && object(registered)["status"] as? String == "active", "register in blocklist mode")
    let token = object(registered)["token"] as? String ?? ""
    check(errorCode(router.handle(request("POST", "/v1/register", json: #"{"bundleID":"x"}"#))) == "invalid_body", "register needs a name")
    check(errorCode(router.handle(request("GET", "/v1/me"))) == "unauthorized", "no token")
    check(errorCode(router.handle(request("GET", "/v1/me", token: "gbb_wrong"))) == "unauthorized", "bad token")

    // Devices
    let put = router.handle(request("PUT", "/v1/devices/mx-keys", token: token,
                                    json: #"{"name":"MX Keys","type":"Keyboard","level":64,"charging":true}"#))
    let putDevice = object(put)["device"] as? [String: Any]
    check(put.status == 200 && putDevice?["id"] as? String == "mx-keys" && putDevice?["charging"] as? Bool == true, "PUT a device")
    check(memory.list.first?.deviceID.hasPrefix("bridge:") == true && memory.list.first?.deviceType == "Keyboard", "stored namespaced")
    check(putDevice?["icon"] == nil, "no icon in the reply unless one was sent")
    let withIcon = router.handle(request("PUT", "/v1/devices/mx-keys", token: token,
                                         json: #"{"name":"MX Keys","type":"Keyboard","level":64,"icon":"keyboard.badge.ellipsis"}"#))
    check(withIcon.status == 200 && (object(withIcon)["device"] as? [String: Any])?["icon"] as? String == "keyboard.badge.ellipsis"
          && memory.list.first?.deviceIcon == "keyboard.badge.ellipsis", "PUT with an icon stores and echoes it")
    check(errorCode(router.handle(request("PUT", "/v1/devices/mx-keys", token: token,
                                           json: #"{"name":"MX Keys","type":"Keyboard","level":64,"icon":"Not A Symbol"}"#))) == "invalid_icon",
          "a malformed icon is a 422")
    check(errorCode(router.handle(request("PUT", "/v1/devices/mx-keys", token: token,
                                           json: #"{"id":"other","name":"MX Keys","type":"Keyboard","level":64}"#))) == "invalid_id",
          "body id must match the URL")
    check(errorCode(router.handle(request("PUT", "/v1/devices/a", token: token, json: #"{"name":"A","type":"Mouse","level":"high"}"#))) == "invalid_body",
          "wrong JSON type")

    memory.list.append(Device(deviceID: "AA:BB", deviceType: "MMouse", deviceName: "Magic Mouse", batteryLevel: 80, isCharging: 0, lastUpdate: 0))
    let clash = router.handle(request("PUT", "/v1/devices/m", token: token, json: #"{"name":"Magic Mouse","type":"Mouse","level":1}"#))
    check(clash.status == 409 && errorCode(clash) == "name_taken", "name clash is a 409")

    let batch = router.handle(request("POST", "/v1/devices:batch", token: token, json: """
        [{"id":"l","name":"Buds L","type":"ap_pod_left","level":50,"parent":"Buds Case"},
         {"id":"r","name":"Buds R","type":"ap_pod_right","level":52,"parent":"Buds Case"},
         {"id":"c","name":"Buds Case","type":"ap_case","level":90}]
        """))
    check(batch.status == 200 && (object(batch)["devices"] as? [Any])?.count == 3 && memory.list.count == 5, "batch")
    let badBatch = router.handle(request("POST", "/v1/devices:batch", token: token, json: """
        [{"id":"n1","name":"New One","type":"Mouse","level":1},{"id":"n2","name":"New One","type":"Mouse","level":1}]
        """))
    check(errorCode(badBatch) == "name_taken" && memory.list.count == 5, "batch is all or nothing, and checks names within itself")

    let me = object(router.handle(request("GET", "/v1/me", token: token)))
    check((me["devices"] as? [Any])?.count == 4 && (me["client"] as? [String: Any])?["tokenHash"] == nil, "me lists own devices, no hash")

    check(router.handle(request("DELETE", "/v1/devices/l", token: token)).status == 204 && memory.list.count == 4, "DELETE")
    check(errorCode(router.handle(request("DELETE", "/v1/devices/l", token: token))) == "not_found", "DELETE twice")

    // Allowlist
    mode = .allowlist
    let waiting = router.handle(request("POST", "/v1/register", json: #"{"name":"Pi"}"#))
    check(waiting.status == 202 && object(waiting)["status"] as? String == "pending" && pendingSeen == ["Pi"], "allowlist registration waits")
    let piToken = object(waiting)["token"] as? String ?? ""
    let piPut = router.handle(request("PUT", "/v1/devices/x", token: piToken, json: #"{"name":"Pi","type":"general_bt","level":3}"#))
    check(piPut.status == 403 && errorCode(piPut) == "pending" && memory.list.count == 4, "pending clients can't push")
}

// MARK: Server

func runServerTests() throws {
    let (store, _) = freshStore()
    let memory = MemoryDevices()
    let discovery = tempDir.appendingPathComponent("bridge.json")
    let bridge = BatteryBridge(store: store, devices: memory.deviceList, icons: testIcons(), discoveryURL: discovery)
    bridge.start(port: 0)

    guard waitUntil({ fd.fileExists(atPath: discovery.path) }),
          let info = try? JSONSerialization.jsonObject(with: Data(contentsOf: discovery)) as? [String: Any],
          let port = info["port"] as? Int, let base = info["url"] as? String else {
        check(false, "listener came up and wrote the discovery file")
        return
    }
    check(base == "http://127.0.0.1:\(port)" && info["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier, "discovery file")
    let streamPort = info["streamPort"] as? Int ?? 0
    check(info["streamURL"] as? String == "ws://127.0.0.1:\(streamPort)" && streamPort != 0, "discovery file names the stream")
    check(waitUntil({ bridge.state == .listening(port: UInt16(port), streamPort: UInt16(streamPort)) }), "state is published")

    check(curl(["\(base)/v1/health"]).status == 200, "health over the wire")
    let reg = curl(["-H", "Content-Type: application/json", "-d", #"{"name":"curl"}"#, "\(base)/v1/register"])
    let token = (try? JSONSerialization.jsonObject(with: Data(reg.body.utf8)) as? [String: Any])?["token"] as? String ?? ""
    check(reg.status == 201 && !token.isEmpty, "register over the wire")

    // Padded past 1 KB with Expect: 100-continue. Without the interim 100 curl stalls a full second.
    let padded = #"{"name":"Wire Mouse","type":"Mouse","level":42}"# + String(repeating: " ", count: 2000)
    let put = curl(["-X", "PUT", "-H", "Content-Type: application/json", "-H", "Authorization: Bearer \(token)",
                    "-H", "Expect: 100-continue", "--data-binary", padded, "\(base)/v1/devices/wire"])
    check(put.status == 200 && memory.list.map(\.deviceName) == ["Wire Mouse"], "PUT over the wire (got \(put.status) \(put.body))")
    check(put.seconds < 0.8, "100-continue is answered (took \(put.seconds)s)")

    check(curl(["-H", "Host: evil.example", "\(base)/v1/health"]).status == 403, "forged Host over the wire")
    check(curl(["-H", "Origin: https://evil.example", "\(base)/v1/health"]).status == 403, "Origin over the wire")
    let huge = tempDir.appendingPathComponent("huge.json")
    try Data(repeating: 0x20, count: 300_000).write(to: huge)
    check(curl(["-H", "Content-Type: application/json", "--data-binary", "@\(huge.path)", "\(base)/v1/register"]).status == 413, "oversized body")

    // A second listener can't share the port.
    let (otherStore, _) = freshStore()
    let second = BatteryBridge(store: otherStore, devices: MemoryDevices().deviceList, icons: testIcons(),
                               discoveryURL: tempDir.appendingPathComponent("second.json"))
    second.start(port: UInt16(port))
    check(waitUntil({ if case .failed = second.state { return true } else { return false } }),
          "second listener on the same port fails (state \(second.state))")
    check(curl(["\(base)/v1/health"]).status == 200, "first listener unaffected")

    bridge.stop()
    check(waitUntil({ !fd.fileExists(atPath: discovery.path) && bridge.state == .stopped }), "stop removes the discovery file")
    check(curl(["--max-time", "2", "\(base)/v1/health"]).status == 0, "nothing listening after stop")
}

/// Spins the main run loop (the bridge publishes state on main) until `condition` holds or 5 s pass.
func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// Runs curl and returns the status (0 when it couldn't connect), body and total time.
func curl(_ arguments: [String]) -> (status: Int, body: String, seconds: Double) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-s", "--max-time", "5", "-w", "\n%{http_code} %{time_total}"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return (0, "", 0) }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    var lines = output.components(separatedBy: "\n")
    let stats = lines.removeLast().split(separator: " ")
    return (Int(stats.first ?? "") ?? 0, lines.joined(separator: "\n"), Double(stats.last ?? "") ?? 0)
}
