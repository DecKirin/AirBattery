//
//  MagicBattery.swift
//  AirBattery
//
//  Created by apple on 2024/2/9.
//
import SwiftUI
import Foundation
import IOBluetooth
import IOKit.ps

class SPBluetoothDataModel {
    static var shared: SPBluetoothDataModel = SPBluetoothDataModel()

    private let scanQueue = DispatchQueue(label: "com.lihaoyun6.AirBattery.spbluetooth-scan")
    private let lock = NSLock()
    private var _data: String = "{}"
    private var isRunning = false
    private var pendingCallbacks: [(completion: (String) -> Void, error: (() -> Void)?)] = []

    var data: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }
        set {
            lock.lock()
            _data = newValue
            lock.unlock()
        }
    }

    func refeshData(completion: @escaping (String) -> Void, error: (() -> Void)? = nil) {
        lock.lock()
        pendingCallbacks.append((completion, error))
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        runScan()
    }

    private func runScan() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            // Must have a timeout: `system_profiler SPBluetoothDataType` can hang indefinitely.
            // Without one, `readDataToEndOfFile()` blocks forever, `isRunning` never clears, and
            // every later `refeshData` call parks its callback in `pendingCallbacks` and is never
            // invoked — permanently killing the Magic device rescan until the app is relaunched.
            let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"], timeout: 20)

            self.lock.lock()
            let callbacks = self.pendingCallbacks
            self.pendingCallbacks = []
            if let result { self._data = result }
            self.lock.unlock()

            for callback in callbacks {
                if let result { callback.completion(result) } else { callback.error?() }
            }

            self.lock.lock()
            let runAgain = !self.pendingCallbacks.isEmpty
            if !runAgain { self.isRunning = false }
            self.lock.unlock()

            if runAgain { self.runScan() }
        }
    }
}

/// Signature of `IOPSCopyPowerSourcesByType`, the call behind `pmset -g accps`. It returns the
/// power-source blob for one class of sources, to be walked with the public `IOPSCopyPowerSourcesList`
/// / `IOPSGetPowerSourceDescription` pair.
private typealias IOPSCopyPowerSourcesByTypeFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?

/// `IOPSCopyPowerSourcesByType` is exported by IOKit but is not declared in the public SDK headers,
/// so bind it at runtime. Resolved via `dlsym` rather than `@_silgen_name` deliberately: a missing
/// symbol then degrades to "no accessory batteries" instead of stopping the app from launching at all.
private let ioPSCopyPowerSourcesByType: IOPSCopyPowerSourcesByTypeFn? = {
    guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
          let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType")
    else {
        print("⚠️ IOPSCopyPowerSourcesByType unavailable, accessory batteries will not be read")
        return nil
    }
    return unsafeBitCast(symbol, to: IOPSCopyPowerSourcesByTypeFn.self)
}()

/// `kIOPSSourceForAccessories`, from IOKit's private `IOPowerSourcesPrivate.h`.
private let kIOPSSourceForAccessories: Int32 = 4

class MagicBattery {
    static var shared: MagicBattery = MagicBattery()
    
    //var scanTimer: Timer?
    @AppStorage("readBTDevice") var readBTDevice = true
    //@AppStorage("readBTHID") var readBTHID = true
    @AppStorage("updateInterval") var updateInterval = 1
    @AppStorage("deviceName") var deviceName = "Mac"
    
    func startScan() {
        //let interval = TimeInterval(59.0 * updateInterval)
        //scanTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(scanDevices), userInfo: nil, repeats: true)
        print("ℹ️ Start scanning Magic devices...")
        scanDevices()
    }
    
    @objc func scanDevices() {
        //Thread.detachNewThread {
            if self.readBTDevice {
                self.getIOBTBattery()
                self.getOtherBTBattery()
                self.getMagicBattery()
                self.getOldMagicKeyboard()
                self.getOldMagicTrackpad()
                self.getOldMagicMouse()
                // Last on purpose: this is the freshest reading for anything macOS itself tracks,
                // and running after the scans above lets it keep the more specific device types
                // they set rather than overwrite them.
                self.getAccessoryBattery()
            }
        //}
    }
    
    func findParentKey(forValue value: Any, in json: [String: Any]) -> String? {
        for (key, subJson) in json {
            if let subJsonDictionary = subJson as? [String: Any] {
                if subJsonDictionary.values.contains(where: { $0 as? String == value as? String }) {
                    return key
                } else if let parentKey = findParentKey(forValue: value, in: subJsonDictionary) {
                    return parentKey
                }
            } else if let subJsonArray = subJson as? [[String: Any]] {
                for subJsonDictionary in subJsonArray {
                    if subJsonDictionary.values.contains(where: { $0 as? String == value as? String }) {
                        return key
                    } else if let parentKey = findParentKey(forValue: value, in: subJsonDictionary) {
                        return parentKey
                    }
                }
            }
        }
        return nil
    }
    
    func getDeviceName(_ mac: String, _ def: String) -> String {
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return def }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any] {
            if let parent = findParentKey(forValue: mac, in: json) {
                return parent
            }
        }
        return def
    }
    
    func getDeviceType(_ mac: String, _ def: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
           let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
           let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        if let id = info["device_address"] as? String,
                           let type = info["device_minorType"] as? String{
                            if id == mac { return type }
                        }
                    }
                }
            }
        }
        return def
    }
    
    func getDeviceTypeWithPID(_ pid: String, _ def: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
           let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
           let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        if let id = info["device_productID"] as? String,
                           let type = info["device_minorType"] as? String{
                            if id == pid { return type }
                        }
                    }
                }
            }
        }
        return def
    }
    
    func readMagicBattery(object: io_object_t) {
        var mac = ""
        var type = "hid"
        var status = 0
        var percent = 0
        var productName = ""
        let lastUpdate = Date().timeIntervalSince1970
        if let productProperty = IORegistryEntryCreateCFProperty(object, "DeviceAddress" as CFString, kCFAllocatorDefault, 0) {
            mac = productProperty.takeRetainedValue() as! String
            mac = mac.replacingOccurrences(of:"-", with:":").uppercased()
        }
        if let percentProperty = IORegistryEntryCreateCFProperty(object, "BatteryStatusFlags" as CFString, kCFAllocatorDefault, 0) {
            status = percentProperty.takeRetainedValue() as! Int
            if status == 4 { status = 0 }
        }
        if let percentProperty = IORegistryEntryCreateCFProperty(object, "BatteryPercent" as CFString, kCFAllocatorDefault, 0) {
            percent = percentProperty.takeRetainedValue() as! Int
        }
        if let productProperty = IORegistryEntryCreateCFProperty(object, "Product" as CFString, kCFAllocatorDefault, 0) {
            productName = productProperty.takeRetainedValue() as! String
            if productName.contains("Trackpad") { type = "Trackpad" }
            if productName.contains("Keyboard") { type = "Keyboard" }
            if productName.contains("Mouse") { type = "MMouse" }
            if type == "hid" {
                type = getDeviceType(mac, type)
                if type.contains("Trackpad") { type = "Trackpad" }
                if type.contains("Keyboard") { type = "Keyboard" }
                if type.contains("Mouse") { type = "MMouse" }
            } else {
                productName = getDeviceName(mac, productName)
            }
        }
        if !productName.contains("Internal"){
            AirBatteryModel.updateDevice(Device(deviceID: mac, deviceType: type, deviceName: productName, batteryLevel: percent, isCharging: status, parentName: deviceName, lastUpdate: lastUpdate))
        }
    }

    /// Walk every IOService matching `serviceName` and hand each entry to `readMagicBattery`.
    ///
    /// Every `io_object_t` returned by `IOIteratorNext` carries a +1 retain that the caller owns.
    /// The old per-function loops only released the trailing 0 sentinel, so each scan leaked one
    /// Mach port per matched device. Since these scans re-run on `widgetDataTimer`, the leak
    /// accumulated until the process hit its Mach port limit and `IOServiceGetMatchingServices`
    /// started failing outright — at which point Magic Mouse/Keyboard/Trackpad silently stopped
    /// being refreshed and aged out of the list via the `disappearTime` filter.
    private func scanIOService(_ serviceName: String) {
        var serialPortIterator = io_iterator_t()
        let masterPort: mach_port_t
        if #available(macOS 12.0, *) {
            masterPort = kIOMainPortDefault // New name in macOS 12 and higher
        } else {
            masterPort = kIOMasterPortDefault // Old name in macOS 11 and lower
        }
        let matchingDict: CFDictionary = IOServiceMatching(serviceName)
        let kernResult = IOServiceGetMatchingServices(masterPort, matchingDict, &serialPortIterator)
        guard kernResult == KERN_SUCCESS else {
            print("⚠️ IOServiceGetMatchingServices(\(serviceName)) failed: \(kernResult)")
            return
        }
        defer { IOObjectRelease(serialPortIterator) }

        var object = IOIteratorNext(serialPortIterator)
        while object != 0 {
            readMagicBattery(object: object)
            IOObjectRelease(object)
            object = IOIteratorNext(serialPortIterator)
        }
    }

    func getMagicBattery() { scanIOService("AppleDeviceManagementHIDEventService") }

    func getOldMagicKeyboard() { scanIOService("AppleBluetoothHIDKeyboard") }

    func getOldMagicTrackpad() { scanIOService("BNBTrackpadDevice") }

    func getOldMagicMouse() { scanIOService("BNBMouseDevice") }
    
    func getAirpods() {
        let now = Date().timeIntervalSince1970
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        var productID = "200e"
                        var mainDevice: Device?
                        var subDevices: [Device] = []
                        if let level = info["device_batteryLevelCase"] as? String {
                            var id = n
                            if let mac = info["device_address"] as? String { id = mac }
                            if let pid = info["device_productID"] as? String { productID = pid.replacingOccurrences(of: "0x", with: "") }
                            if let level = Int(level.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "%", with: "")) {
                                if var apCase = AirBatteryModel.getByName(n + " (Case)".local) {
                                    apCase.batteryLevel = level
                                    apCase.lastUpdate = now
                                    mainDevice = apCase
                                } else {
                                    mainDevice = Device(deviceID: id, deviceType: "ap_case", deviceName: n + " (Case)".local, deviceModel: getHeadphoneModel(productID), batteryLevel: level, isCharging: 0, lastUpdate: now)
                                }
                            }
                        }
                        if let level = info["device_batteryLevelLeft"] as? String {
                            var id = n
                            if let mac = info["device_address"] as? String { id = mac }
                            if let pid = info["device_productID"] as? String { productID = pid.replacingOccurrences(of: "0x", with: "") }
                            if let level = Int(level.replacingOccurrences(of: "%", with: "")) {
                                if var apLeft = AirBatteryModel.getByName(n + " 🄻") {
                                    apLeft.batteryLevel = level
                                    apLeft.lastUpdate = now
                                    subDevices.append(apLeft)
                                } else {
                                    subDevices.append(Device(deviceID: id, deviceType: "ap_pod_left", deviceName: n + " 🄻", deviceModel: getHeadphoneModel(productID), batteryLevel: level, isCharging: 0, parentName: n + " (Case)".local, lastUpdate: now))
                                }
                            }
                            mainDevice?.deviceModel = getHeadphoneModel(productID)
                        }
                        if let level = info["device_batteryLevelRight"] as? String {
                            var id = n
                            if let mac = info["device_address"] as? String { id = mac }
                            if let pid = info["device_productID"] as? String { productID = pid.replacingOccurrences(of: "0x", with: "") }
                            if let level = Int(level.replacingOccurrences(of: "%", with: "")) {
                                if var apRight = AirBatteryModel.getByName(n + " 🅁") {
                                    apRight.batteryLevel = level
                                    apRight.lastUpdate = now
                                    subDevices.append(apRight)
                                } else {
                                    subDevices.append(Device(deviceID: id, deviceType: "ap_pod_right", deviceName: n + " 🅁", deviceModel: getHeadphoneModel(productID), batteryLevel: level, isCharging: 0, parentName: n + " (Case)".local, lastUpdate: now))
                                }
                            }
                            mainDevice?.deviceModel = getHeadphoneModel(productID)
                        }
                        if let apCase = mainDevice { AirBatteryModel.updateDevice(apCase) }
                        if subDevices.count != 0 {
                            if subDevices.count == 2 {
                                if abs(Int(subDevices[0].batteryLevel) - Int(subDevices[1].batteryLevel)) < 3 {
                                    AirBatteryModel.hideDevice(n + " 🄻")
                                    AirBatteryModel.hideDevice(n + " 🅁")
                                    AirBatteryModel.updateDevice(Device(deviceID: n + "_All", deviceType: "ap_pod_all", deviceName: n + " 🄻🅁", deviceModel: getHeadphoneModel(productID), batteryLevel: Int(min(subDevices[0].batteryLevel, subDevices[1].batteryLevel)), isCharging: 0, parentName: n + " (Case)".local, lastUpdate: now))
                                }
                            } else {
                                AirBatteryModel.hideDevice(n + " 🄻🅁")
                                for pod in subDevices { AirBatteryModel.updateDevice(pod) }
                            }
                        }
                    }
                }
            }
        }
    }
    
    /// `Accessory Category` values worth adopting, mapped to the device types `getDeviceIcon`
    /// draws. Deliberately limited to input devices: audio accessories already arrive through the
    /// BLE-advertisement, `system_profiler` and IOBluetooth paths, each with its own naming scheme,
    /// so adopting them here would duplicate rows rather than refresh them.
    private static let accessoryCategoryTypes = [
        "Keyboard": "Keyboard",
        "Mouse": "Mouse",
        "Trackpad": "Trackpad",
        "Gamepad": "Gamepad",
        "Game Controller": "Gamepad"
    ]

    /// MAC address of a *connected* device by name, from the cached `system_profiler` JSON.
    ///
    /// Deliberately restricted to `device_connected`: an unpaired-but-remembered clone of a
    /// keyboard is a routine sight in that list (the same board paired over a second BT channel),
    /// and matching one would hand back the wrong address.
    func getDeviceAddress(ofName name: String, _ def: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
           let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
           let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any],
           let device_connected = SPBluetoothDataType["device_connected"] as? [Any] {
            for device in device_connected {
                if let d = device as? [String: Any], let n = d.keys.first, n == name,
                   let info = d[n] as? [String: Any],
                   let mac = info["device_address"] as? String { return mac }
            }
        }
        return def
    }

    /// Battery levels from macOS's accessory power-source registry — the list `pmset -g accps`
    /// prints, and the one the system's own Bluetooth menu reads.
    ///
    /// This is the *only* route to a BLE input device whose battery lives solely in the standard
    /// GATT Battery Service. Such a keyboard has no `device_batteryLevelMain` in `system_profiler`,
    /// no `BatteryPercent` anywhere in the IORegistry, and emits none of the vendor statedumps
    /// `logReader.sh` parses — yet macOS shows its level, which is what made the omission look like
    /// an AirBattery bug rather than a source it had never read.
    ///
    /// It is also the most current source for devices the other scanners *do* find: the statedump
    /// path reports whatever the device last broadcast inside the log window, which can be hours
    /// stale (measured here: 64% from the log against a true 100%).
    func getAccessoryBattery() {
        guard let copyByType = ioPSCopyPowerSourcesByType,
              let blob = copyByType(kIOPSSourceForAccessories)?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        let now = Date().timeIntervalSince1970
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            // AirPods publish one power source per part (case, left, right). Those rows belong to
            // the AirPods paths, which name them "… (Case)" / "… 🄻" / "… 🅁"; re-adding them under
            // the bare accessory name would duplicate every pod instead of updating it.
            guard info["Part Identifier"] == nil else { continue }
            guard let name = info[kIOPSNameKey] as? String, !name.isEmpty,
                  let category = info["Accessory Category"] as? String,
                  let type = MagicBattery.accessoryCategoryTypes[category],
                  let current = info[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            // Accessories report out of 100 in practice, but the key is defined relative to
            // "Max Capacity", so scale rather than assume.
            let capacity = info[kIOPSMaxCapacityKey] as? Int ?? 100
            guard capacity > 0 else { continue }
            let level = min(100, current * 100 / capacity)
            let isCharging = (info[kIOPSIsChargingKey] as? Bool ?? false) ? 1 : 0
            let isCharged = info[kIOPSIsChargedKey] as? Bool ?? false

            if var device = AirBatteryModel.getByName(name) {
                // Refresh the reading, but keep the identity a more specific scanner established:
                // `getMagicBattery` types a Magic Mouse as "MMouse", which the generic "Mouse"
                // category here would otherwise downgrade to the plain mouse icon.
                device.batteryLevel = level
                device.isCharging = isCharging
                device.isCharged = isCharged
                device.lastUpdate = now
                AirBatteryModel.updateDevice(device)
            } else {
                let id = getDeviceAddress(ofName: name, info["Accessory Identifier"] as? String ?? name)
                AirBatteryModel.updateDevice(Device(deviceID: id, deviceType: type, deviceName: name, batteryLevel: level, isCharging: isCharging, isCharged: isCharged, lastUpdate: now))
            }
        }
    }

    func getOtherBTBattery() {
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let n = d.keys.first, let info = d[n] as? [String: Any] {
                        if let level = info["device_batteryLevelMain"] as? String,
                           let id = info["device_address"] as? String,
                           let type = info["device_minorType"] as? String,
                           (info["device_vendorID"] as? String) != "0x004C" {
                            // `continue`, not `return`: one device with an unparseable battery string
                            // must not abort the walk and starve every device after it in the list.
                            guard let batLevel = Int(level.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "%", with: "")) else { continue }
                            AirBatteryModel.updateDevice(Device(deviceID: id, deviceType: type, deviceName: n, batteryLevel: batLevel, isCharging: 0, lastUpdate: Date().timeIntervalSince1970))
                        }
                    }
                }
            }
        }
    }
    
    func getIOBTBattery() {
        if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in devices {
                let name = device.name
                let address = device.addressString
                let connected = device.isConnected()
                //let usb = device.getValue(forKey: "isPluggedOverUSB") as! Bool ?? false
                
                if connected && !device.isAppleDevice {
                    if let battery = device.getValue(forKey: "batteryPercentSingle") as? Int, let name = name, let address = address, battery != 0 {
                        let type = getDeviceType(address.replacingOccurrences(of: "-", with: ":").uppercased(),"")
                        AirBatteryModel.updateDevice(Device(deviceID: address, deviceType: type, deviceName: name, batteryLevel: battery, isCharging: 0, lastUpdate: Date().timeIntervalSince1970))
                    }
                    //let left = device.getValue(forKey: "batteryPercentLeft") as? Int
                    //let right = device.getValue(forKey: "batteryPercentRight") as? Int
                    //let _case = device.getValue(forKey: "batteryPercentCase") as? Int
                }
            }
        }
    }
}

extension IOBluetoothDevice {
    func getValue(forKey: String) -> Any? {
        if self.responds(to: Selector((forKey))) {
            return self.value(forKey: forKey)
        }
        return nil
    }
    
    var isAppleDevice: Bool {
        return self.getValue(forKey: "isAppleDevice") as? Bool ?? false
    }
}
