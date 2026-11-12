//
//  TestSupport.swift
//  BridgeCoreTests
//
//  The BatteryBridge test harness. The app has no test target, so run.sh compiles these files
//  together with the real model and Bridge sources into one executable.
//

import Foundation

// Each target defines these in its entry file (GlassyBatteryApp.swift, abt/main.swift).
let fd = FileManager.default
let ud = UserDefaults(suiteName: "glassybattery-bridge-tests")!

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ label: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("✘ \(file):\(line): \(label)")
    }
}

func expectError(_ expected: BridgeError, _ label: String, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("✘ \(file):\(line): \(label) — no error, expected \(expected.code)")
    } catch let error as BridgeError where error == expected {
    } catch {
        failures += 1
        print("✘ \(file):\(line): \(label) — got \(error), expected \(expected.code)")
    }
}

let tempDir = fd.temporaryDirectory.appendingPathComponent("bridge-tests-\(UUID().uuidString)")
/// An icon store in the temporary folder, so no test touches the real one.
func testIcons() -> BridgeIconStore {
    BridgeIconStore(directory: tempDir.appendingPathComponent("icons-\(UUID().uuidString)"))
}

func freshStore() -> (BridgeClientStore, URL) {
    let url = tempDir.appendingPathComponent("\(UUID().uuidString)/clients.json")
    return (BridgeClientStore(fileURL: url), url)
}
