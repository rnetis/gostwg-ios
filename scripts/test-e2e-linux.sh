#!/usr/bin/env bash
# Linux E2E test: validates the full GostWG data path:
#
#   wireguard-go client (netstack) -> local gost UDP listener (gostsidecar,
#   same code as the iOS app) -> relay+icmp transport -> official gost
#   server -> WireGuard server (netstack) -> in-tunnel TCP echo.
#
# Requirements: Linux, root (run inside a network namespace):
#       unshare -rn ./scripts/test-e2e-linux.sh
#
# Options:
#       --unprivileged  also run the client side with unprivileged ICMP sockets
#                       (GOST_ICMP_UNPRIVILEGED=1), which mirrors the iOS build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOST_BIN="${GOST_BIN:-$ROOT/.tools/gost}"
E2E_BIN="${E2E_BIN:-$ROOT/.tools/e2e}"

echo "[e2e-sh] building e2e harness..."
mkdir -p "$ROOT/.tools"
(cd "$ROOT" && go build -C "$ROOT/e2e" -o "$E2E_BIN" .)

if [ ! -x "$GOST_BIN" ]; then
    echo "[e2e-sh] GOST_BIN not found; building gost from go-gost/gost (requires network)"
    tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/go-gost/gost.git "$tmp/gost"
    (cd "$tmp/gost" && go build -o "$GOST_BIN" ./cmd/gost)
    rm -rf "$tmp"
fi

echo "[e2e-sh] bringing loopback up"
ip link set lo up 2>/dev/null || true

echo "[e2e-sh] allowing unprivileged ICMP ping sockets"
echo "0 2147483647" > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true

if [ "${1:-}" = "--unprivileged" ]; then
    echo "[e2e-sh] running E2E (unprivileged ICMP client mode = iOS mode)"
    exec "$E2E_BIN" -gost "$GOST_BIN" -unprivileged
else
    echo "[e2e-sh] running E2E (raw ICMP client mode)"
    exec "$E2E_BIN" -gost "$GOST_BIN"
fi
