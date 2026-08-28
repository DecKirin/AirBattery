//
//  ContentView.swift
//  AirBattery
//
//  Created by apple on 2023/9/4.
//
import AppKit
import SwiftUI
import WidgetKit
import Combine
//import UserNotifications

/*let test_data: [CGFloat] = [99,80,80,73,70,60,59,51,30,30,25,25,19,18,17,15,12,10,10,9] // 示例数据
struct BarChartView: View {
    let data: [CGFloat] // 电量数据，取值范围 0 到 1
    let barSpacing: CGFloat // 柱子之间的间距
    let barWidth: CGFloat // 柱子宽度

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: barSpacing) { // 设置底部对齐
                ForEach(0..<data.count, id: \.self) { index in
                    let height = (data[index] * geometry.size.height)/100
                    Capsule()
                        .fill(Color(getPowerColor(Int(data[index]))))
                        .frame(width: barWidth, height: height)
                        .padding(.bottom, -barWidth / 2) // 设置底部平坦
                }
            }
        }
    }
}*/

class AppearanceMonitor: ObservableObject {
    @Published var isDarkMode: Bool = false
    private var appearanceChangeCancellable: AnyCancellable?

    init() {
        updateAppearance()
        appearanceChangeCancellable = NotificationCenter.default.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                self?.updateAppearance()
            }
    }
    private func updateAppearance() {
        let appearance = NSApp.effectiveAppearance
        isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

struct MultiBatteryView: View {
    @AppStorage("showThisMac") var showThisMac = "icon"
    @AppStorage("carouselMode") var carouselMode = true
    @AppStorage("appearance") var appearance = "auto"
    @AppStorage("showOn") var showOn = "sbar"
    @AppStorage("widgetInterval") var widgetInterval = 0
    @AppStorage("readBTHID") var readBTHID = true
    @AppStorage("deviceName") var deviceName = "Mac"
    @AppStorage("nearCast") var nearCast = false
    @AppStorage("ncGroupID") var ncGroupID = ""
    
    @StateObject private var appearanceMonitor = AppearanceMonitor()

    @State private var rollCount = 1
    @State private var darkMode = getDarkMode()
    @State private var lastTime = Double(Date().timeIntervalSince1970)
    @State private var batteryList = AirBatteryModel.getAll()
    @State private var lineWidth = 6.0
    
    var body: some View {
        ZStack {
            Group{
                Image(darkMode ? "background_dark" : "background")
                RoundedRectangle(cornerRadius: 23.5, style: RoundedCornerStyle.continuous)
                    .strokeBorder(darkMode ? .white : .black, lineWidth: 2)
                    .frame(width: 104, height: 104)
                    .opacity(darkMode ? 0.25 : 0.0)
                RoundedRectangle(cornerRadius: 23.5, style: RoundedCornerStyle.continuous)
                    .strokeBorder(.black, lineWidth: 1)
                    .frame(width: 104, height: 104)
                    .opacity(darkMode ? 0.55 : 0.2)
            }
            if batteryList.count < 4 {
                Circle()
                    .trim(from: 0.0, to: 0.75)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth*1.2, lineCap: .round, lineJoin: .round))
                    .foregroundColor(darkMode ? .white : .black)
                    .opacity(darkMode ? 0.2 : 0.13)
                    .rotationEffect(Angle(degrees: 135))
                    .offset(x:-24, y: -24)
                    .frame(width: 38, height: 38, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(batteryList[0..<2], id: \.self) { item in
                            ZStack {
                                Group {
                                    Group {
                                        Circle()
                                            .trim(from: 0.0, to: 0.75)
                                            .stroke(style: StrokeStyle(lineWidth: lineWidth*1.2, lineCap: .round, lineJoin: .round))
                                            .foregroundColor(darkMode ? .white : .black)
                                            .opacity(darkMode ? 0.2 : 0.13)
                                        Circle()
                                            .trim(from: CGFloat(abs((min(Double(item.batteryLevel)/100.0*0.75, 0.75))-0.001)), to: CGFloat(abs((min(Double(item.batteryLevel)/100.0*0.75, 0.75))-0.0005)))
                                            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                                            .foregroundColor(Color(getPowerColor(item)))
                                            .shadow(color: .black, radius: lineWidth*0.76, x: 0, y: 0)
                                            .clipShape(
                                                Circle()
                                                    .trim(from: 0.0, to: 0.75)
                                                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                                            )
                                            .opacity(item.batteryLevel == 100 ? 0 : 1)
                                        Circle()
                                            .trim(from: 0.0, to: Double(item.batteryLevel)/100.0*0.75)
                                            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                                            .foregroundColor(Color(getPowerColor(item)))
                                    }.rotationEffect(Angle(degrees: 135))
                                    
                                    if item.deviceType.contains("mac") && showThisMac == "percent"{
                                        Text(String(item.batteryLevel))
                                            .colorScheme(darkMode ? .dark : .light)
                                            .foregroundColor(item.isCharging != 0 ? Color("dark_"+getPowerColor(item)) : .blackWhite)
                                            .font(.custom("Helvetica-Bold", size: item.batteryLevel>99 ? 32 : 42))
                                            .frame(width: 100, alignment: .center)
                                            .scaleEffect(0.5)
                                            .offset(x:-0.2, y:1.5)
                                        
                                    } else {
                                        Image(getDeviceIcon(item))
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .colorScheme(darkMode ? .dark : .light)
                                            .foregroundColor(item.isCharging != 0 ? Color("dark_"+getPowerColor(item)) : .blackWhite)
                                            .offset(y:-1)
                                            .frame(width: 44, height: 43, alignment: .center)
                                            .scaleEffect(0.5)
                                    }
                                }.frame(width: 38, height: 38, alignment: .center)
                                Text(item.hasBattery ? "\(item.batteryLevel)" : "")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(darkMode ? .white : .black)
                                    .scaleEffect(0.5)
                                    .offset(y: 17)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(batteryList[2..<4], id: \.self) { item in
                            ZStack {
                                Group {
                                    Group {
                                        Circle()
                                            .trim(from: 0.0, to: 0.75)
                                            .stroke(style: StrokeStyle(lineWidth: lineWidth*1.2, lineCap: .round, lineJoin: .round))
                                            .foregroundColor(darkMode ? .white : .black)
                                            .opacity(darkMode ? 0.2 : 0.13)
                                        Circle()
                                            .trim(from: CGFloat(abs((min(Double(item.batteryLevel)/100.0*0.75, 0.75))-0.001)), to: CGFloat(abs((min(Double(item.batteryLevel)/100.0*0.75, 0.75))-0.0005)))
                                            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                                            .foregroundColor(Color(getPowerColor(item)))
                                            .shadow(color: .black, radius: lineWidth*0.76, x: 0, y: 0)
                                            .clipShape(
                                                Circle()
                                                    .trim(from: 0.0, to: 0.75)
                                                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                                            )
                                            .opacity(item.batteryLevel == 100 ? 0 : 1)
                                        Circle()
                                            .trim(from: 0.0, to: Double(item.batteryLevel)/100.0*0.75)
                                            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                                            .foregroundColor(Color(getPowerColor(item)))
                                    }.rotationEffect(Angle(degrees: 135))
                                    Image(getDeviceIcon(item))
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .colorScheme(darkMode ? .dark : .light)
                                        .foregroundColor(item.isCharging != 0 ? Color("dark_"+getPowerColor(item)) : .blackWhite)
                                        .offset(y:-1)
                                        .frame(width: 44, height: 43, alignment: .center)
                                        .scaleEffect(0.5)
                                }.frame(width: 38, height: 38, alignment: .center)
                                Text(item.hasBattery ? "\(item.batteryLevel)" : "")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(darkMode ? .white : .black)
                                    .scaleEffect(0.5)
                                    .offset(y: 17)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 128, height: 128, alignment: .center)
        .onChange(of: appearanceMonitor.isDarkMode) { newValue in
            darkMode = newValue
            scheduleDockTileDisplay()
        }
        .onChange(of: appearance) { _ in
            darkMode = getDarkMode()
            scheduleDockTileDisplay()
        }
        .onReceive(alertTimer) {_ in batteryAlert() }
        .onReceive(widgetViewTimer) {_ in
            if widgetInterval != -1 { WidgetCenter.shared.reloadAllTimelines() }
        }
        .onReceive(ideviceScanTimer) { _ in
            IDeviceBattery.shared.scanDevices()
        }
        .onReceive(widgetDataTimer) {_ in
            SPBluetoothDataModel.shared.refeshData (completion: { result in
                DispatchQueue.global(qos: .background).async {
                    MagicBattery.shared.scanDevices()
                    AirBatteryModel.writeData()
                }
            }, error: {
                // system_profiler failed or timed out. The IOKit-backed Magic scans don't depend
                // on it (they only consult the cached JSON for friendly names/types, and fall back
                // cleanly), so still rescan — otherwise one flaky system_profiler run starves
                // Magic Mouse/Keyboard/Trackpad until they age out via `disappearTime`.
                DispatchQueue.global(qos: .background).async {
                    MagicBattery.shared.scanDevices()
                    AirBatteryModel.writeData()
                }
            })
        }
        .onReceive(nearCastTimer) {_ in
            if nearCast && ncGroupID != ""{
                var allDevices = AirBatteryModel.getAll()
                allDevices.insert(ib2ab(InternalBattery.status), at: 0)
                do {
                    let jsonData = try JSONEncoder().encode(allDevices)
                    guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
                    guard let data = encryptString(jsonString, password: ncGroupID) else { return }
                    let message = NCMessage(id: String(ncGroupID.prefix(15)), sender: systemUUID ?? deviceName, command: "", content: data)
                    netcastService.sendMessage(message)
                } catch {
                    print("Write JSON error：\(error)")
                }
            }
        }
        .onReceive(dockTimer) { t in
            guard showOn == "both" || showOn == "dock" else { return }
            var list = AirBatteryModel.getAll()
            let ncFiles = getFiles(withExtension: "json", in: ncFolder)
            for ncFile in ncFiles { list += AirBatteryModel.ncGetAll(url: ncFile) }
            let ibStatus = InternalBattery.status
            let now = Double(t.timeIntervalSince1970)

            if !carouselMode { rollCount = 1 }
            if ibStatus.hasBattery && showThisMac != "hidden" { list.insert(ib2ab(ibStatus), at: 0) }

            batteryList = sliceList(data: list, length: 4, count: rollCount)
            if batteryList.isEmpty {
                rollCount = 1
                batteryList = sliceList(data: list, length: 4, count: rollCount)
            }

            if now - lastTime >= 20 && list.count > 4 && carouselMode {
                lastTime = now
                rollCount = rollCount + 1
            }
            scheduleDockTileDisplay()
        }
    }
}

struct BlurView: NSViewRepresentable {
    
    private let material: NSVisualEffectView.Material
    
    init(material: NSVisualEffectView.Material) {
        self.material = material
    }
    
    func makeNSView(context: Context) -> some NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSViewType, context: Context) {
        nsView.material = material
    }
}

/// Transparent Liquid Glass device dropdown, shared by the status-bar and Dock entry points.
/// Each device renders as a `DeviceCapsuleView`; window-level chrome (blur/glass, transparency,
/// sizing) is owned by `presentDeviceDropdown(fromDock:)` in AirBatteryApp.swift.
struct popover: View {
    var fromDock: Bool = false
    var allDevice: [Device]

    @AppStorage("nearCast") var nearCast = false

    @State private var allDevices = [Device]()
    @State private var alertList = ud.get(objectType: [btAlert].self, forKey: "alertList") ?? []
    @State private var pinnedList = (ud.object(forKey: "pinnedList") ?? []) as! [String]
    @State private var allNearcast = getFiles(withExtension: "json", in: ncFolder)
    @State private var hoveredDeviceName: String? = nil

    private var mergedDevices: [Device] {
        guard nearCast else { return allDevices }
        var list = allDevices
        for url in allNearcast { list += AirBatteryModel.ncGetAll(url: url) }
        return list
    }

    private let columns = [GridItem(.flexible(), spacing: dropdownGridSpacing), GridItem(.flexible(), spacing: dropdownGridSpacing)]

    var body: some View {
        VStack(spacing: dropdownToolbarSpacing) {
            toolbar
            if mergedDevices.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: dropdownGridSpacing) {
                    ForEach(mergedDevices, id: \.deviceName) { device in
                        DeviceCapsuleView(
                            device: device,
                            isHovered: hoveredDeviceName == device.deviceName,
                            isAlerting: alertList.map({ $0.name }).contains(device.deviceName),
                            isPinned: pinnedList.contains(device.deviceName),
                            onHoverChanged: { hovering in
                                hoveredDeviceName = hovering ? device.deviceName : (hoveredDeviceName == device.deviceName ? nil : hoveredDeviceName)
                            },
                            onToggleAlert: { toggleAlert(for: device) },
                            onTogglePin: { togglePin(for: device) },
                            onCopyName: { copyName(device) },
                            onHide: { hideDevice(device) }
                        )
                    }
                }
            }
        }
        .padding(dropdownOuterPadding)
        .frame(width: dropdownPanelWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Publishes the selected theme so the capsules can opt out of backdrop-sampling glass and
        // vibrancy inks when pinned — `NSAppearance` on the window only fixes the first frame.
        .modifier(DropdownThemeEnvironment())
        // No panel backdrop: the capsules and toolbar buttons carry their own glass and float
        // directly over the desktop. Anything drawn here would re-introduce the container look.
        .background(Color.clear)
        .onAppear { allDevices = allDevice }
        .onReceive(mainTimer) { _ in
            allDevices = AirBatteryModel.getAll()
            let ibStatus = InternalBattery.status
            if ibStatus.hasBattery { allDevices.insert(ib2ab(ibStatus), at: 0) }
            if nearCast { allNearcast = getFiles(withExtension: "json", in: ncFolder) }
            alertList = ud.get(objectType: [btAlert].self, forKey: "alertList") ?? []
            pinnedList = (ud.object(forKey: "pinnedList") ?? []) as! [String]
        }
    }

    private var toolbar: some View {
        HStack(spacing: dropdownToolbarSpacing) {
            Spacer()
            CircleGlassButton(systemImage: "gearshape.fill") {
                deviceDropdownWindow.dismiss()
                openSettingPanel()
            }
            powerRing
            if let health = InternalBattery.status.health {
                BatteryHealthRing(health: health) {
                    deviceDropdownWindow.dismiss()
                    openSettingPanel()
                }
            }
            CircleGlassButton(systemImage: "power") {
                if fromDock {
                    deviceDropdownWindow.dismiss()
                } else {
                    NSApp.terminate(self)
                }
            }
            Spacer()
        }
        .frame(height: dropdownToolbarHeight)
    }

    /// Power dial for this Mac's own battery.
    ///
    /// Keyed on `acPowered` rather than `isCharging` so a plugged-in machine that has finished
    /// charging still reports its adapter contract — the protocol is live whether or not current is
    /// flowing. Absent entirely on desktop Macs and whenever IOKit gives us no reading, matching how
    /// the health ring stays out of the toolbar when there is no battery to describe.
    @ViewBuilder
    private var powerRing: some View {
        let ib = InternalBattery.status
        if ib.hasBattery {
            if ib.acPowered, let adapter = ib.adapterWatts {
                PowerWattageRing(watts: Double(adapter),
                                 progress: Double(adapter) / maxAdapterWatts,
                                 help: "\("Charging Power".local): \(adapter)W") {
                    deviceDropdownWindow.dismiss()
                    openSettingPanel()
                }
            } else if !ib.acPowered, let draw = ib.powerWatts, draw > 0 {
                PowerWattageRing(watts: draw,
                                 progress: nil,
                                 help: String(format: "%@: %.1fW", "Power Usage".local, draw)) {
                    deviceDropdownWindow.dismiss()
                    openSettingPanel()
                }
            }
        }
    }

    private var emptyState: some View {
        let ib = ib2ab(InternalBattery.status)
        return HStack(spacing: dropdownScaled(8)) {
            Image(getDeviceIcon(ib))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: dropdownScaled(20), height: dropdownScaled(20), alignment: .center)
            Text(ib.deviceName)
                .font(.system(size: dropdownScaled(12)))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, dropdownScaled(10))
        .padding(.horizontal, dropdownScaled(16))
        .chromeGlassBackground(in: Capsule(style: .continuous))
    }

    private func toggleAlert(for device: Device) {
        alertList = ud.get(objectType: [btAlert].self, forKey: "alertList") ?? []
        let alertWindowController = AlertWindowController()
        if let existing = alertList.first(where: { $0.name == device.deviceName }) {
            alertWindowController.showAlert(with: existing, iconName: getDeviceIcon(device), onConfirm: { newAlert in
                alertList = ud.get(objectType: [btAlert].self, forKey: "alertList") ?? []
                alertList.removeAll { $0.name == device.deviceName }
                alertList.append(newAlert)
                ud.set(object: alertList, forKey: "alertList")
            }, onCancel: {})
        } else {
            let alert = btAlert(name: device.deviceName, full: 80, fullOn: true, fullSound: true, low: 20, lowOn: true, lowSound: true)
            alertWindowController.showAlert(with: alert, iconName: getDeviceIcon(device), onConfirm: { newAlert in
                alertList = ud.get(objectType: [btAlert].self, forKey: "alertList") ?? []
                alertList.append(newAlert)
                ud.set(object: alertList, forKey: "alertList")
            }, onCancel: {})
        }
    }

    private func togglePin(for device: Device) {
        pinnedList = (ud.object(forKey: "pinnedList") ?? []) as! [String]
        if pinnedList.contains(device.deviceName) {
            pinnedList.removeAll { $0 == device.deviceName }
            ud.set(pinnedList, forKey: "pinnedList")
            refeshPinnedBar(unpin: device.deviceName)
        } else {
            pinnedList.append(device.deviceName)
            ud.set(pinnedList, forKey: "pinnedList")
            refeshPinnedBar()
        }
    }

    private func copyName(_ device: Device) {
        copyToClipboard(device.deviceName)
        DispatchQueue.main.async {
            _ = createAlert(title: "Device Name Copied".local,
                            message: String(format: "Device name \"%@\" has been copied to the clipboard.".local, device.deviceName),
                            button1: "OK".local).runModal()
        }
    }

    private func hideDevice(_ device: Device) {
        var blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        if !blackList.contains(device.deviceName) { blackList.append(device.deviceName) }
        ud.set(blackList, forKey: "blackList")
        allDevices.removeAll { $0.deviceName == device.deviceName }
        if pinnedList.contains(device.deviceName) { refeshPinnedBar() }
    }
}

func openAboutPanel() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
}

func openSettingPanel() {
    deviceDropdownWindow.dismiss()
    openAirBatterySettingsWindow()
}
