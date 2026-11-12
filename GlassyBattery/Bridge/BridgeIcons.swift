//
//  BridgeIcons.swift
//  GlassyBattery
//
//  Icons a BatteryBridge client uploads for its own devices. They're files beside the widget's
//  data.json (`GlassyBatteryModel.bridgeIconsURL`), one folder per client, so the widget — a
//  separate, sandboxed process — draws them too. `customDeviceIcon` in Supports.swift reads them.
//

import AppKit

final class BridgeIconStore {
    static let shared = BridgeIconStore(directory: GlassyBatteryModel.bridgeIconsURL())
    static let maxPerClient = 32
    static let maxBytes = 64 * 1024
    /// What an icon may be, as the file extension it's stored under.
    static let formats = ["pdf", "svg", "png"]

    struct Info: Encodable, Equatable {
        let name: String
        let format: String
        let bytes: Int
    }

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    /// Stores (or replaces) one of a client's icons, after checking it is what it claims to be and
    /// that this Mac can draw it.
    func put(name: String, format: String, data: Data, clientID: String) throws -> Info {
        try Self.checkName(name)
        let format = format.lowercased()
        guard Self.formats.contains(format) else {
            throw BridgeError.invalid("format", "must be \"pdf\", \"svg\" or \"png\"")
        }
        guard !data.isEmpty, data.count <= Self.maxBytes else {
            throw BridgeError.invalid("data", "must be 1 byte to \(Self.maxBytes / 1024) KB")
        }
        guard Self.looksLike(format, data), let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            throw BridgeError.invalid("data", "isn't a \(format.uppercased()) this Mac can draw")
        }

        lock.lock()
        defer { lock.unlock() }
        let folder = directory.appendingPathComponent(clientID, isDirectory: true)
        if !Self.formats.contains(where: { fd.fileExists(atPath: file(name, $0, in: folder).path) })
            && names(in: folder).count >= Self.maxPerClient {
            throw BridgeError.tooManyIcons
        }
        try fd.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file(name, format, in: folder), options: .atomic)
        // One file per name: a new format replaces the old one.
        for other in Self.formats where other != format { try? fd.removeItem(at: file(name, other, in: folder)) }
        return Info(name: name, format: format, bytes: data.count)
    }

    func list(clientID: String) -> [Info] {
        lock.lock()
        defer { lock.unlock() }
        let folder = directory.appendingPathComponent(clientID, isDirectory: true)
        let files = (try? fd.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url -> Info? in
            guard Self.formats.contains(url.pathExtension) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Info(name: url.deletingPathExtension().lastPathComponent, format: url.pathExtension, bytes: size)
        }.sorted { $0.name < $1.name }
    }

    func exists(name: String, clientID: String) -> Bool {
        guard Self.isValidName(name) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let folder = directory.appendingPathComponent(clientID, isDirectory: true)
        return Self.formats.contains { fd.fileExists(atPath: file(name, $0, in: folder).path) }
    }

    func delete(name: String, clientID: String) throws {
        try Self.checkName(name)
        lock.lock()
        defer { lock.unlock() }
        let folder = directory.appendingPathComponent(clientID, isDirectory: true)
        let removed = Self.formats.filter { (try? fd.removeItem(at: file(name, $0, in: folder))) != nil }
        if removed.isEmpty { throw BridgeError.iconNotFound }
    }

    /// Forgets every icon of a client (it was removed).
    func removeAll(clientID: String) {
        lock.lock()
        defer { lock.unlock() }
        try? fd.removeItem(at: directory.appendingPathComponent(clientID, isDirectory: true))
    }

    /// Icon names are file names, so no leading dot: "." and ".." would name folders.
    static func checkName(_ name: String) throws {
        guard isValidName(name) else {
            throw BridgeError.invalid("name", "must be 1–64 characters of A–Z, a–z, 0–9, '.', '_' or '-', not starting with '.'")
        }
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    private func names(in folder: URL) -> Set<String> {
        let files = (try? fd.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(files.filter { Self.formats.contains(($0 as NSString).pathExtension) }
                        .map { ($0 as NSString).deletingPathExtension })
    }

    private func file(_ name: String, _ format: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(name).\(format)")
    }

    /// The bytes start the way the format says, so the stored extension is honest.
    private static func looksLike(_ format: String, _ data: Data) -> Bool {
        switch format {
        case "pdf": return data.starts(with: Array("%PDF-".utf8))
        case "png": return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        default:
            // SVG is text: an <svg element near the start, after any XML declaration or comments.
            let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
            return head.contains("<svg")
        }
    }
}
