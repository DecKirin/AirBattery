//
//  main.swift
//  BridgeCoreTests
//

import Foundation

do {
    try runCoreTests()
    try runHTTPTests()
    try runRouterTests()
    try runServerTests()
} catch {
    failures += 1
    print("✘ unexpected error: \(error)")
}

try? fd.removeItem(at: tempDir)
print(failures == 0 ? "✔ \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
