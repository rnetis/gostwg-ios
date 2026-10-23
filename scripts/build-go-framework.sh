#!/usr/bin/env bash
# Build the Go engine (wireguard-go + gost sidecar) as a static library for
# iOS, ready to be linked by the GostWGTunnel extension target.
#
# Output:
#   framework/libwg-go.a                  static lib (iphoneos arm64)
#   framework/include/wireguard.h         umbrella header (wg* + gost* exports)
#   framework/include/module.modulemap    Swift import module "WireGuardKitGo"
#
# Requirements (macOS): Xcode + Go >= 1.26 in PATH.
# Usage: scripts/build-go-framework.sh
#        (or invoked from the Xcode build phase with SRCROOT set)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRCROOT="${SRCROOT:-$REPO_ROOT/project}"
OUT_DIR="$SRCROOT/framework"
INCLUDE_DIR="$OUT_DIR/include"

# Idempotency: skip when the archive is newer than every Go source.
if [ -f "$OUT_DIR/libwg-go.a" ] && [ "${FORCE_GO_BUILD:-0}" != "1" ]; then
    if [ -z "$(find "$REPO_ROOT/go-api" "$REPO_ROOT/vendored/gost-x" -newer "$OUT_DIR/libwg-go.a" \( -name '*.go' -o -name 'go.mod' \) -print -quit 2>/dev/null)" ]; then
        echo "[go-framework] $OUT_DIR/libwg-go.a is up to date"
        exit 0
    fi
fi

command -v go >/dev/null 2>&1 || {
    # Xcode build phases run with a minimal PATH; add the usual Go locations.
    export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/local/go/bin:$PATH"
    [ -f "$HOME/go/bin/go" ] && export PATH="$HOME/go/bin:$PATH"
    [ -f "$HOME/sdk/go1.27.3/bin/go" ] && export PATH="$HOME/sdk/go1.27.3/bin:$PATH"
}
command -v go >/dev/null 2>&1 || { echo "[go-framework] ERROR: go not found in PATH" >&2; exit 1; }

# Dependencies: vendored gost-x with the iOS patches.
bash "$REPO_ROOT/scripts/fetch-deps.sh"

PLATFORM_NAME="${PLATFORM_NAME:-iphoneos}"
SDKROOT="$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)"
CC="$(xcrun --sdk "$PLATFORM_NAME" --find clang)"
ARCH="${ARCHS:-arm64}"
# Only device builds are produced; the tunnel extension targets devices.
if [ "$PLATFORM_NAME" != "iphoneos" ]; then
    echo "[go-framework] skipping Go build for non-device platform $PLATFORM_NAME"
    exit 0
fi

DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
CFLAGS="-isysroot $SDKROOT -arch $ARCH -miphoneos-version-min=$DEPLOYMENT_TARGET"

echo "[go-framework] building libwg-go.a ($PLATFORM_NAME $ARCH)..."
mkdir -p "$OUT_DIR" "$INCLUDE_DIR"

(
    cd "$REPO_ROOT/go-api"
    export GOOS=ios
    export GOARCH=arm64
    export CGO_ENABLED=1
    export CC="$CC"
    export CGO_CFLAGS="$CFLAGS"
    export CGO_LDFLAGS="$CFLAGS"
    go build -buildmode c-archive -trimpath -ldflags=-w -o "$OUT_DIR/libwg-go.a" .
)

# Clean up c-archive artifacts we don't need; keep only our own header set.
rm -f "$OUT_DIR"/*.h "$OUT_DIR"/*.syso 2>/dev/null || true
cp "$REPO_ROOT/go-api/wireguard.h" "$INCLUDE_DIR/wireguard.h"
cp "$REPO_ROOT/go-api/module.modulemap" "$INCLUDE_DIR/module.modulemap"

echo "[go-framework] done: $OUT_DIR/libwg-go.a"
