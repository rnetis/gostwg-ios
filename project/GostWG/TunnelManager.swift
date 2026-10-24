// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension

/// Manages the VPN tunnel: profile creation, start/stop, status and logs.
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published var status: NEVPNStatus = .invalid
    @Published var logText: String = ""
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusDidChange),
            name: .NEVPNStatusDidChange, object: nil)
    }

    @objc private func statusDidChange(_ notification: Notification) {
        guard let conn = notification.object as? NETunnelProviderSession else { return }
        DispatchQueue.main.async {
            self.status = conn.status
        }
    }

    /// Loads (or creates) the tunnel profile with the given settings and
    /// prepares it for activation.
    func connect(wgConfig: String, gostHost: String, gostPort: String,
                 localPort: String, serverPort: String, debug: Bool) {
        lastError = nil

        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = AppConstants.tunnelBundleID
        providerProtocol.serverAddress = gostHost // shown as the "server" in Settings
        providerProtocol.providerConfiguration = [
            "wgConfig": wgConfig,
            "gostHost": gostHost,
            "gostPort": gostPort,
            "localPort": localPort,
            "serverPort": serverPort,
            "debug": debug,
        ]

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.fail("Failed to load VPN profiles: \(error.localizedDescription)")
                return
            }

            // Reuse the profile we own, so toggling Settings doesn't duplicate it.
            let existing = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == AppConstants.tunnelBundleID
            }
            let manager = existing ?? NETunnelProviderManager()
            manager.protocolConfiguration = providerProtocol
            manager.localizedDescription = AppConstants.profileDescription
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    self.fail("Failed to save VPN profile: \(saveError.localizedDescription)")
                    return
                }
                manager.loadFromPreferences { reloadError in
                    if let reloadError = reloadError {
                        self.fail("Failed to reload VPN profile: \(reloadError.localizedDescription)")
                        return
                    }
                    self.manager = manager
                    guard let session = manager.connection as? NETunnelProviderSession else {
                        self.fail("VPN session is unavailable")
                        return
                    }
                    do {
                        try session.startVPNTunnel(options: nil)
                        DispatchQueue.main.async { self.status = session.status }
                    } catch {
                        self.fail("Failed to start tunnel: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func disconnect() {
        guard let manager = manager else {
            // Fall back: find and stop whichever profile is running.
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                managers?.first(where: { $0.connection.status == .connected })?
                    .connection.stopVPNTunnel()
            }
            return
        }
        manager.connection.stopVPNTunnel()
    }

    /// Fetches the last log lines from the tunnel extension.
    func fetchLogs() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            // Profile might exist but not be loaded into `manager` yet.
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                guard let session = managers?
                    .first(where: { $0.isEnabled })?
                    .connection as? NETunnelProviderSession else { return }
                self.requestLogs(session: session)
            }
            return
        }
        requestLogs(session: session)
    }

    private func requestLogs(session: NETunnelProviderSession) {
        try? session.sendProviderMessage(Data([AppConstants.logRequestCode])) { data in
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { self.logText = "(no log data — is the tunnel running?)" }
                return
            }
            DispatchQueue.main.async { self.logText = text }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.lastError = message
            self.logText += "\n[app] " + message
        }
    }
}
