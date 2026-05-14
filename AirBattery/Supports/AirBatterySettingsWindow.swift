//
//  AirBatterySettingsWindow.swift
//  AirBattery
//
//  Replaces the SwiftUI `Settings { }` scene, which uses a non-standard window template
//  (extra inset chrome / title bar lines vs. System Settings). This file is the supported
//  entry point; do not reintroduce `Settings { }` for this app.
//

import AppKit
import SwiftUI

let airBatterySettingsWindowId = "AirBatterySettings"

/// Root view for the settings `Window` scene: full-size content + window hooks + `openWindow` capture.
struct AirBatterySettingsWindowRoot: View {
    var body: some View {
        SettingsView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                WindowAccessor(onWindowOpen: Self.configureWindow)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                AirBatterySettingsOpenWindowBinder()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
    }

    private static func configureWindow(_ window: NSWindow?) {
        guard let w = window else { return }
        w.titlebarSeparatorStyle = .none
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.orderFront(nil)
    }
}

private struct AirBatterySettingsOpenWindowBinder: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                AirBatterySettingsWindowOpener.shared.register(openWindow)
            }
    }
}

final class AirBatterySettingsWindowOpener {
    static let shared = AirBatterySettingsWindowOpener()
    private var openWindow: OpenWindowAction?

    func register(_ action: OpenWindowAction) {
        openWindow = action
    }

    func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let openWindow {
            openWindow(id: airBatterySettingsWindowId)
            return
        }
        for w in NSApp.windows where w.title.contains("AirBattery") && w.title.contains("Settings") {
            w.makeKeyAndOrderFront(nil)
            return
        }
    }
}

/// Called from the Dock menu, status item, and other non-SwiftUI entry points.
func openAirBatterySettingsWindow() {
    AirBatterySettingsWindowOpener.shared.open()
}
