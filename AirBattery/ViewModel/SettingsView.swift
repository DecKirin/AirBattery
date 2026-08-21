//
//  SettingsView.swift
//  AirBattery
//
//  Created by apple on 2023/9/7.
//

import SwiftUI
import ServiceManagement
import WidgetKit

// MARK: - Shared settings behavior

fileprivate func applyShowOnValue(_ newValue: String) {
    switch newValue {
    case "sbar":
        statusBarItem.isVisible = true
        for i in pinnedItems { i.isVisible = true }
        NSApp.setActivationPolicy(.accessory)
    case "both":
        statusBarItem.isVisible = true
        for i in pinnedItems { i.isVisible = true }
        NSApp.setActivationPolicy(.regular)
    case "dock":
        statusBarItem.isVisible = false
        for i in pinnedItems { i.isVisible = false }
        NSApp.setActivationPolicy(.regular)
    default:
        statusBarItem.isVisible = false
        for i in pinnedItems { i.isVisible = false }
        NSApp.setActivationPolicy(.accessory)
    }
    if newValue == "dock" || newValue == "both" {
        _ = createAlert(title: "AirBattery Tips".local, message: "Displaying AirBattery on the Dock will consume more power, it is better to use Menu Bar mode or Widgets.".local, button1: "OK").runModal()
    }
}

/// Sidebar panes for the settings window.
enum SettingsPane: String, Hashable, Identifiable, CaseIterable {
    case general
    case display
    case nearbility
    case nearcast
    case widget
    case blocklist
    case debug

    var id: String { rawValue }

    var sidebarTitle: String {
        switch self {
        case .general: "General"
        case .display: "Menu Bar & Dock"
        case .nearbility: "Nearbility"
        case .nearcast: "Nearcast"
        case .widget: "Widget"
        case .blocklist: "Blocklist"
        case .debug: "Debug"
        }
    }

    var sidebarImage: String {
        switch self {
        case .general: "gear"
        case .display: "dock"
        case .nearbility: "nearbility"
        case .nearcast: "nearcast"
        case .widget: "widget"
        case .blocklist: "blacklist"
        case .debug: "debug"
        }
    }

    static func sidebarPanes(includeDebug: Bool) -> [SettingsPane] {
        var panes = Self.allCases.filter { $0 != .debug }
        if includeDebug { panes.append(.debug) }
        return panes
    }
}

@ViewBuilder
private func settingsPaneDetail(for pane: SettingsPane, selection: Binding<SettingsPane>) -> some View {
    switch pane {
    case .general: GeneralView()
    case .display: DisplayView()
    case .nearbility: NearbilityView()
    case .nearcast: NearcastView()
    case .widget: WidgetView()
    case .blocklist: BlacklistView()
    case .debug: DebugView(selectedPane: selection)
    }
}

private struct SettingsNavigationSplit: View {
    @Binding var selection: SettingsPane
    var showDebug: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section {
                    ForEach(SettingsPane.sidebarPanes(includeDebug: showDebug)) { pane in
                        NavigationLink(value: pane) {
                            Label(pane.sidebarTitle, image: pane.sidebarImage)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea(edges: [.top, .leading, .bottom])
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            NavigationStack {
                settingsPaneDetail(for: selection, selection: $selection)
                    .navigationTitle(selection.sidebarTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationSplitViewStyle(.automatic)
    }
}

struct SettingsView: View {
    @State private var selection: SettingsPane = .general
    @AppStorage("showDebug") var showDebug: Bool = false

    var body: some View {
        SettingsNavigationSplit(selection: $selection, showDebug: showDebug)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: showDebug) { enabled in
                if !enabled, selection == .debug {
                    selection = .general
                }
            }
    }
}

struct GeneralView: View {
    @AppStorage("showOn") var showOn = "sbar"
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("showDebug") var showDebug: Bool = false
    @State private var debugCount: Int = 0
    @State private var cltInstalled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        SMLoginItemSetEnabled("com.lihaoyun6.AirBatteryHelper" as CFString, newValue)
                    }
                Picker("Show AirBattery", selection: $showOn) {
                    Text("Dock").tag("dock")
                    Text("Menu Bar").tag("sbar")
                    Text("Both").tag("both")
                    Text("None").tag("none")
                }
                .onChange(of: showOn) { newValue in
                    applyShowOnValue(newValue)
                }
            } header: {
                Text("Startup")
            }
            Section {
                LabeledContent {
                    Button("Open") { openAboutPanel() }
                } label: {
                    Text("About AirBattery")
                }
            } header: {
                Text("About")
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        SInfoButton(tips: "After installation, you can run \"airbattery\" in yor terminal to list all devices.")
                        Button(cltInstalled ? "Uninstall" : "Install") {
                            if cltInstalled {
                                CommandLineTool.uninstall { updateCTL() }
                            } else {
                                CommandLineTool.install { updateCTL() }
                            }
                        }
                    }
                } label: {
                    Text("Command Line Tool")
                }
            }
            .onAppear { cltInstalled = CommandLineTool.isInstalled() }
            Section {
                UpdaterSettingsView(updater: updaterController.updater)
            } header: {
                Text("Update")
            }
            Section {
                CheckForUpdatesView(updater: updaterController.updater)
                    .frame(maxWidth: .infinity, alignment: .center)
            } footer: {
                if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("AirBattery v\(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .onTapGesture {
                            debugCount += 1
                            if debugCount > 9 {
                                debugCount = 0
                                showDebug.toggle()
                            }
                        }
                }
            }
        }
        .formStyle(.grouped)
    }

    func updateCTL() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cltInstalled = CommandLineTool.isInstalled()
        }
    }
}

struct NearbilityView: View {
    @AppStorage("ideviceOverBLE") var ideviceOverBLE = false
    @AppStorage("readBTDevice") var readBTDevice = true
    @AppStorage("readBLEDevice") var readBLEDevice = false
    @AppStorage("readPencil") var readPencil = false
    @AppStorage("readIDevice") var readIDevice = true
    @AppStorage("readBTHID") var readBTHID = true
    @AppStorage("updateInterval") var updateInterval = 1
    @AppStorage("twsMerge") var twsMerge = 5

    var body: some View {
        Form {
            Section {
                Toggle("Discover iOS devices via Network", isOn: $readIDevice)
                    .help("Scan your iPhone / iPad / Apple Watch / VisionPro and other iDevices in your local network.")
                Toggle("Discover iOS devices via Bluetooth", isOn: $ideviceOverBLE)
                    .help("Scan your iPhone and iPad (Cellular) via Bluetooth.")
                Toggle("Discover BT and BLE devices", isOn: $readBTDevice)
                    .help("Get the battery usage of some Bluetooth peripherals like mouse, keyboard, headphone or etc.\n\nIf some of your device is not shown, try enabling \"Discover more BT devices\" or \"Discover more BLE devices\"")
                Toggle("Discover more BT devices", isOn: $readBTHID)
                    .help("Get the battery usage of more third-party Bluetooth devices\n\nBattery data will be updated when devices are reconnected to the Mac or the Mac wakes up.")
                Toggle("Discover more BLE devices", isOn: $readBLEDevice)
                    .tint(.orange)
                    .help("Try to get the battery usage of any Bluetooth device that AirBattery can find\n\nWARNING: This is a BETA feature and may cause unexpected errors!")
                    .onChange(of: readBLEDevice) { newValue in
                        if newValue {
                            _ = createAlert(title: "AirBattery Tips".local, message: "If you see a bluetooth pairing request from any device that isn't yours, add it to your blocklist!".local, button1: "OK").runModal()
                        }
                    }
                Toggle("Apple Pencil from your iPad", isOn: $readPencil)
                    .tint(.orange)
                    .help("Read the battery status of the connected Apple Pencil through your iPad\n(It may take 10 minutes or longer to discover the Pencil for the first time)\n\nWARNING: This is a BETA feature and may drain your iPad's battery faster!")
            } header: {
                Text("Scanner")
            }
            Section {
                SSteper("Refresh Interval (min)", value: $updateInterval, min: 1, max: 99)
                if updateDelay != updateInterval {
                    Text("Relaunch AirBattery to apply this change")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                SSteper("Earbud Merging Threshold", value: $twsMerge, min: 1, max: 99, tips: "If the difference in battery usage between the left and right earbuds is less than this value, AirBattery will show them as one device.")
            } header: {
                Text("Others")
            }
        }
        .formStyle(.grouped)
    }
}

struct NearcastView: View {
    @AppStorage("nearCast") var nearCast = false
    @AppStorage("ncGroupID") var ncGroupID = ""

    var body: some View {
        Form {
            Section {
                Toggle("Enable Nearcast", isOn: $nearCast)
                    .onChange(of: nearCast) { newValue in
                        handleNearCastChange(newValue)
                    }
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Group ID", text: $ncGroupID)
                            .textFieldStyle(.roundedBorder)
                            .disabled(nearCast)
                        Button {
                            ncGroupID = "nc-" + randomString(length: 20)
                        } label: {
                            Image(systemName: ncGroupID.isEmpty ? "plus.circle" : "arrow.clockwise.circle")
                                .font(.system(size: 15, weight: .light))
                        }
                        .buttonStyle(.borderless)
                        .disabled(nearCast)
                        Button(action: { copyOrWarnGroupID() }) {
                            Image("list.clipboard.fill.circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 15, height: 15)
                        }
                        .buttonStyle(.borderless)
                    }
                } label: {
                    Text("Group ID")
                }
            } header: {
                Text("Nearcast")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nearcast will broadcast your battery data within the local network.")
                    Text("Your data has been encrypted using the group id, don't share it with others.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Text(netcastService.transceiver.localPeerId ?? "")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } label: {
                    Text("Local ID")
                }
                LabeledContent {
                    Button("Refresh Now") { netcastService.refeshAll() }
                        .disabled(!nearCast)
                } label: {
                    Text("Peers")
                }
            } header: {
                Text("Peer Info")
            }
        }
        .formStyle(.grouped)
    }

    private func handleNearCastChange(_ newValue: Bool) {
        if newValue {
            if ncGroupID != "" && isGroudIDValid(id: ncGroupID) {
                netcastService.resume()
            } else {
                DispatchQueue.main.async { nearCast = false; ncGroupID = "" }
                _ = createAlert(
                    title: "Invalid group ID".local,
                    message: "Please create or enter a valid Group ID before use!",
                    button1: "OK".local
                ).runModal()
            }
        } else {
            netcastService.stop()
        }
    }

    private func copyOrWarnGroupID() {
        if ncGroupID != "" && isGroudIDValid(id: ncGroupID) {
            copyToClipboard(ncGroupID)
            _ = createAlert(title: "Group ID Copied".local,
                            message: String(format: "Group ID has been copied to the clipboard.".local, ncGroupID),
                            button1: "OK".local).runModal()
        } else {
            DispatchQueue.main.async { ncGroupID = "" }
            _ = createAlert(
                title: "Invalid group ID".local,
                message: "Please create or enter a valid Group ID before use!",
                button1: "OK".local
            ).runModal()
        }
    }
}

/// Applies an `NSAppearance` to hosted SwiftUI content the same way `presentDeviceDropdown` applies
/// it to the panel window, so the Liquid Glass in the preview resolves exactly as it will in the
/// real dropdown. A SwiftUI `.preferredColorScheme` is not equivalent — it sets the colour-scheme
/// environment, but the glass materials follow `NSAppearance`, so the preview would disagree with
/// the panel it is previewing.
private struct ThemedGlassPreview<Content: View>: NSViewRepresentable {
    var appearance: NSAppearance?
    var content: Content

    init(appearance: NSAppearance?, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.content = content()
    }

    /// Click-through: an `NSViewRepresentable`'s AppKit view does its own hit testing, which a
    /// SwiftUI `.allowsHitTesting(false)` on the enclosing view does not necessarily suppress. The
    /// preview is decorative, so it should never take a mouse event.
    final class ClickThroughHostingView: NSHostingView<Content> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = ClickThroughHostingView(rootView: content)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.appearance = appearance
        nsView.rootView = content
    }
}

/// Loaded once — the wallpaper is only a backdrop for the preview and re-reading a 5K image on
/// every body evaluation would be wasteful.
private enum DesktopPicture {
    static let image: NSImage? = {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }()
}

/// The backdrop both dropdown previews float over. The wallpaper matters: adaptive mode is
/// *defined* by what sits behind the panel, so against a flat swatch it would look identical to the
/// system mode and the preview would not actually show you the difference you are choosing between.
private struct DesktopBackdrop: View {
    var body: some View {
        if let wallpaper = DesktopPicture.image {
            Image(nsImage: wallpaper).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.34),
                                    Color(red: 0.42, green: 0.34, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Framing shared by both dropdown previews: clip to a rounded card, keep the `.scaledToFill()`
/// wallpaper's invisible overflow from eating clicks meant for the pickers above, and stay out of
/// the accessibility tree.
///
/// `.clipShape` clips drawing but NOT hit testing. The wallpaper renders far taller than the frame
/// (a 1894x1065 picture in a 460x104 box draws 460x259) and its overflow spilled ~77pt upward, over
/// the Theme picker — later Form rows paint above earlier ones, so the picker rendered normally but
/// never received a click. `.contentShape` confines the hit region to the visible rounded rect; the
/// previews are decorative, so they opt out of hit testing entirely as well.
private struct PreviewCard: ViewModifier {
    var height: CGFloat
    var label: String

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

/// Two representative capsules rendered by the real `DeviceCapsuleView`, over the current desktop
/// picture.
private struct DropdownThemePreview: View {
    var theme: DropdownTheme

    private var sampleDevices: [Device] {
        let now = Date().timeIntervalSince1970
        return [
            // Real `deviceType`/`deviceModel` values, not invented ones, so `getDeviceIcon` and the
            // capsule subtitle resolve exactly as they do in the live panel. An unrecognised type
            // renders a "?" badge, and a missing model makes the subtitle fall back to the raw
            // type token ("ap_case").
            // The Mac icon comes from the real `macID`, so `deviceModel` here only feeds the
            // subtitle — a readable string rather than a raw "Mac15,3" identifier.
            Device(deviceID: "preview-mac", deviceType: "macbookpro", deviceName: "MacBook Pro", deviceModel: "MacBook Pro", batteryLevel: 76, isCharging: 0, lastUpdate: now),
            Device(deviceID: "preview-pods", deviceType: "ap_case", deviceName: "AirPods Pro", deviceModel: "Airpods Pro", batteryLevel: 28, isCharging: 0, lastUpdate: now)
        ]
    }

    var body: some View {
        ZStack {
            DesktopBackdrop()
            ThemedGlassPreview(appearance: theme.nsAppearance) {
                HStack(spacing: dropdownGridSpacing) {
                    ForEach(sampleDevices, id: \.deviceName) { device in
                        DeviceCapsuleView(
                            device: device,
                            isHovered: false,
                            isAlerting: false,
                            isPinned: false,
                            onHoverChanged: { _ in },
                            onToggleAlert: {},
                            onTogglePin: {},
                            onCopyName: {},
                            onHide: {}
                        )
                    }
                }
                .padding(.horizontal, dropdownOuterPadding)
                .padding(.vertical, dropdownOuterPadding - dropdownBadgeOverlap / 2)
                // Same opt-out as the real panel, driven by the theme being previewed rather than
                // the stored one, so the preview matches what the picker is currently showing.
                .modifier(DropdownThemeEnvironment(override: theme))
            }
        }
        .modifier(PreviewCard(height: dropdownCapsuleCellHeight + dropdownOuterPadding * 2 - dropdownBadgeOverlap,
                              label: "Preview of the device dropdown"))
    }
}

/// The dropdown's toolbar row, rendered by the real dial views, so the unit picker is previewed on
/// the only elements it actually changes.
///
/// The sample readings are fixed rather than taken from `InternalBattery.status`: a desktop Mac has
/// no dials to show at all, and even on a laptop the live wattage would swing while you are trying
/// to compare the three styles. 96W plugged in exercises the ringed dial, which is the tighter of
/// the two layouts for a unit marker to fit into.
private struct DropdownUnitStylePreview: View {
    var theme: DropdownTheme
    var unitStyle: DropdownUnitStyle

    var body: some View {
        ZStack {
            DesktopBackdrop()
            ThemedGlassPreview(appearance: theme.nsAppearance) {
                HStack(spacing: dropdownToolbarSpacing) {
                    CircleGlassButton(systemImage: "gearshape.fill") {}
                    PowerWattageRing(watts: 96,
                                     progress: 96 / maxAdapterWatts,
                                     help: "") {}
                    BatteryHealthRing(health: 92) {}
                    CircleGlassButton(systemImage: "power") {}
                }
                .padding(dropdownOuterPadding - 6)
                .modifier(DropdownThemeEnvironment(override: theme, unitOverride: unitStyle))
            }
        }
        .modifier(PreviewCard(height: dropdownToolbarButtonSize + (dropdownOuterPadding - 6) * 2,
                              label: "Preview of the dropdown toolbar dials"))
    }
}

struct DisplayView: View {
    @AppStorage("appearance") var appearance = "auto"
    @AppStorage("dropdownTheme") var dropdownTheme = DropdownTheme.adaptive.rawValue
    @AppStorage("dropdownUnitStyle") var dropdownUnitStyle = DropdownUnitStyle.watermark.rawValue
    @AppStorage("showThisMac") var showThisMac = "icon"
    @AppStorage("carouselMode") var carouselMode = true
    @AppStorage("colorfulBattery") var colorfulBattery = false
    @AppStorage("iosBatteryStyle") var iosBatteryStyle = false
    @AppStorage("intBattOnStatusBar") var intBattOnStatusBar = true
    @AppStorage("batteryPercent") var batteryPercent = "outside"
    @AppStorage("hideLevel") var hideLevel = 100
    @AppStorage("disappearTime") var disappearTime = 20
    @State private var levelList = [95, 90, 80, 70, 60, 50, 40, 30, 20, 10]

    private var selectedDropdownTheme: DropdownTheme {
        DropdownTheme(rawValue: dropdownTheme) ?? .adaptive
    }

    private var selectedDropdownUnitStyle: DropdownUnitStyle {
        DropdownUnitStyle(rawValue: dropdownUnitStyle) ?? .watermark
    }

    var body: some View {
        Form {
            Section {
                Toggle("Dynamic Battery Icon", isOn: $intBattOnStatusBar)
                Toggle("Colorful Battery Icon", isOn: $colorfulBattery)
                    .disabled(!intBattOnStatusBar)
                Picker("Battery Icon Style", selection: $iosBatteryStyle) {
                    Text("macOS").tag(false)
                    Text("iOS").tag(true)
                }
                .disabled(!intBattOnStatusBar)
                Picker("Show Percentage", selection: $batteryPercent) {
                    Text("Hidden").tag("hide")
                    Text("Inside").tag("inside")
                    Text("Outside").tag("outside")
                }
                .disabled(!intBattOnStatusBar)
                Picker("Remove Offline Device", selection: $disappearTime) {
                    Text("Never").tag(UInt32.max)
                    Text("after 20min").tag(20)
                    Text("after 40min").tag(40)
                    Text("after 60min").tag(60)
                }
                Picker("Hide percentage when above", selection: $hideLevel) {
                    Text("Never").tag(100)
                    ForEach(levelList, id: \.self) { number in
                        Text("\(number)%").tag(number)
                    }
                    if !levelList.contains(hideLevel) && hideLevel != 100 {
                        Text("\(hideLevel)%").tag(hideLevel)
                    }
                }
                .disabled(!intBattOnStatusBar || (batteryPercent == "hide"))
            } header: {
                Text("Menu Bar")
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Automatic").tag("auto")
                    Text("Light").tag("false")
                    Text("Dark").tag("true")
                }
                .pickerStyle(.segmented)
                Picker("Built-in Battery Style", selection: $showThisMac) {
                    Text("Hidden").tag("hidden")
                    Text("Device Icon").tag("icon")
                    Text("Percent").tag("percent")
                }
                .help("Show or hide this Mac's built-in battery in the Dock icon")
                Toggle("Carousel Mode", isOn: $carouselMode)
                    .help("Cycle through all found devices in the Dock icon")
            } header: {
                Text("Dock")
            }
            Section {
                Picker("Theme", selection: $dropdownTheme) {
                    Text("Adaptive").tag(DropdownTheme.adaptive.rawValue)
                    Text("System").tag(DropdownTheme.system.rawValue)
                    Text("Light").tag(DropdownTheme.light.rawValue)
                    Text("Dark").tag(DropdownTheme.dark.rawValue)
                }
                .pickerStyle(.segmented)
                Text(LocalizedStringKey(selectedDropdownTheme.helpText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DropdownThemePreview(theme: selectedDropdownTheme)
                    .padding(.vertical, 4)
                Picker("Dial Unit", selection: $dropdownUnitStyle) {
                    Text("Hidden").tag(DropdownUnitStyle.hidden.rawValue)
                    Text("Watermark").tag(DropdownUnitStyle.watermark.rawValue)
                    Text("Badge").tag(DropdownUnitStyle.badge.rawValue)
                }
                .pickerStyle(.segmented)
                .help("How the toolbar dials label their unit (W, %)")
                Text(LocalizedStringKey(selectedDropdownUnitStyle.helpText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DropdownUnitStylePreview(theme: selectedDropdownTheme,
                                         unitStyle: selectedDropdownUnitStyle)
                    .padding(.vertical, 4)
            } header: {
                Text("Device Dropdown")
            } footer: {
                Text("Takes effect the next time the dropdown is opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct WidgetView: View {
    @AppStorage("revListOnWidget") var revListOnWidget = false
    @AppStorage("deviceOnWidget") var deviceOnWidget = ""
    @AppStorage("widgetInterval") var widgetInterval = 0
    @AppStorage("deviceName") var deviceName = "Mac"

    @State var ib = getMacDeviceType().lowercased().contains("book")
    @State var devices = [String]()

    var body: some View {
        Form {
            Section {
                Toggle("Reverse Device List", isOn: $revListOnWidget)
                Picker("Refresh Interval", selection: $widgetInterval) {
                    Text("System Default").tag(-1)
                    Text("Same as Nearbility").tag(0)
                }
                if #unavailable(macOS 14) {
                    Picker("Single Device Widget", selection: $deviceOnWidget) {
                        Text("Not Set").tag("")
                        if ib { Text(deviceName).tag(deviceName) }
                        ForEach(devices, id: \.self) { device in
                            Text(device).tag(device)
                        }
                        if !devices.contains(deviceOnWidget) && deviceOnWidget != deviceName && deviceOnWidget != "" {
                            Text(deviceOnWidget).tag(deviceOnWidget)
                        }
                    }
                    .onChange(of: deviceOnWidget) { _ in _ = AirBatteryModel.singleDeviceName() }
                }
                LabeledContent {
                    Button("Reload") {
                        AirBatteryModel.writeData()
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                } label: {
                    Text("Reload All Widgets")
                }
            } header: {
                Text("Widget")
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AirBatteryModel.getAll(noFilter: true).filter({ $0.hasBattery }).map({ $0.deviceName }) }
        .onReceive(dockTimer) { _ in
            if #unavailable(macOS 14) {
                devices = AirBatteryModel.getAll(noFilter: true).filter({ $0.hasBattery }).map({ $0.deviceName })
            }
        }
    }
}

struct BlacklistView: View {
    @AppStorage("whitelistMode") var whitelistMode = false
    @State private var blockedItems = [String]()
    @State private var temp = ""
    @State private var showSheet = false
    @State private var editingIndex: Int?
    @State private var hiddenItems = [String]()

    var body: some View {
        Form {
            Section {
                Toggle("Allowlist Mode", isOn: $whitelistMode)
            } footer: {
                Text(whitelistMode ? "Only the following devices will be showed" : "The following devices will be ignored")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                List {
                    ForEach(hiddenItems, id: \.self) { name in
                        HStack {
                            Button {
                                unhideDevice(name)
                            } label: {
                                Image(systemName: "eye.slash.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            Text(name)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 80)
                .environment(\.defaultMinListRowHeight, 28)
            } header: {
                Text("Hidden Devices")
            } footer: {
                Text("Devices hidden from the dropdown via the eye icon. Click to unhide.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onAppear { hiddenItems = AirBatteryModel.getBlackList().map { $0.deviceName } }
            Section {
                List {
                    ForEach(Array(blockedItems.enumerated()), id: \.offset) { index, name in
                        HStack {
                            Button {
                                if editingIndex == nil { blockedItems.remove(at: index) }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            Text(name)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
                .environment(\.defaultMinListRowHeight, 28)
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    Button {
                        showSheet = true
                    } label: {
                        Image(systemName: "plus.square.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSheet) {
            addDeviceSheet
        }
        .onAppear { blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]() }
        .onChange(of: blockedItems) { b in ud.setValue(b, forKey: "blockedDevices") }
    }

    private func unhideDevice(_ name: String) {
        var blackList = (ud.object(forKey: "blackList") ?? []) as! [String]
        blackList.removeAll { $0 == name }
        ud.set(blackList, forKey: "blackList")
        hiddenItems.removeAll { $0 == name }
        let pinnedList = (ud.object(forKey: "pinnedList") ?? []) as! [String]
        if pinnedList.contains(name) { refeshPinnedBar() }
    }

    @ViewBuilder private var addDeviceSheet: some View {
        VStack {
            TextField("Enter Device Name".local, text: $temp).frame(width: 300)
            HStack(spacing: 20) {
                Button {
                    if temp == "" { return }
                    if !blockedItems.contains(temp) { blockedItems.append(temp) }
                    temp = ""
                    showSheet = false
                } label: {
                    Text("Add to List").frame(width: 80)
                }.keyboardShortcut(.defaultAction)
                Button {
                    showSheet = false
                } label: {
                    Text("Cancel").frame(width: 80)
                }
            }.padding(.top, 10)
        }.padding()
    }
}

struct DebugView: View {
    @AppStorage("test_debug") var test_debug = false
    @AppStorage("test_hasib") var test_hasib = false
    @AppStorage("test_acpower") var test_ac = false
    @AppStorage("test_full") var test_full = false
    @AppStorage("test_iblevel") var test_iblevel = 100
    @AppStorage("showDebug") var showDebug: Bool = false

    @State private var deviceID: String = ""
    @State private var deviceType: String = ""
    @State private var deviceName: String = ""
    @State private var deviceModel: String = ""
    @State private var parentName: String = ""
    @State private var batteryLevel: Int = 0
    @State private var lowPower: Bool = false
    @State private var isCharging: Bool = false
    @State private var fullCharged: Bool = false
    @State private var isPresented: Bool = false

    @Binding var selectedPane: SettingsPane

    var body: some View {
        Form {
            Section {
                Toggle("Debug Mode", isOn: $test_debug)
                LabeledContent {
                    Button("Open") {
                        NSWorkspace.shared.open(ncFolder.deletingLastPathComponent())
                    }
                } label: {
                    Text("Data Folder")
                }
            }
            Section {
                Toggle("Built-in Battery", isOn: $test_hasib)
                Toggle("AC Powered", isOn: $test_ac)
                Toggle("Paused", isOn: $test_full)
                SSteper("Level", value: $test_iblevel, min: 1)
            } header: {
                Text("Built-in Battery")
            }
            Section {
                LabeledContent {
                    Button {
                        isPresented = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                } label: {
                    Text("Create Item")
                }
            } header: {
                Text("Remote Battery")
            }
            Section {
                Button("Hide Debug Menu") {
                    test_debug = false
                    showDebug = false
                    selectedPane = .general
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isPresented) {
            remoteBatterySheet
        }
    }

    private var remoteBatterySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device ID", text: $deviceID)
                    TextField("Device Name", text: $deviceName)
                    TextField("Device Type", text: $deviceType)
                    TextField("Device Model", text: $deviceModel)
                    HStack {
                        TextField("Parent Name", text: $parentName)
                        Button {
                            parentName = getMacDeviceName()
                        } label: {
                            let ib = ib2ab(InternalBattery.status)
                            Image(getDeviceIcon(ib))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                    }
                    SSteper("Level", value: $batteryLevel)
                    Toggle("Charging", isOn: $isCharging)
                    Toggle("Paused", isOn: $fullCharged)
                    Toggle("Low Power", isOn: $lowPower)
                } header: {
                    Text("Remote Battery")
                }
            }
            .formStyle(.grouped)
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancle") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addVirtualDevice() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 400)
        .onAppear(perform: resetRemoteBatteryFields)
    }

    private func resetRemoteBatteryFields() {
        deviceID = randomString(length: 10)
        deviceType = "virtual"
        deviceName = "Virtual Device"
        deviceModel = ""
        parentName = ""
        batteryLevel = 100
        lowPower = false
        isCharging = false
        fullCharged = false
    }

    private func addVirtualDevice() {
        let device = Device(deviceID: deviceID, deviceType: deviceType, deviceName: deviceName, batteryLevel: batteryLevel, isCharging: isCharging ? 1 : (fullCharged ? 5 : 0), lowPower: lowPower, parentName: parentName, lastUpdate: Date().timeIntervalSince1970)
        AirBatteryModel.updateDevice(device)
        isPresented = false
    }
}
