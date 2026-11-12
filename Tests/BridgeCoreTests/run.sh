#!/bin/sh
# Compiles the BatteryBridge sources (all but the settings pane and notifications, which need the
# rest of the app) with the model sources the app shares with the CLI, then runs
# the checks. The server tests bind a free loopback port and drive it with curl.
# Usage: Tests/BridgeCoreTests/run.sh
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

xcrun swiftc -o "$out/bridge-core-tests" \
    "$root/GlassyBattery/BatteryInfo/GlassyBatteryModel.swift" \
    "$root/GlassyBattery/BatteryInfo/InternalBattery.swift" \
    "$root/GlassyBattery/Supports/Supports.swift" \
    "$root/GlassyBattery/Bridge/BridgeModels.swift" \
    "$root/GlassyBattery/Bridge/BridgeClientStore.swift" \
    "$root/GlassyBattery/Bridge/BridgeDevices.swift" \
    "$root/GlassyBattery/Bridge/BridgeIcons.swift" \
    "$root/GlassyBattery/Bridge/BridgeHTTP.swift" \
    "$root/GlassyBattery/Bridge/BridgeRouter.swift" \
    "$root/GlassyBattery/Bridge/BridgeStream.swift" \
    "$root/GlassyBattery/Bridge/BatteryBridge.swift" \
    "$root"/Tests/BridgeCoreTests/*.swift
"$out/bridge-core-tests"
