# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AirBattery is a macOS menu bar / Dock app (SwiftUI + AppKit) that discovers the battery level of the Mac's own battery plus every nearby Apple/Bluetooth peripheral (iPhone, iPad, Apple Watch, AirPods, Magic Mouse/Keyboard/Trackpad, third-party BT HID devices, etc.) and displays them in the Dock, status bar, and widgets. It also supports "Nearcast" — broadcasting/receiving battery state to/from other Macs on the LAN.

## Build & run

There is no CLI build script, SPM `Package.swift`, or test target — this is an Xcode-only project (`AirBattery.xcodeproj`) with **no automated test suite**. To build/run/archive:

```bash
open AirBattery.xcodeproj          # then Cmd+R in Xcode, or:
xcodebuild -project AirBattery.xcodeproj -scheme AirBattery -configuration Debug build
xcodebuild -project AirBattery.xcodeproj -scheme AirBattery -configuration Release archive ...
```

The only shared scheme is `AirBattery` (builds/runs the main app target only; the helper, widget, and CLI targets build implicitly as embedded dependencies/CopyFiles, not via a separate scheme).

Swift Package dependencies (remote, resolved via Xcode's SPM integration — no `Package.resolved` to hand-edit):
- `sparkle-project/Sparkle` — app auto-update
- `insidegui/MultipeerKit` — Nearcast (Mac-to-Mac LAN sync) transport
- `apple/swift-argument-parser` — used only by the `abt` CLI target

## Xcode targets

| Target | Product | Purpose |
|---|---|---|
| `AirBattery` | `AirBattery.app` | Main app — menu bar/Dock UI, all battery scanners, settings window |
| `AirBatteryHelper` | `AirBatteryHelper.app` | Login-item launcher (`SMAppService`); relaunches the main app if not already running |
| `AirBatteryWidgetExtension` | `AirBatteryWidgetExtension.appex` | WidgetKit extension, reads the JSON snapshot the main app writes |
| `abt` | `abt` (CLI tool) | Standalone command-line tool (ArgumentParser-based) that reads the same JSON snapshot; installed to `/usr/local/bin/airbattery` via `CommandLineTool.swift`'s `runAsRoot`/AppleScript admin prompt |

The app also bundles precompiled `libimobiledevice` binaries/libraries (`AirBattery/libimobiledevice/`) and a `logReader.sh` script (`AirBattery/Supports/logReader.sh`) invoked as subprocesses — these are not Swift code and aren't rebuilt from source in this repo.

## Architecture

### Device model & data flow

Everything funnels into one shared type in `AirBattery/BatteryInfo/AirBatteryModel.swift`:

- `Device` — the canonical struct for any battery-having thing (Mac, iPhone, AirPods, mouse, Nearcast peer, etc.), keyed by `deviceName`.
- `AirBatteryModel.Devices` — a static, `NSLock`-protected `[Device]` array that is the single in-memory source of truth. All scanners write into it via `AirBatteryModel.updateDevice(_:)`; all UI reads through `AirBatteryModel.getAll(...)`, which applies the disappear-timeout filter (`disappearTime` minutes since `lastUpdate`), the blacklist/whitelist (`checkIfBlocked`), and hidden-device filtering.
- `AirBatteryModel.writeData()` serializes the current device list to a JSON file in the shared App Group container (keyed by `AirBatteryModel.key = "com.lihaoyun6.AirBattery.widget"`). The widget extension and the `abt` CLI tool are separate processes/sandboxes, so they *only* read this JSON file (`readData()`) — they never touch the in-memory `Devices` array directly.
- The Mac's own internal battery is handled separately as `InternalBattery.status` (an `iBattery`, from `AirBattery/BatteryInfo/InternalBattery.swift`, via `IOKit.ps`/`IOPowerSources`) and converted into a `Device` on demand via `ib2ab(_:)` — it's inserted at the front of device lists rather than living in `AirBatteryModel.Devices`.

### Battery scanners (`AirBattery/BatteryInfo/`)

Each scanner is an independent, self-throttled subsystem that periodically pushes discoveries into `AirBatteryModel.updateDevice(_:)`. All follow the same concurrency pattern: a private serial `DispatchQueue`, an `NSLock`-guarded `isRunning`/`queued` pair so overlapping timer fires coalesce into "run again after this one finishes" instead of stacking up:

- `BLEBattery.swift` (file: `AirpodsBattery.swift`) — parses raw BLE advertisement bytes from AirPods/Beats (manufacturer-ID 0x4c00 packets) to get per-earbud/case battery without a paired connection.
- `BTDBattery.swift` — polls classic Bluetooth HID devices via `IOBluetooth`.
- `MagicBattery.swift` — `SPBluetoothDataModel` shells out to `system_profiler SPBluetoothDataType -json` (cached, coalesced across callers) to read Magic Mouse/Keyboard/Trackpad and other IOBluetooth-reported battery levels.
  Its `getAccessoryBattery()` also reads macOS's accessory power-source registry via `IOPSCopyPowerSourcesByType(kIOPSSourceForAccessories)` — the list `pmset -g accps` prints. That is the only source for BLE input devices whose battery lives solely in the standard GATT Battery Service (nothing in `system_profiler`, the IORegistry, or the log statedumps), and the freshest one for devices the other scanners do find. It runs last in `scanDevices()` so it refreshes levels without overwriting the more specific device types set before it.
- `IDeviceBattery.swift` — drives the bundled `libimobiledevice` binaries to talk to USB/WiFi-paired iPhone/iPad (and their paired Apple Watch) over `lockdownd`/`afc`-style protocols.
- `LogReader` (in `AirBattery/Supports/Supports.swift`) — runs `logReader.sh` against the unified system log to catch "Enhanced HID" battery events other scanners miss; triggered incrementally on bootstrap, display wake, and BT device-connect notifications, tracking a `logReaderLastTS` watermark so each run only scans the new log window.

Scan cadence is centralized as shared `Timer.publish` instances at the top of `Supports.swift` (`mainTimer`, `dockTimer`, `ideviceScanTimer`, `alertTimer`, `widgetDataTimer`, `nearCastTimer`, `widgetViewTimer`), scaled by the user's `updateInterval` preference.

### App shell (`AirBattery/Supports/AirBatteryApp.swift`)

`AppDelegate` (not a SwiftUI `App` body) owns the actual UI lifecycle: status bar item, Dock tile custom view, the popover menu, and a borderless `AutoHideWindow` used for the Dock-click flyout (`applicationShouldHandleReopen`). The SwiftUI `Window` scene is used *only* for the Settings window (`AirBatterySettingsWindowRoot`) — note the comment there explaining why the old `Settings {}` scene was dropped (wrong chrome/traffic-light alignment) and why `applicationShouldTerminateAfterLastWindowClosed` must return `false` (else closing Settings quits the whole menu bar app).

`showOn` (`AppStorage`) drives whether the app presents in the status bar, the Dock, both, or neither ("none" = widgets only), switching `NSApp.setActivationPolicy` and toggling `statusBarItem.isVisible` accordingly.

### Nearcast (LAN sync)

`AirBattery/Supports/Multipeer.swift` wraps `MultipeerKit` in `MultipeerService`. Peers are grouped by a shared `ncGroupID`; messages are AES-GCM encrypted using a key derived from that group ID (`generateSymmetricKey`/`encryptString`/`decryptString` in `Supports.swift`). Incoming peer snapshots are written as per-peer JSON files into `ncFolder` (inside the widget's App Group container) and merged into UI device lists via `AirBatteryModel.ncGetAll(url:)`, which de-dupes against locally-known device names.

### UI layer (`AirBattery/ViewModel/`)

SwiftUI views only — `ContentView.swift` (popover/dock content, largest file), `BatteryView.swift` (per-device row rendering, icons, colors), `BatteryAlertView.swift` (low/full battery alert configuration), `SettingsView.swift` (preferences window content). Device icon selection (`getDeviceIcon`) and battery-level color coding (`getPowerColor`, `getHealthColor`) live in `Supports.swift` and are shared by both the main app UI and the widget.

### Localization

`Base.lproj`, `en.lproj`, `zh-Hans.lproj`, `zh-Hant.lproj` hold `.strings` files; UI strings go through the `String.local` extension (`NSLocalizedString` wrapper) defined in `Supports.swift`.

## Conventions worth knowing

- Mutable global state shared across scanners/UI (`AirBatteryModel.Devices`, `SPBluetoothDataModel.data`, dock-tile display scheduling) is protected with `NSLock`, not actors — stay consistent with that pattern rather than introducing Swift concurrency primitives piecemeal.
- Comments and `print()` log messages are a mix of English and Chinese (original author's bilingual style) — this is intentional, not something to "fix" during unrelated edits.
- Bilingual README: `README.md` (English) and `README_zh.md` (Chinese) are both maintained; update both if user-facing behavior/instructions change.
