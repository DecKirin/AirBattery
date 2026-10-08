//
//  BatteryBridge.swift
//  GlassyBattery
//
//  The loopback server behind BatteryBridge. It binds 127.0.0.1 only, so nothing off this Mac
//  can reach it; other Macs see bridged devices through Nearcast instead.
//

import Foundation
import Network

final class BatteryBridge: ObservableObject {
    static let shared = BatteryBridge(store: .shared, discoveryURL: defaultDiscoveryURL)
    static let defaultPort: UInt16 = 48620
    static let maxConnections = 32
    static let requestTimeout: TimeInterval = 10

    /// Clients read this to find the port instead of assuming the default.
    static var defaultDiscoveryURL: URL {
        fd.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GlassyBattery/bridge.json")
    }

    /// The configured mode, read on every registration.
    static var mode: BridgeMode {
        BridgeMode(rawValue: ud.string(forKey: "bridgeMode") ?? "") ?? .blocklist
    }

    enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case failed(String)
    }

    /// Published on the main thread for the settings pane.
    @Published private(set) var state: State = .stopped

    let store: BridgeClientStore
    let router: BridgeRouter
    private let discoveryURL: URL
    private let queue = DispatchQueue(label: "com.deckirin.GlassyBattery.bridge")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]

    init(store: BridgeClientStore, devices: BridgeRouter.DeviceList = .model, discoveryURL: URL) {
        self.store = store
        self.discoveryURL = discoveryURL
        router = BridgeRouter(store: store, devices: devices, mode: { BatteryBridge.mode })
    }

    /// Starts listening on 127.0.0.1. `port` 0 picks a free port (tests use this).
    func start(port: UInt16 = BatteryBridge.configuredPort) {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                publish(.failed(error.localizedDescription))
                return
            }
            listener.stateUpdateHandler = { [weak self, weak listener] newState in
                guard let self, let listener else { return }
                switch newState {
                case .ready:
                    let bound = listener.port?.rawValue ?? port
                    router.port = bound
                    writeDiscoveryFile(port: bound)
                    publish(.listening(port: bound))
                    print("ℹ️ BatteryBridge listening on 127.0.0.1:\(bound)")
                case .failed(let error):
                    print("⚠️ BatteryBridge failed: \(error)")
                    tearDown()
                    publish(.failed(Self.describe(error, port: port)))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            tearDown()
            publish(.stopped)
            print("ℹ️ BatteryBridge has stopped")
        }
    }

    /// Blocks a client and drops its devices from the list straight away.
    func block(clientID: String) {
        store.setStatus(.blocked, for: clientID)
        removeDevices(ofClient: clientID)
    }

    /// Forgets a client and its devices.
    func remove(clientID: String) {
        store.remove(id: clientID)
        removeDevices(ofClient: clientID)
    }

    func removeDevices(ofClient clientID: String) {
        router.devices.remove { BridgeDevices.clientID(of: $0.deviceID) == clientID }
    }

    static var configuredPort: UInt16 {
        let value = ud.integer(forKey: "bridgePort")
        return (1024...65535).contains(value) ? UInt16(value) : defaultPort
    }

    // MARK: Private

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

    /// Runs on `queue`.
    private func tearDown() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        try? fd.removeItem(at: discoveryURL)
    }

    private func writeDiscoveryFile(port: UInt16) {
        struct Discovery: Encodable {
            let api: Int
            let url: String
            let port: UInt16
            let pid: Int32
        }
        let discovery = Discovery(api: BridgeRouter.apiVersion, url: "http://127.0.0.1:\(port)", port: port,
                                  pid: ProcessInfo.processInfo.processIdentifier)
        do {
            try fd.createDirectory(at: discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
