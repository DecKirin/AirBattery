//
//  AirBatteryModel.swift
//  AirBattery
//
//  Created by apple on 2024/2/6.
//
import SwiftUI
import Foundation

class IDeviceBattery {
    static var shared: IDeviceBattery = IDeviceBattery()

    private let scanQueue = DispatchQueue(label: "com.lihaoyun6.AirBattery.idevice-scan")
    private var isRunning = false
    private var queued = false
    private let lock = NSLock()

    @AppStorage("readPencil") var readPencil = false
    @AppStorage("readIDevice") var readIDevice = true
    @AppStorage("updateInterval") var updateInterval = 1

    func startScan() {
        print("ℹ️ Start scanning iDevice devices...")
        scanDevices()
    }

    @objc func scanDevices() {
        guard readIDevice else { return }
        lock.lock()
        if isRunning {
            queued = true
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        scanQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                self.getIDeviceBattery()
            }
            self.finishScan()
        }
    }

    private func finishScan() {
        lock.lock()
        isRunning = false
        let again = queued
        queued = false
        lock.unlock()
        if again { scanDevices() }
    }

    func getPencil(d: Device, type: String = "") {
        guard d.deviceType == "iPad", readPencil else { return }
        if let result = process(path: "/bin/bash", arguments: ["\(Bundle.main.resourcePath!)/logReader.sh", "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevicesyslog", type, d.deviceID], timeout: 11 * updateInterval) {
            if let json = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: []) as? [String: Any] {
                if let level = json["level"] as? Int, let model = json["model"] as? String, let vendor = json["vendor"] as? String {
                    let status = (json["status"] as? Int) ?? 0
                    print("ℹ️ Pencil of \(d.deviceName): \(result)")
                    AirBatteryModel.updateDevice(Device(deviceID: "Pencil_"+d.deviceID, deviceType: vendor == "Apple" ? "ApplePencil" : "Pencil", deviceName: vendor == "Apple" ? "Apple Pencil".local : "Pencil".local, deviceModel: model, batteryLevel: level, isCharging: status, parentName: d.deviceName, lastUpdate: Date().timeIntervalSince1970))
                }
            }
        }
    }

    /// Every libimobiledevice call below runs with an explicit timeout.
    ///
    /// These talk to the phone over USB or WiFi-sync and routinely wedge when the phone drops off
    /// the network or locks mid-handshake. `process()` with `timeout: 0` blocks in
    /// `readDataToEndOfFile()` forever, which parks the serial `idevice-scan` queue permanently —
    /// `isRunning` stays true, so every subsequent `scanDevices()` returns immediately. The iPhone
    /// and the Apple Watch hanging off it then stop being refreshed and age out of the list at
    /// `disappearTime`, never returning until the app is relaunched.
    private var idTimeout: Int { 10 * updateInterval }
    private var infoTimeout: Int { 15 * updateInterval }
    private var watchTimeout: Int { 20 * updateInterval }

    func getIDeviceBattery() {
        if let result = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevice_id", arguments: ["-n"], timeout: idTimeout) {
            // Drop blank lines: an empty UDID would otherwise burn a full subprocess timeout.
            for id in result.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                if let d = AirBatteryModel.getByID(id) {
                    if (Double(Date().timeIntervalSince1970) - d.lastUpdate) > Double(60 * updateInterval) { writeBatteryInfo(id, "-n") }
                    getPencil(d: d, type: "-n")
                } else {
                    writeBatteryInfo(id, "-n")
                }
            }
        }
        if let result = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevice_id", arguments: ["-l"], timeout: idTimeout) {
            // Drop blank lines: an empty UDID would otherwise burn a full subprocess timeout.
            for id in result.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                if let d = AirBatteryModel.getByID(id) {
                    if (Double(Date().timeIntervalSince1970) - d.lastUpdate) > Double(60 * updateInterval) { writeBatteryInfo(id, "") }
                    getPencil(d: d)
                } else {
                    writeBatteryInfo(id, "")
                }
            }
        }
    }

    /// Per-phone backoff for the paired-watch lookup.
    ///
    /// On some phone/iOS combinations `comptest` starts the companion proxy fine but then hangs
    /// forever inside "Retrieving list of watches" — it only ends when `watchTimeout` kills it.
    /// Retrying that on every phone refresh spends the whole timeout budget on the serial scan
    /// queue and delays every other device behind it. Back off after fruitless attempts (1, 2, 4,
    /// 8, capped at 16 minutes) and reset the moment a watch is actually read.
    private let watchLock = NSLock()
    private var watchSkipUntil = [String: Double]()
    private var watchFailures = [String: Int]()

    private func shouldQueryWatch(_ id: String) -> Bool {
        watchLock.lock()
        defer { watchLock.unlock() }
        return Date().timeIntervalSince1970 >= (watchSkipUntil[id] ?? 0)
    }

    private func noteWatchResult(_ id: String, found: Bool) {
        watchLock.lock()
        defer { watchLock.unlock() }
        if found {
            watchFailures[id] = 0
            watchSkipUntil[id] = 0
        } else {
            let n = min((watchFailures[id] ?? 0) + 1, 5)
            watchFailures[id] = n
            watchSkipUntil[id] = Date().timeIntervalSince1970 + Double(60 * (1 << (n - 1)))
        }
    }

    func writeBatteryInfo(_ id: String, _ connectType: String) {
        let lastUpdate = Date().timeIntervalSince1970
        if connectType == "" { _ = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/wificonnection", arguments: ["-u", id, "true"], timeout: idTimeout) }
        if let deviceInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/ideviceinfo", arguments: [connectType, "-u", id], timeout: infoTimeout){
            let i = deviceInfo.components(separatedBy: .newlines)
            if let deviceName = i.filter({ $0.contains("DeviceName") }).first?.components(separatedBy: ": ").last,
               let model = i.filter({ $0.contains("ProductType") }).first?.components(separatedBy: ": ").last,
               let type = i.filter({ $0.contains("DeviceClass") }).first?.components(separatedBy: ": ").last {
                if let batteryInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/ideviceinfo", arguments: [connectType, "-u", id, "-q", "com.apple.mobile.battery"], timeout: infoTimeout) {
                    let b = batteryInfo.components(separatedBy: .newlines)
                    // A timed-out subprocess is terminated mid-write, so its output can be
                    // truncated or missing keys entirely. Parse defensively — the old force
                    // unwraps here would turn a slow phone into a crash.
                    if let level = b.filter({ $0.contains("BatteryCurrentCapacity") }).first?.components(separatedBy: ": ").last,
                       let charging = b.filter({ $0.contains("BatteryIsCharging") }).first?.components(separatedBy: ": ").last,
                       let levelValue = Int(level.trimmingCharacters(in: .whitespaces)) {
                        let isCharging = Bool(charging.trimmingCharacters(in: .whitespaces)) ?? false
                        AirBatteryModel.updateDevice(Device(deviceID: id, deviceType: type, deviceName: deviceName, deviceModel: model, batteryLevel: levelValue, isCharging: isCharging ? 1 : 0, lastUpdate: lastUpdate))
                        if shouldQueryWatch(id) {
                            var foundWatch = false
                            if let watchInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/comptest", arguments: [id], timeout: watchTimeout) {
                                let w = watchInfo.components(separatedBy: .newlines)
                                if let watchID = w.filter({ $0.contains("Checking watch") }).first?.components(separatedBy: " ").last,
                                   let watchName = w.filter({ $0.contains("DeviceName") }).first?.components(separatedBy: ": ").last,
                                   let watchModel = w.filter({ $0.contains("ProductType") }).first?.components(separatedBy: ": ").last,
                                   let watchLevel = w.filter({ $0.contains("BatteryCurrentCapacity") }).first?.components(separatedBy: ": ").last,
                                   let watchCharging = w.filter({ $0.contains("BatteryIsCharging") }).first?.components(separatedBy: ": ").last,
                                   let watchLevelValue = Int(watchLevel.trimmingCharacters(in: .whitespaces)) {
                                    let watchIsCharging = Bool(watchCharging.trimmingCharacters(in: .whitespaces)) ?? false
                                    foundWatch = true
                                    AirBatteryModel.updateDevice(Device(deviceID: watchID, deviceType: "Watch", deviceName: watchName, deviceModel: watchModel, batteryLevel: watchLevelValue, isCharging: watchIsCharging ? 1 : 0, parentName: deviceName, lastUpdate: lastUpdate))
                                }
                            }
                            noteWatchResult(id, found: foundWatch)
                        }
                    }
                }
            }
        }
    }
}
