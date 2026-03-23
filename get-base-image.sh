#!/bin/bash
# get-base-image.sh — Download Ubuntu 22.04 cloud image and convert to raw format
#                      for use with Apple Virtualization.framework (VZEFIBootLoader).
#
# The Ubuntu 22.04 arm64 cloud image ships with a GPT partition table including
# an EFI System Partition (partition 15) with GRUB, so it boots via UEFI out of
# the box — no extra repartitioning needed.
#
# Usage:
#   ./get-base-image.sh              # download + convert
#   ./get-base-image.sh --size 10G   # custom disk size (default: 10G)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$SCRIPT_DIR/rootfs.img"
DISK_SIZE="10G"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size) DISK_SIZE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Ubuntu cloud image URL (select by host architecture)
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
    UBUNTU_URL="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-arm64.img"
    UBUNTU_FILE="ubuntu-22.04-server-cloudimg-arm64.img"
else
    UBUNTU_URL="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
    UBUNTU_FILE="ubuntu-22.04-server-cloudimg-amd64.img"
fi

echo "=== JanworkVM Base Image Setup ==="
echo ""

# ── Check if already exists ──

if [[ -f "$OUTPUT" ]]; then
    size=$(stat -f%z "$OUTPUT" 2>/dev/null || stat -c%s "$OUTPUT" 2>/dev/null)
    echo "rootfs.img already exists ($(echo "$size" | awk '{printf "%.1f GB", $1/1024/1024/1024}'))"
    echo "Delete it first if you want to re-download."
    exit 0
fi

# ── Check tools ──

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
if ! command -v qemu-img &>/dev/null; then
    echo "Error: qemu-img not found. Install with: brew install qemu"
    exit 1
fi

# ── Download ──

IMG_PATH="$SCRIPT_DIR/$UBUNTU_FILE"

if [[ -f "$IMG_PATH" ]]; then
    echo "Ubuntu cloud image already downloaded: $UBUNTU_FILE"
else
    echo "Downloading Ubuntu 22.04 cloud image ($ARCH)..."
    echo "  URL: $UBUNTU_URL"
    echo ""
    curl -L --progress-bar -o "$IMG_PATH" "$UBUNTU_URL"
fi

echo ""

# ── Convert QCOW2 → raw ──

echo "Converting QCOW2 → raw..."
qemu-img convert -f qcow2 -O raw "$IMG_PATH" "$OUTPUT"

echo "Resizing to $DISK_SIZE..."
qemu-img resize -f raw "$OUTPUT" "$DISK_SIZE" 2>/dev/null

echo ""
echo "Output: $OUTPUT ($(ls -lh "$OUTPUT" | awk '{print $5}') sparse)"

# ── Verify partition layout ──

echo ""
echo "Verifying partition layout..."
ATTACH_OUT=$(hdiutil attach "$OUTPUT" -nomount 2>&1)
DEVICE=$(echo "$ATTACH_OUT" | head -1 | awk '{print $1}')

echo "$ATTACH_OUT" | while IFS= read -r line; do
    echo "  $line"
done

# Check for EFI partition
if echo "$ATTACH_OUT" | grep -qi "EFI\|Apple_HFS\|Windows_FAT"; then
    echo ""
    echo "  ✓ EFI partition found — image is UEFI-bootable"
fi

hdiutil detach "$DEVICE" 2>/dev/null || true

echo ""
echo "=== Next steps ==="
echo ""
echo "  # 1. Build the Rust daemon (if not done yet)"
echo "  cd daemon && ./build-image.sh --build-only && cd .."
echo ""
echo "  # 2. Inject our daemon into the rootfs"
echo "  ./customize-rootfs.sh rootfs.img"
echo ""
echo "  # 3. Move to bundle and run"
echo "  mkdir -p bundle && cp rootfs.img bundle/"
echo "  node demo.mjs"
