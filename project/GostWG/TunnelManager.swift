// SPDX-License-Identifier: MIT

import Foundation
import NetworkExtension

/// Manages the VPN tunnel: profile creation, start/stop, status and logs.
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published var status: NEVPNStatus = .invalid
    @Published var logText: String = ""
    @Published var lastError: String?
    @Published var isPreparingConnection = false

    private var manager: NETunnelProviderManager?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusDidChange),
            name: .NEVPNStatusDidChange, object: nil)
        loadPersistedLogs()
        loadExistingProfile()
    }

    @objc private func statusDidChange(_ notification: Notification) {
        guard let conn = notification.object as? NETunnelProviderSession,
              conn === manager?.connection else { return }
        let newStatus = conn.status
        DispatchQueue.main.async {
            let previousStatus = self.status
            self.status = newStatus
            if newStatus == .disconnected && previousStatus != .disconnected {
                self.fetchDisconnectError(from: conn)
            }
        }
    }

    private func loadExistingProfile() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error {
                self.fail("Failed to load VPN profile: \(error.localizedDescription)")
                return
            }
            let owned = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == AppConstants.tunnelBundleID
            }
            DispatchQueue.main.async {
                self.manager = owned
                self.status = owned?.connection.status ?? .invalid
            }
        }
    }

    /// Loads (or creates) the tunnel profile with the given settings and
    /// prepares it for activation.
    func connect(wgConfig: String, gostHost: String, gostPort: String,
                 localPort: String, serverPort: String,
                 protocolFocus: String, serverTunnelAddress: String, debug: Bool) {
        guard !isPreparingConnection, status != .connecting,
              status != .connected, status != .reasserting else { return }
        lastError = nil
        isPreparingConnection = true
        resetPersistedLogs()
        logText = "[app] Starting tunnel attempt at \(Date())"

        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = AppConstants.tunnelBundleID
        providerProtocol.serverAddress = gostHost // shown as the "server" in Settings
        providerProtocol.providerConfiguration = [
            "wgConfig": wgConfig,
            "gostHost": gostHost,
            "gostPort": gostPort,
            "localPort": localPort,
            "serverPort": serverPort,
            "protocolFocus": protocolFocus,
            "serverTunnelAddress": serverTunnelAddress,
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
                        DispatchQueue.main.async {
                            self.status = session.status
                            self.isPreparingConnection = false
                        }
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
                managers?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == AppConstants.tunnelBundleID
                })?
                    .connection.stopVPNTunnel()
            }
            return
        }
        manager.connection.stopVPNTunnel()
    }

    /// Fetches the last log lines from the tunnel extension.
    func fetchLogs() {
        loadPersistedLogs()
        guard let session = manager?.connection as? NETunnelProviderSession else {
            // Profile might exist but not be loaded into `manager` yet.
            NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
                if let error = error {
                    self?.report("[app] loadAllFromPreferences failed: \(error.localizedDescription)")
                    return
                }
                guard let session = managers?
                    .first(where: {
                        ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                            .providerBundleIdentifier == AppConstants.tunnelBundleID
                    })?
                    .connection as? NETunnelProviderSession else {
                    self?.report("[app] no enabled VPN profile found — tap Connect first")
                    return
                }
                self?.requestLogs(session: session)
            }
            return
        }
        requestLogs(session: session)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async {
            if self.logText.isEmpty { self.logText = message }
            else { self.logText += "\n" + message }
        }
    }

    private func loadPersistedLogs() {
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID) else {
            return
        }
        let file = directory.appendingPathComponent(AppConstants.logFileName)
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else { return }
        DispatchQueue.main.async { self.logText = text }
    }

    private func resetPersistedLogs() {
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID) else { return }
        let file = directory.appendingPathComponent(AppConstants.logFileName)
        try? FileManager.default.removeItem(at: file)
    }

    private func requestLogs(session: NETunnelProviderSession) {
        do {
            try session.sendProviderMessage(Data([AppConstants.logRequestCode])) { [weak self] data in
                guard let data = data, let text = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        self?.loadPersistedLogs()
                        if self?.logText.isEmpty ?? true {
                            self?.logText = "(No persisted log is available. The extension may have failed before it could write one.)"
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    // Prefer the extension response while it is alive; its
                    // ring and the shared file contain the same latest lines.
                    self?.logText = text
                }
            }
        } catch {
            // sendProviderMessage throws when the extension process is not
            // reachable (crashed at launch, or the tunnel never started).
            report("[app] could not reach tunnel extension: \(error.localizedDescription)\n"
                   + "This usually means the extension crashed immediately at launch.")
        }
    }

    /// NetworkExtension may reject a start before the packet-tunnel provider
    /// launches. In that case there is no extension log, but the connection
    /// still exposes the system's last disconnect error.
    private func fetchDisconnectError(from connection: NEVPNConnection) {
        connection.fetchLastDisconnectError { [weak self] error in
            guard let self, let error else { return }
            let nsError = error as NSError
            let message = "VPN disconnect error: \(nsError.localizedDescription) (\(nsError.domain), code \(nsError.code))"
            DispatchQueue.main.async {
                self.lastError = message
                if self.logText.isEmpty { self.logText = "[app] " + message }
                else { self.logText += "\n[app] " + message }
            }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.lastError = message
            self.isPreparingConnection = false
            self.logText += "\n[app] " + message
        }
    }
}
