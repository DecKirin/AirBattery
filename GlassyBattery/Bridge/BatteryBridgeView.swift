//
//  BatteryBridgeView.swift
//  GlassyBattery
//
//  The BatteryBridge settings pane: on/off, port, allowlist/blocklist mode and the client list.
//

import SwiftUI

struct BatteryBridgeView: View {
    @AppStorage("batteryBridge") var enabled = false
    @AppStorage("bridgeMode") var mode = BridgeMode.blocklist.rawValue
    @AppStorage("bridgePort") var port = Int(BatteryBridge.defaultPort)
    @ObservedObject private var bridge = BatteryBridge.shared
    @State private var clients: [BridgeClient] = []
    @State private var deviceCounts: [String: Int] = [:]
    @State private var issuedToken: IssuedToken?
    /// "Last seen" and device counts aren't pushed, so the list refreshes on a timer while visible.
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Enable BatteryBridge", isOn: $enabled)
                    .onChange(of: enabled) { on in on ? bridge.start() : bridge.stop() }
                LabeledContent {
                    statusText
                } label: {
                    Text("Status")
                }
                LabeledContent {
                    TextField("", value: $port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .disabled(enabled)
                } label: {
                    Text("Port")
                }
            } header: {
                Text("BatteryBridge")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BatteryBridge lets other apps on this Mac add devices to GlassyBattery through a local API.")
                    Text("Only apps on this Mac can connect. Bridged devices reach your other Macs through Nearcast.")
                    if !(1024...65534).contains(port) {
                        Text("Ports must be between 1024 and 65534, the default port will be used.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mode", selection: Binding(get: { BridgeMode(rawValue: mode) ?? .blocklist },
                                                  set: { bridge.setMode($0); mode = $0.rawValue; reload() })) {
                    Text("Block List").tag(BridgeMode.blocklist)
                    Text("Allow List").tag(BridgeMode.allowlist)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == BridgeMode.allowlist.rawValue
                     ? "New apps must be approved before they can add devices."
                     : "New apps can add devices right away. Block the ones you don't want.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if clients.isEmpty {
                    Text("No apps have connected yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(clients) { client in
                        BridgeClientRow(client: client,
                                        deviceCount: deviceCounts[client.id] ?? 0,
                                        onIssuedToken: { issuedToken = IssuedToken(client: client.name, token: $0) },
                                        onChange: reload)
                    }
                }
            } header: {
                Text("Apps")
            }

            if case .listening(let port, let streamPort) = bridge.state {
                Section {
                    CopyableRow(label: "API", value: "http://127.0.0.1:\(port)")
                    CopyableRow(label: "Stream", value: "ws://127.0.0.1:\(streamPort)")
                    CopyableRow(label: "Discovery File", value: BatteryBridge.defaultDiscoveryURL.path)
                } header: {
                    Text("For Developers")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            BatteryBridge.shared.store.onChange = { DispatchQueue.main.async { reload() } }
        }
        .onDisappear { BatteryBridge.shared.store.onChange = nil }
        .onReceive(refresh) { _ in reload() }
        .alert(item: $issuedToken) { issued in
            Alert(title: Text("New Token"),
                  message: Text(String(format: "Give this token to %@. It replaces the old one and won't be shown again.\n\n%@".local,
                                       issued.client, issued.token)),
                  primaryButton: .default(Text("Copy")) { copyToClipboard(issued.token) },
                  secondaryButton: .cancel(Text("Done")))
        }
    }

    @ViewBuilder private var statusText: some View {
        switch bridge.state {
        case .stopped:
            Text("Off").foregroundStyle(.secondary)
        case .listening(let port, _):
            Text(String(format: "Listening on 127.0.0.1:%@".local, String(port))).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason).foregroundStyle(.red)
        }
    }

    /// Waiting apps first, then active, then blocked; by name within each.
    private func reload() {
        let order: [BridgeClientStatus: Int] = [.pending: 0, .active: 1, .blocked: 2]
        clients = BatteryBridge.shared.store.all.sorted {
            (order[$0.status] ?? 3, $0.name.lowercased()) < (order[$1.status] ?? 3, $1.name.lowercased())
        }
        var counts: [String: Int] = [:]
        for device in GlassyBatteryModel.snapshot() {
            if let owner = BridgeDevices.clientID(of: device.deviceID) { counts[owner, default: 0] += 1 }
        }
        deviceCounts = counts
    }
}

private struct IssuedToken: Identifiable {
    let id = UUID()
    let client: String
    let token: String
}

private struct BridgeClientRow: View {
    let client: BridgeClient
    let deviceCount: Int
    let onIssuedToken: (String) -> Void
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.name).fontWeight(.medium)
                    statusChip
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Toggle("Nearcast", isOn: Binding(get: { client.nearcast },
                                             set: { BatteryBridge.shared.setNearcast($0, clientID: client.id); onChange() }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(client.status == .blocked)
                .help("Share this app's devices with your other Macs over Nearcast")
            if client.status == .pending {
                Button("Approve") { BatteryBridge.shared.approve(clientID: client.id); onChange() }
            }
            Menu {
                if client.status == .blocked {
                    Button("Unblock") { BatteryBridge.shared.approve(clientID: client.id); onChange() }
                } else {
                    Button("Block") { BatteryBridge.shared.block(clientID: client.id); onChange() }
                }
                Button("Reset Token") {
                    if let token = BatteryBridge.shared.resetToken(clientID: client.id) { onIssuedToken(token) }
                }
                Divider()
                Button("Remove", role: .destructive) { BatteryBridge.shared.remove(clientID: client.id); onChange() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = []
        if let bundleID = client.bundleID, !bundleID.isEmpty { parts.append(bundleID) }
        parts.append(String(format: "%d device(s)".local, deviceCount))
        if let lastSeen = client.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append(String(format: "seen %@".local,
                                formatter.localizedString(for: Date(timeIntervalSince1970: lastSeen), relativeTo: Date())))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusChip: some View {
        let (title, color): (LocalizedStringKey, Color) = switch client.status {
        case .active: ("Active", .green)
        case .pending: ("Waiting", .orange)
        case .blocked: ("Blocked", .red)
        }
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

private struct CopyableRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    copyToClipboard(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        } label: {
            Text(label)
        }
    }
}
