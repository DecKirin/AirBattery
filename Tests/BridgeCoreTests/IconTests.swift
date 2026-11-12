//
//  IconTests.swift
//  BridgeCoreTests
//
//  Uploaded icons: the /v1/icons endpoints, `customIcon` on devices, and drawing them.
//

import AppKit

func runIconTests() throws {
    let (store, _) = freshStore()
    let memory = MemoryDevices()
    let iconDir = tempDir.appendingPathComponent("icons-\(UUID().uuidString)")
    let icons = BridgeIconStore(directory: iconDir)
    let router = BridgeRouter(store: store, devices: memory.deviceList, icons: icons, mode: { .blocklist })
    router.port = 48620

    func register(_ name: String) -> String {
        let reply = router.handle(request("POST", "/v1/register", json: #"{"name":"\#(name)"}"#))
        return object(reply)["token"] as? String ?? ""
    }
    let token = register("Printer Helper")
    let clientID = (try? store.authenticate(token: token))?.id ?? ""
    func upload(_ name: String, _ format: String, _ data: Data, as token: String = token) -> BridgeHTTPResponse {
        router.handle(request("PUT", "/v1/icons/\(name)", token: token,
                              json: #"{"format":"\#(format)","data":"\#(data.base64EncodedString())"}"#))
    }

    let svg = Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="24"><rect x="2" y="2" width="16" height="20" rx="3"/></svg>
        """#.utf8)
    let png = samplePNG()
    let pdf = samplePDF()

    // Uploading
    let put = upload("printer", "svg", svg)
    let info = object(put)["icon"] as? [String: Any]
    check(put.status == 200 && info?["name"] as? String == "printer" && info?["format"] as? String == "svg"
          && info?["bytes"] as? Int == svg.count, "upload an SVG (got \(put.status) \(String(decoding: put.body ?? Data(), as: UTF8.self)))")
    check(fd.fileExists(atPath: iconDir.appendingPathComponent("\(clientID)/printer.svg").path), "stored in the client's folder")
    check(upload("label", "png", png).status == 200 && upload("doc", "PDF", pdf).status == 200, "PNG and PDF, format in any case")
    let listed = (object(router.handle(request("GET", "/v1/icons", token: token)))["icons"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    check(listed == ["doc", "label", "printer"], "GET /v1/icons lists them")
    check(errorCode(router.handle(request("GET", "/v1/icons"))) == "unauthorized", "icons need the token")

    // Bad uploads
    check(errorCode(upload("x", "gif", png)) == "invalid_format", "unknown format")
    check(errorCode(upload("x", "png", svg)) == "invalid_data", "bytes that aren't the format claimed")
    check(errorCode(upload("x", "svg", Data("<svg nope".utf8))) == "invalid_data", "an SVG that doesn't parse")
    check(errorCode(upload("x", "png", Data(count: BridgeIconStore.maxBytes + 1))) == "invalid_data", "over 64 KB")
    check(errorCode(router.handle(request("PUT", "/v1/icons/x", token: token, json: #"{"format":"png","data":"%%%"}"#))) == "invalid_data",
          "not base64")
    check(errorCode(upload(".hidden", "svg", svg)) == "invalid_name" && errorCode(upload("..", "svg", svg)) == "invalid_name",
          "names that would be dot files or folders")
    check(!fd.fileExists(atPath: iconDir.appendingPathComponent("\(clientID)/x.png").path), "nothing stored for a rejected upload")

    // Devices
    let device = router.handle(request("PUT", "/v1/devices/p1", token: token,
                                       json: #"{"name":"Label Printer","type":"generic","icon":"printer.fill","customIcon":"printer","level":40}"#))
    check(device.status == 200 && (object(device)["device"] as? [String: Any])?["customIcon"] as? String == "printer",
          "a device uses its uploaded icon")
    let stored = memory.list.first { $0.deviceName == "Label Printer" }
    check(stored?.deviceCustomIcon == "printer" && stored?.deviceIcon == "printer.fill", "both icons are stored")
    let drawn = stored.flatMap { customDeviceIcon($0, in: iconDir) }
    check(drawn?.isTemplate == true && (drawn?.size.width ?? 0) > 0, "the uploaded icon is drawn as a template")
    check(errorCode(router.handle(request("PUT", "/v1/devices/p2", token: token,
                                          json: #"{"name":"Other","type":"generic","customIcon":"nothing","level":4}"#))) == "invalid_customIcon",
          "a device can't name an icon that wasn't uploaded")

    let other = register("Someone Else")
    check(errorCode(router.handle(request("PUT", "/v1/devices/p3", token: other,
                                          json: #"{"name":"Borrowed","type":"generic","customIcon":"printer","level":4}"#))) == "invalid_customIcon",
          "a client can't use another client's icon")
    check(errorCode(router.handle(request("DELETE", "/v1/icons/printer", token: other))) == "not_found", "or delete it")

    // Replacing and deleting
    check(upload("printer", "png", png).status == 200, "re-upload in another format")
    let afterReplace = icons.list(clientID: clientID).first { $0.name == "printer" }
    check(afterReplace?.format == "png" && !fd.fileExists(atPath: iconDir.appendingPathComponent("\(clientID)/printer.svg").path),
          "a new format replaces the old file")
    check(stored.flatMap { customDeviceIcon($0, in: iconDir) } != nil, "the device draws the replacement")
    check(router.handle(request("DELETE", "/v1/icons/printer", token: token)).status == 204, "DELETE an icon")
    check(errorCode(router.handle(request("DELETE", "/v1/icons/printer", token: token))) == "not_found", "DELETE it twice")
    check(stored.flatMap { customDeviceIcon($0, in: iconDir) } == nil, "a device whose icon is gone falls back")

    // Limits
    for i in icons.list(clientID: clientID).count..<BridgeIconStore.maxPerClient {
        _ = upload("n\(i)", "svg", svg)
    }
    check(icons.list(clientID: clientID).count == BridgeIconStore.maxPerClient, "up to the limit")
    check(errorCode(upload("one-more", "svg", svg)) == "too_many_icons", "past the limit")
    check(upload("n10", "svg", svg).status == 200, "replacing one at the limit is fine")

    // Drawing never leaves the client's folder
    func drawIcon(_ id: String, _ icon: String) -> NSImage? {
        customDeviceIcon(Device(deviceID: id, deviceType: "generic", deviceName: "x", deviceCustomIcon: icon,
                                batteryLevel: 1, isCharging: 0, lastUpdate: 0), in: iconDir)
    }
    check(drawIcon("bridge:\(clientID):d", "doc") != nil, "a bridged device draws its client's icon")
    check(drawIcon("AA:BB:CC", "doc") == nil, "a device that isn't bridged doesn't")
    check(drawIcon("bridge:\(clientID):d", "../\(clientID)/doc") == nil, "a name with a path in it doesn't")
    check(drawIcon("bridge:..:d", "doc") == nil, "nor a client ID with one")

    // Removing the client takes its icons
    icons.removeAll(clientID: clientID)
    check(!fd.fileExists(atPath: iconDir.appendingPathComponent(clientID).path) && icons.list(clientID: clientID).isEmpty,
          "removing a client deletes its icons")
}

private func samplePNG() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 24, height: 24)).fill()
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

private func samplePDF() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 20, height: 24)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.fill(CGRect(x: 2, y: 2, width: 16, height: 20))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}
