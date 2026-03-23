#!/bin/bash
# build-image.sh — Cross-compile the Rust daemon for Linux aarch64 (musl, static)
#                   and package it into an exFAT disk image (smol-bin.arm64.img).
#
# The resulting image replaces the original smol-bin.arm64.img and contains:
#   sdk-daemon        — our Rust janworkd daemon (static ELF aarch64)
#   srt-settings.json — network/filesystem security policy
#
# Usage:
#   ./build-image.sh              # build + package
#   ./build-image.sh --build-only # only cross-compile, skip image creation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
TARGET="aarch64-unknown-linux-musl"
BINARY="$SCRIPT_DIR/target/$TARGET/release/janworkd"
IMAGE_SIZE_MB=16
IMAGE_NAME="smol-bin.arm64.img"
IMAGE_OUT="$VM_DIR/$IMAGE_NAME"
VOLUME_NAME="SDK_DAEMON"

export PATH="$HOME/.cargo/bin:$PATH"

echo "=== Cross-compiling janworkd for $TARGET ==="
cd "$SCRIPT_DIR"

# Ensure target is installed
rustup target add "$TARGET" 2>/dev/null || true

# Build static release binary
cargo build --target "$TARGET" --release 2>&1

echo ""
file "$BINARY"
ls -lh "$BINARY"

if [[ "${1:-}" == "--build-only" ]]; then
    echo "=== Build-only mode, skipping image creation ==="
    exit 0
fi

echo ""
echo "=== Creating exFAT disk image ($IMAGE_SIZE_MB MB) ==="

# Create blank image
TEMP_IMG=$(mktemp /tmp/smolbin.XXXXXX.img)
dd if=/dev/zero of="$TEMP_IMG" bs=1M count=$IMAGE_SIZE_MB 2>/dev/null
echo "  Created blank image: $TEMP_IMG"

# Attach as disk device (no auto-mount)
DEVICE=$(hdiutil attach -nomount "$TEMP_IMG" 2>/dev/null | awk '{print $1}')
echo "  Attached as: $DEVICE"

# Format as exFAT
newfs_exfat -v "$VOLUME_NAME" "$DEVICE" >/dev/null 2>&1
echo "  Formatted as exFAT (volume: $VOLUME_NAME)"

# Mount
MOUNT_POINT="/Volumes/$VOLUME_NAME"
diskutil mount "$DEVICE" >/dev/null 2>&1
echo "  Mounted at: $MOUNT_POINT"

# Copy files (matching original smol-bin layout)
cp "$BINARY" "$MOUNT_POINT/sdk-daemon"
cp "$SCRIPT_DIR/srt-settings.json" "$MOUNT_POINT/"

# Create a minimal sandbox-helper stub
cat > "$MOUNT_POINT/sandbox-helper" << 'STUB'
#!/bin/sh
# sandbox-helper stub — in production this applies seccomp-bpf filters
exec "$@"
STUB
chmod +x "$MOUNT_POINT/sandbox-helper"

echo ""
echo "  Image contents:"
ls -lh "$MOUNT_POINT/"

# Unmount and detach
diskutil unmount "$DEVICE" >/dev/null 2>&1
hdiutil detach "$DEVICE" >/dev/null 2>&1

# Move to final location
mv "$TEMP_IMG" "$IMAGE_OUT"

echo ""
echo "=== Done ==="
echo "  Image: $IMAGE_OUT"
ls -lh "$IMAGE_OUT"
echo ""
echo "  Verify with: hdiutil attach -readonly $IMAGE_OUT"
