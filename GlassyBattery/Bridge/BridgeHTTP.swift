//
//  BridgeHTTP.swift
//  GlassyBattery
//
//  Just enough HTTP/1.1 for BatteryBridge: one request per connection, Content-Length bodies,
//  JSON responses, `Connection: close`. Clients are local apps, not browsers, so nothing more is needed.
//

import Foundation

struct BridgeHTTPRequest {
    let method: String
    /// The path without its query string, e.g. `/v1/devices/mouse`.
    let path: String
    let query: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
    let body: Data

    var bearerToken: String? {
        guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
        let token = value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

struct BridgeHTTPResponse {
    var status: Int
    var body: Data?

    static let noContent = BridgeHTTPResponse(status: 204, body: nil)

    static func json<T: Encodable>(_ status: Int, _ value: T) -> BridgeHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return BridgeHTTPResponse(status: status, body: try? encoder.encode(value))
    }

    static func error(_ error: BridgeError) -> BridgeHTTPResponse {
        struct Envelope: Encodable { let error: Detail }
        struct Detail: Encodable { let code: String; let message: String }
        return json(error.status, Envelope(error: Detail(code: error.code, message: error.message)))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(BridgeHTTP.reason(status))\r\n"
        if let body { head += "Content-Type: application/json; charset=utf-8\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }
}

enum BridgeHTTP {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 256 * 1024
    static let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    enum ParseResult {
        /// More bytes are needed. `expectsContinue` is set once the headers are in and the client
        /// asked for `Expect: 100-continue` (curl does for bodies over 1 KB).
        case incomplete(expectsContinue: Bool)
        case complete(BridgeHTTPRequest)
    }

    /// Parses one request from the start of `buffer`. Throws a `BridgeError` the connection
    /// should answer with.
    static func parse(_ buffer: Data) throws -> ParseResult {
        let buffer = Data(buffer)    // zero-based indices from here on
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeaderBytes { throw BridgeError.payloadTooLarge }
            return .incomplete(expectsContinue: false)
        }
        guard headerEnd.lowerBound <= maxHeaderBytes else { throw BridgeError.payloadTooLarge }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw BridgeError.malformedRequest
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else {
            throw BridgeError.malformedRequest
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw BridgeError.malformedRequest }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { throw BridgeError.malformedRequest }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        if headers["transfer-encoding"] != nil { throw BridgeError.lengthRequired }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { throw BridgeError.malformedRequest }
        guard length <= maxBodyBytes else { throw BridgeError.payloadTooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else {
            return .incomplete(expectsContinue: headers["expect"]?.lowercased() == "100-continue")
        }

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count == 2 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }

        return .complete(BridgeHTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query,
                                           headers: headers, body: buffer[bodyStart..<(bodyStart + length)]))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Entity"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
