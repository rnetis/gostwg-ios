#!/usr/bin/env bash
# Fetch external Go dependencies at pinned commits and apply the iOS patches.
#
#  - vendored/gost-x : go-gost/x cloned at GOST_X_COMMIT with patches/gost-x/*.patch
#                      applied (unprivileged ICMP transport for iOS).
#
# Run from the repository root:  ./scripts/fetch-deps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GOST_X_REPO="https://github.com/go-gost/x.git"
GOST_X_COMMIT="5503adeaebfe96642afa1d1b0e073bcfef6752eb"

mkdir -p vendored

if [ -d vendored/gost-x/.git ]; then
    echo "[fetch-deps] vendored/gost-x already present, resetting to ${GOST_X_COMMIT:0:12}..."
    git -C vendored/gost-x checkout -q "$GOST_X_COMMIT"
    git -C vendored/gost-x reset --hard -q "$GOST_X_COMMIT"
    git -C vendored/gost-x clean -qfd
else
    echo "[fetch-deps] cloning go-gost/x at ${GOST_X_COMMIT:0:12}..."
    rm -rf vendored/gost-x
    git clone "$GOST_X_REPO" vendored/gost-x
    git -C vendored/gost-x checkout -q "$GOST_X_COMMIT"
fi

echo "[fetch-deps] applying gost-x patches..."
for patch in "$ROOT"/patches/gost-x/*.patch; do
    [ -e "$patch" ] || continue
    # Skip silently if already applied (git apply fails on already-applied hunks).
    if git -C vendored/gost-x apply --check "$patch" 2>/dev/null; then
        git -C vendored/gost-x apply "$patch"
        echo "[fetch-deps]   applied $(basename "$patch")"
    else
        echo "[fetch-deps]   skipped $(basename "$patch") (already applied or conflicts)"
    fi
done

echo "[fetch-deps] done"
