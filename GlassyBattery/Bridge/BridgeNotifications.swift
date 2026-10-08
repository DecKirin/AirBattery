//
//  BridgeNotifications.swift
//  GlassyBattery
//
//  The "an app wants to connect" notification shown in allowlist mode, with Approve and Block
//  buttons so the user doesn't have to open Settings.
//

import Foundation
import UserNotifications

enum BridgeNotifications {
    static let categoryID = "BRIDGE_APPROVAL"
    static let approveAction = "BRIDGE_APPROVE"
    static let blockAction = "BRIDGE_BLOCK"
    private static let clientKey = "bridgeClientID"

    /// Adds the approval category next to the ones `registerNotificationCategory` set up.
    /// (`setNotificationCategories` replaces the whole set, so read it first.)
    static func registerCategory() {
        let approve = UNNotificationAction(identifier: approveAction, title: "Approve".local, options: [])
        let block = UNNotificationAction(identifier: blockAction, title: "Block".local, options: [.destructive])
        let category = UNNotificationCategory(identifier: categoryID, actions: [approve, block],
                                              intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.filter { $0.identifier != categoryID }.union([category]))
        }
    }

    static func requestApproval(for client: BridgeClient) {
        let content = UNMutableNotificationContent()
        content.title = "BatteryBridge".local
        let app = client.bundleID.map { "\(client.name) (\($0))" } ?? client.name
        content.body = String(format: "\"%@\" wants to add devices to GlassyBattery.".local, app)
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = [clientKey: client.id]
        // One notification per client: a client re-registering replaces its earlier request.
        let request = UNNotificationRequest(identifier: "bridge-\(client.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("⚠️ BatteryBridge: approval notification failed: \(error.localizedDescription)") }
        }
    }

    /// Handles a tap on one of the buttons. Returns false for notifications that aren't ours.
    static func handle(_ response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        guard content.categoryIdentifier == categoryID, let clientID = content.userInfo[clientKey] as? String else { return false }
        switch response.actionIdentifier {
        case approveAction: BatteryBridge.shared.approve(clientID: clientID)
        case blockAction: BatteryBridge.shared.block(clientID: clientID)
        default: DispatchQueue.main.async { openSettings(pane: .batteryBridge) }    // the notification itself: show the client list
        }
        return true
    }
}
