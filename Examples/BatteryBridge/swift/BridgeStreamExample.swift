// BridgeStreamExample.swift
//
// A long-running BatteryBridge client over the WebSocket stream, with no dependencies:
//
//     swift BridgeStreamExample.swift
//
// It registers (or reuses its saved token), opens the stream, says hello, then reports a
// simulated headset whose battery drains a little every few seconds. Press Ctrl-C to quit:
// GlassyBattery sees the stream close and removes the device straight away.
//
// In allowlist mode the stream stays open in "pending" until you click Approve in GlassyBattery,
// then carries on by itself.

import Foundation

let appName = "BridgeStreamExample"
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let discoveryURL = support.appendingPathComponent("GlassyBattery/bridge.json")
let tokenURL = support.appendingPathComponent("GlassyBridgeExample/stream-token")

struct Discovery: Decodable {
    let url: String
    let streamURL: String
    let pid: Int32
}

/// The ports from bridge.json, if BatteryBridge is running.
func discover() -> Discovery? {
    guard let data = try? Data(contentsOf: discoveryURL),
          let discovery = try? JSONDecoder().decode(Discovery.self, from: data),
          kill(discovery.pid, 0) == 0 else { return nil }
    return discovery
}

/// POST /v1/register. Blocking is fine for a command-line example.
func register(at base: String) throws -> String {
    var request = URLRequest(url: URL(string: base + "/v1/register")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["name": appName, "bundleID": "com.example.bridge-stream"])
    var result: Result<Data, Error> = .failure(URLError(.unknown))
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, error in
        result = data.map { .success($0) } ?? .failure(error ?? URLError(.badServerResponse))
        done.signal()
    }.resume()
    done.wait()
    let reply = try JSONSerialization.jsonObject(with: result.get()) as? [String: Any]
    guard let token = reply?["token"] as? String else { throw URLError(.userAuthenticationRequired) }
    try FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try token.write(to: tokenURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    return token
}

final class StreamClient {
    private let task: URLSessionWebSocketTask
    private let token: String
    private var level = 100
    private var timer: DispatchSourceTimer?
    /// Set once this stream is being replaced, so its closing doesn't end the program.
    private var replaced = false
    /// Called when the server says the saved token is no good, so main can register again.
    var onRevoked: (() -> Void)?

    init(streamURL: String, token: String) {
        task = URLSession.shared.webSocketTask(with: URL(string: streamURL)!)
        self.token = token
    }

    /// Closes the stream properly, so GlassyBattery removes the device at once.
    func stop() {
        replaced = true
        timer?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    func start() {
        task.resume()
        send(["op": "hello", "token": token, "ref": "hello"])
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                handle(text)
                receive()
            case .success:
                receive()
            case .failure(let error):
                if replaced { return }
                print("Stream closed: \(error.localizedDescription)")
                exit(0)
            }
        }
    }

    private func handle(_ text: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let name = event["event"] as? String else { return }
        switch name {
        case "pending":
            print("Waiting for approval in GlassyBattery…")
        case "ready":
            print("Connected. Reporting a simulated headset; Ctrl-C to stop.")
            startReporting()
        case "ack":
            if let device = event["device"] as? [String: Any] { print("✔︎ \(device["name"] ?? "") \(device["level"] ?? "")%") }
        case "error":
            let error = event["error"] as? [String: Any]
            print("✘ \(error?["code"] ?? ""): \(error?["message"] ?? "")")
        case "revoked":
            replaced = true
            timer?.cancel()
            onRevoked?()
        case "blocked", "removed":
            print("GlassyBattery \(name) this app. Bye.")
            exit(1)
        default:
            break
        }
    }

    private func startReporting() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.report() }
        timer.resume()
        self.timer = timer
    }

    private func report() {
        level = level <= 5 ? 100 : level - 3
        send(["op": "upsert", "ref": level, "device": [
            "id": "headset", "name": "Example Headset", "type": "Headphones",
            "level": level, "charging": level == 100,
        ]])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { print("Send failed: \(error.localizedDescription)") }
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)    // line-buffered even when piped to a file

guard let discovery = discover() else {
    print("BatteryBridge isn't running. Turn it on in GlassyBattery → Settings → BatteryBridge.")
    exit(1)
}

var client: StreamClient?
func connect(token: String) {
    let next = StreamClient(streamURL: discovery.streamURL, token: token)
    // A reset token (or a first run) means registering again; the new one may need approval.
    next.onRevoked = {
        print("Token not accepted, registering again…")
        DispatchQueue.main.async { connect(token: (try? register(at: discovery.url)) ?? "") }
    }
    client = next
    next.start()
}

// Ctrl-C (or kill): say goodbye on the stream instead of just dropping the socket.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGINT, SIGTERM] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        print("Disconnecting…")
        client?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
    source.resume()
    signalSources.append(source)
}

let saved = try? String(contentsOf: tokenURL, encoding: .utf8)
connect(token: saved ?? (try? register(at: discovery.url)) ?? "")
dispatchMain()
