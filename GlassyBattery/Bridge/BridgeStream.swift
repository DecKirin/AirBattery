//
//  BridgeStream.swift
//  GlassyBattery
//
//  The BatteryBridge WebSocket stream: one long-lived connection per client app, JSON text
//  frames both ways. The first frame must be `hello` with the client's token; after that the
//  client pushes devices and the server pushes acks and status changes (approved, blocked, ...).
//

import Foundation
import Network

/// A client's correlation ID, echoed in the matching `ack` or `error`. Clients use strings or numbers.
enum BridgeStreamRef: Codable, Equatable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        }
    }
}

struct BridgeStreamMessage: Decodable {
    let op: String
    let ref: BridgeStreamRef?
    /// `hello`
    let token: String?
    /// `hello`: "remove" (default) drops this client's devices when the last stream closes, "keep"
    /// leaves them to age out like any other device.
    let onDisconnect: String?
    /// `upsert`
    let device: BridgeDevicePayload?
    /// `batch`
    let devices: [BridgeDevicePayload]?
    /// `remove`
    let id: String?
}

struct BridgeStreamEvent: Encodable {
    let event: String
    var ref: BridgeStreamRef?
    var client: BridgeClientInfo?
    var device: BridgeDeviceInfo?
    var devices: [BridgeDeviceInfo]?
    var id: String?
    var error: Detail?

    struct Detail: Encodable {
        let code: String
        let message: String
    }

    static func failure(_ error: BridgeError, ref: BridgeStreamRef? = nil) -> BridgeStreamEvent {
        BridgeStreamEvent(event: "error", ref: ref, error: Detail(code: error.code, message: error.message))
    }
}

final class BridgeStreamSession {
    /// A var so the tests can shorten it.
    static var helloTimeout: TimeInterval = 5
    static let maxMessageSize = BridgeHTTP.maxBodyBytes

    enum Phase: Equatable {
        case awaitingHello
        /// Authenticated but waiting for approval in allowlist mode.
        case pending(clientID: String)
        case ready(clientID: String)
        case closed
    }

    private(set) var phase: Phase = .awaitingHello
    private(set) var removeOnDisconnect = true
    /// The client this session belongs to, once `hello` succeeded.
    var clientID: String? {
        switch phase {
        case .pending(let id), .ready(let id): id
        case .awaitingHello, .closed: nil
        }
    }

    private let connection: NWConnection
    private let router: BridgeRouter
    private let queue: DispatchQueue
    private var token: String?
    private var helloTimer: DispatchWorkItem?
    /// Called once, after the session closed. The bridge uses it to drop the session and, when it
    /// was the client's last one, its devices.
    var onClose: ((BridgeStreamSession, _ clientID: String?) -> Void)?

    init(connection: NWConnection, router: BridgeRouter, queue: DispatchQueue) {
        self.connection = connection
        self.router = router
        self.queue = queue
    }

    func start() {
        let timer = DispatchWorkItem { [weak self] in
            guard let self, phase == .awaitingHello else { return }
            end(.failure(BridgeError(status: 408, code: "hello_timeout", message: "Send hello with your token first")))
        }
        helloTimer = timer
        queue.asyncAfter(deadline: .now() + Self.helloTimeout, execute: timer)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish(cancel: false)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    // MARK: Pushed by the bridge (all on `queue`)

    /// The client was approved while this session waited.
    func approved() {
        guard case .pending(let id) = phase, let client = router.store.client(id: id) else { return }
        phase = .ready(clientID: id)
        send(BridgeStreamEvent(event: "ready", client: BridgeClientInfo(client)))
    }

    /// Sends a last event (`blocked`, `revoked`, `removed`, ...) and closes.
    func end(_ event: BridgeStreamEvent) {
        send(event)    // sends go out in order, so this lands before the close frame
        close()
    }

    /// Sends a close frame and cancels the connection once it is out.
    func close() {
        guard phase != .closed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        finish(cancel: false)
    }

    // MARK: Incoming

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, phase != .closed else { return }
            if error != nil {
                finish(cancel: true)
                return
            }
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            if opcode == .close {
                close()
                return
            }
            if let data, opcode == .text || opcode == .binary {
                handle(data)
            }
            if phase != .closed { receive() }
        }
    }

    private func handle(_ data: Data) {
        let message: BridgeStreamMessage
        do {
            message = try JSONDecoder().decode(BridgeStreamMessage.self, from: data)
        } catch {
            send(.failure(.invalidBody("frame: expected a JSON object with an \"op\"")))
            return
        }

        switch phase {
        case .awaitingHello:
            hello(message)
        case .pending:
            send(.failure(.pending, ref: message.ref))
        case .ready:
            // Re-checked on every frame, so a blocked client or a reset token stops working at
            // once even if no status event reached this session.
            let client: BridgeClient
            do {
                client = try router.store.authenticate(token: token ?? "", now: router.now())
            } catch let error as BridgeError {
                end(Self.statusEvent(for: error))
                return
            } catch {
                return
            }
            do {
                send(try perform(message, for: client))
            } catch let error as BridgeError {
                send(.failure(error, ref: message.ref))
            } catch {
                send(.failure(.malformedRequest, ref: message.ref))
            }
        case .closed:
            break
        }
    }

    private func hello(_ message: BridgeStreamMessage) {
        guard message.op == "hello", let token = message.token else {
            end(.failure(BridgeError(status: 400, code: "hello_required", message: "The first frame must be hello with your token"), ref: message.ref))
            return
        }
        switch message.onDisconnect {
        case nil, "remove": removeOnDisconnect = true
        case "keep": removeOnDisconnect = false
        default:
            end(.failure(.invalid("onDisconnect", "must be \"remove\" or \"keep\""), ref: message.ref))
            return
        }
        helloTimer?.cancel()
        self.token = token

        let hash = BridgeClientStore.hash(token)
        do {
            let client = try router.store.authenticate(token: token, now: router.now())
            phase = .ready(clientID: client.id)
            send(BridgeStreamEvent(event: "ready", ref: message.ref, client: BridgeClientInfo(client)))
        } catch let error as BridgeError where error == .pending {
            // Stay connected: the bridge calls approved() when the user lets this client in.
            guard let client = router.store.all.first(where: { $0.tokenHash == hash }) else { return }
            phase = .pending(clientID: client.id)
            send(BridgeStreamEvent(event: "pending", ref: message.ref, client: BridgeClientInfo(client)))
        } catch let error as BridgeError {
            end(Self.statusEvent(for: error, ref: message.ref))
        } catch {
            close()
        }
    }

    private func perform(_ message: BridgeStreamMessage, for client: BridgeClient) throws -> BridgeStreamEvent {
        switch message.op {
        case "upsert":
            guard let payload = message.device else { throw BridgeError.invalidBody("device: missing") }
            return BridgeStreamEvent(event: "ack", ref: message.ref, device: try router.upsert(payload, for: client))
        case "batch":
            guard let payloads = message.devices else { throw BridgeError.invalidBody("devices: missing") }
            return BridgeStreamEvent(event: "ack", ref: message.ref, devices: try router.upsert(batch: payloads, for: client))
        case "remove":
            guard let id = message.id else { throw BridgeError.invalidBody("id: missing") }
            try router.removeDevice(localID: id, for: client)
            return BridgeStreamEvent(event: "ack", ref: message.ref, id: id)
        case "ping":
            return BridgeStreamEvent(event: "pong", ref: message.ref)
        case "hello":
            throw BridgeError(status: 400, code: "already_ready", message: "hello was already accepted")
        default:
            throw BridgeError(status: 400, code: "unknown_op", message: "Unknown op \"\(message.op)\"")
        }
    }

    // MARK: Helpers

    /// `blocked` / `revoked` as their own events, so clients needn't parse error codes to stop retrying.
    static func statusEvent(for error: BridgeError, ref: BridgeStreamRef? = nil) -> BridgeStreamEvent {
        switch error {
        case .blocked: BridgeStreamEvent(event: "blocked", ref: ref)
        case .unauthorized: BridgeStreamEvent(event: "revoked", ref: ref)
        default: .failure(error, ref: ref)
        }
    }

    private func send(_ event: BridgeStreamEvent) {
        guard phase != .closed else { return }
        connection.send(content: Self.encode(event), contentContext: Self.textContext, isComplete: true, completion: .idempotent)
    }

    private func finish(cancel: Bool) {
        guard phase != .closed else { return }
        let clientID = clientID
        phase = .closed
        helloTimer?.cancel()
        if cancel { connection.cancel() }
        onClose?(self, clientID)
        onClose = nil
    }

    private static let textContext = NWConnection.ContentContext(identifier: "event",
                                                                 metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])

    private static func encode(_ event: BridgeStreamEvent) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(event)) ?? Data()
    }
}
