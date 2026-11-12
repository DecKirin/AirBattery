//
//  BatteryBridge.swift
//  GlassyBattery
//
//  The loopback server behind BatteryBridge. It binds 127.0.0.1 only, so nothing off this Mac
//  can reach it; other Macs see bridged devices through Nearcast instead. HTTP is on `port`,
//  the WebSocket stream on `port + 1`.
//

import Foundation
import Network

final class BatteryBridge: ObservableObject {
    static let shared = BatteryBridge(store: .shared, discoveryURL: defaultDiscoveryURL)
    static let defaultPort: UInt16 = 48620
    static let maxConnections = 32
    static let maxStreams = 32
    static let requestTimeout: TimeInterval = 10

    /// Clients read this to find the ports instead of assuming the defaults.
    static var defaultDiscoveryURL: URL {
        fd.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GlassyBattery/bridge.json")
    }

    /// The configured mode, read on every registration.
    static var mode: BridgeMode {
        BridgeMode(rawValue: ud.string(forKey: "bridgeMode") ?? "") ?? .blocklist
    }

    static var configuredPort: UInt16 {
        let value = ud.integer(forKey: "bridgePort")
        return (1024...65534).contains(value) ? UInt16(value) : defaultPort
    }

    enum State: Equatable {
        case stopped
        case listening(port: UInt16, streamPort: UInt16)
        case failed(String)
    }

    /// Published on the main thread for the settings pane.
    @Published private(set) var state: State = .stopped

    let store: BridgeClientStore
    let router: BridgeRouter
    private let discoveryURL: URL
    private let queue = DispatchQueue(label: "com.deckirin.GlassyBattery.bridge")
    private var listener: NWListener?
    private var streamListener: NWListener?
    private var boundPort: UInt16?
    private var boundStreamPort: UInt16?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]
    private var sessions: [ObjectIdentifier: BridgeStreamSession] = [:]

    init(store: BridgeClientStore, devices: BridgeRouter.DeviceList = .model, icons: BridgeIconStore = .shared,
         discoveryURL: URL) {
        self.store = store
        self.discoveryURL = discoveryURL
        router = BridgeRouter(store: store, devices: devices, icons: icons, mode: { BatteryBridge.mode })
    }

    /// Starts listening on 127.0.0.1. `port` 0 picks free ports for both listeners (tests use this).
    func start(port: UInt16 = BatteryBridge.configuredPort) {
        queue.async { [self] in
            guard listener == nil else { return }
            let streamPort = port == 0 ? 0 : port + 1
            do {
                listener = try makeListener(port: port, parameters: .tcp)
                streamListener = try makeListener(port: streamPort, parameters: streamParameters())
            } catch {
                tearDown()
                publish(.failed(error.localizedDescription))
                return
            }
            listener?.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            streamListener?.newConnectionHandler = { [weak self] connection in self?.acceptStream(connection) }
            listener?.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state, stream: false, requested: port) }
            streamListener?.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state, stream: true, requested: streamPort) }
            listener?.start(queue: queue)
            streamListener?.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            tearDown()
            publish(.stopped)
            print("ℹ️ BatteryBridge has stopped")
        }
    }

    // MARK: Managing clients
    //
    // The settings pane changes clients through these rather than the store, so live streams hear
    // about it straight away.

    func approve(clientID: String) {
        store.setStatus(.active, for: clientID)
        queue.async { [self] in streams(of: clientID).forEach { $0.approved() } }
    }

    /// Blocks a client and drops its devices from the list straight away.
    func block(clientID: String) {
        store.setStatus(.blocked, for: clientID)
        removeDevices(ofClient: clientID)
        endStreams(of: clientID, with: BridgeStreamEvent(event: "blocked"))
    }

    /// Forgets a client, its devices and its icons.
    func remove(clientID: String) {
        store.remove(id: clientID)
        removeDevices(ofClient: clientID)
        router.icons.removeAll(clientID: clientID)
        endStreams(of: clientID, with: BridgeStreamEvent(event: "removed"))
    }

    /// Issues a new token. Streams on the old one are closed with `revoked`.
    func resetToken(clientID: String) -> String? {
        let token = store.resetToken(for: clientID)
        if token != nil { endStreams(of: clientID, with: BridgeStreamEvent(event: "revoked")) }
        return token
    }

    func setNearcast(_ enabled: Bool, clientID: String) {
        store.setNearcast(enabled, for: clientID)
    }

    /// Switching to blocklist mode admits everyone still waiting, including their open streams.
    func setMode(_ mode: BridgeMode) {
        let waiting = store.all.filter { $0.status == .pending }.map(\.id)
        ud.set(mode.rawValue, forKey: "bridgeMode")
        store.applyMode(mode)
        guard mode == .blocklist else { return }
        queue.async { [self] in waiting.forEach { id in streams(of: id).forEach { $0.approved() } } }
    }

    func removeDevices(ofClient clientID: String) {
        router.devices.remove { BridgeDevices.clientID(of: $0.deviceID) == clientID }
    }

    // MARK: Listeners (all on `queue`)

    private func makeListener(port: UInt16, parameters: NWParameters) throws -> NWListener {
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        return try NWListener(using: parameters)
    }

    private func streamParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = BridgeStreamSession.maxMessageSize
        // Same rule as HTTP: loopback Host, no browser Origin. The token comes in the hello frame,
        // since this handler can't tell which connection it is answering for.
        options.setClientRequestHandler(queue) { [weak self] _, additionalHeaders in
            var headers: [String: String] = [:]
            for header in additionalHeaders { headers[header.name.lowercased()] = header.value }
            let port = self?.boundStreamPort ?? 0
            let allowed = (try? BridgeRouter.checkLocal(headers: headers, port: port)) != nil
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return parameters
    }

    private func listenerChanged(_ state: NWListener.State, stream: Bool, requested: UInt16) {
        switch state {
        case .ready:
            let bound = (stream ? streamListener : listener)?.port?.rawValue ?? requested
            if stream { boundStreamPort = bound } else { boundPort = bound; router.port = bound }
            guard let port = boundPort, let streamPort = boundStreamPort else { return }
            writeDiscoveryFile(port: port, streamPort: streamPort)
            publish(.listening(port: port, streamPort: streamPort))
            print("ℹ️ BatteryBridge listening on 127.0.0.1:\(port) (stream \(streamPort))")
        case .failed(let error):
            print("⚠️ BatteryBridge failed: \(error)")
            tearDown()
            publish(.failed(Self.describe(error, port: requested)))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let handler = BridgeConnection(connection: connection, router: router, queue: queue)
        let key = ObjectIdentifier(handler)
        connections[key] = handler
        handler.onClose = { [weak self] in self?.connections[key] = nil }
        handler.start()
    }

    private func acceptStream(_ connection: NWConnection) {
        guard sessions.count < Self.maxStreams else {
            connection.cancel()
            return
        }
        let session = BridgeStreamSession(connection: connection, router: router, queue: queue)
        sessions[ObjectIdentifier(session)] = session
        session.onClose = { [weak self] session, clientID in self?.streamClosed(session, clientID: clientID) }
        session.start()
    }

    /// When a client's last stream goes, its devices go too, unless it said `onDisconnect: "keep"`.
    private func streamClosed(_ session: BridgeStreamSession, clientID: String?) {
        sessions[ObjectIdentifier(session)] = nil
        guard let clientID, session.removeOnDisconnect, streams(of: clientID).isEmpty else { return }
        removeDevices(ofClient: clientID)
    }

    private func streams(of clientID: String) -> [BridgeStreamSession] {
        sessions.values.filter { $0.clientID == clientID }
    }

    private func endStreams(of clientID: String, with event: BridgeStreamEvent) {
        queue.async { [self] in streams(of: clientID).forEach { $0.end(event) } }
    }

    private func tearDown() {
        listener?.cancel()
        streamListener?.cancel()
        listener = nil
        streamListener = nil
        boundPort = nil
        boundStreamPort = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        sessions.values.forEach { $0.close() }
        sessions.removeAll()
        try? fd.removeItem(at: discoveryURL)
    }

    private func writeDiscoveryFile(port: UInt16, streamPort: UInt16) {
        struct Discovery: Encodable {
            let api: Int
            let url: String
            let port: UInt16
            let streamURL: String
            let streamPort: UInt16
            let pid: Int32
        }
        let discovery = Discovery(api: BridgeRouter.apiVersion, url: "http://127.0.0.1:\(port)", port: port,
                                  streamURL: "ws://127.0.0.1:\(streamPort)", streamPort: streamPort,
                                  pid: ProcessInfo.processInfo.processIdentifier)
        do {
            try fd.createDirectory(at: discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(discovery).write(to: discoveryURL, options: .atomic)
        } catch {
            print("⚠️ BatteryBridge: writing \(discoveryURL.lastPathComponent) failed: \(error)")
        }
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async { self.state = state }
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(.EADDRINUSE) = error { return "Port \(port) is already in use" }
        return error.localizedDescription
    }
}

/// One request/response exchange. Closes after the response, or after `requestTimeout`.
private final class BridgeConnection {
    private let connection: NWConnection
    private let router: BridgeRouter
    private let queue: DispatchQueue
    private var buffer = Data()
    private var sentContinue = false
    private var closed = false
    private var timeout: DispatchWorkItem?
    var onClose: (() -> Void)?

    init(connection: NWConnection, router: BridgeRouter, queue: DispatchQueue) {
        self.connection = connection
        self.router = router
        self.queue = queue
    }

    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + BatteryBridge.requestTimeout, execute: timeout)
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        connection.cancel()
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !closed else { return }
            if let data { buffer.append(data) }
            do {
                switch try BridgeHTTP.parse(buffer) {
                case .complete(let request):
                    respond(router.handle(request))
                case .incomplete(let expectsContinue):
                    if expectsContinue && !sentContinue {
                        sentContinue = true
                        connection.send(content: BridgeHTTP.continueResponse, completion: .idempotent)
                    }
                    if isComplete || error != nil { close() } else { receive() }
                }
            } catch let error as BridgeError {
                respond(.error(error))
            } catch {
                respond(.error(.malformedRequest))
            }
        }
    }

    private func respond(_ response: BridgeHTTPResponse) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}
