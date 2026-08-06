//
//  AirBatteryApp.swift
//  AirBattery
//
//  Created by apple on 2023/9/4.
//
import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit
import UserNotifications
import IOBluetooth
import Sparkle

let fd = FileManager.default
let ud = UserDefaults.standard
var updaterController: SPUStandardUpdaterController!
var statusBarItem: NSStatusItem!
var pinnedItems = [NSStatusItem]()
var netcastService: MultipeerService = MultipeerService(serviceType: "airbattery-nc")
let ncFolder = fd.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Containers/\(AirBatteryModel.key)/Data/Documents/NearcastData")
let systemUUID = getMacDeviceUUID()
var deviceDropdownWindow = AutoHideWindow()
let bleBattery = BLEBattery()
let btdBattery = BTDBattery()
var updateDelay = 1
var keepAliveActivity: NSObjectProtocol? = nil

@main
struct AirBatteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // If you want to start the updater manually, pass false to startingUpdater and call .startUpdater() later
        // This is where you can also pass an updater delegate if you need one
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        registerNotificationCategory()
    }
    
    /// Standard `Window` scene (System Settings–style chrome). The old `Settings { }` scene is deprecated for this app — it drew an extra title bar / inset frame and misaligned the traffic lights.
    var body: some Scene {
        Window("AirBattery Settings", id: airBatterySettingsWindowId) {
            AirBatterySettingsWindowRoot()
        }
        .defaultSize(width: 780, height: 560)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    //static let shared = AppDelegate()
    @AppStorage("showOn") var showOn = "sbar"
    @AppStorage("machineType") var machineType = "mac"
    @AppStorage("deviceName") var deviceName = "Mac"
    @AppStorage("ncGroupID") var ncGroupID = ""
    @AppStorage("nearCast") var nearCast = false
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("intBattOnStatusBar") var intBattOnStatusBar = true
    @AppStorage("batteryPercent") var batteryPercent = "outside"
    @AppStorage("alertSound") var alertSound = true
    @AppStorage("readBTHID") var readBTHID = true
    @AppStorage("hideLevel") var hideLevel = 100
    @AppStorage("disappearTime") var disappearTime = 20
    @AppStorage("whitelistMode") var whitelistMode = false
    @AppStorage("iosBatteryStyle") var iosBatteryStyle = false
    @AppStorage("updateInterval") var updateInterval = 1
    @AppStorage("carouselMode") var carouselMode = true
    
    //加载旧版设置项
    @AppStorage("alertLevel") var alertLevel = 10
    @AppStorage("fullyLevel") var fullyLevel = 100
    
    //var statusMenu: NSMenu = NSMenu()
    var menu: NSMenu = NSMenu()
    /// Right-click menu for the status bar item. Kept separate from `menu` (the Dock tile menu) because
    /// it's attached to `statusBarItem` on demand and detached again on close, so left-click keeps
    /// opening the device dropdown instead of the menu.
    var statusBarMenu: NSMenu = NSMenu()
    var startTime = Date()
    let nc = NSWorkspace.shared.notificationCenter
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        
        if response.actionIdentifier == "DELAY_30_MIN" {
            let deviceName = response.notification.request.content.userInfo["customInfo"] as? String ?? ""
            lowPowerNoteDelay[deviceName] = Date().timeIntervalSince1970 + 1800
        }
        completionHandler()
    }
    
    /// The SwiftUI settings `Window` is the only document-style window; without this, closing it is treated as “last window closed” and quits the whole app (menu bar item disappears).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 用户点击 Dock 图标时会调用这个方法
        if showOn == "sbar" || showOn == "none" {
            openSettingPanel()
            return false
        }
        if deviceDropdownWindow.isVisible {
            deviceDropdownWindow.dismiss()
        } else {
            presentDeviceDropdown(fromDock: true)
        }
        // Returning true lets AppKit run default reopen handling, which also fronts the SwiftUI settings `Window` — so Dock would show both panels.
        return false
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // default defaults (used if not set)
        ud.register(
            defaults: [
                "showOn": "sbar",
                "machineType": "mac",
                "deviceName": "Mac",
                "launchAtLogin": false,
                "intBattOnStatusBar": true,
                "deviceOnWidget": "",
                "updateInterval": 1,
                "widgetInterval": 0,
                "hideLevel": 90,
                "nearCast": false,
                "readBTHID": true,
                "whitelistMode": false,
                "dropdownTheme": DropdownTheme.adaptive.rawValue,
                "neverRemindMe": [String]()
            ]
        )
        
        updateDelay = updateInterval
        machineType = getMacDeviceType()
        deviceName = getMacDeviceName()
        InternalBattery.status = getPowerState()
        
        if showOn == "dock" || showOn == "both" { NSApp.setActivationPolicy(.regular) }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        menu.addItem(withTitle:"Settings...".local, action: #selector(openSetting), keyEquivalent: "")
        menu.addItem(withTitle:"About AirBattery".local, action: #selector(openAbout), keyEquivalent: "")

        statusBarMenu.delegate = self
        statusBarMenu.addItem(withTitle: "Settings...".local, action: #selector(openSetting), keyEquivalent: "")
        statusBarMenu.addItem(withTitle: "About AirBattery".local, action: #selector(openAbout), keyEquivalent: "")
        statusBarMenu.addItem(.separator())
        statusBarMenu.addItem(withTitle: "Quit AirBattery".local, action: #selector(quitApp), keyEquivalent: "")
        // The status item menu isn't in the responder chain, so each item needs an explicit target.
        for item in statusBarMenu.items { item.target = self }

        //处理旧版偏好设置
        if let alertList = (ud.object(forKey: "alertList") ?? []) as? [String] {
            let alerts: [btAlert] = alertList.map({
                btAlert(name: $0, full: fullyLevel == 100 ? 99 : fullyLevel, fullOn: true, fullSound: alertSound, low: alertLevel, lowOn: true, lowSound: alertSound)
            })
            ud.set([], forKey: "alertList")
            ud.set(object: alerts, forKey: "alertList")
        }
        
        if !fd.fileExists(atPath: ncFolder.path) {
            do {
                try fd.createDirectory(at: ncFolder, withIntermediateDirectories: true, attributes: nil)
                print("ℹ️ Folder created at: \(ncFolder.path)")
            } catch {
                print("⚠️ Failed to create folder: \(error)")
            }
        } else {
            let oldFiles = getFiles(withExtension: "json", in: ncFolder)
            for url in oldFiles { try? fd.removeItem(at: url) }
        }
        
        startTime = Date()
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceIsConnected(notification:fromDevice:)))
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:replyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        //if let window = NSApplication.shared.windows.first { window.close() }
        launchAtLogin = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.lihaoyun6.AirBatteryHelper" }
        print("⚙️ Launch AirBattery at login = \(launchAtLogin)")
        print("⚙️ Icon mode = \(showOn)")
        if ncGroupID != "" { if nearCast { netcastService.resume() } }
        if let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) { SPBluetoothDataModel.shared.data = result }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error { print("⚠️ Notification authorization denied: \(error.localizedDescription)") }
        }
        UNUserNotificationCenter.current().delegate = self
        
        bleBattery.startScan()
        btdBattery.startScan()
        MagicBattery.shared.startScan()
        IDeviceBattery.shared.startScan()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            AirBatteryModel.writeData()
            _ = AirBatteryModel.singleDeviceName()
            WidgetCenter.shared.reloadAllTimelines()
        }
        
        //menu.delegate = self
        //statusMenu.delegate = self
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        //statusBarItem.menu = statusMenu
        if let button = statusBarItem.button {
            button.target = self
            let ib = getPowerState()
            let iconView = NSHostingView(rootView: mainBatteryView())
            if ib.hasBattery && intBattOnStatusBar {
                iconView.frame = NSRect(x: 0, y: 0, width: 42, height: 21.5)
            } else {
                iconView.frame = NSRect(x: 0, y: 0, width: 36, height: 21.5)
            }
            button.image = NSImage()
            button.addSubview(iconView)
            button.frame = iconView.frame
            button.action = #selector(togglePopover(_ :))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusBarItem.isVisible = !(showOn == "dock" || showOn == "none")
        NSApp.dockTile.contentView = NSHostingView(rootView: MultiBatteryView())
        NSApp.dockTile.display()
        if nearCast {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                netcastService.refeshAll()
            }
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let opts: ProcessInfo.ActivityOptions = [.automaticTerminationDisabled, .suddenTerminationDisabled]
        keepAliveActivity = ProcessInfo.processInfo.beginActivity(options: opts, reason: "AirBattery menu bar monitoring")

        if showOn == "dock" || showOn == "both" {
            let tipID = "ab.docktile-power.note"
            let never = ud.object(forKey: "neverRemindMe") as! [String]
            if !never.contains(tipID) {
                let alert = createAlert(title: "AirBattery Tips".local, message: "Displaying AirBattery on the Dock will consume more power, it is better to use Menu Bar mode or Widgets.".local, button1: "Don't remind me again", button2: "OK")
                if alert.runModal() == .alertFirstButtonReturn { ud.setValue(never + [tipID], forKey: "neverRemindMe") }
            }
        }
        
        // Keep the settings `Window` scene off-screen at launch (SwiftUI materializes it; `WindowAccessor` used to `orderFront` it).
        DispatchQueue.main.async {
            orderOutAirBatterySettingsWindow()
        }

        if readBTHID {
            let tipID = "ab.third-party-device.note"
            let never = ud.object(forKey: "neverRemindMe") as! [String]
            if !never.contains(tipID) {
                let alert = createAlert(title: "AirBattery Tips".local, message: "If some of your devices shows battery level in the Bluetooth menu, but AirBattery doesn't find it. Try disconnecting and reconnecting it, and wait a few minutes.".local, button1: "Don't remind me again", button2: "OK")
                if alert.runModal() == .alertFirstButtonReturn { ud.setValue(never + [tipID], forKey: "neverRemindMe") }
            }
            // Bootstrap Enhanced HID scan incrementally with a short initial window
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                LogReader.shared.run(.bootstrap)
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        if let act = keepAliveActivity { ProcessInfo.processInfo.endActivity(act) }

        _ = process(path: "/usr/bin/killall", arguments: ["idevicesyslog"])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    
    @objc func onDisplayWake() {
        if readBTHID {
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                LogReader.shared.run(.wake)
            }
        }
    }
    
    @objc func deviceIsConnected(notification: IOBluetoothUserNotification, fromDevice device: IOBluetoothDevice) {
        if readBTHID {
            let now = Date()
            if now.timeIntervalSince(startTime) >= 10 {
                if let name = device.name, let macAdd = device.addressString {
                    if AirBatteryModel.checkIfBlocked(name: name) { return }
                    //if let prefix = getFirstNCharacters(of: macAdd, count: 8) {
                        print("ℹ️ \(name) (\(macAdd)) connected")
                        DispatchQueue.global(qos: .background).async {
                            usleep(2500000)
                            //if !appleMacPrefix.contains(prefix) {
                            if !device.isAppleDevice {
                                SPBluetoothDataModel.shared.refeshData { _ in
                                    LogReader.shared.run(.connect)
                                    MagicBattery.shared.getIOBTBattery()
                                    MagicBattery.shared.getOtherBTBattery()
                                }
                            } else {
                                if let device = AirBatteryModel.getByName(name) {
                                    if ["Trackpad", "Keyboard", "MMouse", "Mouse"].contains(device.deviceType) {
                                        SPBluetoothDataModel.shared.refeshData { _ in MagicBattery.shared.scanDevices() }
                                    }
                                } else {
                                    SPBluetoothDataModel.shared.refeshData { _ in MagicBattery.shared.scanDevices() }
                                }
                            }
                        }
                    //}
                }
            }
        }
    }
    
    /*func menuWillOpen(_ menu: NSMenu) {
        dockWindow.orderOut(nil)
        var allDevices = AirBatteryModel.getAll()
        let ibStatus = InternalBattery.status
        if ibStatus.hasBattery { allDevices.insert(ib2ab(ibStatus), at: 0) }
        let contentViewSwiftUI = popover(fromDock: false, allDevice: allDevices)
        let contentView = NSHostingView(rootView: contentViewSwiftUI)
        let hiddenRow = AirBatteryModel.getBlackList().count > 0 ? 1 : 0
        let allNearcast = getFiles(withExtension: "json", in: ncFolder)
        var ncCount = 0
        var ncDeviceCount = 0
        for jsonUrl in allNearcast {
            let count = AirBatteryModel.ncGetAll(url: jsonUrl).count
            if count != 0 {
                ncCount += 7
                ncDeviceCount += count
            }
        }
        contentView.frame = NSRect(x: 0, y: 0, width: 352, height: (max(max(allDevices.count,1)+ncDeviceCount,1)+hiddenRow)*37+20+ncCount)
        let menuItem = NSMenuItem()
        menuItem.view = contentView
        statusMenu.removeAllItems()
        statusMenu.addItem(menuItem)
    }*/
    
    @objc func togglePopover(_ sender: Any?) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            showStatusBarMenu()
            return
        }
        if deviceDropdownWindow.isVisible {
            deviceDropdownWindow.dismiss()
        } else {
            presentDeviceDropdown(fromDock: false)
        }
    }
    
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        if let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
           let url = URL(string: urlString) {
            if url.scheme == "airbattery"{
                switch url.host {
                case "writedata" :
                    print("Writing data to disk...")
                    AirBatteryModel.writeData()
                case "reloadwingets" :
                    print("Reloading all widgets...")
                    AirBatteryModel.writeData()
                    WidgetCenter.shared.reloadAllTimelines()
                default: print("Unknow command!")
                }
            }
        }
    }
     
    /// Attaching the menu and re-clicking the button is what makes AppKit draw it as a proper status
    /// item menu (highlighted item, anchored under the icon); `popUp(positioning:)` on the button
    /// loses that. `menuDidClose` detaches it again so the next left click still opens the dropdown.
    private func showStatusBarMenu() {
        deviceDropdownWindow.dismiss()
        statusBarItem.menu = statusBarMenu
        statusBarItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusBarMenu else { return }
        // Clearing it inside the close callback confuses AppKit's menu tracking, so defer a runloop turn.
        DispatchQueue.main.async { statusBarItem.menu = nil }
    }

    @objc func openAbout() {
        openAboutPanel()
    }

    @objc func openSetting() {
        openSettingPanel()
    }

    @objc func quitApp() {
        NSApp.terminate(self)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        deviceDropdownWindow.dismiss()
        return menu
    }
}

/// Builds and shows the transparent Liquid Glass device dropdown. Replaces the old `NSPopover`
/// (status bar) and inline window-building code (Dock) with one shared borderless-window
/// presenter, since `NSPopover`'s system chrome can't be made transparent for the capsule design.
func presentDeviceDropdown(fromDock: Bool) {
    orderOutAirBatterySettingsWindow()
    deviceDropdownWindow.dismiss() // tear down the previous presentation's monitors
    var allDevices = AirBatteryModel.getAll()
    let ibStatus = InternalBattery.status
    if ibStatus.hasBattery { allDevices.insert(ib2ab(ibStatus), at: 0) }

    var deviceCount = allDevices.count
    if ud.bool(forKey: "nearCast") {
        for jsonUrl in getFiles(withExtension: "json", in: ncFolder) {
            deviceCount += AirBatteryModel.ncGetAll(url: jsonUrl).count
        }
    }
    let panelSize = NSSize(width: dropdownPanelWidth, height: estimatedDropdownHeight(deviceCount: deviceCount))
    let origin = fromDock ? dockAnchoredDropdownOrigin(panelSize: panelSize) : statusBarAnchoredDropdownOrigin(panelSize: panelSize)
    let frame = NSRect(origin: origin, size: panelSize)

    // Reuse the window and hosting view rather than rebuilding them per open. Constructing a fresh
    // window each time forced the glass to re-establish and re-sample its backdrop from scratch,
    // which is what made the panel take a beat to settle to the right colour every time it opened.
    let contentView = configuredDropdownHostingView()
    // Re-applied on every presentation so a change in Settings takes effect the next time the panel
    // opens. `nil` (adaptive) restores inheritance, so switching back off light/dark is not sticky.
    deviceDropdownWindow.appearance = DropdownTheme.current().nsAppearance
    contentView.rootView = popover(fromDock: fromDock, allDevice: allDevices)
    deviceDropdownWindow.title = fromDock ? "AirBattery Dock Window" : "AirBattery Menu Bar Window"
    deviceDropdownWindow.setFrame(frame, display: false)
    contentView.frame = NSRect(origin: .zero, size: panelSize)
    // Lay out and render before the window is shown, so the first frame the user sees is already
    // sampled against the current backdrop instead of adapting after it appears.
    contentView.layoutSubtreeIfNeeded()
    deviceDropdownWindow.displayIfNeeded()
    deviceDropdownWindow.makeKeyAndOrderFront(nil)
    deviceDropdownWindow.installDismissMonitors()
}

private var dropdownHostingView: NSHostingView<popover>?

/// Creates the panel's hosting view on first use and configures the shared window once.
private func configuredDropdownHostingView() -> NSHostingView<popover> {
    if let existing = dropdownHostingView { return existing }

    let view = NSHostingView(rootView: popover(fromDock: false, allDevice: []))
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor

    // `.nonactivatingPanel` lets the panel take key focus without activating AirBattery, so its
    // glass materials render in the active (coloured, live-blur) state — see `AutoHideWindow`.
    deviceDropdownWindow.styleMask = [.nonactivatingPanel, .fullSizeContentView]
    deviceDropdownWindow.becomesKeyOnlyIfNeeded = false
    deviceDropdownWindow.hidesOnDeactivate = false
    deviceDropdownWindow.level = .popUpMenu
    // Fully transparent: there is no panel backdrop, so the capsules float directly over the
    // desktop and each carries its own glass. `hasShadow` is off because AppKit would otherwise
    // cast a rectangular window shadow around the empty area between the floating capsules.
    deviceDropdownWindow.isOpaque = false
    deviceDropdownWindow.backgroundColor = NSColor.clear
    deviceDropdownWindow.hasShadow = false
    deviceDropdownWindow.contentView = view

    dropdownHostingView = view
    return view
}

/// Positions the dropdown near the Dock click point, clamped per the Dock's screen edge (same
/// orientation-aware clamping the old inline Dock window code used).
private func dockAnchoredDropdownOrigin(panelSize: NSSize) -> NSPoint {
    let mouse = NSEvent.mouseLocation
    var menuX = mouse.x
    var menuY = mouse.y
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else {
        return NSPoint(x: menuX, y: menuY)
    }
    let visibleFrame = screen.visibleFrame
    var dockOrientation = "bottom"
    if let defaults = UserDefaults(suiteName: "com.apple.dock"), let orientation = defaults.string(forKey: "orientation") { dockOrientation = orientation }
    switch dockOrientation {
    case "bottom":
        if menuX + 186 > visibleFrame.maxX {
            menuX = visibleFrame.maxX - panelSize.width - 10
        } else if menuX - 166 < visibleFrame.minX {
            menuX = visibleFrame.minX + 10
        } else {
            menuX = menuX - 176
        }
        menuY = max(menuY, visibleFrame.origin.y) + 20
    case "right":
        menuX = menuX + panelSize.width - 10 > visibleFrame.maxX ? visibleFrame.maxX - panelSize.width - 20 : menuX + 10
        menuY = max(menuY - panelSize.height / 2, visibleFrame.origin.y)
    case "left":
        menuX = menuX + panelSize.width - 10 > visibleFrame.maxX ? visibleFrame.maxX - panelSize.width - 20 : menuX
        menuX = menuX < visibleFrame.origin.x ? visibleFrame.origin.x + 20 : menuX + 10
        menuY = max(menuY - panelSize.height / 2, visibleFrame.origin.y)
    default:
        print("⚠️ Failed to get Dock orientation!")
    }
    return NSPoint(x: menuX, y: menuY)
}

/// Positions the dropdown directly under the status bar button, clamped to the active screen —
/// replaces `NSPopover.show(relativeTo:of:preferredEdge:)`.
private func statusBarAnchoredDropdownOrigin(panelSize: NSSize) -> NSPoint {
    guard let button = statusBarItem.button, let buttonWindow = button.window else {
        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x - panelSize.width / 2, y: mouse.y - panelSize.height)
    }
    let buttonFrameInWindow = button.convert(button.bounds, to: nil)
    let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
    var x = buttonFrameOnScreen.midX - panelSize.width / 2
    var y = buttonFrameOnScreen.minY - panelSize.height - 6

    let referenceScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? buttonWindow.screen ?? NSScreen.main
    if let visibleFrame = referenceScreen?.visibleFrame {
        x = min(max(x, visibleFrame.minX + 10), visibleFrame.maxX - panelSize.width - 10)
        y = max(y, visibleFrame.minY + 10)
    }
    return NSPoint(x: x, y: y)
}

class NNSWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
}

/// Borderless dropdown panel that dismisses as soon as focus leaves it, mirroring `NSPopover`'s
/// old `.transient` behavior.
///
/// `resignKey` alone is not enough: AirBattery usually runs as an accessory app
/// (`.accessory` activation policy), so this panel often never becomes key in the first place and
/// therefore never resigns. The event monitors below are what actually make click-outside work —
/// `resignKey` is kept as a backstop for the case where the panel *did* hold focus.
/// An `NSPanel` (not a plain `NSWindow`) specifically so it can carry `.nonactivatingPanel`.
///
/// AirBattery normally runs as an accessory app, so a plain window here never becomes key. macOS
/// then renders every vibrancy/glass material in its *inactive* state — which desaturates the tier
/// colours to grey and collapses the panel's live blur into a flat grey slab. A non-activating
/// panel can take key focus *without* activating the whole app (the same trick `NSPopover` uses for
/// menu-bar UI), so the glass stays live and coloured while the user's frontmost app is untouched.
class AutoHideWindow: NSPanel {
    private var dismissMonitors: [Any] = []

    override var canBecomeKey: Bool {
        return true
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// Starts watching for clicks outside the panel (and for Escape). Safe to call repeatedly.
    func installDismissMonitors() {
        removeDismissMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // Clicks in any other application.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            self?.dismiss()
        }) {
            dismissMonitors.append(global)
        }

        // Clicks elsewhere in AirBattery itself. Clicks landing in the panel keep it open, and
        // clicks on the status item are left to `togglePopover` — dismissing here too would let it
        // immediately reopen the panel it just closed.
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self && event.window !== statusBarItem?.button?.window {
                self.dismiss()
            }
            return event
        }) {
            dismissMonitors.append(local)
        }

        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                return nil
            }
            return event
        }) {
            dismissMonitors.append(escape)
        }
    }

    private func removeDismissMonitors() {
        for monitor in dismissMonitors { NSEvent.removeMonitor(monitor) }
        dismissMonitors.removeAll()
    }

    /// Hides the panel and stops the monitors. Idempotent.
    func dismiss() {
        removeDismissMonitors()
        orderOut(nil)
    }

    deinit {
        removeDismissMonitors()
    }
}

extension NSImage {
    func resized(to maxSize: NSSize) -> NSImage {
        let aspectWidth = maxSize.width / self.size.width
        let aspectHeight = maxSize.height / self.size.height
        let aspectRatio = min(aspectWidth, aspectHeight)
        
        let newSize = NSSize(width: self.size.width * aspectRatio, height: self.size.height * aspectRatio)
        
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .sourceOver,
                  fraction: 1.0)
        newImage.unlockFocus()
        
        return newImage
    }
}

public extension UserDefaults {
    func set<T: Codable>(object: T, forKey: String) {
        if let jsonData = try? JSONEncoder().encode(object) {
            set(jsonData, forKey: forKey)
        }
    }
    
    func get<T: Codable>(objectType: T.Type, forKey: String) -> T? {
        guard let result = value(forKey: forKey) as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(objectType, from: result)
    }
}

func refeshPinnedBar(unpin: String? = nil) {
    var pinnedList = (ud.object(forKey: "pinnedList") ?? []) as! [String]
    if pinnedList.isEmpty { return }
    if let unpin = unpin { pinnedList.removeAll(where: { $0 == unpin }) }
    var allDevices = AirBatteryModel.getAll()
    let ncFiles = getFiles(withExtension: "json", in: ncFolder)
    for ncFile in ncFiles { allDevices += AirBatteryModel.ncGetAll(url: ncFile) }
    let pinnedDevices = allDevices.filter({ pinnedList.contains($0.deviceName) })
    let deviceNames = pinnedDevices.map({ $0.deviceName })
    for device in pinnedDevices {
        if let index = pinnedItems.firstIndex(where: { $0.button?.toolTip == device.deviceName }) {
            pinnedItems[index].button?.title = "\(device.batteryLevel)\(device.isCharging != 0  ? "⚡︎" : "%")"
        } else {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem.button {
                let icon = getDeviceIcon(device)
                let image = NSImage(named: icon)!.resized(to: NSSize(width: 17, height: 17))
                image.isTemplate = true
                button.image = image
                button.title = "\(device.batteryLevel)\(device.isCharging != 0  ? "⚡︎" : "%")"
                button.toolTip = device.deviceName
            }
            pinnedItems.append(statusItem)
        }
    }
    let expItems = pinnedItems.filter({ !pinnedList.contains($0.button?.toolTip ?? "") || !deviceNames.contains($0.button?.toolTip ?? "") })
    let expNames = expItems.map({ $0.button?.toolTip ?? "" })
    DispatchQueue.main.async { for e in expItems { NSStatusBar.system.removeStatusItem(e) } }
    pinnedItems.removeAll{ expNames.contains($0.button?.toolTip ?? "") }
}

@discardableResult
func ensureLoginItem(enabled: Bool) -> Bool {
    do {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return true
    } catch {
        NSLog("[AirBattery] SMAppService register/unregister failed: \(error.localizedDescription)")
        return false
    }
}

func registerDefaults() {
    UserDefaults.standard.register(defaults: ["LaunchAtLogin": false])
}
