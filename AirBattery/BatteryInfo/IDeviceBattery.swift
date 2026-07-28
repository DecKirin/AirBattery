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

    func getIDeviceBattery() {
        if let result = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevice_id", arguments: ["-n"]) {
            for id in result.components(separatedBy: .newlines) {
                if let d = AirBatteryModel.getByID(id) {
                    if (Double(Date().timeIntervalSince1970) - d.lastUpdate) > Double(60 * updateInterval) { writeBatteryInfo(id, "-n") }
                    getPencil(d: d, type: "-n")
                } else {
                    writeBatteryInfo(id, "-n")
                }
            }
        }
        if let result = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/idevice_id", arguments: ["-l"]) {
            for id in result.components(separatedBy: .newlines) {
                if let d = AirBatteryModel.getByID(id) {
                    if (Double(Date().timeIntervalSince1970) - d.lastUpdate) > Double(60 * updateInterval) { writeBatteryInfo(id, "") }
                    getPencil(d: d)
                } else {
                    writeBatteryInfo(id, "")
                }
            }
        }
    }

    func writeBatteryInfo(_ id: String, _ connectType: String) {
        let lastUpdate = Date().timeIntervalSince1970
        if connectType == "" { _ = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/wificonnection", arguments: ["-u", id, "true"]) }
        if let deviceInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/ideviceinfo", arguments: [connectType, "-u", id]){
            let i = deviceInfo.components(separatedBy: .newlines)
            if let deviceName = i.filter({ $0.contains("DeviceName") }).first?.components(separatedBy: ": ").last,
               let model = i.filter({ $0.contains("ProductType") }).first?.components(separatedBy: ": ").last,
               let type = i.filter({ $0.contains("DeviceClass") }).first?.components(separatedBy: ": ").last {
                if let batteryInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/ideviceinfo", arguments: [connectType, "-u", id, "-q", "com.apple.mobile.battery"]) {
                    let b = batteryInfo.components(separatedBy: .newlines)
                    if let level = b.filter({ $0.contains("BatteryCurrentCapacity") }).first?.components(separatedBy: ": ").last,
                       let charging = b.filter({ $0.contains("BatteryIsCharging") }).first!.components(separatedBy: ": ").last {
                        AirBatteryModel.updateDevice(Device(deviceID: id, deviceType: type, deviceName: deviceName, deviceModel: model, batteryLevel: Int(level)!, isCharging: Bool(charging)! ? 1 : 0, lastUpdate: lastUpdate))
                        if let watchInfo = process(path: "\(Bundle.main.resourcePath!)/libimobiledevice/bin/comptest", arguments: [id]) {
                            let w = watchInfo.components(separatedBy: .newlines)
                            if let watchID = w.filter({ $0.contains("Checking watch") }).first?.components(separatedBy: " ").last,
                               let watchName = w.filter({ $0.contains("DeviceName") }).first?.components(separatedBy: ": ").last,
                               let watchModel = w.filter({ $0.contains("ProductType") }).first?.components(separatedBy: ": ").last,
                               let watchLevel = w.filter({ $0.contains("BatteryCurrentCapacity") }).first?.components(separatedBy: ": ").last,
                               let watchCharging = w.filter({ $0.contains("BatteryIsCharging") }).first?.components(separatedBy: ": ").last {
                                AirBatteryModel.updateDevice(Device(deviceID: watchID, deviceType: "Watch", deviceName: watchName, deviceModel: watchModel, batteryLevel: Int(watchLevel)!, isCharging: Bool(watchCharging)! ? 1 : 0, parentName: deviceName, lastUpdate: lastUpdate))
                            }
                        }
                    }
                }
            }
        }
    }
}
