//
//  BridgeClientStore.swift
//  GlassyBattery
//
//  The registered BatteryBridge clients, persisted as JSON in Application Support.
//

import Foundation
import CryptoKit

final class BridgeClientStore {
    static let shared = BridgeClientStore(fileURL: defaultURL)
    /// Registration needs no token, so this keeps a misbehaving local process from growing the file forever.
    static let maxClients = 64

    static var defaultURL: URL {
        fd.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GlassyBattery/bridge-clients.json")
    }

    /// `lastSeen` is only written to disk when it moves by more than this, so a client pushing
    /// every second doesn't rewrite the file every second.
    private static let lastSeenPersistInterval: Double = 60

    private let lock = NSLock()
    private let fileURL: URL
    private var clients: [BridgeClient] = []
    /// Called on the calling thread after any change; the settings pane uses it to refresh.
    var onChange: (() -> Void)?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([BridgeClient].self, from: data) {
            clients = list
        }
    }

    var all: [BridgeClient] {
        lock.lock()
        defer { lock.unlock() }
        return clients
    }

    func client(id: String) -> BridgeClient? {
        all.first { $0.id == id }
    }

    /// Registers a client and returns it with its token, which is never stored and can't be shown again.
    ///
    /// A second registration from the same app (see `BridgeClient.identity`) gets a fresh token
    /// instead of a second entry. In allowlist mode that sends it back to `pending`: anything on
    /// this Mac can claim a bundle ID, so a new token must not inherit an approval.
    func register(name: String, bundleID: String?, mode: BridgeMode,
                  now: Double = Date().timeIntervalSince1970) throws -> (client: BridgeClient, token: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count) else { throw BridgeError.invalid("name", "must be 1–64 characters") }
        let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleID, bundleID.count > 128 { throw BridgeError.invalid("bundleID", "must be at most 128 characters") }

        let token = Self.makeToken()
        let tokenHash = Self.hash(token)
        let identity = BridgeClient.identity(name: name, bundleID: bundleID)
        let result: BridgeClient
        lock.lock()
        if let index = clients.firstIndex(where: { $0.identity == identity }) {
            if clients[index].status == .blocked {
                lock.unlock()
                throw BridgeError.blocked
            }
            clients[index].name = name
            clients[index].tokenHash = tokenHash
            if mode == .allowlist { clients[index].status = .pending }
            clients[index].lastSeen = now
            result = clients[index]
        } else {
            guard clients.count < Self.maxClients else {
                lock.unlock()
                throw BridgeError.tooManyClients
            }
            result = BridgeClient(id: Self.makeClientID(), name: name, bundleID: bundleID,
                                  status: mode == .allowlist ? .pending : .active,
                                  tokenHash: tokenHash, createdAt: now, lastSeen: now)
            clients.append(result)
        }
        lock.unlock()
        save()
        return (result, token)
    }

    /// Returns the client a token belongs to, or throws if it is unknown, pending or blocked.
    func authenticate(token: String, now: Double = Date().timeIntervalSince1970) throws -> BridgeClient {
        let hash = Self.hash(token)
        lock.lock()
        guard let index = clients.firstIndex(where: { $0.tokenHash == hash }) else {
            lock.unlock()
            throw BridgeError.unauthorized
        }
        let shouldPersist = now - (clients[index].lastSeen ?? 0) > Self.lastSeenPersistInterval
        clients[index].lastSeen = now
        let client = clients[index]
        lock.unlock()
        if shouldPersist { save() }

        switch client.status {
        case .active: return client
        case .pending: throw BridgeError.pending
        case .blocked: throw BridgeError.blocked
        }
    }

    func setStatus(_ status: BridgeClientStatus, for id: String) {
        mutate(id) { $0.status = status }
    }

    func setNearcast(_ enabled: Bool, for id: String) {
        mutate(id) { $0.nearcast = enabled }
    }

    /// Issues a new token, invalidating the old one. Returns nil for an unknown client.
    func resetToken(for id: String) -> String? {
        let token = Self.makeToken()
        return mutate(id) { $0.tokenHash = Self.hash(token) } ? token : nil
    }

    func remove(id: String) {
        lock.lock()
        clients.removeAll { $0.id == id }
        lock.unlock()
        save()
    }

    /// Switching to blocklist mode lets everyone in, so clients still waiting for approval become active.
    func applyMode(_ mode: BridgeMode) {
        guard mode == .blocklist else { return }
        lock.lock()
        let hadPending = clients.contains { $0.status == .pending }
        for index in clients.indices where clients[index].status == .pending {
            clients[index].status = .active
        }
        lock.unlock()
        if hadPending { save() }
    }

    /// Whether devices from this client may go out over Nearcast. False for unknown clients.
    func sharesOnNearcast(clientID: String) -> Bool {
        guard let client = client(id: clientID) else { return false }
        return client.status == .active && client.nearcast
    }

    @discardableResult
    private func mutate(_ id: String, _ change: (inout BridgeClient) -> Void) -> Bool {
        lock.lock()
        guard let index = clients.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        change(&clients[index])
        lock.unlock()
        save()
        return true
    }

    private func save() {
        let snapshot = all
        do {
            try fd.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            // Token hashes aren't secrets, but there's no reason for other users to read them.
            try fd.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("BatteryBridge: saving clients failed: \(error)")
        }
        onChange?()
    }

    /// 256 random bits, base64url, with a prefix so a leaked token is recognisable.
    static func makeToken() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let base64 = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "gbb_" + base64
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Short and URL/ID safe, since it ends up inside every device ID of the client.
    private static func makeClientID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }
}
