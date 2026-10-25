// SPDX-License-Identifier: MIT
//
// Packet Tunnel Provider that runs wireguard-go together with an embedded
// gost client so that all WireGuard UDP traffic is transported to the server
// inside ICMP echo packets (gost relay+icmp = QUIC over ICMP echo).
//
// Data path on the device:
//
//   apps -> NEPacketTunnelFlow -> wireguard-go -> UDP 127.0.0.1:<localPort>
//     -> gost udp forwarder (in-process, gostsidecar)
//     -> relay+icmp://<gostHost>:<gostPort>   (QUIC over ICMP echo req/reply)
//     -> gost server on the VPS -> dials 127.0.0.1:<serverPort>
//     -> WireGuard server
//
// Note: on iOS the tunnel provider process's own traffic never loops back
// into its own tunnel, so the ICMP flow to the relay server is safe without
// any extra socket protection.

import Foundation
import Network
import WireGuardKitGo
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Must match AppConstants.logRequestCode in the app target.
    private static let logRequestCode: UInt8 = 1

    /// Ring buffer of log lines returned to the app via handleAppMessage.
    private final class LogRing {
        private var lines: [String] = []
        private let capacity = 400
        private let lock = NSLock()
        private let logURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.gostwg.vpn")?
            .appendingPathComponent("tunnel.log")

        func add(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            lines.append("[" + formatter.string(from: Date()) + "] " + line)
            if lines.count > capacity {
                lines.removeFirst(lines.count - capacity)
            }
            // Keep a durable copy outside the extension process. Network
            // Extension may terminate immediately after a startup failure,
            // before the containing app can request the in-memory ring.
            if let logURL,
               let data = lines.joined(separator: "\n").data(using: .utf8) {
                do {
                    try data.write(to: logURL, options: .atomic)
                } catch {
                    os_log("Could not persist tunnel log: %{public}@", log: OSLogShim.tunnel, error.localizedDescription)
                }
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            if let logURL, let persisted = try? String(contentsOf: logURL, encoding: .utf8), !persisted.isEmpty {
                return persisted
            }
            return lines.joined(separator: "\n")
        }
    }

    private let log = LogRing()

    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log.add("wg: \(message)")
            os_log("%{public}@", log: OSLog(subsystem: "com.gostwg.vpn.tunnel", category: "wireguard"), message)
        }
    }()

    private enum TunnelError: Error, CustomStringConvertible {
        case savedProtocolConfigurationIsInvalid
        case wireGuardConfigInvalid(String)
        case gostHostResolutionFailed(String)
        case gostStartFailed

        var description: String {
            switch self {
            case .savedProtocolConfigurationIsInvalid:
                return "saved protocol configuration is invalid"
            case .wireGuardConfigInvalid(let reason):
                return "invalid WireGuard config: \(reason)"
            case .gostHostResolutionFailed(let host):
                return "could not resolve gost relay host: \(host)"
            case .gostStartFailed:
                return "failed to start gost sidecar"
            }
        }
    }

    // MARK: - Tunnel lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.add("startTunnel requested")
        wg_log(.info, message: "Starting tunnel from the " + ((options?["activationAttemptId"] != nil) ? "app" : "OS"))

        do {
            let settings = try readProviderConfiguration()
            let tunnelConfiguration = try parseWireGuardConfig(settings.wgConfig)

            // Resolve the gost relay host with the pre-tunnel system resolver
            // so the ICMP transport never depends on tunnel DNS.
            let relayAddr = try gostRelayAddress(settings.gostHost, port: settings.gostPort)
            log.add("gost relay address: \(relayAddr)")
            log.add(icmpSelfTest(relayAddr: relayAddr))
            if settings.protocolFocus == "all" {
                log.add("protocol focus: all IP protocols")
            } else {
                log.add("protocol focus: \(settings.protocolFocus.uppercased()) only; other IP protocols will be dropped")
                if !settings.forwards.isEmpty {
                    log.add("WARNING: UDP port forwards will not pass while protocol focus is \(settings.protocolFocus) — set focus to All")
                }
            }

            // Start the embedded gost sidecar first: it owns the local UDP
            // listener that the WireGuard endpoint points at, plus any
            // user-defined UDP port-forward rules.
            let serviceList = gostServices(
                localPort: settings.localPort,
                serverPort: settings.serverPort,
                forwards: settings.forwards)
                .map { "\"\($0)\"" }
                .joined(separator: ",")
            let gostJSON = """
            {"services":[\(serviceList)],\
            "nodes":["relay+icmp://\(relayAddr)"],\
            "debug":\(settings.debug ? "true" : "false")}
            """
            log.add("gost config: \(gostJSON)")

            // gost forwards its startup logs through WireGuard's C logger.
            // Initialize the adapter first so that logger is registered even
            // when gostStart fails before the WireGuard backend is started.
            _ = adapter
            if gostStart(gostJSON) != 0 {
                throw TunnelError.gostStartFailed
            }
            log.add("gost sidecar running (local udp :\(settings.localPort) -> relay+icmp \(relayAddr) -> 127.0.0.1:\(settings.serverPort))")

            // Bring up the WireGuard engine. Endpoint inside the WG config is
            // 127.0.0.1:<localPort> — the gost listener started above.
            adapter.start(tunnelConfiguration: tunnelConfiguration, protocolFocus: settings.protocolFocus) { [weak self] adapterError in
                guard let self = self else { return }
                if let adapterError = adapterError {
                    self.log.add("wg adapter failed: \(adapterError)")
                    gostStop()
                    completionHandler(adapterError)
                    return
                }
                let name = self.adapter.interfaceName ?? "unknown"
                self.log.add("wg adapter started, interface \(name)")
                completionHandler(nil)
            }
        } catch {
            log.add("startTunnel failed: \(error)")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.add("stopTunnel (reason \(reason.rawValue))")
        gostStop()
        adapter.stop { [weak self] error in
            if let error = error {
                self?.log.add("wg adapter stop error: \(error)")
            }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }
        guard messageData.count == 1, messageData[0] == PacketTunnelProvider.logRequestCode else {
            completionHandler(nil)
            return
        }
        var text = log.text
        text += "\n[gost running: \(gostIsRunning() == 1)]"
        completionHandler(text.data(using: .utf8))
    }

    // MARK: - Configuration

    private struct ProviderSettings {
        let wgConfig: String
        let gostHost: String
        let gostPort: UInt16
        let localPort: UInt16
        let serverPort: UInt16
        let debug: Bool
        let protocolFocus: String
        let forwards: [String]
    }

    private func readProviderConfiguration() throws -> ProviderSettings {
        guard let providerProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = providerProtocol.providerConfiguration as? [String: Any],
              let wgConfig = providerConfiguration["wgConfig"] as? String, !wgConfig.isEmpty,
              let gostHost = providerConfiguration["gostHost"] as? String, !gostHost.isEmpty else {
            throw TunnelError.savedProtocolConfigurationIsInvalid
        }

        func uint16Value(_ key: String, fallback: UInt16) -> UInt16 {
            if let s = providerConfiguration[key] as? String, let v = UInt16(s), v > 0 {
                return v
            }
            return fallback
        }

        let protocolFocus = providerConfiguration["protocolFocus"] as? String ?? "all"
        guard ["all", "sctp", "dccp"].contains(protocolFocus) else {
            throw TunnelError.savedProtocolConfigurationIsInvalid
        }

        return ProviderSettings(
            wgConfig: wgConfig,
            gostHost: gostHost,
            gostPort: uint16Value("gostPort", fallback: 12345),
            localPort: uint16Value("localPort", fallback: 51820),
            serverPort: uint16Value("serverPort", fallback: 51820),
            debug: (providerConfiguration["debug"] as? Bool) ?? false,
            protocolFocus: protocolFocus,
            forwards: (providerConfiguration["forwards"] as? [String]) ?? [])
    }

    /// Builds the gost service list: the WireGuard UDP forwarder plus any
    /// user-defined UDP port forwards. Rule format: "listenPort>host:port".
    private func gostServices(localPort: UInt16, serverPort: UInt16, forwards: [String]) -> [String] {
        var services = ["udp://:\(localPort)/127.0.0.1:\(serverPort)"]
        for rule in forwards {
            let parts = rule.split(separator: ">", maxSplits: 1)
            guard parts.count == 2,
                  let listen = UInt16(parts[0]), listen > 0,
                  !parts[1].isEmpty else {
                log.add("ignoring malformed forward rule: \(rule)")
                continue
            }
            services.append("udp://:\(listen)/\(parts[1])")
            log.add("forward: udp :\(listen) -> \(parts[1]) (over tunnel)")
        }
        return services
    }


    // MARK: - ICMP self-test

    /// Sends one ICMP echo request to the relay host over the same
    /// unprivileged socket type gost uses (SOCK_DGRAM + IPPROTO_ICMP) and
    /// reports whether the echo reply comes back. This separates "the NE
    /// sandbox blocks ICMP sockets" from "the network/server drops ICMP".
    private func icmpSelfTest(relayAddr: String) -> String {
        let host = relayAddr.split(separator: ":").first.map(String.init) ?? relayAddr
        var relayInAddr = in_addr()
        guard inet_pton(AF_INET, host, &relayInAddr) == 1 else {
            return "icmp self-test: cannot parse relay IP \(host)"
        }
        let ip = relayInAddr.s_addr

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard sock >= 0 else {
            return "icmp self-test: socket(SOCK_DGRAM, IPPROTO_ICMP) FAILED errno \(errno) — the extension sandbox blocks ICMP sockets"
        }
        defer { close(sock) }

        // 3 s receive timeout.
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Build an echo request; id/seq 0 — with DGRAM ICMP the kernel
        // assigns the identifier itself.
        var packet: [UInt8] = Array(repeating: 0, count: 8)
        packet[0] = 8 // ICMP echo request
        packet += Array("gostwg-probe".utf8) // 12-byte payload
        let checksum = icmpChecksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xff)

        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = 0
        sin.sin_addr = relayInAddr

        let sent = withUnsafePointer(to: &sin) { sinPtr in
            sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes { buf in
                    sendto(sock, buf.baseAddress, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            return "icmp self-test: sendto FAILED errno \(errno) — the sandbox or network blocks outbound ICMP echo"
        }

        var reply = [UInt8](repeating: 0, count: 128)
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var from = sockaddr_in()
        let start = Date()
        let n: Int = withUnsafeMutablePointer(to: &from) { fromPtr in
            fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                withUnsafeMutableBytes(of: &reply) { buf in
                    recvfrom(sock, buf.baseAddress, reply.count, 0, sa, &fromLen)
                }
            }
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard n >= 20, reply[0] == 0 else {
            return "icmp self-test: request SENT but NO echo reply within 3 s — network or server drops ICMP"
        }
        let replyPayload = String(bytes: reply[8..<20], encoding: .ascii) ?? "?"
        if replyPayload == "gostwg-probe" {
            return "icmp self-test: echo reply received in \(ms) ms — ICMP works end-to-end, the problem is inside gost's transport"
        }
        return "icmp self-test: got an echo reply (\(ms) ms) but payload mismatch: \(replyPayload)"
    }

    private func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let hi = UInt32(bytes[i]) << 8
            let lo = i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0
            sum += hi | lo
            i += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    private func parseWireGuardConfig(_ config: String) throws -> TunnelConfiguration {
        do {
            return try TunnelConfiguration(fromWgQuickConfig: config, called: "GostWG")
        } catch let error as TunnelConfiguration.ParseError {
            throw TunnelError.wireGuardConfigInvalid(String(describing: error))
        } catch {
            throw TunnelError.wireGuardConfigInvalid(String(describing: error))
        }
    }

    /// Builds the gost relay node address ("host:port" with IPv6 brackets),
    /// resolving the hostname to a literal IP before the tunnel's DNS
    /// settings take effect.
    private func gostRelayAddress(_ host: String, port: UInt16) throws -> String {
        // Normalize: user may paste a bare IPv6 literal without brackets.
        let bareHost: String
        if host.hasPrefix("[") && host.hasSuffix("]") {
            bareHost = String(host.dropFirst().dropLast())
        } else {
            bareHost = host
        }

        func formatted(_ hostPart: String, isIPv6: Bool) -> String {
            isIPv6 ? "[\(hostPart)]:\(port)" : "\(hostPart):\(port)"
        }

        switch NWEndpoint.Host(bareHost) {
        case .ipv6:
            return formatted(bareHost, isIPv6: true)
        case .ipv4:
            return formatted(bareHost, isIPv6: false)
        default:
            break // hostname: resolve below
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TunnelError.gostHostResolutionFailed(host)
        }
        // NWEndpoint.Host(hostString) parses IP literals into .ipv4/.ipv6 and
        // keeps hostnames as .name — DNSResolver relies on exactly that.
        let endpoint = Endpoint(host: NWEndpoint.Host(bareHost), port: nwPort)
        let results = DNSResolver.resolveSync(endpoints: [endpoint])
        guard let result = results.first, case .success(let resolvedEndpoint) = result else {
            throw TunnelError.gostHostResolutionFailed(host)
        }
        switch resolvedEndpoint.host {
        case .ipv6:
            return formatted("\(resolvedEndpoint.host)", isIPv6: true)
        default:
            return formatted("\(resolvedEndpoint.host)", isIPv6: false)
        }
    }
}

/// Local wg_log shim (the WireGuard app's shared logger is not vendored).
enum OSLogShim {
    static let tunnel = OSLog(subsystem: "com.gostwg.vpn.tunnel", category: "tunnel")
}

func wg_log(_ type: OSLogType, staticMessage message: StaticString) {
    os_log("%{public}@", log: OSLogShim.tunnel, type: type, "\(message)")
}

func wg_log(_ type: OSLogType, message: String) {
    os_log("%{public}@", log: OSLogShim.tunnel, type: type, message)
}
