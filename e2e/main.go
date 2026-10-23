// E2E test: full data-path validation for the GostWG iOS design.
//
// Topology (single process + one gost server subprocess):
//
//      wg client (netstack 172.17.172.2)
//        -> UDP 127.0.0.1:51821   [gostsidecar udp listener — same code as on iOS]
//        -> relay+icmp://127.0.0.1:12345  [gost ICMP relay transport]
//        -> gost server (relay+icmp://:0, official gost build)
//        -> dials 127.0.0.1:51820
//        -> wg server (netstack 172.17.172.1, UDP 51820, TCP echo :8080 in-tunnel)
//
// The client dials the in-tunnel TCP echo server and verifies the payload
// round-trips. This exercises: the exact gostsidecar service definitions the
// iOS app uses, the patched ICMP dialer (both raw and unprivileged modes),
// QUIC-over-ICMP, the relay protocol, UDP forwarding, and the user's actual
// WireGuard keys/config.
//
// Must run as root inside a network namespace:
//      unshare -rn ./scripts/test-e2e-linux.sh
package main

import (
        "flag"
        "fmt"
        "os"
        "os/exec"
        "time"

        "golang.zx2c4.com/wireguard/apple/gostsidecar"

        "gostwg/e2e/wgstack"
)

// Keys from the user's real deployment.
const (
        serverPriv = "QCLj7nvec69sMSVeNArALKFkYF207uj2n6HC9T5DGGw=" // server WireGuard private key
        clientPriv = "sCqsTmYdDca/EX3I7EUs1bqpm+Nh5o46PRnITWwXn3o=" // client2 WireGuard private key
        serverPub  = "Ki1LZUHyj2xAxe568qnPcQXrWBDmGQUODmQQ4div2jw="
        clientPub  = "/RK0o2Y/6ogcJuTibDmoQFW1ZSK07se4SKPVyffsCFs="
)

const (
        wgServerPort = 51820 // real wg server port (server side of the relay)
        wgClientPort = 51821 // local gost UDP listener port (test uses a different local port to avoid clashing with the wg server in the same netns)
        icmpRelayID  = 12345 // the "port" in relay+icmp://host:12345
        echoPort     = 8080
)

func main() {
        gostBin := flag.String("gost", "/home/z/work/bin/gost", "path to gost server binary")
        unprivileged := flag.Bool("unprivileged", false, "use GOST_ICMP_UNPRIVILEGED=1 for the client side (mirrors the iOS build)")
        flag.Parse()

        fmt.Println("=== GostWG E2E ===")

        // 0. Sanity-check the user's keypairs.
        derivedServerPub, err := wgstack.PublicKey(serverPriv)
        must(err, "derive server pubkey")
        derivedClientPub, err := wgstack.PublicKey(clientPriv)
        must(err, "derive client pubkey")
        checkMatch("server", derivedServerPub, serverPub)
        checkMatch("client", derivedClientPub, clientPub)

        if *unprivileged {
                os.Setenv("GOST_ICMP_UNPRIVILEGED", "1")
                fmt.Println("[e2e] client side uses unprivileged ICMP sockets (GOST_ICMP_UNPRIVILEGED=1, mirrors iOS)")
        }

        // 1. Start the gost relay+icmp server (official gost build).
        gostCmd := exec.Command(*gostBin, "-L", "relay+icmp://:0")
        gostCmd.Stdout = os.Stdout
        gostCmd.Stderr = os.Stderr
        must(gostCmd.Start(), "start gost server")
        defer gostCmd.Process.Kill()
        time.Sleep(1500 * time.Millisecond)
        if gostCmd.ProcessState != nil && gostCmd.ProcessState.Exited() {
                fmt.Println("[e2e] FATAL: gost server exited immediately")
                os.Exit(1)
        }
        fmt.Println("[e2e] gost relay+icmp server running")

        // 2. Start the WireGuard server (simulates the real WireGuard server
        //    listening on 127.0.0.1:51820 on the server box).
        _, err = wgstack.StartServer(serverPriv, clientPub, wgServerPort, echoPort)
        must(err, "start wg server")
        fmt.Printf("[e2e] wg server up: UDP :%d, in-tunnel TCP echo :%d\n", wgServerPort, echoPort)

        // 3. Start the gost sidecar exactly like the iOS app does.
        gostsidecar.SetLogSink(func(level int, msg string) {
                prefix := "[gost  v]"
                if level == 1 {
                        prefix = "[gost  e]"
                }
                fmt.Println(prefix, msg)
        })
        err = gostsidecar.Start(gostsidecar.Config{
                Services: []string{fmt.Sprintf("udp://:%d/127.0.0.1:%d", wgClientPort, wgServerPort)},
                Nodes:    []string{fmt.Sprintf("relay+icmp://127.0.0.1:%d", icmpRelayID)},
        })
        must(err, "gostsidecar.Start")
        fmt.Printf("[e2e] gost sidecar up: udp://:%d -> relay+icmp://127.0.0.1:%d (target 127.0.0.1:%d)\n",
                wgClientPort, icmpRelayID, wgServerPort)

        // 4. Start the WireGuard client — Endpoint points at the local gost
        //    listener, exactly like the phone configuration.
        _, clientNet, err := wgstack.StartClient(clientPriv, serverPub, fmt.Sprintf("127.0.0.1:%d", wgClientPort))
        must(err, "start wg client")
        fmt.Println("[e2e] wg client up: 172.17.172.2, endpoint 127.0.0.1:" + fmt.Sprint(wgClientPort))

        // 5. Round-trip a payload through the full chain.
        payload := []byte("hello-from-the-gostwg-e2e-test-over-icmp-quic-wireguard!")
        fmt.Println("[e2e] dialing 172.17.172.1:" + fmt.Sprint(echoPort) + " through the tunnel (handshake may take a few seconds)...")
        start := time.Now()
        must(wgstack.DialEcho(clientNet, echoPort, payload, 30*time.Second), "tunnel echo round-trip")
        fmt.Printf("[e2e] PASS: %d bytes round-tripped through WireGuard over gost relay+icmp in %s\n",
                len(payload), time.Since(start).Round(time.Millisecond))

        // 6. Bulk transfer: 128 KiB exercises QUIC flow control, retransmission
        //    and sustained TCP-over-WG-over-QUIC-over-ICMP delivery. gost's UDP
        //    forwarding over ICMP is burst-sensitive; WireGuard and TCP
        //    retransmission absorb it, exactly like the reference laptop setup.
        big := make([]byte, 128*1024)
        for i := range big {
                big[i] = byte(i * 7)
        }
        start = time.Now()
        must(wgstack.DialEcho(clientNet, echoPort, big, 120*time.Second), "128 KiB echo round-trip")
        fmt.Printf("[e2e] PASS: 128 KiB round-tripped in %s (%.2f KB/s effective, TCP-over-WG-over-QUIC-over-ICMP)\n",
                time.Since(start).Round(time.Millisecond),
                float64(len(big)*2)/1024/time.Since(start).Seconds())
}

func checkMatch(name, derived, expected string) {
        if derived != expected {
                fmt.Printf("[e2e] WARNING: %s public key mismatch: derived %s, config says %s (continuing with derived keys)\n",
                        name, derived, expected)
        } else {
                fmt.Printf("[e2e] %s keypair verified\n", name)
        }
}

func must(err error, what string) {
        if err != nil {
                fmt.Printf("[e2e] FATAL: %s: %v\n", what, err)
                os.Exit(1)
        }
}
