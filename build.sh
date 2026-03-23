#!/bin/bash
# build.sh — Compiles Swift sources into a .node shared library for Node.js.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Paths ──
NODE_INCLUDE="$(node -e "console.log(require('path').join(process.execPath, '..', '..', 'include', 'node'))")"
OUTPUT_DIR="$SCRIPT_DIR/build"
OUTPUT="$OUTPUT_DIR/smolvm.node"

echo "=== SmolVM Build ==="
echo "Node headers: $NODE_INCLUDE"
echo "Output:       $OUTPUT"

mkdir -p "$OUTPUT_DIR"

# ── Compile Swift → .node (dynamic library) ──
# -emit-library:        produce a .dylib
# -module-name SmolVM:  Swift module name
# -I:                   include path for node_api.h
# -Xcc -DBUILDING_NODE_EXTENSION: tell node_api.h we're a native addon
# -Xlinker -undefined -Xlinker dynamic_lookup: resolve Node symbols at load time

SWIFT_FILES=(
    Sources/NAPIHelpers.swift
    Sources/JanworkVMManager.swift
    Sources/NAPIModule.swift
)

swiftc \
    "${SWIFT_FILES[@]}" \
    -emit-library \
    -module-name SmolVM \
    -I "$NODE_INCLUDE" \
    -Xcc -DBUILDING_NODE_EXTENSION \
    -Xcc -DNAPI_DISABLE_CPP_EXCEPTIONS \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    -Xlinker -install_name -Xlinker @rpath/smolvm.node \
    -framework Virtualization \
    -framework vmnet \
    -o "$OUTPUT" \
    -O

echo "=== Build complete: $OUTPUT ==="
ls -lh "$OUTPUT"
