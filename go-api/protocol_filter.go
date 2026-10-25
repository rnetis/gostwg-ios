// SPDX-License-Identifier: MIT

package main

import (
	"sync/atomic"

	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

// protocolFilterTUN enforces SCTP-only or DCCP-only mode at the packet
// boundary. Read is traffic from iOS toward WireGuard; Write is traffic from
// WireGuard back to iOS. The selected protocol number is 132 (SCTP) or 33
// (DCCP). All other packets are intentionally dropped in both directions.
type protocolFilterTUN struct {
	tun.Device
	focus        byte
	logger       *device.Logger
	droppedRead  atomic.Bool
	droppedWrite atomic.Bool
}

func newProtocolFilterTUN(inner tun.Device, focus byte, logger *device.Logger) tun.Device {
	return &protocolFilterTUN{Device: inner, focus: focus, logger: logger}
}

func (t *protocolFilterTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	for {
		n, err := t.Device.Read(bufs, sizes, offset)
		if n <= 0 {
			return n, err
		}
		kept := 0
		for i := 0; i < n; i++ {
			start, end := offset, offset+sizes[i]
			if start < 0 || end < start || end > len(bufs[i]) || !matchesIPProtocol(bufs[i][start:end], t.focus) {
				t.logDrop(&t.droppedRead, "iOS-to-WireGuard")
				continue
			}
			if kept != i {
				bufs[kept], sizes[kept] = bufs[i], sizes[i]
			}
			kept++
		}
		if kept > 0 || err != nil {
			return kept, err
		}
		// Every packet in this batch was filtered. Keep reading so WireGuard
		// does not mistake a policy drop for a tunnel shutdown or read error.
	}
}

func (t *protocolFilterTUN) Write(bufs [][]byte, offset int) (int, error) {
	processed := 0
	for i := range bufs {
		if offset < 0 || offset > len(bufs[i]) || !matchesIPProtocol(bufs[i][offset:], t.focus) {
			t.logDrop(&t.droppedWrite, "WireGuard-to-iOS")
			processed++
			continue
		}
		n, err := t.Device.Write(bufs[i:i+1], offset)
		processed += n
		if err != nil {
			return processed, err
		}
	}
	return processed, nil
}

func (t *protocolFilterTUN) logDrop(logged *atomic.Bool, direction string) {
	if logged.CompareAndSwap(false, true) {
		t.logger.Verbosef("Protocol focus dropped non-selected IP traffic (%s)", direction)
	}
}

// matchesIPProtocol classifies IPv4 and IPv6 packets by their upper-layer IP
// protocol. IPv6 extension headers are walked with strict bounds and a depth
// limit; malformed or opaque packets fail closed in focused modes.
func matchesIPProtocol(packet []byte, focus byte) bool {
	if len(packet) == 0 {
		return false
	}
	switch packet[0] >> 4 {
	case 4:
		if len(packet) < 20 {
			return false
		}
		headerLen := int(packet[0]&0x0f) * 4
		return headerLen >= 20 && headerLen <= len(packet) && packet[9] == focus
	case 6:
		if len(packet) < 40 {
			return false
		}
		next := packet[6]
		pos := 40
		for depth := 0; depth < 16; depth++ {
			switch next {
			case 0, 43, 60, 135, 139, 140: // IPv6 extension headers with 8-byte units.
				if pos+2 > len(packet) {
					return false
				}
				length := (int(packet[pos+1]) + 1) * 8
				if pos+length > len(packet) {
					return false
				}
				next = packet[pos]
				pos += length
			case 44: // Fragment header.
				if pos+8 > len(packet) {
					return false
				}
				next = packet[pos]
				pos += 8
			case 51: // Authentication Header uses 4-byte units.
				if pos+2 > len(packet) {
					return false
				}
				length := (int(packet[pos+1]) + 2) * 4
				if pos+length > len(packet) {
					return false
				}
				next = packet[pos]
				pos += length
			default:
				return next == focus
			}
		}
	}
	return false
}
