//
//  BTDBattery.swift
//  AirBattery
//
//  Created by apple on 2024/6/23.
//

import SwiftUI
import Foundation
import IOBluetooth

class BTDBattery {
    var scanTimer: Timer?
    static var allDevices = [String]()
    @AppStorage("readBTHID") var readBTHID = true

    private let scanQueue = DispatchQueue(label: "com.lihaoyun6.AirBattery.btd-scan")
    private var isRunning = false
    private var queued = false
    private var queuedLongScan = false
    private let lock = NSLock()

    func startScan() {
        let interval = TimeInterval(59 * updateInterval)
        scanTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(scanDevices), userInfo: nil, repeats: true)
        print("ℹ️ Start scanning Bluetooth HID devices...")
        scanDevices(longScan: true)
    }

    @objc func scanDevices(longScan: Bool = false) {
        lock.lock()
        if isRunning {
            queued = true
            if longScan { queuedLongScan = true }
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        scanQueue.async { [weak self] in
            guard let self else { return }
            autoreleasepool {
                if self.readBTHID {
                    if longScan { BTDBattery.getOtherDevice(last: "2h", timeout: 25) }
                    let connects = BTDBattery.getConnected()
                    let names = BTDBattery.allDevices.filter({ connects.contains($0) })
                    for name in names {
                        if var device = AirBatteryModel.getByName(name) {
                            device.lastUpdate = Date().timeIntervalSince1970
                            AirBatteryModel.updateDevice(device)
                        }
                    }
                }
            }
            self.finishScan()
        }
    }

    private func finishScan() {
        lock.lock()
        isRunning = false
        let again = queued
        let longScan = queuedLongScan
        queued = false
        queuedLongScan = false
        lock.unlock()
        if again { scanDevices(longScan: longScan) }
    }

    static func getConnected(mac: Bool = false) -> [String]{
        guard var bluetoothDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        bluetoothDevices = bluetoothDevices.filter({ $0.isConnected() })
        if mac {
            let devices = bluetoothDevices.map({ ($0.addressString ?? "").uppercased().replacingOccurrences(of: "-", with: ":") })
            return devices.filter({ $0 != "" })
        }
        return bluetoothDevices.map({ $0.name ?? "" }).filter({ $0 != "" })
    }

    static func getOtherDevice(last: String = "10m", timeout: Int = 0) {
        let parent = ud.string(forKey: "deviceName") ?? "Mac"
        guard let result = process(path: "/bin/bash", arguments: ["\(Bundle.main.resourcePath!)/logReader.sh", "mac", last], timeout: timeout) else { return }
        let connected = getConnected(mac: true)
        var list = [[String : Any]]()
        let devices = result.components(separatedBy: "\n")
        for device in devices {
            if let json = try? JSONSerialization.jsonObject(with: Data(device.utf8), options: []) as? [String: Any] {
                if let index = list.firstIndex(where: { dict in
                    let name = dict["name"] as! String
                    let mac = dict["mac"] as! String
                    let type = dict["type"] as! String
                    let nameNow = json["name"] as! String
                    let macNow = json["mac"] as! String
                    let typeNow = json["type"] as! String
                    return (name == nameNow && mac == macNow && type == typeNow)
                }) {
                    list[index] = json
                } else {
                    list.append(json)
                }
            }
        }
        for d in list {
            let mac = d["mac"] as! String
            var name = d["name"] as! String
            let type = d["type"] as! String
            let time = d["time"] as! String
            let level = d["level"] as! Int
            let status = (d["status"] as! String) == "+" ? 1 : 0
            if name == "" { name = "\(type) (\(mac))" }
            if connected.contains(mac) {
                if let index = allDevices.firstIndex(of: name) { allDevices[index] = name } else { allDevices.append(name) }
                AirBatteryModel.updateDevice(Device(deviceID: mac, deviceType: type, deviceName: name, batteryLevel: min(100, max(0, level)), isCharging: status, parentName: parent, lastUpdate: Date().timeIntervalSince1970, realUpdate: isoFormatter.date(from: time)?.timeIntervalSince1970 ?? 0.0))
            }
        }
    }
}
