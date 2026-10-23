// Package wgstack spins up wireguard-go devices on gVisor netstack tun
// interfaces (no kernel TUN needed), simulating the phone-side WireGuard
// client and the server-side WireGuard listener for the E2E test.
package wgstack

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
	"golang.org/x/crypto/curve25519"
)

const (
	ServerTunnelIP = "172.17.172.1"
	ClientTunnelIP = "172.17.172.2"
)

func parseKey(b64 string) ([]byte, error) {
	k, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, err
	}
	if len(k) != 32 {
		return nil, fmt.Errorf("key must be 32 bytes, got %d", len(k))
	}
	return k, nil
}

// PublicKey derives the WireGuard public key from a base64 private key.
func PublicKey(privB64 string) (string, error) {
	priv, err := parseKey(privB64)
	if err != nil {
		return "", err
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}

func hexKey(b64 string) (string, error) {
	k, err := parseKey(b64)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(k), nil
}

// StartServer starts a wireguard-go "server" with a gVisor netstack:
//   - WireGuard listens on UDP <listenPort> (all interfaces)
//   - tunnel address 172.17.172.1
//   - a TCP echo server listens on 172.17.172.1:<echoPort> inside the tunnel
func StartServer(serverPrivB64, clientPubB64 string, listenPort, echoPort uint16) (*device.Device, error) {
	priv, err := hexKey(serverPrivB64)
	if err != nil {
		return nil, err
	}
	peerPub, err := hexKey(clientPubB64)
	if err != nil {
		return nil, err
	}

	tun, tunNet, err := netstack.CreateNetTUN(
		[]netip.Addr{netip.MustParseAddr(ServerTunnelIP)},
		[]netip.Addr{},
		1420)
	if err != nil {
		return nil, err
	}

	dev := device.NewDevice(tun, conn.NewStdNetBind(), device.NewLogger(device.LogLevelError, "wg-server: "))
	err = dev.IpcSet(fmt.Sprintf(
		"private_key=%s\nlisten_port=%d\nreplace_peers=true\npublic_key=%s\nallowed_ip=%s/32\n",
		priv, listenPort, peerPub, ClientTunnelIP))
	if err != nil {
		return nil, fmt.Errorf("server IpcSet: %w", err)
	}
	dev.Up()

	ln, err := tunNet.ListenTCP(&net.TCPAddr{Port: int(echoPort)})
	if err != nil {
		return nil, fmt.Errorf("netstack listen :%d: %w", echoPort, err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				io.Copy(c, c) // echo
			}()
		}
	}()

	return dev, nil
}

// StartClient starts a wireguard-go "client" with a gVisor netstack:
//   - tunnel address 172.17.172.2
//   - peer = server public key, endpoint = <endpoint> (the local gost UDP listener)
//   - AllowedIPs 0.0.0.0/0
//
// Use the returned Net to dial TCP connections through the tunnel.
func StartClient(clientPrivB64, serverPubB64, endpoint string) (*device.Device, *netstack.Net, error) {
	priv, err := hexKey(clientPrivB64)
	if err != nil {
		return nil, nil, err
	}
	peerPub, err := hexKey(serverPubB64)
	if err != nil {
		return nil, nil, err
	}

	tun, tunNet, err := netstack.CreateNetTUN(
		[]netip.Addr{netip.MustParseAddr(ClientTunnelIP)},
		[]netip.Addr{},
		1420)
	if err != nil {
		return nil, nil, err
	}

	dev := device.NewDevice(tun, conn.NewStdNetBind(), device.NewLogger(device.LogLevelError, "wg-client: "))
	err = dev.IpcSet(fmt.Sprintf(
		"private_key=%s\nreplace_peers=true\npublic_key=%s\nendpoint=%s\nallowed_ip=0.0.0.0/0\npersistent_keepalive_interval=25\n",
		priv, peerPub, endpoint))
	if err != nil {
		return nil, nil, fmt.Errorf("client IpcSet: %w", err)
	}
	dev.Up()

	return dev, tunNet, nil
}

// DialEcho dials the server's TCP echo service through the tunnel and
// performs a round-trip with the given payload. deadline bounds each read
// (TCP-over-WireGuard retransmits absorb datagram loss on the relay path).
func DialEcho(tunNet *netstack.Net, port uint16, payload []byte, deadline time.Duration) error {
	var lastErr error
	for attempt := 0; attempt < 30; attempt++ {
		c, err := tunNet.DialTCP(&net.TCPAddr{
			IP:   net.ParseIP(ServerTunnelIP),
			Port: int(port),
		})
		if err != nil {
			lastErr = err
			time.Sleep(time.Second)
			continue
		}

		if _, err := c.Write(payload); err != nil {
			lastErr = err
			c.Close()
			time.Sleep(time.Second)
			continue
		}
		buf := make([]byte, len(payload))
		c.SetReadDeadline(time.Now().Add(deadline))
		n, err := io.ReadFull(c, buf)
		if err != nil {
			lastErr = err
			c.Close()
			time.Sleep(time.Second)
			continue
		}
		if subtle.ConstantTimeCompare(buf[:n], payload) != 1 {
			return fmt.Errorf("echo mismatch: got %q", buf[:n])
		}
		return nil
	}
	return fmt.Errorf("dial/echo failed after retries: %w", lastErr)
}
