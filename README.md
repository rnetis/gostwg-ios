# GostWG — WireGuard over gost `relay+icmp` for iOS

An iOS VPN app that reproduces this exact client setup on your phone:

```
gost -L udp://:51820/127.0.0.1:51820 -F "relay+icmp://wireguard.fqdn:12345"
```

…with wireguard-go attached to it, packed as a NetworkExtension packet-tunnel
app. All of your device's traffic goes into a WireGuard tunnel whose UDP
packets are carried to your server **inside ICMP echo request/reply packets**
(gost's `relay+icmp` transport = QUIC running over ICMP echo), where the gost
server hands them to the real WireGuard listener.

```
        iPhone (GostWG app)                                VPS
┌──────────────────────────────────┐          ┌──────────────────────────────┐
│  apps → NEPacketTunnelProvider   │          │  gost -L relay+icmp://:0     │
│          │ (wireguard-go)        │   ICMP   │        │ dials 127.0.0.1     │
│          ▼                       │   echo   │        ▼                     │
│  UDP 127.0.0.1:51820 (loopback)  │ ───────► │  WireGuard :51820            │
│          │ gost udp forwarder    │  QUIC/   │  (wg interface 172.17.172.1) │
│          └ relay+icmp client ────┘  ICMP    │                              │
└──────────────────────────────────┘          └──────────────────────────────┘
```

- The server side **does not change**: keep running
  `gost -L relay+icmp://:0` next to your WireGuard server (listen port 51820,
  phone peer = 172.17.172.2/32) exactly as you have it now.
- The app embeds two Go programs in the tunnel extension:
  [wireguard-go](https://github.com/WireGuard/wireguard-go) (the same engine
  the official iOS WireGuard app uses) and
  [gost](https://github.com/go-gost) (the same code the gost CLI runs),
  glued together in-process. The WireGuard `Endpoint` on the phone is
  `127.0.0.1:<localPort>` — the local gost forwarder — so there are no
  routing loops: iOS never routes the tunnel provider's own traffic back
  into its own tunnel.

## How it is built

| Piece | What it is |
|---|---|
| `go-api/` | Go module `golang.zx2c4.com/wireguard/apple` — upstream WireGuardKitGo API (`wgTurnOn`, `wgSetLogger`, …) **plus** `gostStart`/`gostStop` exports and the `gostsidecar` package that runs gost services in-process |
| `patches/gost-x/` | Two small patches to go-gost/x: (1) on iOS use **unprivileged ICMP echo sockets** (`SOCK_DGRAM + IPPROTO_ICMP`, like Apple's SimplePing) because iOS forbids raw sockets, with kernel-assigned echo ID adoption; (2) a logger override hook for embedding |
| `project/WireGuardKit/` | Vendored MIT-licensed WireGuardKit Swift sources (WireGuardAdapter, config parser, …) so the Xcode build has no SPM dependency |
| `project/GostWG/` | SwiftUI app: edit WireGuard config + relay address, connect, read logs |
| `project/Tunnel/` | `NEPacketTunnelProvider`: resolves the relay host, starts the gost sidecar, then brings up wireguard-go via `WireGuardAdapter` |
| `scripts/` | `fetch-deps.sh` (clone go-gost/x at pinned commit + apply patches), `build-go-framework.sh` (iOS static lib via `go build -buildmode c-archive`), `test-e2e-linux.sh` |
| `e2e/` | Linux end-to-end test that validates the whole data path (see below) |

## Getting an IPA

You don't need a Mac: the repo ships a GitHub Actions workflow that builds an
unsigned IPA on a macOS runner.

1. Push this repository to GitHub.
2. Actions → **Build unsigned IPA** → run it (it also runs on every push).
3. Download the `GostWG-unsigned-ipa` artifact.

Install options:

- **TrollStore**: import the IPA and install (entitlements for the packet
  tunnel provider are already embedded with ldid).
- **Sideloadly / AltStore / Xcode**: sideload normally — they re-sign with
  your Apple ID / developer identity.
- The phone must run **iOS 16+** (arm64 device builds only; no simulator
  slice is produced).

Building on your own Mac: `brew install go xcodegen`, then
`./scripts/fetch-deps.sh && ./scripts/build-go-framework.sh`, then
`cd project && xcodegen generate` and open `GostWG.xcodeproj`.

## Phone configuration

Server side (unchanged — for reference):

```ini
# /etc/wireguard/wg0.conf on the VPS
[Interface]
Address = 172.17.172.1/24
ListenPort = 51820
PrivateKey = <server private key>

[Peer]
## phone (client 2)
AllowedIPs = 172.17.172.2/32
PublicKey = /RK0o2Y/6ogcJuTibDmoQFW1ZSK07se4SKPVyffsCFs=
```

```bash
gost -L relay+icmp://:0
```

In the app, the defaults already match your setup:

- **WireGuard configuration** (wg-quick format). Note the Endpoint points at
  the embedded gost forwarder on loopback, *not* at the server:

  ```ini
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
  ```

- **Gost ICMP relay**: host `wireguard.fqdn`, relay port `12345` (the port in
  `relay+icmp://...:12345` — it becomes the ICMP echo identifier server-side),
  local UDP port `51820`, server-side WireGuard UDP port `51820`.

Tap **Connect**. First activation takes a couple of seconds (QUIC handshake
over ICMP + WireGuard handshake). Use **Refresh log** to see the extension
log if something misbehaves.

## MTU and throughput notes

- `relay+icmp` carries data in ICMP echo payloads (~1472 bytes of payload on
  a 1500 MTU path) and QUIC segments/retransmits on top of that, so the
  WireGuard interface MTU can stay at the usual 1380–1420. The default here
  is `1380`. If you see stalls, drop to `1280`.
- ICMP is the most deprioritized traffic class on the internet; expect
  higher latency/jitter than UDP-based transports. It shines precisely where
  UDP gets throttled or blocked.
- Throughput: the E2E test measures ~0.2 MB/s per sequential ping-pong
  stream through gost's UDP-over-ICMP forwarding. gost's UDP connection
  handling over the ICMP transport is burst-sensitive (relay connections
  rotate every few datagrams); WireGuard's and TCP's own retransmission
  absorb the occasional lost datagram, which is exactly how the same gost
  build behaves in the reference laptop setup. Interactive traffic
  (browsing, SSH, chat) is what this transport is for; avoid bulk
  downloads if it feels sluggish.

## Validation done on Linux (`e2e/`)

The repo contains an end-to-end test that reproduces the exact data path in
a network namespace: wireguard-go client (netstack, 172.17.172.2) → local
gost UDP forwarder (the same `gostsidecar` code the iOS app embeds) →
`relay+icmp` transport → official gost server → wireguard-go server
(172.17.172.1) with an in-tunnel TCP echo, using your real keys:

```
unshare -rn ./scripts/test-e2e-linux.sh
...
[e2e] PASS: 56 bytes round-tripped through WireGuard over gost relay+icmp in 14ms
[e2e] PASS: 128 KiB round-tripped in 2m14s (sustained, with retransmission)
```

What is verified there:

- your WireGuard keypairs derive the expected public keys,
- the exact gost service/node definitions the app embeds parse and run,
- QUIC-over-ICMP relay + UDP forwarding + WireGuard handshakes and data
  round-trips end to end.

The only path that cannot run in this Linux container is the
**unprivileged DGRAM-ICMP socket mode** (this container's kernel denies
`SOCK_DGRAM/IPPROTO_ICMP` even to root; the test supports
`--unprivileged` on hosts that allow it). That mode mirrors Apple's
SimplePing (unprivileged ICMP echo sockets) and is the mode used on iOS;
its framing/session code is shared with the raw-socket path that the E2E
test does exercise.

## Known limitations

- The relay server address is resolved once at tunnel start (before the
  tunnel's DNS is applied) and pinned for the session. Toggle the tunnel to
  re-resolve.
- On first release, reconnects after long sleep may need a tunnel toggle if
  the ICMP QUIC session was silently dropped by a NAT — WireGuard
  `PersistentKeepalive` mostly covers this.
- No on-demand rules / kill switch / split tunneling — this is a
  personal-use tool.
- iOS restriction: apps cannot create raw ICMP sockets, hence the
  unprivileged ICMP patch; some very restrictive networks (blocked ICMP
  entirely) will not work — by design, ICMP *is* the transport.

## License notes

- `go-api/api-apple.go`, `project/WireGuardKit/` — MIT, © WireGuard LLC /
  Jason A. Donenfeld (vendored from wireguard-apple).
- gost — MIT/ASL2 (go-gost). Patches kept minimal and documented.
- The rest — MIT.
