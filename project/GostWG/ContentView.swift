// SPDX-License-Identifier: MIT

import NetworkExtension
import SwiftUI

enum AppConstants {
    static let tunnelBundleID = "com.gostwg.vpn.tunnel"
    static let appGroupID = "group.com.gostwg.vpn"
    static let logFileName = "tunnel.log"
    static let profileDescription = "GostWG (WireGuard over gost relay+icmp)"
    static let logRequestCode: UInt8 = 1

    // Default phone-side WireGuard configuration. The Endpoint points at the
    // gost UDP forwarder that runs INSIDE the tunnel extension process, so it
    // is always loopback. All WireGuard UDP traffic is relayed to the server
    // inside ICMP echo packets (QUIC-over-ICMP via gost relay+icmp).
    // Never ship a real WireGuard private key in the app or repository.
    // Users paste their own client key and server public key here.
    static let defaultWireGuardConfig = """
    [Interface]
    Address = 172.17.172.2/24
    PrivateKey = REPLACE_WITH_CLIENT_PRIVATE_KEY
    DNS = 1.1.1.1, 8.8.8.8
    MTU = 1380

    [Peer]
    PublicKey = REPLACE_WITH_SERVER_PUBLIC_KEY
    AllowedIPs = 0.0.0.0/0
    Endpoint = 127.0.0.1:51820
    PersistentKeepalive = 25
    """
}

// MARK: - Status model

private enum TunnelState {
    case invalid, disconnected, connecting, connected, reasserting, disconnecting, unknown

    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .invalid: return "Not set up"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "VPN active"
        case .reasserting: return "Reconnecting…"
        case .disconnecting: return "Disconnecting…"
        case .unknown: return "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .connected: return "Handshake status is available in the extension log"
        case .connecting: return "Starting relay and WireGuard…"
        case .invalid: return "Tap Connect to create the VPN profile"
        case .disconnected: return "Tap Connect to start the tunnel"
        case .reasserting: return "Restoring the tunnel…"
        case .disconnecting: return "Tearing down…"
        case .unknown: return ""
        }
    }

    var icon: String {
        switch self {
        case .connected: return "lock.shield.fill"
        case .connecting, .reasserting, .disconnecting: return "hourglass"
        default: return "lock.open.shield"
        }
    }

    var isActive: Bool { self == .connected }
    var isBusy: Bool {
        self == .connecting || self == .reasserting || self == .disconnecting
    }
}

// MARK: - Root view

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager.shared
    @State private var showWireGuardEditor = false
    @State private var showLog = false
    @State private var hasStartedConnectionAttempt = false

    @AppStorage("wgConfig") private var wgConfig: String = AppConstants.defaultWireGuardConfig
    @AppStorage("gostHost") private var gostHost: String = ""
    @AppStorage("gostPort") private var gostPort: String = "12345"
    @AppStorage("localPort") private var localPort: String = "51820"
    @AppStorage("serverPort") private var serverPort: String = "51820"
    @AppStorage("debugLogging") private var debugLogging: Bool = false

    private var state: TunnelState { TunnelState(tunnel.status) }

    private func wireGuardValue(for key: String) -> String? {
        for line in wgConfig.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private var wireGuardKeysReady: Bool {
        guard let privateKey = wireGuardValue(for: "PrivateKey"),
              let peerKey = wireGuardValue(for: "PublicKey") else { return false }
        return !privateKey.isEmpty && !peerKey.isEmpty
            && !privateKey.hasPrefix("REPLACE_WITH_")
            && !peerKey.hasPrefix("REPLACE_WITH_")
    }

    private var wireGuardEndpointReady: Bool {
        wireGuardValue(for: "Endpoint") == "127.0.0.1:\(localPort)"
    }

    private func validPort(_ value: String) -> Bool {
        guard let port = UInt16(value) else { return false }
        return port > 0
    }

    private var relaySettingsReady: Bool {
        let host = gostHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty && host.lowercased() != "wireguard.fqdn"
            && validPort(gostPort) && validPort(localPort) && validPort(serverPort)
    }

    private var canConnect: Bool {
        relaySettingsReady && wireGuardKeysReady && wireGuardEndpointReady
    }

    var body: some View {
        NavigationView {
            Form {
                heroSection
                setupSection
                relaySection
                wireguardSection
                logSection
                aboutSection
            }
            .navigationTitle("GostWG")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onChange(of: tunnel.status) { newStatus in
            if newStatus == .connected {
                tunnel.fetchLogs()
            } else if newStatus == .disconnected && hasStartedConnectionAttempt {
                showLog = true
                tunnel.fetchLogs()
                // The provider can finish writing its stop/error details just
                // after NetworkExtension reports the status transition.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    tunnel.fetchLogs()
                }
            }
        }
    }

    // MARK: Hero (status + main action)

    private var heroSection: some View {
        Section {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: state.isActive
                                    ? [Color.green.opacity(0.25), Color.green.opacity(0.05)]
                                    : [Color.secondary.opacity(0.15), Color.secondary.opacity(0.03)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 92, height: 92)
                    Image(systemName: state.icon)
                        .font(.system(size: 38, weight: .medium))
                        .foregroundColor(state.isActive ? .green : .secondary)
                        .symbolRenderingMode(.hierarchical)
                        .opacity(state.isBusy ? 0.55 : 1.0)
                    if state.isBusy {
                        ProgressView()
                            .scaleEffect(1.6)
                            .frame(width: 92, height: 92)
                    }
                }

                Text(tunnel.isPreparingConnection ? "Preparing VPN…" : state.label)
                    .font(.title2.weight(.semibold))
                    .foregroundColor(state.isActive ? .green : .primary)

                Text(tunnel.isPreparingConnection ? "Saving your VPN profile" : state.detail)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: toggleTunnel) {
                    HStack(spacing: 8) {
                        if tunnel.isPreparingConnection || state.isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: state.isActive ? "stop.fill" : "play.fill")
                        }
                        Text(connectButtonTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: state.isActive
                                    ? [Color.red, Color.red.opacity(0.8)]
                                    : [Color.blue, Color.cyan],
                                startPoint: .leading, endPoint: .trailing)
                        )
                    )
                    .foregroundColor(.white)
                }
                .disabled(tunnel.isPreparingConnection || state.isBusy || (!state.isActive && !canConnect))
                .animation(.easeInOut(duration: 0.2), value: state.isActive)
                .padding(.top, 4)

                if !relaySettingsReady {
                    Label("Enter a relay host and valid ports (1–65535)", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if !wireGuardKeysReady {
                    Label("Add your WireGuard private and peer public keys", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if !wireGuardEndpointReady {
                    Label("Set the WireGuard endpoint to 127.0.0.1:\(localPort)", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if let error = tunnel.lastError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private var connectButtonTitle: String {
        if tunnel.isPreparingConnection { return "Preparing…" }
        if state.isBusy {
            switch state {
            case .connecting: return "Connecting…"
            case .reasserting: return "Reconnecting…"
            case .disconnecting: return "Disconnecting…"
            default: return "Working…"
            }
        }
        return state.isActive ? "Disconnect" : "Connect"
    }

    private var setupSection: some View {
        Section {
            Label("Relay", systemImage: relaySettingsReady ? "checkmark.circle.fill" : "circle")
                .foregroundColor(relaySettingsReady ? .green : .secondary)
            Label("WireGuard keys", systemImage: wireGuardKeysReady ? "checkmark.circle.fill" : "circle")
                .foregroundColor(wireGuardKeysReady ? .green : .secondary)
            Label("Local endpoint", systemImage: wireGuardEndpointReady ? "checkmark.circle.fill" : "circle")
                .foregroundColor(wireGuardEndpointReady ? .green : .secondary)
        } header: {
            Text("Setup")
        } footer: {
            Text("Complete setup, then connect. The WireGuard endpoint must match the local relay port.")
        }
    }

    // MARK: Relay settings

    private var relaySection: some View {
        Section {
            fieldRow(icon: "server.rack", placeholder: "Relay host or IP address", text: $gostHost)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            fieldRow(icon: "antenna.radiowaves.left.and.right", placeholder: "Relay port", text: $gostPort)
                .keyboardType(.numberPad)
            DisclosureGroup("Advanced relay settings") {
                fieldRow(icon: "arrow.up.forward", placeholder: "Local WG UDP port", text: $localPort)
                    .keyboardType(.numberPad)
                fieldRow(icon: "arrow.down.forward", placeholder: "Server WG UDP port", text: $serverPort)
                    .keyboardType(.numberPad)
                Toggle(isOn: $debugLogging) {
                    Label("Debug logging", systemImage: "pencil.and.outline")
                }
            }
        } header: {
            Text("Gost ICMP relay")
        } footer: {
            Text("The relay port is the port in relay+icmp://host:port — it becomes the ICMP echo identifier on the server.")
        }
    }

    // MARK: WireGuard config

    private var wireguardSection: some View {
        Section {
            DisclosureGroup("Edit configuration", isExpanded: $showWireGuardEditor) {
                TextEditor(text: $wgConfig)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 220)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("WireGuard configuration")
                Button {
                    wgConfig = AppConstants.defaultWireGuardConfig
                } label: {
                    Label("Reset to template", systemImage: "arrow.counterclockwise")
                        .font(.footnote)
                }
            }
        } header: {
            Text("WireGuard configuration")
        } footer: {
            Text("wg-quick format. Enter your own client private key and the server public key. The Endpoint must stay 127.0.0.1 — the gost forwarder runs inside the tunnel extension.")
        }
    }

    // MARK: Log console

    private var logSection: some View {
        Section {
            DisclosureGroup("View extension log", isExpanded: $showLog) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.85))
                ScrollView {
                    Text(
                        tunnel.logText.isEmpty
                            ? "— no log yet —\n\nTap Refresh to pull the last 400 lines from the tunnel extension."
                            : tunnel.logText
                    )
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.green.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
                }
            }
            .frame(minHeight: 150)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            Button {
                tunnel.fetchLogs()
            } label: {
                Label("Refresh log", systemImage: "arrow.clockwise")
                    .font(.footnote)
            }
            }
        } header: {
            Text("Extension log")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            DisclosureGroup("How it works") {
                Text(
                    "WireGuard runs inside the VPN tunnel extension. Its UDP packets are "
                        + "relayed to \(gostHost):\(gostPort) inside ICMP echo packets by an embedded "
                        + "gost client (relay+icmp = QUIC over ICMP echo)."
                )
                .font(.footnote)
                .foregroundColor(.secondary)
                Text("Server side stays unchanged:\n\ngost -L relay+icmp://:0\nnext to the WireGuard server.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("ICMP is the most deprioritized traffic class — expect higher latency than UDP, but it works where UDP is throttled or blocked. Best for browsing, SSH and chat; avoid bulk downloads.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("About")
        }
    }

    // MARK: Helpers

    private func fieldRow(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            TextField(placeholder, text: text)
        }
    }

    private func toggleTunnel() {
        switch tunnel.status {
        case .connected, .connecting, .reasserting:
            tunnel.disconnect()
        default:
            hasStartedConnectionAttempt = true
            showLog = true
            tunnel.connect(
                wgConfig: wgConfig,
                gostHost: gostHost.trimmingCharacters(in: .whitespaces),
                gostPort: gostPort,
                localPort: localPort,
                serverPort: serverPort,
                debug: debugLogging)
        }
    }
}

private extension NEVPNStatus {
    var isLoading: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }
}
