//
//  StreamTests.swift
//  BridgeCoreTests
//
//  The WebSocket stream, over real connections from URLSessionWebSocketTask.
//

import Foundation

/// A blocking WebSocket client for the tests.
final class StreamClient {
    let task: URLSessionWebSocketTask

    init(_ url: String, headers: [String: String] = [:]) {
        var request = URLRequest(url: URL(string: url)!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(_ json: String) {
        let done = DispatchSemaphore(value: 0)
        task.send(.string(json)) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    /// The next event, or nil when the connection failed, closed or nothing came within `timeout`.
    func next(timeout: TimeInterval = 3) -> [String: Any]? {
        let done = DispatchSemaphore(value: 0)
        var event: [String: Any]?
        task.receive { result in
            if case .success(.string(let text)) = result {
                event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            }
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? event : nil
    }

    /// Sends one frame and returns the reply.
    func call(_ json: String) -> [String: Any]? {
        send(json)
        return next()
    }

    func disconnect() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

func eventName(_ event: [String: Any]?) -> String? { event?["event"] as? String }
func streamErrorCode(_ event: [String: Any]?) -> String? { (event?["error"] as? [String: Any])?["code"] as? String }

func register(_ base: String, name: String) -> (token: String, clientID: String) {
    let reply = curl(["-H", "Content-Type: application/json", "-d", #"{"name":"\#(name)"}"#, "\(base)/v1/register"])
    let body = (try? JSONSerialization.jsonObject(with: Data(reply.body.utf8)) as? [String: Any]) ?? [:]
    return (body["token"] as? String ?? "", body["clientID"] as? String ?? "")
}

func runStreamTests() throws {
    ud.set(BridgeMode.blocklist.rawValue, forKey: "bridgeMode")
    let (store, _) = freshStore()
    let memory = MemoryDevices()
    let discovery = tempDir.appendingPathComponent("stream-bridge.json")
    let bridge = BatteryBridge(store: store, devices: memory.deviceList, icons: testIcons(), discoveryURL: discovery)
    bridge.start(port: 0)
    guard waitUntil({ fd.fileExists(atPath: discovery.path) }),
          let info = try? JSONSerialization.jsonObject(with: Data(contentsOf: discovery)) as? [String: Any],
          let base = info["url"] as? String, let ws = info["streamURL"] as? String else {
        check(false, "stream bridge came up")
        return
    }
    defer { bridge.stop() }

    // Handshake checks
    check(StreamClient(ws, headers: ["Origin": "https://evil.example"]).next() == nil, "browser Origin is refused at the handshake")
    let notHello = StreamClient(ws)
    let refused = notHello.call(#"{"op":"ping","ref":1}"#)
    check(streamErrorCode(refused) == "hello_required" && notHello.next() == nil, "first frame must be hello, then the stream closes")
    let badToken = StreamClient(ws).call(#"{"op":"hello","token":"gbb_nope"}"#)
    check(eventName(badToken) == "revoked", "unknown token is told it's revoked")

    BridgeStreamSession.helloTimeout = 0.3
    let silent = StreamClient(ws)
    check(streamErrorCode(silent.next()) == "hello_timeout", "silent clients are dropped")
    BridgeStreamSession.helloTimeout = 5

    // A working session
    let (token, clientID) = register(base, name: "Streamer")
    let stream = StreamClient(ws)
    let ready = stream.call(#"{"op":"hello","token":"\#(token)","ref":"h"}"#)
    check(eventName(ready) == "ready" && ready?["ref"] as? String == "h"
          && (ready?["client"] as? [String: Any])?["id"] as? String == clientID, "hello → ready with the client")

    let ack = stream.call(#"{"op":"upsert","ref":7,"device":{"id":"k","name":"Stream Keys","type":"Keyboard","level":30}}"#)
    check(eventName(ack) == "ack" && ack?["ref"] as? Int == 7 && (ack?["device"] as? [String: Any])?["id"] as? String == "k",
          "upsert is acked with its numeric ref")
    check(memory.list.map(\.deviceName) == ["Stream Keys"], "upsert reached the device list")

    let batch = stream.call(#"{"op":"batch","ref":8,"devices":[{"id":"a","name":"Stream A","type":"Mouse","level":1},{"id":"b","name":"Stream B","type":"Mouse","level":2}]}"#)
    check(eventName(batch) == "ack" && (batch?["devices"] as? [Any])?.count == 2 && memory.list.count == 3, "batch")
    check(eventName(stream.call(#"{"op":"remove","id":"a","ref":9}"#)) == "ack" && memory.list.count == 2, "remove")

    let invalid = stream.call(#"{"op":"upsert","ref":10,"device":{"id":"k","name":"Stream Keys","type":"Keyboard","level":300}}"#)
    check(streamErrorCode(invalid) == "invalid_level" && invalid?["ref"] as? Int == 10, "errors carry the ref")
    check(streamErrorCode(stream.call("not json")) == "invalid_body", "garbage frame")
    check(streamErrorCode(stream.call(#"{"op":"fly"}"#)) == "unknown_op", "unknown op")
    check(eventName(stream.call(#"{"op":"ping","ref":11}"#)) == "pong", "the stream survives errors")

    // Disconnect drops the devices (default), unless the client asked to keep them.
    stream.disconnect()
    check(waitUntil({ memory.list.isEmpty }), "devices go when the last stream closes")

    let keeper = StreamClient(ws)
    check(eventName(keeper.call(#"{"op":"hello","token":"\#(token)","onDisconnect":"keep"}"#)) == "ready", "hello with keep")
    _ = keeper.call(#"{"op":"upsert","device":{"id":"k","name":"Kept","type":"Keyboard","level":30}}"#)
    keeper.disconnect()
    Thread.sleep(forTimeInterval: 0.3)
    check(memory.list.map(\.deviceName) == ["Kept"], "onDisconnect keep leaves devices to age out")

    // Token reset and blocking reach live streams.
    let live = StreamClient(ws)
    _ = live.call(#"{"op":"hello","token":"\#(token)"}"#)
    let newToken = bridge.resetToken(clientID: clientID) ?? ""
    check(eventName(live.next()) == "revoked" && live.next() == nil, "token reset revokes the stream")

    let doomed = StreamClient(ws)
    check(eventName(doomed.call(#"{"op":"hello","token":"\#(newToken)"}"#)) == "ready", "new token works")
    bridge.block(clientID: clientID)
    check(eventName(doomed.next()) == "blocked" && doomed.next() == nil, "blocking ends the stream")
    check(memory.list.isEmpty, "blocking drops the devices")

    // Allowlist: the stream waits for approval instead of being refused.
    bridge.setMode(.allowlist)
    let (piToken, piID) = register(base, name: "Pi")
    let pi = StreamClient(ws)
    check(eventName(pi.call(#"{"op":"hello","token":"\#(piToken)"}"#)) == "pending", "pending client is told to wait")
    check(streamErrorCode(pi.call(#"{"op":"upsert","device":{"id":"p","name":"Pi","type":"general_bt","level":5}}"#)) == "pending",
          "pending client can't push")
    bridge.approve(clientID: piID)
    check(eventName(pi.next()) == "ready", "approval reaches the waiting stream")
    check(eventName(pi.call(#"{"op":"upsert","device":{"id":"p","name":"Pi","type":"general_bt","level":5}}"#)) == "ack",
          "approved client can push")

    let (otherToken, _) = register(base, name: "Other")
    let other = StreamClient(ws)
    _ = other.call(#"{"op":"hello","token":"\#(otherToken)"}"#)
    bridge.setMode(.blocklist)
    check(eventName(other.next()) == "ready", "switching to blocklist admits waiting streams")
    check(ud.string(forKey: "bridgeMode") == "blocklist", "mode is saved")

    bridge.remove(clientID: piID)
    check(eventName(pi.next()) == "removed" && memory.list.isEmpty, "removing a client ends its stream and drops its devices")
}
