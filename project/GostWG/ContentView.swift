// SPDX-License-Identifier: MIT

import NetworkExtension
import SwiftUI

enum AppConstants {
    static let tunnelBundleID = "com.gostwg.vpn.tunnel"
    static let profileDescription = "GostWG (WireGuard over gost relay+icmp)"
    static let logRequestCode: UInt8 = 1

    // Default phone-side WireGuard configuration. The Endpoint points at the
    // gost UDP forwarder that runs INSIDE the tunnel extension process, so it
    // is always loopback. All WireGuard UDP traffic is relayed to the server
    // inside ICMP echo packets (QUIC-over-ICMP via gost relay+icmp).
    static let defaultWireGuardConfig = """
    [Interface]
    Address = 172.17.172.2/24
    PrivateKey = sCqsTmYdDca/EX3I7EUs1bqpm+Nh5o46PRnITWwXn3o=
    DNS = 1.1.1.1, 8.8.8.8
    MTU = 1380

    [Peer]
    PublicKey = Ki1LZUHyj2xAxe568qnPcQXrWBDmGQUODmQQ4div2jw=
    AllowedIPs = 0.0.0.0/0
    Endpoint = 127.0.0.1:51820
    PersistentKeepalive = 25
    """
}

struct ContentView: View {
    @StateObject private var tunnel = TunnelManager.shared

    @State private var wgConfig: String = AppConstants.defaultWireGuardConfig
    @State private var gostHost: String = "wireguard.fqdn"
    @State private var gostPort: String = "12345"
    @State private var localPort: String = "51820"
    @State private var serverPort: String = "51820"
    @State private var debugLogging: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section("WireGuard configuration (wg-quick format)") {
                    TextEditor(text: $wgConfig)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                }

                Section("Gost ICMP relay") {
                    TextField("Server host (gost relay+icmp)", text: $gostHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Relay port", text: $gostPort)
                        .keyboardType(.numberPad)
                    TextField("Local WireGuard UDP port", text: $localPort)
                        .keyboardType(.numberPad)
                    TextField("Server-side WireGuard UDP port", text: $serverPort)
                        .keyboardType(.numberPad)
                    Toggle("Debug logging", isOn: $debugLogging)
                }

                Section {
                    Button(action: toggleTunnel) {
                        HStack {
                            if status.isLoading { ProgressView() }
                            Text(tunnel.status == .connected ? "Disconnect" : "Connect")
                                .frame(maxWidth: .infinity)
                                .font(.headline)
                        }
                    }
                    .disabled(status.isStarting)

                    statusView

                    if let error = tunnel.lastError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                } header: {
                    Text("Tunnel")
                }

                Section("Extension log") {
                    Button("Refresh log") {
                        tunnel.fetchLogs()
                    }
                    ScrollView {
                        Text(tunnel.logText.isEmpty ? "No log yet." : tunnel.logText)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 140)
                }

                Section {
                    Text(
                        "WireGuard runs inside the VPN tunnel extension; its UDP packets are "
                        + "relayed to \(gostHost):\(gostPort) inside ICMP echo packets by an embedded "
                        + "gost client (relay+icmp transport, QUIC over ICMP). The server must run: "
                        + "gost -L relay+icmp://:0 next to the WireGuard server."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                } header: {
                    Text("How it works")
                }
            }
            .navigationTitle("GostWG")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        let text: String = {
            switch tunnel.status {
            case .invalid: return "Status: profile not created"
            case .disconnected: return "Status: disconnected"
            case .connecting: return "Status: connecting..."
            case .connected: return "Status: connected"
            case .reasserting: return "Status: reasserting..."
            case .disconnecting: return "Status: disconnecting..."
            @unknown default: return "Status: unknown"
            }
        }()
        Text(text)
            .font(.footnote)
            .foregroundColor(tunnel.status == .connected ? .green : .secondary)
    }

    private func toggleTunnel() {
        switch tunnel.status {
        case .connected, .connecting, .reasserting:
            tunnel.disconnect()
        default:
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

    var isStarting: Bool {
        self == .connecting || self == .disconnecting
    }
}
