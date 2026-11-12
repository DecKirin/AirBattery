# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

GlassyBattery (a rebranded fork of lihaoyun6's AirBattery, AGPL-3.0) is a macOS menu bar / Dock app (SwiftUI + AppKit) that discovers the battery level of the Mac's own battery plus every nearby Apple/Bluetooth peripheral (iPhone, iPad, Apple Watch, AirPods, Magic Mouse/Keyboard/Trackpad, third-party BT HID devices, etc.) and displays them in the Dock, status bar, and widgets. It also supports "Nearcast" — broadcasting/receiving battery state to/from other Macs on the LAN.

**Naming:** everything is **GlassyBattery**: the app (`GlassyBattery.app`), bundle IDs `com.deckirin.GlassyBattery*`, the Xcode project, scheme, targets, source folders and Swift types (`GlassyBatteryModel`, `GlassyBatteryApp`, ...), the CLI `glassybattery` and the URL scheme `glassybattery://`. The exceptions are the `abt` CLI target and folder, the GitHub repo `DecKirin/AirBattery` (and the Sparkle feed URL on it), the upstream release history in `appcast.xml`, and the attribution to lihaoyun6's AirBattery. The Swift module is `GlassyBattery` (from `PRODUCT_NAME`), which is why `Scriptable.sdef` refers to `GlassyBattery.listAll` etc. Keep lihaoyun6's copyright and the "modified version" notice (About panel `Credits.rtf`, `NSHumanReadableCopyright`, README) intact, since AGPL §5 requires them.

**Demo mode:** launching with `-demoDevices YES` (see `DemoMode` in `Supports.swift`) replaces every scanner result and the internal battery with fixed sample devices, for README/marketing screenshots.

## Build & run

There is no SPM `Package.swift` or test target — this is an Xcode-only project (`GlassyBattery.xcodeproj`) with **no automated test suite**. To build/run/archive:

```bash
open GlassyBattery.xcodeproj          # then Cmd+R in Xcode, or:
xcodebuild -project GlassyBattery.xcodeproj -scheme GlassyBattery -configuration Debug build
xcodebuild -project GlassyBattery.xcodeproj -scheme GlassyBattery -configuration Release archive ...
```

To produce a distributable disk image, use `scripts/build-dmg.sh` — the local counterpart to `.github/workflows/build-dmg.yml`. It builds, verifies the bundle (embedded widget/login item/`logReader.sh`, plus the static Library Validation check described below), and writes `dist/GlassyBattery-<version>.dmg`:

```bash
./scripts/build-dmg.sh                        # auto: Developer ID if installed, else ad-hoc
./scripts/build-dmg.sh --adhoc                # force ad-hoc (local testing only)
./scripts/build-dmg.sh --notarize <profile>   # Developer ID + notarytool + staple (shippable)
./scripts/build-dmg.sh --help
```

Ad-hoc builds must pass `ENABLE_HARDENED_RUNTIME=NO`: hardened runtime enables Library Validation, which requires embedded frameworks to share the host's Team ID, and ad-hoc signatures have none — so dyld refuses to map `Sparkle.framework` and the app dies before `main()`. Both the script and the workflow encode this; hardened runtime must stay ON for anything notarized.

The only shared scheme is `GlassyBattery` (builds/runs the main app target only; the helper, widget, and CLI targets build implicitly as embedded dependencies/CopyFiles, not via a separate scheme).

Swift Package dependencies (remote, resolved via Xcode's SPM integration — no `Package.resolved` to hand-edit):
- `sparkle-project/Sparkle` — app auto-update
- `insidegui/MultipeerKit` — Nearcast (Mac-to-Mac LAN sync) transport
- `apple/swift-argument-parser` — used only by the `abt` CLI target

## Xcode targets

| Target | Product | Purpose |
|---|---|---|
| `GlassyBattery` | `GlassyBattery.app` | Main app — menu bar/Dock UI, all battery scanners, settings window |
| `GlassyBatteryHelper` | `GlassyBatteryHelper.app` | Login-item launcher (`SMAppService`); relaunches the main app if not already running |
| `GlassyBatteryWidgetExtension` | `GlassyBatteryWidgetExtension.appex` | WidgetKit extension, reads the JSON snapshot the main app writes |
| `abt` | `abt` (CLI tool) | Standalone command-line tool (ArgumentParser-based) that reads the same JSON snapshot; installed to `/usr/local/bin/glassybattery` via `CommandLineTool.swift`'s `runAsRoot`/AppleScript admin prompt |

The app also bundles precompiled `libimobiledevice` binaries/libraries (`GlassyBattery/libimobiledevice/`) and a `logReader.sh` script (`GlassyBattery/Supports/logReader.sh`) invoked as subprocesses — these are not Swift code and aren't rebuilt from source in this repo.

## Architecture

### Device model & data flow

Everything funnels into one shared type in `GlassyBattery/BatteryInfo/GlassyBatteryModel.swift`:

- `Device` — the canonical struct for any battery-having thing (Mac, iPhone, AirPods, mouse, Nearcast peer, etc.), keyed by `deviceName`.
- `GlassyBatteryModel.Devices` — a static, `NSLock`-protected `[Device]` array that is the single in-memory source of truth. All scanners write into it via `GlassyBatteryModel.updateDevice(_:)`; all UI reads through `GlassyBatteryModel.getAll(...)`, which applies the disappear-timeout filter (`disappearTime` minutes since `lastUpdate`), the blacklist/whitelist (`checkIfBlocked`), and hidden-device filtering.
- `GlassyBatteryModel.writeData()` serializes the current device list to a JSON file in the shared App Group container (keyed by `GlassyBatteryModel.key = "com.deckirin.GlassyBattery.widget"`, which must equal the widget's bundle ID). The widget extension and the `abt` CLI tool are separate processes/sandboxes, so they *only* read this JSON file (`readData()`) — they never touch the in-memory `Devices` array directly.
- The Mac's own internal battery is handled separately as `InternalBattery.status` (an `iBattery`, from `GlassyBattery/BatteryInfo/InternalBattery.swift`, via `IOKit.ps`/`IOPowerSources`) and converted into a `Device` on demand via `ib2ab(_:)` — it's inserted at the front of device lists rather than living in `GlassyBatteryModel.Devices`.

### Battery scanners (`GlassyBattery/BatteryInfo/`)

Each scanner is an independent, self-throttled subsystem that periodically pushes discoveries into `GlassyBatteryModel.updateDevice(_:)`. All follow the same concurrency pattern: a private serial `DispatchQueue`, an `NSLock`-guarded `isRunning`/`queued` pair so overlapping timer fires coalesce into "run again after this one finishes" instead of stacking up:

- `BLEBattery.swift` (file: `AirpodsBattery.swift`) — parses raw BLE advertisement bytes from AirPods/Beats (manufacturer-ID 0x4c00 packets) to get per-earbud/case battery without a paired connection.
- `BTDBattery.swift` — polls classic Bluetooth HID devices via `IOBluetooth`.
- `MagicBattery.swift` — `SPBluetoothDataModel` shells out to `system_profiler SPBluetoothDataType -json` (cached, coalesced across callers) to read Magic Mouse/Keyboard/Trackpad and other IOBluetooth-reported battery levels.
  Its `getAccessoryBattery()` also reads macOS's accessory power-source registry via `IOPSCopyPowerSourcesByType(kIOPSSourceForAccessories)` — the list `pmset -g accps` prints. That is the only source for BLE input devices whose battery lives solely in the standard GATT Battery Service (nothing in `system_profiler`, the IORegistry, or the log statedumps), and the freshest one for devices the other scanners do find. It runs last in `scanDevices()` so it refreshes levels without overwriting the more specific device types set before it.
- `IDeviceBattery.swift` — drives the bundled `libimobiledevice` binaries to talk to USB/WiFi-paired iPhone/iPad (and their paired Apple Watch) over `lockdownd`/`afc`-style protocols.
- `LogReader` (in `GlassyBattery/Supports/Supports.swift`) — runs `logReader.sh` against the unified system log to catch "Enhanced HID" battery events other scanners miss; triggered incrementally on bootstrap, display wake, and BT device-connect notifications, tracking a `logReaderLastTS` watermark so each run only scans the new log window.

Scan cadence is centralized as shared `Timer.publish` instances at the top of `Supports.swift` (`mainTimer`, `dockTimer`, `ideviceScanTimer`, `alertTimer`, `widgetDataTimer`, `nearCastTimer`, `widgetViewTimer`), scaled by the user's `updateInterval` preference.

### App shell (`GlassyBattery/Supports/GlassyBatteryApp.swift`)

`AppDelegate` (not a SwiftUI `App` body) owns the actual UI lifecycle: status bar item, Dock tile custom view, the popover menu, and a borderless `AutoHideWindow` used for the Dock-click flyout (`applicationShouldHandleReopen`). The SwiftUI `Window` scene is used *only* for the Settings window (`GlassyBatterySettingsWindowRoot`) — note the comment there explaining why the old `Settings {}` scene was dropped (wrong chrome/traffic-light alignment) and why `applicationShouldTerminateAfterLastWindowClosed` must return `false` (else closing Settings quits the whole menu bar app).

`showOn` (`AppStorage`) drives whether the app presents in the status bar, the Dock, both, or neither ("none" = widgets only), switching `NSApp.setActivationPolicy` and toggling `statusBarItem.isVisible` accordingly.

### Nearcast (LAN sync)

`GlassyBattery/Supports/Multipeer.swift` wraps `MultipeerKit` in `MultipeerService`. Peers are grouped by a shared `ncGroupID`; messages are AES-GCM encrypted using a key derived from that group ID (`generateSymmetricKey`/`encryptString`/`decryptString` in `Supports.swift`). Incoming peer snapshots are written as per-peer JSON files into `ncFolder` (inside the widget's App Group container) and merged into UI device lists via `GlassyBatteryModel.ncGetAll(url:)`, which de-dupes against locally-known device names.

### UI layer (`GlassyBattery/ViewModel/`)

SwiftUI views only — `ContentView.swift` (popover/dock content, largest file), `BatteryView.swift` (per-device row rendering, icons, colors), `BatteryAlertView.swift` (low/full battery alert configuration), `SettingsView.swift` (preferences window content). Device icon selection (`getDeviceIcon`) and battery-level color coding (`getPowerColor`, `getHealthColor`) live in `Supports.swift` and are shared by both the main app UI and the widget. `getDeviceIcon` returns the name of a bundled icon (`Assets.xcassets/Device Icon`, SF Symbols exported as SVG so they draw on every supported macOS); draw it with `deviceIconImage(_:)` / `deviceIconNSImage(_:)`, never `Image(getDeviceIcon(...))` directly, because those helpers first honour what a BatteryBridge client chose: `Device.deviceCustomIcon` (an icon it uploaded, a file under `GlassyBatteryModel.bridgeIconsURL()/<clientID>/`, which `BridgeIconStore` manages), then `Device.deviceIcon` (an SF Symbol), each only when this Mac can draw it.

### Localization

`Base.lproj`, `en.lproj`, `zh-Hans.lproj`, `zh-Hant.lproj` hold `.strings` files; UI strings go through the `String.local` extension (`NSLocalizedString` wrapper) defined in `Supports.swift`.

## Conventions worth knowing

- Mutable global state shared across scanners/UI (`GlassyBatteryModel.Devices`, `SPBluetoothDataModel.data`, dock-tile display scheduling) is protected with `NSLock`, not actors — stay consistent with that pattern rather than introducing Swift concurrency primitives piecemeal.
- Comments and `print()` log messages are a mix of English and Chinese (original author's bilingual style) — this is intentional, not something to "fix" during unrelated edits.
- Bilingual README: `README.md` (English) and `README_zh.md` (Chinese) are both maintained; update both if user-facing behavior/instructions change.
