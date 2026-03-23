#!/bin/bash
# sign.sh — Code-sign the .node binary with virtualization entitlement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_BIN="$SCRIPT_DIR/build/smolvm.node"

if [ ! -f "$NODE_BIN" ]; then
    echo "Error: $NODE_BIN not found. Run build.sh first."
    exit 1
fi

echo "=== Signing $NODE_BIN with virtualization entitlement ==="

codesign --force --sign - \
    --entitlements "$SCRIPT_DIR/entitlements.plist" \
    "$NODE_BIN"

echo "=== Also signing node binary (required for Virtualization.framework) ==="

NODE_PATH="$(which node)"
codesign --force --sign - \
    --entitlements "$SCRIPT_DIR/entitlements.plist" \
    "$NODE_PATH"

echo "=== Done ==="
codesign -d --entitlements - "$NODE_BIN" 2>/dev/null | head -20
