//
//  BatteryInfo.swift
//  AirBattery
//
//  Created by apple on 2023/9/7.
//

import Foundation
import IOKit.ps

struct iBattery {
    var hasBattery: Bool
    var isCharging: Bool
    var isCharged: Bool
    var acPowered: Bool
    var timeLeft: String
    var batteryLevel: Int
    var lowPower: Bool = false
    var health: Int? = nil
    /// Wattage of the negotiated USB-PD / MagSafe contract, as reported by the adapter itself.
    /// This is the charging protocol's rating (a 65W brick reports 65), not the power actually
    /// flowing into the cell right now. nil whenever nothing is plugged in.
    var adapterWatts: Int? = nil
    /// Magnitude of power crossing the battery terminals, in watts. While running on battery this
    /// is what the machine is consuming; it is always positive (`InternalFinder` folds the sign of
    /// `Amperage` into a direction factor).
    var powerWatts: Double? = nil
}

class InternalBattery {
    static var status: iBattery = getPowerState()
    
    var name: String?
    var timeToFull: Int?
    var timeToEmpty: Int?
    var manufacturer: String?
    var manufactureDate: Date?
    var currentCapacity: Int?
    var maxCapacity: Int?
    var rawMaxCapacity: Int?
    var designCapacity: Int?
    var cycleCount: Int?
    var designCycleCount: Int?
    var acPowered: Bool?
    var isCharging: Bool?
    var isCharged: Bool?
    var amperage: Int?
    var voltage: Double?
    var watts: Double?
    var temperature: Double?

    var charge: Double? {
        get {
            if let current = self.currentCapacity,
               let max = self.maxCapacity {
                return (Double(current) / Double(max)) * 100.0
            }
            return nil
        }
    }

    var health: Double? {
        get {
            // On Apple Silicon, "MaxCapacity" is a percentage (0-100), not the same
            // mAh unit as "DesignCapacity" — "AppleRawMaxCapacity" (or, from macOS 27,
            // "BatteryData.FullChargeCapacity") is the mAh value that actually compares
            // against design capacity. Fall back to "MaxCapacity" on older Macs where
            // it's already reported in mAh.
            if let design = self.designCapacity, design > 0,
               let current = self.rawMaxCapacity ?? self.maxCapacity {
                return min(100.0, (Double(current) / Double(design)) * 100.0)
            }
            return nil
        }
    }

    var timeLeft: String {
        get {
            if let isCharging = self.isCharging {
                if let isCharged = self.isCharged { if isCharged { return "∞" } }
                if let minutes = isCharging ? self.timeToFull : self.timeToEmpty {
                    if minutes <= 0 { return "…" }
                    return String(format: "%.2d:%.2d", minutes / 60, minutes % 60)
                }
            }
            return "…"
        }
    }

    var timeRemaining: Int? {
        get {
            if let isCharging = self.isCharging {
                return isCharging ? self.timeToFull : self.timeToEmpty
            }
            return nil
        }
    }
}

/// Rated wattage of the attached power adapter, i.e. the USB-PD / MagSafe contract that was
/// negotiated — a 65W brick reports 65 even while the battery is only sipping a few watts near
/// full. Returns nil when running on battery, and on Macs whose adapter reports no wattage.
func getAdapterWatts() -> Int? {
    guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
          let watts = details[kIOPSPowerAdapterWattsKey] as? Int,
          watts > 0
    else { return nil }
    return watts
}

/// Health of the Mac's own battery, as the percentage System Settings › Battery calls
/// "Maximum Capacity".
///
/// That figure is powerd's own smoothed number, not a raw capacity ratio, and the IOKit call that
/// exposes it (`IOPSCopyPowerSourcesByTypePrecise`) refuses callers without a private entitlement —
/// the only way an ordinary app can get it is to ask `system_profiler`. That's a subprocess, and
/// battery health moves over weeks, not seconds, so unlike everything else in `getPowerState()` it is
/// not re-read on the 1 s timer: it's refreshed once at launch and twice a day after that, and the
/// last reading is kept in UserDefaults so the badge is right from the first frame of a launch.
///
/// When `system_profiler` yields nothing (no battery, older macOS, a hang) the raw
/// `FullChargeCapacity / DesignCapacity` ratio from the IORegistry is stored instead.
enum BatteryHealth {
    static let refreshInterval: TimeInterval = 12 * 60 * 60

    private static let valueKey = "internalBatteryHealth"
    private static let checkedAtKey = "internalBatteryHealthCheckedAt"
    private static let queue = DispatchQueue(label: "com.lihaoyun6.AirBattery.battery-health")
    private static let lock = NSLock()
    private static var isRunning = false
    private static var timer: Timer?

    /// Last stored reading, nil until the first successful check on this machine.
    static var cached: Int? { ud.object(forKey: valueKey) as? Int }

    /// When `cached` was measured.
    static var checkedAt: Date? {
        let stamp = ud.double(forKey: checkedAtKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Checks now and then every `refreshInterval`. Call once from the app delegate.
    static func start() {
        refresh()
        let t = Timer(timeInterval: refreshInterval, repeats: true) { _ in refresh() }
        t.tolerance = 30 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Runs the check off the main thread and stores the result. A call that lands while one is
    /// already in flight is dropped — there's nothing newer for it to learn.
    static func refresh() {
        lock.lock()
        if isRunning { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        queue.async {
            defer { lock.lock(); isRunning = false; lock.unlock() }
            guard let health = readFromSystemProfiler() ?? readFromIORegistry() else {
                print("⚠️ Battery health unavailable, keeping last reading")
                return
            }
            ud.set(health, forKey: valueKey)
            ud.set(Date().timeIntervalSince1970, forKey: checkedAtKey)
            print("ℹ️ Battery health: \(health)%")
        }
    }

    /// `sppower_battery_health_maximum_capacity` from `system_profiler SPPowerDataType`, e.g. "84%".
    private static func readFromSystemProfiler() -> Int? {
        guard let json = process(path: "/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"], timeout: 20),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]]
        else { return nil }

        for item in items {
            guard let info = item["sppower_battery_health_info"] as? [String: Any],
                  let text = info["sppower_battery_health_maximum_capacity"] as? String,
                  let value = Int(text.filter(\.isNumber)),
                  (1...100).contains(value)
            else { continue }
            return value
        }
        return nil
    }

    private static func readFromIORegistry() -> Int? {
        guard let health = InternalFinder().getInternalBattery()?.health else { return nil }
        return Int(health.rounded())
    }
}

class InternalFinder {
    private var serviceInternal: io_connect_t = 0 // io_object_t
    private var internalChecked: Bool = false
    private var hasInternalBattery: Bool = false

    public init() { }

    public var batteryPresent: Bool {
        get {
            if !self.internalChecked {
                let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
                let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

                self.hasInternalBattery = sources.count > 0
                self.internalChecked = true
            }

            return self.hasInternalBattery
        }
    }

    fileprivate func open() {
        if #available(macOS 12, *) {
            self.serviceInternal = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        } else {
            self.serviceInternal = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
    }

    fileprivate func close() {
        IOServiceClose(self.serviceInternal)
        IOObjectRelease(self.serviceInternal)

        self.serviceInternal = 0
    }

    func getInternalBattery() -> InternalBattery? {
        self.open()

        if self.serviceInternal == 0 {
            return nil
        }

        let battery = self.getBatteryData()

        self.close()

        return battery
    }

    fileprivate func getBatteryData() -> InternalBattery {
        let battery = InternalBattery()

        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for ps in sources {
            // Fetch the information for a given power source out of our snapshot
            let info = IOPSGetPowerSourceDescription(snapshot, ps).takeUnretainedValue() as! Dictionary<String, Any>

            // Pull out the name and capacity
            battery.name = info[kIOPSNameKey] as? String

            battery.timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int
            battery.timeToFull = info[kIOPSTimeToFullChargeKey] as? Int
        }

        // Capacities
        // macOS 27 dropped the mAh keys ("AppleRawMaxCapacity", "DesignCapacity") from the top
        // level of AppleSmartBattery; the same numbers now only live inside its "BatteryData"
        // dictionary as "FullChargeCapacity" / "DesignCapacity". Try the legacy keys first so
        // older systems keep reading exactly what they did, and fall back to the dictionary.
        let batteryData = self.getDictValue("BatteryData" as CFString) ?? [:]
        battery.currentCapacity = self.getIntValue("CurrentCapacity" as CFString)
        battery.maxCapacity = self.getIntValue("MaxCapacity" as CFString)
        battery.rawMaxCapacity = self.getIntValue("AppleRawMaxCapacity" as CFString)
            ?? batteryData["FullChargeCapacity"] as? Int
        battery.designCapacity = self.getIntValue("DesignCapacity" as CFString)
            ?? batteryData["DesignCapacity"] as? Int

        // Battery Cycles
        battery.cycleCount = self.getIntValue("CycleCount" as CFString)
        battery.designCycleCount = self.getIntValue("DesignCycleCount9C" as CFString)

        // Plug
        battery.acPowered = self.getBoolValue("ExternalConnected" as CFString)
        battery.isCharging = self.getBoolValue("IsCharging" as CFString)
        battery.isCharged = self.getBoolValue("FullyCharged" as CFString)

        // Power
        battery.amperage = self.getIntValue("Amperage" as CFString)
        battery.voltage = self.getVoltage()

        // Various
        battery.temperature = self.getTemperature()

        // Manufaction
        battery.manufacturer = self.getStringValue("Manufacturer" as CFString)
        battery.manufactureDate = self.getManufactureDate()

        if let amperage = battery.amperage,
           let volts = battery.voltage, let isCharging = battery.isCharging {
            let factor: CGFloat = isCharging ? 1 : -1
            let watts: CGFloat = (CGFloat(amperage) * CGFloat(volts)) / 1000.0 * factor

            battery.watts = Double(watts)
        }

        return battery
    }

    fileprivate func getIntValue(_ identifier: CFString) -> Int? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, identifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Int
        }

        return nil
    }

    fileprivate func getDictValue(_ identifier: CFString) -> [String: Any]? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, identifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? [String: Any]
        }

        return nil
    }

    fileprivate func getStringValue(_ identifier: CFString) -> String? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, identifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? String
        }

        return nil
    }

    fileprivate func getBoolValue(_ forIdentifier: CFString) -> Bool? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, forIdentifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Bool
        }

        return nil
    }

    fileprivate func getTemperature() -> Double? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, "Temperature" as CFString, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as! Double / 100.0
        }

        return nil
    }

    fileprivate func getDoubleValue(_ identifier: CFString) -> Double? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, identifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Double
        }

        return nil
    }

    fileprivate func getVoltage() -> Double? {
        if let value = getDoubleValue("Voltage" as CFString) {
            return value / 1000.0
        }

        return nil
    }

    fileprivate func getManufactureDate() -> Date? {
        if let value = IORegistryEntryCreateCFProperty(self.serviceInternal, "ManufactureDate" as CFString, kCFAllocatorDefault, 0) {
            let date = value.takeRetainedValue() as! Int

            let day = date & 31
            let month = (date >> 5) & 15
            let year = ((date >> 9) & 127) + 1980

            var components = DateComponents()
            components.calendar = Calendar.current
            components.day = day
            components.month = month
            components.year = year

            return components.date
        }

        return nil
    }
}

