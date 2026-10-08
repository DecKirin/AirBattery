#!/bin/sh
# Compiles the BatteryBridge core with the model sources the app shares with the CLI, then runs
# the checks in main.swift. Usage: Tests/BridgeCoreTests/run.sh
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
    "$root/Tests/BridgeCoreTests/main.swift"
"$out/bridge-core-tests"
